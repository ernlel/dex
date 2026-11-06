/// Minimal HTTP/1.1 server used by `dex`.
module dex.server;

import core.atomic : atomicLoad, atomicOp, atomicStore;
import core.sync.mutex : Mutex;
import core.thread : Thread;
import core.time : Duration, dur;
import std.algorithm.mutation : remove;
import std.array : appender, join;
import std.conv : ConvException, to;
import std.datetime : Clock;
import std.format : format;
import std.socket;
import std.stdio : stderr;
import std.string : indexOf, split, startsWith, strip, toLower;

import dex.app : App;
import dex.errors : HttpError;
import dex.http : httpDate, reasonPhrase;
import dex.request : Request;
import dex.response : Response;

package class HttpServer
{
    private App _app;
    private Socket _listener;
    private Thread _acceptThread;
    private shared bool _running;
    private shared size_t _activeConnections;
    private bool _started;
    private bool _closed;
    private ushort _port;
    private Duration _idleTimeout = dur!"seconds"(60);
    private size_t _maxBodySize;
    private size_t _maxHeaderSize;
    private size_t _maxConnections;

    private Mutex _lifecycleMutex;
    private Mutex _mutex;
    private Connection[] _connections;

    package this(App app)
    {
        _app = app;
        _lifecycleMutex = new Mutex;
        _mutex = new Mutex;
    }

    @property ushort port() const
    {
        return _port;
    }

    @property bool isRunning() const
    {
        return atomicLoad(_running);
    }

    package void start(ushort port, string host)
    {
        synchronized (_lifecycleMutex)
        {
            if (_started)
                throw new Exception("Server already started");

            _idleTimeout = _app.idleTimeout;
            _maxBodySize = _app.maxBodySize;
            _maxHeaderSize = _app.maxHeaderSize;
            _maxConnections = _app.maxConnections;

            auto address = new InternetAddress(host, port);
            _listener = new Socket(address.addressFamily, SocketType.STREAM,
                                   ProtocolType.TCP);
            try
            {
                _listener.setOption(SocketOptionLevel.SOCKET,
                                    SocketOption.REUSEADDR, 1);
                _listener.bind(address);
                _listener.listen(128);
                auto local = cast(InternetAddress) _listener.localAddress;
                _port = local.port;
            }
            catch (Throwable error)
            {
                _listener.close();
                _listener = null;
                throw error;
            }

            _started = true;
            _closed = false;
            atomicStore(_running, true);
            _acceptThread = new Thread(&acceptLoop);
            _acceptThread.isDaemon = false;
            try
            {
                _acceptThread.start();
            }
            catch (Throwable error)
            {
                _started = false;
                atomicStore(_running, false);
                _listener.close();
                _listener = null;
                throw error;
            }
        }
    }

    package void close()
    {
        synchronized (_lifecycleMutex)
        {
            if (!_started || _closed)
                return;
            _closed = true;
            atomicStore(_running, false);
        }

        if (_acceptThread !is null)
        {
            try _acceptThread.join();
            catch (Throwable) {}
        }

        Connection[] snapshot;
        synchronized (_mutex)
        {
            snapshot = _connections;
            _connections.length = 0;
        }

        foreach (ref connection; snapshot)
        {
            try connection.socket.shutdown(SocketShutdown.BOTH);
            catch (Throwable) {}
        }
        foreach (ref connection; snapshot)
        {
            if (connection.thread is Thread.getThis())
                continue;
            try connection.thread.join();
            catch (Throwable) {}
        }

        synchronized (_lifecycleMutex)
        {
            if (_listener !is null)
            {
                try _listener.close();
                catch (Throwable) {}
                _listener = null;
            }
            _started = false;
        }
    }

    private void acceptLoop()
    {
        auto readSet = new SocketSet;
        while (atomicLoad(_running))
        {
            try
            {
                readSet.reset();
                readSet.add(_listener);
                const ready = Socket.select(readSet, null, null,
                                            dur!"msecs"(200));
                if (ready <= 0)
                    continue;

                auto connection = _listener.accept();
                if (connection is null)
                    continue;

                if (_maxConnections != 0 &&
                    atomicLoad(_activeConnections) >= _maxConnections)
                {
                    sendError(connection, 503, "Service Unavailable");
                    connection.close();
                    continue;
                }

                atomicOp!"+="(_activeConnections, 1);
                try
                {
                    spawnConnection(connection);
                }
                catch (Throwable error)
                {
                    atomicOp!"-="(_activeConnections, 1);
                    try connection.close();
                    catch (Throwable) {}
                    stderr.writefln("dex: cannot start connection thread: %s",
                                    error.msg);
                }
            }
            catch (Throwable error)
            {
                if (!atomicLoad(_running))
                    break;
                stderr.writefln("dex: accept failed: %s", error.msg);
                Thread.sleep(dur!"msecs"(50));
            }
        }
    }

    private void spawnConnection(Socket socket)
    {
        Thread thread;
        thread = new Thread({
            scope (exit)
            {
                atomicOp!"-="(_activeConnections, 1);
                synchronized (_mutex)
                {
                    foreach (i, connection; _connections)
                    {
                        if (connection.thread is Thread.getThis())
                        {
                            _connections = _connections.remove(i);
                            break;
                        }
                    }
                }
            }

            try
            {
                connectionLoop(socket);
            }
            catch (Throwable)
            {
                // Client disconnects, timeouts and resets are normal.
            }
            finally
            {
                socket.close();
            }
        });
        thread.isDaemon = true;

        synchronized (_mutex)
            _connections ~= Connection(thread, socket);

        try
        {
            thread.start();
        }
        catch (Throwable error)
        {
            synchronized (_mutex)
            {
                foreach (i, connection; _connections)
                {
                    if (connection.thread is thread)
                    {
                        _connections = _connections.remove(i);
                        break;
                    }
                }
            }
            throw error;
        }
    }

    private void connectionLoop(Socket socket)
    {
        socket.setOption(SocketOptionLevel.SOCKET, SocketOption.RCVTIMEO,
                         _idleTimeout);
        socket.setOption(SocketOptionLevel.SOCKET, SocketOption.SNDTIMEO,
                         _idleTimeout);

        auto reader = SocketReader(socket);
        while (atomicLoad(_running))
        {
            RawRequest raw;
            try
            {
                if (!readRequest(reader, raw))
                    return;
            }
            catch (HttpError error)
            {
                sendError(socket, error.status, error.msg);
                return;
            }
            catch (Throwable)
            {
                return;
            }

            Request request;
            try
            {
                request = new Request(raw.method, raw.target, raw.httpVersion,
                                      raw.headers, raw.body, remoteIp(socket));
            }
            catch (HttpError error)
            {
                sendError(socket, error.status, error.msg);
                return;
            }
            auto response = new Response(request);

            try
            {
                _app.handle(request, response);
            }
            catch (Throwable)
            {
                if (!response.finished)
                    response.status(500).type("text")
                            .send("Internal Server Error");
            }

            bool keepAlive = raw.keepAlive && !response._forceClose;
            auto connectionHeader = response.get("connection");
            if (connectionHeader !is null &&
                connectionHeader.toLower.indexOf("close") >= 0)
            {
                keepAlive = false;
            }

            try
            {
                writeResponse(socket, request, response, keepAlive);
            }
            catch (Throwable)
            {
                return;
            }

            if (!keepAlive)
                return;
        }
    }

    private bool readRequest(ref SocketReader reader, out RawRequest raw)
    {
        raw = RawRequest.init;

        string line;
        if (!reader.readLine(line, 8192))
            return false;

        auto fields = line.split();
        if (fields.length != 3)
            throw new HttpError(400, "Malformed request line");

        const method = fields[0];
        const target = fields[1];
        const httpVersion = fields[2];

        if (!isToken(method))
            throw new HttpError(400, "Malformed request method");
        if (httpVersion != "HTTP/1.1" && httpVersion != "HTTP/1.0")
            throw new HttpError(505, "HTTP Version Not Supported");
        if (!target.length)
            throw new HttpError(400, "Malformed request target");
        foreach (const char c; target)
            if (c <= 0x20 || c == 0x7f)
                throw new HttpError(400, "Malformed request target");
        if (target != "*" && target[0] != '/' &&
            !target.startsWith("http://") && !target.startsWith("https://") &&
            method != "CONNECT")
        {
            throw new HttpError(400, "Unsupported request target");
        }

        string[][string] headers;
        size_t headerBytes;
        size_t headerCount;
        while (true)
        {
            if (!reader.readLine(line, _maxHeaderSize))
                throw new HttpError(400, "Unexpected end of headers");
            if (line.length == 0)
                break;

            headerBytes += line.length + 2;
            if (headerBytes > _maxHeaderSize)
                throw new HttpError(431, "Request headers too large");
            if (++headerCount > 100)
                throw new HttpError(431, "Too many request headers");
            if (line[0] == ' ' || line[0] == '\t')
                throw new HttpError(400, "Obsolete header folding is not supported");

            const colon = line.indexOf(':');
            if (colon <= 0)
                throw new HttpError(400, "Malformed header");

            const name = line[0 .. colon];
            foreach (const char c; name)
                if (!isToken(c))
                    throw new HttpError(400, "Malformed header name");

            auto value = line[colon + 1 .. $].strip;
            if (value.indexOf('\0') >= 0)
                throw new HttpError(400, "Malformed header value");
            headers[name.toLower] ~= value;
        }

        if (httpVersion == "HTTP/1.1")
        {
            auto hosts = "host" in headers;
            if (hosts is null || (*hosts).length != 1 || (*hosts)[0].length == 0)
                throw new HttpError(400, "Missing Host header");
        }

        size_t contentLength;
        bool hasContentLength;
        if (auto lengths = "content-length" in headers)
        {
            string first;
            foreach (value; *lengths)
            {
                if (value.length == 0)
                    throw new HttpError(400, "Malformed Content-Length");
                foreach (const char c; value)
                    if (c < '0' || c > '9')
                        throw new HttpError(400, "Malformed Content-Length");
                if (first.length == 0)
                    first = value;
                else if (value != first)
                    throw new HttpError(400, "Conflicting Content-Length headers");
            }
            try
                contentLength = to!size_t(first);
            catch (ConvException)
                throw new HttpError(413, "Payload Too Large");
            hasContentLength = true;
        }

        bool chunked;
        if (auto encodings = "transfer-encoding" in headers)
        {
            if (hasContentLength)
                throw new HttpError(400, "Content-Length and Transfer-Encoding together");

            bool sawChunked;
            foreach (token; (*encodings).join(",").split(','))
            {
                const value = token.strip.toLower;
                if (value.length == 0)
                    continue;
                if (value == "chunked")
                {
                    if (sawChunked)
                        throw new HttpError(400, "Duplicate chunked encoding");
                    sawChunked = true;
                }
                else
                {
                    throw new HttpError(400, "Unsupported transfer encoding");
                }
            }
            if (!sawChunked)
                throw new HttpError(400, "Malformed Transfer-Encoding");
            chunked = true;
        }

        if (contentLength > _maxBodySize)
            throw new HttpError(413, "Payload Too Large");

        if (auto expectations = "expect" in headers)
        {
            if ((*expectations).length == 0 ||
                (*expectations)[0].strip.toLower != "100-continue" ||
                httpVersion != "HTTP/1.1")
            {
                throw new HttpError(417, "Expectation Failed");
            }
            if (chunked || contentLength != 0)
                reader.sendRaw("HTTP/1.1 100 Continue\r\n\r\n");
        }

        ubyte[] body;
        if (chunked)
            body = reader.readChunked(_maxBodySize, _maxHeaderSize);
        else if (contentLength != 0)
            body = reader.readExact(contentLength);

        bool keepAlive = httpVersion == "HTTP/1.1";
        if (auto values = "connection" in headers)
        {
            foreach (token; (*values).join(",").split(','))
            {
                const value = token.strip.toLower;
                if (value == "close")
                    keepAlive = false;
                else if (value == "keep-alive")
                    keepAlive = true;
            }
        }

        raw.method = method;
        raw.target = target;
        raw.httpVersion = httpVersion;
        raw.headers = headers;
        raw.body = body;
        raw.keepAlive = keepAlive;
        return true;
    }

    private void writeResponse(Socket socket, Request request, Response response,
                               bool keepAlive)
    {
        auto header = appender!string;
        header ~= "HTTP/1.1 " ~ to!string(response.statusCode) ~ " " ~
            reasonPhrase(response.statusCode) ~ "\r\n";

        bool hasDate;
        bool hasServer;
        foreach (name, value; response._headers)
        {
            if (name == "connection" || name == "content-length" ||
                name == "transfer-encoding")
            {
                continue;
            }
            header ~= name ~ ": " ~ value ~ "\r\n";
            if (name == "date")
                hasDate = true;
            else if (name == "server")
                hasServer = true;
        }

        if (!hasDate)
            header ~= "Date: " ~ httpDate(Clock.currTime()) ~ "\r\n";
        if (!hasServer)
            header ~= "Server: dex\r\n";

        foreach (cookie; response._setCookies)
            header ~= "Set-Cookie: " ~ cookie ~ "\r\n";

        const noBody = response.statusCode == 204 || response.statusCode == 304 ||
                       response.statusCode < 200;
        if (!noBody)
        {
            header ~= "Content-Length: " ~ to!string(response._body.length) ~ "\r\n";
        }
        header ~= "Connection: " ~ (keepAlive ? "keep-alive" : "close") ~ "\r\n";
        header ~= "\r\n";

        sendAll(socket, header.data);

        if (!noBody && request.method != "HEAD" && response._body.length != 0)
            sendAll(socket, response._body);
    }

    private void sendError(Socket socket, int status, string message)
    {
        auto body = message.length ? message : reasonPhrase(status);
        auto header = "HTTP/1.1 " ~ to!string(status) ~ " " ~
            reasonPhrase(status) ~ "\r\n" ~
            "Content-Type: text/plain; charset=utf-8\r\n" ~
            "Content-Length: " ~ to!string(body.length) ~ "\r\n" ~
            "Connection: close\r\n\r\n";
        try
        {
            sendAll(socket, header);
            if (body.length)
                sendAll(socket, body);
        }
        catch (Throwable) {}
    }

    private string remoteIp(Socket socket)
    {
        try
        {
            auto address = socket.remoteAddress;
            if (auto inet = cast(InternetAddress) address)
            {
                const a = inet.addr;
                return format("%d.%d.%d.%d", (a >> 24) & 0xFF,
                              (a >> 16) & 0xFF, (a >> 8) & 0xFF, a & 0xFF);
            }
            return address.toString();
        }
        catch (Throwable)
        {
            return "";
        }
    }
}

private struct Connection
{
    Thread thread;
    Socket socket;
}

private struct RawRequest
{
    string method;
    string target;
    string httpVersion;
    string[][string] headers;
    ubyte[] body;
    bool keepAlive;
}

private struct SocketReader
{
    Socket socket;
    ubyte[] buffer;
    size_t start;
    size_t end;
    bool eof;

    this(Socket socket)
    {
        this.socket = socket;
    }

    private bool fill()
    {
        if (eof)
            return false;

        if (start == end)
        {
            start = 0;
            end = 0;
            buffer.length = 0;
        }
        else if (start > 0)
        {
            buffer[0 .. end - start] = buffer[start .. end];
            end -= start;
            start = 0;
            buffer.length = end;
        }

        ubyte[16384] chunk;
        const received = socket.receive(chunk[]);
        if (received <= 0)
        {
            eof = true;
            return false;
        }
        buffer ~= chunk[0 .. cast(size_t) received];
        end += cast(size_t) received;
        return true;
    }

    bool readLine(ref string line, size_t maxLength)
    {
        size_t scan = start;
        while (true)
        {
            for (; scan < end; ++scan)
                if (buffer[scan] == '\n')
                    break;

            if (scan < end)
            {
                auto lineEnd = scan;
                if (lineEnd > start && buffer[lineEnd - 1] == '\r')
                    --lineEnd;
                if (lineEnd - start > maxLength)
                    throw new HttpError(431, "Line too long");
                line = bytesToString(buffer[start .. lineEnd]);
                start = scan + 1;
                return true;
            }

            if (end - start > maxLength)
                throw new HttpError(431, "Line too long");
            if (!fill())
            {
                if (start < end)
                    throw new HttpError(400, "Unexpected end of request");
                return false;
            }
            scan = start;
        }
    }

    ubyte[] readExact(size_t length)
    {
        ubyte[] result = new ubyte[length];
        const buffered = end - start;
        const copied = buffered < length ? buffered : length;
        if (copied != 0)
        {
            result[0 .. copied] = buffer[start .. start + copied];
            start += copied;
        }

        size_t offset = copied;
        while (offset < length)
        {
            const received = socket.receive(result[offset .. $]);
            if (received <= 0)
                throw new HttpError(400, "Unexpected end of request body");
            offset += cast(size_t) received;
        }
        return result;
    }

    ubyte[] readChunked(size_t maxLength, size_t maxHeaderLength)
    {
        ubyte[] body;
        while (true)
        {
            string line;
            if (!readLine(line, 1024))
                throw new HttpError(400, "Unexpected end of chunked body");

            const semicolon = line.indexOf(';');
            const hex = (semicolon >= 0 ? line[0 .. semicolon] : line).strip;
            const size = parseChunkSize(hex);

            if (size == 0)
            {
                size_t trailerBytes;
                size_t trailerCount;
                while (true)
                {
                    if (!readLine(line, maxHeaderLength))
                        throw new HttpError(400, "Unexpected end of trailers");
                    if (line.length == 0)
                        break;
                    trailerBytes += line.length + 2;
                    if (trailerBytes > maxHeaderLength || ++trailerCount > 100)
                        throw new HttpError(431, "Trailers too large");
                }
                break;
            }

            if (size > maxLength - body.length)
                throw new HttpError(413, "Payload Too Large");
            body ~= readExact(size);

            string chunkEnd;
            if (!readLine(chunkEnd, 2) || chunkEnd.length != 0)
                throw new HttpError(400, "Malformed chunked body");
        }
        return body;
    }

    void sendRaw(const(char)[] data)
    {
        sendAll(socket, data);
    }
}

private size_t parseChunkSize(string hex)
{
    if (hex.length == 0 || hex.length > 15)
        throw new HttpError(400, "Malformed chunk size");

    size_t result;
    foreach (const char c; hex)
    {
        int value;
        if (c >= '0' && c <= '9')
            value = c - '0';
        else if (c >= 'a' && c <= 'f')
            value = c - 'a' + 10;
        else if (c >= 'A' && c <= 'F')
            value = c - 'A' + 10;
        else
            throw new HttpError(400, "Malformed chunk size");

        if (result > (size_t.max - value) / 16)
            throw new HttpError(413, "Payload Too Large");
        result = result * 16 + value;
    }
    return result;
}

private string bytesToString(ubyte[] bytes)
{
    char[] chars;
    chars.length = bytes.length;
    foreach (i, byte_; bytes)
        chars[i] = cast(char) byte_;
    return chars.idup;
}

private void sendAll(Socket socket, const(void)[] data)
{
    size_t offset;
    while (offset < data.length)
    {
        const sent = socket.send(data[offset .. $]);
        if (sent <= 0)
            throw new Exception("Failed to send response");
        offset += cast(size_t) sent;
    }
}

private bool isTokenChar(char c) pure nothrow @safe
{
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
           (c >= '0' && c <= '9') || c == '!' || c == '#' ||
           c == '$' || c == '%' || c == '&' || c == '\'' ||
           c == '*' || c == '+' || c == '-' || c == '.' ||
           c == '^' || c == '_' || c == '`' || c == '|' || c == '~';
}

private bool isToken(string value) pure nothrow @safe
{
    if (value.length == 0)
        return false;
    foreach (const char c; value)
        if (!isTokenChar(c))
            return false;
    return true;
}

private bool isToken(char c) pure nothrow @safe
{
    return isTokenChar(c);
}
