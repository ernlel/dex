/// Minimal HTTP/1.1 server used by `dex`.
module dex.server;

import core.atomic : atomicLoad, atomicOp, atomicStore;
import core.sync.mutex : Mutex;
import core.thread : Thread;
import core.time : Duration, dur;
import std.algorithm.comparison : max, min;
import std.algorithm.mutation : remove;
import std.array : appender, join;
import std.conv : ConvException, to;
import std.datetime : Clock;
import std.socket;
import std.stdio : File, stderr;
import std.string : indexOf, split, startsWith, strip, toLower;

import dex.app : App;
import dex.errors : HttpError;
import dex.http : hexValue, httpDate, isToken, reasonPhrase;
import dex.request : Request;
import dex.response : Response;

/// Bodies up to this size are sent in the same `send` call as the headers.
private enum coalesceLimit = 16 * 1024;

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

            // `getAddress` resolves host names and supports IPv6 literals.
            auto address = getAddress(host, port)[0];
            _listener = new Socket(address.addressFamily, SocketType.STREAM,
                                   ProtocolType.TCP);
            try
            {
                _listener.setOption(SocketOptionLevel.SOCKET,
                                    SocketOption.REUSEADDR, 1);
                _listener.bind(address);
                _listener.listen(128);
                _port = to!ushort(_listener.localAddress.toPortString);
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
            _connections = null;
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
        auto thread = new Thread({
            scope (exit)
            {
                atomicOp!"-="(_activeConnections, 1);
                untrack(Thread.getThis());
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
            untrack(thread);
            throw error;
        }
    }

    /// Forget a connection thread (it finished or never started).
    private void untrack(Thread thread)
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
    }

    private void connectionLoop(Socket socket)
    {
        socket.setOption(SocketOptionLevel.SOCKET, SocketOption.RCVTIMEO,
                         _idleTimeout);
        socket.setOption(SocketOptionLevel.SOCKET, SocketOption.SNDTIMEO,
                         _idleTimeout);
        // Responses are written in as few sends as possible; disable Nagle so
        // the last segment is not delayed waiting for an ACK.
        socket.setOption(SocketOptionLevel.TCP, SocketOption.TCP_NODELAY, 1);

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
            if (!isToken(name))
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
        if (response._filePath.length != 0)
        {
            streamFile(socket, request, response, keepAlive);
            return;
        }

        const status = response.statusCode;
        const noBody = status == 204 || status == 304 || status < 200;
        const sendBody = !noBody && request.method != "HEAD" &&
                         response._body.length != 0;
        const coalesce = sendBody && response._body.length <= coalesceLimit;

        auto output = appender!(char[]);
        output.reserve(256 + (coalesce ? response._body.length : 0));

        void header(scope const(char)[] name, scope const(char)[] value)
        {
            output.put(name);
            output.put(": ");
            output.put(value);
            output.put("\r\n");
        }

        output.put("HTTP/1.1 ");
        output.put(to!string(status));
        output.put(' ');
        output.put(reasonPhrase(status));
        output.put("\r\n");

        foreach (name, value; response._headers)
        {
            // Framing headers are always computed by the server.
            if (name == "connection" || name == "content-length" ||
                name == "transfer-encoding")
            {
                continue;
            }
            header(name, value);
        }

        if ("date" !in response._headers)
            header("Date", httpDate(Clock.currTime()));
        if ("server" !in response._headers)
            header("Server", "dex");

        foreach (cookie; response._setCookies)
            header("Set-Cookie", cookie);

        if (!noBody)
            header("Content-Length", to!string(response._body.length));
        header("Connection", keepAlive ? "keep-alive" : "close");
        output.put("\r\n");

        if (coalesce)
            output.put(cast(const(char)[]) response._body);

        sendAll(socket, output.data);
        if (sendBody && !coalesce)
            sendAll(socket, response._body);
    }

    private void streamFile(Socket socket, Request request, Response response,
                            bool keepAlive)
    {
        const fileSize = response._fileSize;
        int status = response.statusCode;
        ulong start = 0;
        ulong end = fileSize > 0 ? fileSize - 1 : 0;
        bool isRange = false;

        if (request.method == "GET" && status == 200)
        {
            if (auto rangeHeader = request.get("range"))
            {
                ByteRange br;
                if (parseByteRange(rangeHeader, fileSize, br))
                {
                    if (!br.satisfiable)
                    {
                        auto header = appender!(char[]);
                        header.put("HTTP/1.1 416 Range Not Satisfiable\r\n");
                        header.put("Content-Range: bytes */");
                        header.put(to!string(fileSize));
                        header.put("\r\nContent-Length: 0\r\nConnection: ");
                        header.put(keepAlive ? "keep-alive" : "close");
                        header.put("\r\n\r\n");
                        sendAll(socket, header.data);
                        return;
                    }
                    status = 206;
                    start = br.start;
                    end = br.end;
                    isRange = true;
                }
            }
        }

        const length = (fileSize == 0 || (isRange && start > end)) ? 0 : (end - start + 1);

        auto output = appender!(char[]);
        output.reserve(256);

        output.put("HTTP/1.1 ");
        output.put(to!string(status));
        output.put(' ');
        output.put(reasonPhrase(status));
        output.put("\r\n");

        foreach (name, value; response._headers)
        {
            if (name == "connection" || name == "content-length" ||
                name == "transfer-encoding" || name == "content-range" ||
                name == "accept-ranges")
            {
                continue;
            }
            output.put(name);
            output.put(": ");
            output.put(value);
            output.put("\r\n");
        }

        if ("date" !in response._headers)
        {
            output.put("Date: ");
            output.put(httpDate(Clock.currTime()));
            output.put("\r\n");
        }
        if ("server" !in response._headers)
            output.put("Server: dex\r\n");

        output.put("Accept-Ranges: bytes\r\n");
        if (isRange)
        {
            output.put("Content-Range: bytes ");
            output.put(to!string(start));
            output.put('-');
            output.put(to!string(end));
            output.put('/');
            output.put(to!string(fileSize));
            output.put("\r\n");
        }

        output.put("Content-Length: ");
        output.put(to!string(length));
        output.put("\r\n");

        output.put("Connection: ");
        output.put(keepAlive ? "keep-alive" : "close");
        output.put("\r\n\r\n");

        sendAll(socket, output.data);

        if (request.method != "HEAD" && length != 0)
        {
            auto file = File(response._filePath, "rb");
            if (start > 0)
                file.seek(cast(long) start);

            ubyte[65536] chunkBuf;
            ulong remaining = length;
            while (remaining > 0)
            {
                const toRead = cast(size_t) min(remaining, chunkBuf.length);
                const chunk = file.rawRead(chunkBuf[0 .. toRead]);
                if (chunk.length == 0)
                    break;
                sendAll(socket, chunk);
                remaining -= chunk.length;
            }
        }
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
            return socket.remoteAddress.toAddrString();
        catch (Exception)
            return "";
    }
}

private struct ByteRange
{
    ulong start;
    ulong end;
    bool satisfiable;
}

private bool parseByteRange(string header, ulong fileSize, out ByteRange range)
{
    header = header.strip;
    if (!header.startsWith("bytes="))
        return false;
    auto spec = header[6 .. $].strip;
    if (spec.indexOf(',') >= 0)
        return false;

    const dash = spec.indexOf('-');
    if (dash < 0)
        return false;

    auto first = spec[0 .. dash].strip;
    auto last = spec[dash + 1 .. $].strip;

    try
    {
        if (first.length == 0 && last.length == 0)
            return false;

        if (first.length == 0)
        {
            const suffix = to!ulong(last);
            if (suffix == 0)
                return false;
            range.start = suffix >= fileSize ? 0 : fileSize - suffix;
            range.end = fileSize > 0 ? fileSize - 1 : 0;
            range.satisfiable = fileSize > 0;
            return true;
        }

        range.start = to!ulong(first);
        if (range.start >= fileSize)
        {
            range.satisfiable = false;
            return true;
        }

        if (last.length == 0)
        {
            range.end = fileSize > 0 ? fileSize - 1 : 0;
            range.satisfiable = true;
            return true;
        }

        range.end = to!ulong(last);
        if (range.end >= fileSize)
            range.end = fileSize > 0 ? fileSize - 1 : 0;

        if (range.start > range.end)
        {
            range.satisfiable = false;
            return true;
        }

        range.satisfiable = true;
        return true;
    }
    catch (ConvException)
    {
        return false;
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

/// Buffered reader over a blocking socket.
///
/// The buffer is reused for the lifetime of the connection, so pipelined
/// bytes that belong to the next request are preserved. Anything returned to
/// callers is copied out of the buffer.
private struct SocketReader
{
    /// Initial buffer size and minimum growth step.
    private enum chunkSize = 16 * 1024;

    private Socket socket;
    private ubyte[] buffer; // buffer[start .. end] holds unread bytes
    private size_t start;
    private size_t end;
    private bool eof;

    this(Socket socket)
    {
        this.socket = socket;
    }

    /// Receive more bytes. Returns `false` once the peer closed the stream.
    private bool fill()
    {
        import core.stdc.string : memmove;

        if (eof)
            return false;

        if (start == end)
        {
            start = end = 0;
        }
        else if (start > 0 && end == buffer.length)
        {
            // Slide unread bytes to the front. Source and target may overlap,
            // which rules out slice assignment.
            memmove(buffer.ptr, buffer.ptr + start, end - start);
            end -= start;
            start = 0;
        }
        if (end == buffer.length)
            buffer.length = max(chunkSize, buffer.length * 2);

        const received = socket.receive(buffer[end .. $]);
        if (received <= 0)
        {
            eof = true;
            return false;
        }
        end += cast(size_t) received;
        return true;
    }

    /// Read one CRLF/LF-terminated line (terminator excluded).
    /// Returns `false` on a clean EOF before any byte of the line.
    bool readLine(ref string line, size_t maxLength)
    {
        size_t scanned; // bytes of buffer[start .. end] already searched
        while (true)
        {
            for (; start + scanned < end; ++scanned)
            {
                if (buffer[start + scanned] != '\n')
                    continue;

                size_t length = scanned;
                if (length > 0 && buffer[start + length - 1] == '\r')
                    --length;
                if (length > maxLength)
                    throw new HttpError(431, "Line too long");
                line = (cast(const(char)[]) buffer[start .. start + length]).idup;
                start += scanned + 1;
                return true;
            }

            // +1 leaves room for the CR of a line of exactly `maxLength`.
            if (scanned > maxLength + 1)
                throw new HttpError(431, "Line too long");
            if (!fill())
            {
                if (start < end)
                    throw new HttpError(400, "Unexpected end of request");
                return false;
            }
        }
    }

    /// Read exactly `length` bytes.
    ubyte[] readExact(size_t length)
    {
        ubyte[] result;
        readInto(result, length);
        return result;
    }

    /// Append exactly `length` bytes to `target`.
    ///
    /// The target grows as data arrives instead of being allocated up front,
    /// so a client cannot reserve `maxBodySize` per connection just by
    /// announcing a large `Content-Length`.
    private void readInto(ref ubyte[] target, size_t length)
    {
        const buffered = min(end - start, length);
        target ~= buffer[start .. start + buffered];
        start += buffered;

        size_t filled = target.length;
        const total = filled + (length - buffered);
        while (filled < total)
        {
            if (filled == target.length)
                target.length = min(total, max(filled * 2, chunkSize));
            const received = socket.receive(target[filled .. $]);
            if (received <= 0)
                throw new HttpError(400, "Unexpected end of request body");
            filled += cast(size_t) received;
        }
    }

    /// Read a `Transfer-Encoding: chunked` body. Trailers are discarded.
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
                skipTrailers(maxHeaderLength);
                return body;
            }

            if (size > maxLength - body.length)
                throw new HttpError(413, "Payload Too Large");
            readInto(body, size);

            string chunkEnd;
            if (!readLine(chunkEnd, 2) || chunkEnd.length != 0)
                throw new HttpError(400, "Malformed chunked body");
        }
    }

    private void skipTrailers(size_t maxHeaderLength)
    {
        size_t trailerBytes;
        size_t trailerCount;
        string line;
        while (true)
        {
            if (!readLine(line, maxHeaderLength))
                throw new HttpError(400, "Unexpected end of trailers");
            if (line.length == 0)
                return;
            trailerBytes += line.length + 2;
            if (trailerBytes > maxHeaderLength || ++trailerCount > 100)
                throw new HttpError(431, "Trailers too large");
        }
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
        const value = hexValue(c);
        if (value < 0)
            throw new HttpError(400, "Malformed chunk size");
        if (result > (size_t.max - value) / 16)
            throw new HttpError(413, "Payload Too Large");
        result = result * 16 + value;
    }
    return result;
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
