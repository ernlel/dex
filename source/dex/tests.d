/// Integration tests. Compiled only for `dub test`.
module dex.tests;

version (unittest):

import core.thread : Thread;
import core.time : dur;
import std.array : join, replicate;
import std.conv : to;
import std.file : exists, mkdirRecurse, rmdirRecurse, write;
import std.json : JSONType, JSONValue, parseJSON;
import std.path : buildPath;
import std.process : thisProcessID;
import std.socket;
import std.string : indexOf, split, startsWith, strip, toLower;

import dex;

private struct JsonUser
{
    int id;
    string name;
    bool active;
}

private struct TestResponse
{
    int status;
    string[string] headers;
    string body;
}

private struct TestConnection
{
    Socket socket;
    string buffer;
    string lastMethod;

    static TestConnection connect(ushort port)
    {
        auto socket = new Socket(AddressFamily.INET, SocketType.STREAM,
                                 ProtocolType.TCP);
        socket.connect(new InternetAddress("127.0.0.1", port));
        return TestConnection(socket, "", "");
    }

    void close()
    {
        if (socket !is null)
        {
            socket.close();
            socket = null;
        }
    }

    void send(string method, string target, string body = null,
              string contentType = null, string extraHeaders = null,
              bool keepAlive = true)
    {
        lastMethod = method;
        auto text = method ~ " " ~ target ~ " HTTP/1.1\r\n" ~
                    "Host: localhost\r\n" ~
                    "Connection: " ~ (keepAlive ? "keep-alive" : "close") ~
                    "\r\n";
        if (contentType.length)
            text ~= "Content-Type: " ~ contentType ~ "\r\n";
        if (body !is null)
            text ~= "Content-Length: " ~ to!string(body.length) ~ "\r\n";
        if (extraHeaders.length)
            text ~= extraHeaders;
        text ~= "\r\n";
        if (body !is null)
            text ~= body;
        sendRaw(text);
    }

    void sendRaw(string text)
    {
        sendAll(socket, text);
    }

    TestResponse read()
    {
        size_t headerEnd;
        while (true)
        {
            const found = buffer.indexOf("\r\n\r\n");
            if (found >= 0)
            {
                headerEnd = cast(size_t) found;
                break;
            }
            fill();
        }

        auto headerText = buffer[0 .. headerEnd];
        auto lines = headerText.split("\r\n");
        auto statusParts = lines[0].split();

        TestResponse response;
        response.status = to!int(statusParts[1]);
        foreach (line; lines[1 .. $])
        {
            const colon = line.indexOf(':');
            if (colon < 0)
                continue;
            response.headers[line[0 .. colon].toLower] =
                line[colon + 1 .. $].strip;
        }

        size_t length;
        if (auto contentLength = "content-length" in response.headers)
            length = to!size_t(*contentLength);
        if (lastMethod == "HEAD")
            length = 0;

        const total = headerEnd + 4 + length;
        while (buffer.length < total)
            fill();
        response.body = buffer[headerEnd + 4 .. total];
        buffer = buffer[total .. $];
        return response;
    }

    private void fill()
    {
        ubyte[8192] chunk;
        const received = socket.receive(chunk[]);
        if (received <= 0)
            throw new Exception("Connection closed while reading response");
        buffer ~= bytesToString(chunk[0 .. cast(size_t) received]);
    }
}

private string bytesToString(ubyte[] bytes)
{
    char[] result;
    result.length = bytes.length;
    foreach (i, byte_; bytes)
        result[i] = cast(char) byte_;
    return result.idup;
}

private void sendAll(Socket socket, const(void)[] data)
{
    size_t offset;
    while (offset < data.length)
    {
        const sent = socket.send(data[offset .. $]);
        if (sent <= 0)
            throw new Exception("Failed to send test request");
        offset += cast(size_t) sent;
    }
}

unittest
{
    auto app = new App;
    scope (exit) app.close();

    app.get("/", (req, res) { res.send("home"); });
    app.get("/users/:id", (req, res)
    {
        res.json(["id": req.params["id"], "q": req.queryParam("q")]);
    });
    app.get("/files/*", (req, res) { res.send(req.params["0"]); });
    app.get("/encoded/:name", (req, res) { res.send(req.params["name"]); });
    app.get("/tags", (req, res) { res.send(req.queryParams("tag").join(",")); });
    app.post("/echo", (req, res) { res.json(req.body); });
    app.get("/struct", (req, res) { res.json(JsonUser(1, "Ada", true)); });
    app.post("/type", (req, res) { res.send(req.isType("json") ? "yes" : "no"); });

    app.start(0, "127.0.0.1");
    auto connection = TestConnection.connect(app.port);
    scope (exit) connection.close();

    connection.send("GET", "/");
    auto response = connection.read();
    assert(response.status == 200);
    assert(response.body == "home");
    assert(response.headers["content-type"].startsWith("text/html"));

    connection.send("GET", "/USERS/42?q=hello%20world");
    response = connection.read();
    assert(response.status == 200);
    auto json = parseJSON(response.body);
    assert(json["id"].str == "42");
    assert(json["q"].str == "hello world");

    connection.send("GET", "/files/a/b/c");
    response = connection.read();
    assert(response.body == "a/b/c");

    connection.send("GET", "/encoded/Ada%20Lovelace");
    response = connection.read();
    assert(response.body == "Ada Lovelace");

    connection.send("GET", "/tags?tag=a&tag=b");
    response = connection.read();
    assert(response.body == "a,b");

    connection.send("POST", "/echo", `{"x":1,"ok":true}`,
                    "application/json");
    response = connection.read();
    json = parseJSON(response.body);
    assert(json["x"].integer == 1);
    assert(json["ok"].type == JSONType.true_);

    connection.send("GET", "/struct");
    response = connection.read();
    json = parseJSON(response.body);
    assert(json["id"].integer == 1);
    assert(json["name"].str == "Ada");
    assert(json["active"].type == JSONType.true_);

    connection.send("POST", "/type", `{}`, "application/json");
    response = connection.read();
    assert(response.body == "yes");

    connection.send("GET", "/missing");
    response = connection.read();
    assert(response.status == 404);
    assert(response.body == "Cannot GET /missing");
}

unittest
{
    auto app = new App;
    scope (exit) app.close();

    string[] events;
    app.use((req, res) { events ~= "auto"; });
    app.use((req, res, next) { events ~= "all"; next(); });
    app.use("/api", (req, res, next)
    {
        events ~= "api:" ~ req.path;
        next();
    });
    app.get("/api/items/:id", (req, res)
    {
        events ~= "route";
        res.send(req.params["id"]);
    });
    app.use("/blocked", (req, res, next) { res.status(403).send("blocked"); });
    app.get("/blocked/x", (req, res) { res.send("should not run"); });

    app.start(0, "127.0.0.1");
    auto connection = TestConnection.connect(app.port);
    scope (exit) connection.close();

    connection.send("GET", "/api/items/9");
    auto response = connection.read();
    assert(response.status == 200);
    assert(response.body == "9");
    assert(events == ["auto", "all", "api:/items/9", "route"]);

    connection.send("GET", "/blocked/x");
    response = connection.read();
    assert(response.status == 403);
    assert(response.body == "blocked");
}

unittest
{
    auto app = new App;
    scope (exit) app.close();

    app.get("/teapot", (req, res) { throw new HttpError(418, "short and stout"); });
    app.get("/boom", (req, res) { throw new Exception("kaboom"); });
    app.use((Throwable error, Request req, Response res, Next next)
    {
        if (auto httpError = cast(HttpError) error)
            res.status(httpError.status).send("handled: " ~ httpError.msg);
        else
            res.status(598).send("handled unexpected");
    });

    app.start(0, "127.0.0.1");
    auto connection = TestConnection.connect(app.port);
    scope (exit) connection.close();

    connection.send("GET", "/teapot");
    auto response = connection.read();
    assert(response.status == 418);
    assert(response.body == "handled: short and stout");

    connection.send("GET", "/boom");
    response = connection.read();
    assert(response.status == 598);
    assert(response.body == "handled unexpected");
}

unittest
{
    auto app = new App;
    scope (exit) app.close();

    auto api = new Router;
    api.get("/users/:id", (req, res)
    {
        res.json([
            "id": req.params["id"],
            "base": req.baseUrl,
            "path": req.path,
            "url": req.url,
            "original": req.originalUrl
        ]);
    });
    app.use("/api/v1", api);

    auto versioned = new Router;
    versioned.get("/x", (req, res) { res.send(req.params["version"]); });
    app.use("/v/:version", versioned);

    app.start(0, "127.0.0.1");
    auto connection = TestConnection.connect(app.port);
    scope (exit) connection.close();

    connection.send("GET", "/api/v1/users/7");
    auto response = connection.read();
    auto json = parseJSON(response.body);
    assert(json["id"].str == "7");
    assert(json["base"].str == "/api/v1");
    assert(json["path"].str == "/users/7");
    assert(json["url"].str == "/users/7");
    assert(json["original"].str == "/api/v1/users/7");

    connection.send("GET", "/v/2/x");
    response = connection.read();
    assert(response.body == "2");
}

unittest
{
    auto app = new App;
    scope (exit) app.close();

    app.get("/fail", (req, res) { throw new HttpError(418); });
    app.get("/ok", (req, res) { res.send("ok"); });

    app.start(0, "127.0.0.1");
    auto connection = TestConnection.connect(app.port);
    scope (exit) connection.close();

    connection.send("GET", "/fail");
    auto response = connection.read();
    assert(response.status == 418);

    connection.send("HEAD", "/ok");
    response = connection.read();
    assert(response.status == 200);
    assert(response.body == "");
    assert(response.headers["content-length"] == "2");
}

unittest
{
    auto app = new App;
    scope (exit) app.close();

    app.get("/a", (req, res) { res.send("a"); });
    app.get("/b", (req, res) { res.send("b"); });
    app.post("/chunk", (req, res) { res.send(req.rawBody); });

    app.start(0, "127.0.0.1");
    auto connection = TestConnection.connect(app.port);
    scope (exit) connection.close();

    connection.send("GET", "/a", null, null, null, true);
    auto response = connection.read();
    assert(response.body == "a");

    connection.send("GET", "/b", null, null, null, true);
    response = connection.read();
    assert(response.body == "b");

    connection.sendRaw("POST /chunk HTTP/1.1\r\n" ~
                       "Host: localhost\r\n" ~
                       "Transfer-Encoding: chunked\r\n" ~
                       "Connection: close\r\n\r\n" ~
                       "5\r\nhello\r\n" ~
                       "6\r\n world\r\n" ~
                       "0\r\n\r\n");
    response = connection.read();
    assert(response.body == "hello world");
}

unittest
{
    auto app = new App;
    scope (exit) app.close();

    app.post("/form", (req, res) { res.json(req.body); });
    app.post("/field", (req, res)
    {
        JSONValue[string] values;
        values["name"] = JSONValue(req.bodyValue!string("name"));
        values["age"] = JSONValue(req.bodyValue!int("age"));
        res.json(values);
    });

    app.start(0, "127.0.0.1");
    auto connection = TestConnection.connect(app.port);
    scope (exit) connection.close();

    connection.send("POST", "/form", "name=Ada&tag=a&tag=b",
                    "application/x-www-form-urlencoded");
    auto response = connection.read();
    auto json = parseJSON(response.body);
    assert(json["name"].str == "Ada");
    assert(json["tag"].type == JSONType.array);
    assert(json["tag"].array[0].str == "a");
    assert(json["tag"].array[1].str == "b");

    connection.send("POST", "/field", `{"name":"Ada","age":36}`,
                    "application/json");
    response = connection.read();
    json = parseJSON(response.body);
    assert(json["name"].str == "Ada");
    assert(json["age"].integer == 36);
}

unittest
{
    auto app = new App;
    scope (exit) app.close();

    CookieOptions options;
    options.httpOnly = true;
    options.maxAge = dur!"days"(1);
    options.sameSite = SameSite.lax;

    app.get("/set", (req, res) { res.cookie("user", "Ada Lovelace", options).send("set"); });
    app.get("/read", (req, res)
    {
        auto value = req.cookie("user");
        res.send(value is null ? "none" : value);
    });
    app.get("/clear", (req, res) { res.clearCookie("user").send("cleared"); });
    app.get("/old", (req, res) { res.redirect("/new"); });
    app.get("/new", (req, res) { res.send("new"); });

    app.start(0, "127.0.0.1");
    auto connection = TestConnection.connect(app.port);
    scope (exit) connection.close();

    connection.send("GET", "/set");
    auto response = connection.read();
    const cookieHeader = response.headers["set-cookie"];
    assert(cookieHeader.startsWith("user=Ada%20Lovelace"));
    assert(cookieHeader.indexOf("HttpOnly") >= 0);
    assert(cookieHeader.indexOf("SameSite=Lax") >= 0);

    connection.send("GET", "/read", null, null,
                    "Cookie: user=Ada%20Lovelace\r\n");
    response = connection.read();
    assert(response.body == "Ada Lovelace");

    connection.send("GET", "/clear");
    response = connection.read();
    assert(response.headers["set-cookie"].indexOf("Max-Age=0") >= 0);

    connection.send("GET", "/old");
    response = connection.read();
    assert(response.status == 302);
    assert(response.headers["location"] == "/new");
}

unittest
{
    const root = buildPath("/tmp", "dex-static-" ~ to!string(thisProcessID));
    mkdirRecurse(root);
    scope (exit)
    {
        if (exists(root))
            rmdirRecurse(root);
    }
    write(buildPath(root, "index.html"), "<h1>index</h1>");
    write(buildPath(root, "app.js"), "console.log(1);");
    write(buildPath(root, ".hidden"), "secret");

    auto app = new App;
    scope (exit) app.close();
    app.use(serveStatic(root));
    app.get("/file", (req, res) { res.sendFile(buildPath(root, "app.js")); });

    app.start(0, "127.0.0.1");
    auto connection = TestConnection.connect(app.port);
    scope (exit) connection.close();

    connection.send("GET", "/");
    auto response = connection.read();
    assert(response.status == 200);
    assert(response.body == "<h1>index</h1>");
    assert(response.headers["content-type"].startsWith("text/html"));

    connection.send("GET", "/app.js");
    response = connection.read();
    assert(response.status == 200);
    assert(response.headers["content-type"].startsWith("text/javascript"));

    connection.send("GET", "/file");
    response = connection.read();
    assert(response.body == "console.log(1);");
    assert(response.headers["content-type"].startsWith("text/javascript"));

    connection.send("GET", "/.hidden");
    response = connection.read();
    assert(response.status == 404);

    connection.send("GET", "/../etc/passwd");
    response = connection.read();
    assert(response.status == 404);
}

unittest
{
    auto app = new App;
    scope (exit) app.close();

    app.get("/chain",
        (req, res, next) { res.set("x-one", "1"); next(); },
        (req, res, next) { res.set("x-two", "2"); next(); },
        (req, res) { res.send("chain"); });
    app.delete("/item", (req, res) { res.send("deleted"); });
    app.get("/status", (req, res) { res.sendStatus(201); });
    app.get("/empty", (req, res) { res.status(204).end(); });

    app.start(0, "127.0.0.1");
    auto connection = TestConnection.connect(app.port);
    scope (exit) connection.close();

    connection.send("GET", "/chain");
    auto response = connection.read();
    assert(response.body == "chain");
    assert(response.headers["x-one"] == "1");
    assert(response.headers["x-two"] == "2");

    connection.send("DELETE", "/item");
    response = connection.read();
    assert(response.body == "deleted");

    connection.send("GET", "/status");
    response = connection.read();
    assert(response.status == 201);
    assert(response.body == "Created");

    connection.send("GET", "/empty");
    response = connection.read();
    assert(response.status == 204);
    assert(response.body == "");
    assert("content-length" !in response.headers);
}

unittest
{
    auto app = new App;
    scope (exit) app.close();
    app.maxBodySize = 8;

    app.post("/body", (req, res) { res.send(req.rawBody); });
    app.start(0, "127.0.0.1");

    auto connection = TestConnection.connect(app.port);
    scope (exit) connection.close();
    connection.send("POST", "/body", "123456789", "text/plain");
    auto response = connection.read();
    assert(response.status == 413);
}


unittest
{
    auto app = new App;
    scope (exit) app.close();

    app.get("/stop", (req, res, next)
    {
        next(new HttpError(451, "blocked"));
    });
    app.use((Throwable error, Request req, Response res, Next next)
    {
        res.set("x-first", "1");
        next();
    });
    app.use((Throwable error, Request req, Response res, Next next)
    {
        if (auto httpError = cast(HttpError) error)
            res.status(httpError.status).send("second: " ~ httpError.msg);
        else
            res.status(599).send("second");
    });

    app.start(0, "127.0.0.1");
    auto connection = TestConnection.connect(app.port);
    scope (exit) connection.close();

    connection.send("GET", "/stop");
    auto response = connection.read();
    assert(response.status == 451);
    assert(response.headers["x-first"] == "1");
    assert(response.body == "second: blocked");
}

unittest
{
    auto app = new App;
    scope (exit) app.close();
    app.post("/echo", (req, res) { res.json(req.body); });
    app.start(0, "127.0.0.1");

    auto bad = TestConnection.connect(app.port);
    scope (exit) bad.close();
    bad.send("POST", "/echo", "{bad", "application/json");
    auto response = bad.read();
    assert(response.status == 400);

    auto expect = TestConnection.connect(app.port);
    scope (exit) expect.close();
    expect.sendRaw("POST /echo HTTP/1.1\r\n" ~
                   "Host: localhost\r\n" ~
                   "Content-Type: application/json\r\n" ~
                   "Content-Length: 7\r\n" ~
                   "Expect: 100-continue\r\n" ~
                   "Connection: close\r\n\r\n");
    auto interim = expect.read();
    assert(interim.status == 100);
    expect.sendRaw(`{"x":1}`);
    response = expect.read();
    assert(response.status == 200);
    assert(parseJSON(response.body)["x"].integer == 1);
}

unittest
{
    auto app = new App;
    scope (exit) app.close();

    string[] lines;
    app.use(logger((line) { lines ~= line; }));
    app.get("/missing", (req, res) { throw new HttpError(404, "gone"); });

    app.start(0, "127.0.0.1");
    auto connection = TestConnection.connect(app.port);
    connection.send("GET", "/missing");
    auto response = connection.read();
    assert(response.status == 404);
    connection.close();
    app.close();

    assert(lines.length == 1, lines.length ? lines[0] : "no log line");
    assert(lines[0].indexOf(" 404 ") >= 0, lines[0]);
}

// Regression: a header line split across TCP segments used to trigger an
// overlapping array copy in the reader and silently drop the connection.
unittest
{
    auto app = new App;
    scope (exit) app.close();
    app.get("/", (req, res) { res.send(req.get("x-long")); });
    app.start(0, "127.0.0.1");

    auto connection = TestConnection.connect(app.port);
    scope (exit) connection.close();
    const value = replicate("a", 300);
    connection.sendRaw("GET / HTTP/1.1\r\nHost: x\r\nX-Long: " ~ value[0 .. 200]);
    Thread.sleep(dur!"msecs"(50));
    connection.sendRaw(value[200 .. $] ~ "\r\n\r\n");
    connection.lastMethod = "GET";
    auto response = connection.read();
    assert(response.status == 200);
    assert(response.body == value);
}

// Pipelined requests and bodies larger than the coalescing/read chunk sizes.
unittest
{
    auto app = new App;
    scope (exit) app.close();
    app.get("/a", (req, res) { res.send("a"); });
    app.post("/len", (req, res) { res.send(to!string(req.rawBody.length)); });
    app.get("/big", (req, res) { res.send(replicate("x", 100_000)); });
    app.start(0, "127.0.0.1");

    auto connection = TestConnection.connect(app.port);
    scope (exit) connection.close();
    connection.sendRaw("GET /a HTTP/1.1\r\nHost: x\r\n\r\n" ~
                       "GET /a HTTP/1.1\r\nHost: x\r\n\r\n");
    connection.lastMethod = "GET";
    assert(connection.read().body == "a");
    assert(connection.read().body == "a");

    connection.send("POST", "/len", replicate("y", 200_000), "text/plain");
    assert(connection.read().body == "200000");

    connection.send("GET", "/big");
    assert(connection.read().body.length == 100_000);
}

// A mounted router's error handlers must not handle errors raised by the
// parent after the request left the sub-router.
unittest
{
    auto app = new App;
    scope (exit) app.close();
    app.logErrors = false;

    auto api = new Router;
    // A pass-through middleware (auth, logging...) puts the parent's
    // continuation inside this router's call stack.
    api.use((req, res, next) { next(); });
    api.get("/known", (req, res) { res.send("known"); });
    api.use((Throwable error, Request req, Response res, Next next)
    {
        res.status(500).send("api handler");
    });
    app.use("/api", api);
    app.get("/api/later", (req, res) { throw new HttpError(409, "parent"); });
    app.use((Throwable error, Request req, Response res, Next next)
    {
        res.status(499).send("app handler");
    });

    app.start(0, "127.0.0.1");
    auto connection = TestConnection.connect(app.port);
    scope (exit) connection.close();

    connection.send("GET", "/api/later");
    auto response = connection.read();
    assert(response.status == 499, response.body);
    assert(response.body == "app handler");
}

// Malformed JSON reaches app error handlers instead of a raw socket error,
// and routes that never read the body are unaffected by it.
unittest
{
    auto app = new App;
    scope (exit) app.close();
    app.post("/echo", (req, res) { res.json(req.body); });
    app.post("/ignore", (req, res) { res.send("ignored"); });
    app.use((Throwable error, Request req, Response res, Next next)
    {
        auto httpError = cast(HttpError) error;
        res.status(httpError ? httpError.status : 500)
           .json(["error": error.msg]);
    });

    app.start(0, "127.0.0.1");
    auto connection = TestConnection.connect(app.port);
    scope (exit) connection.close();

    connection.send("POST", "/echo", "{bad", "application/json");
    auto response = connection.read();
    assert(response.status == 400);
    assert(parseJSON(response.body)["error"].str == "Invalid JSON body");

    connection.send("POST", "/ignore", "{bad", "application/json");
    response = connection.read();
    assert(response.status == 200);
    assert(response.body == "ignored");
}

// `type()` must not allow CRLF header injection; `onFinish` is public.
unittest
{
    auto app = new App;
    scope (exit) app.close();
    app.logErrors = false;

    int finished;
    app.use((req, res, next) { res.onFinish((r) { ++finished; }); next(); });
    app.get("/inject", (req, res)
    {
        res.type("text/html\r\nX-Injected: 1").send("x");
    });

    app.start(0, "127.0.0.1");
    auto connection = TestConnection.connect(app.port);
    scope (exit) connection.close();

    connection.send("GET", "/inject");
    auto response = connection.read();
    assert(response.status == 500);
    assert("x-injected" !in response.headers);
    assert(finished == 1);
}

// Streaming sendFile with Range requests and Accept-Ranges.
unittest
{
    import std.file : write, remove;

    const testFile = "/tmp/dex-range-test-" ~ to!string(thisProcessID) ~ ".txt";
    write(testFile, "0123456789abcdefghijklmnopqrstuvwxyz");
    scope (exit)
    {
        if (exists(testFile))
            remove(testFile);
    }

    auto app = new App;
    scope (exit) app.close();
    app.get("/file", (req, res) { res.sendFile(testFile); });

    app.start(0, "127.0.0.1");
    auto connection = TestConnection.connect(app.port);
    scope (exit) connection.close();

    // Normal full file request
    connection.send("GET", "/file");
    auto response = connection.read();
    assert(response.status == 200);
    assert(response.headers["accept-ranges"] == "bytes");
    assert(response.body == "0123456789abcdefghijklmnopqrstuvwxyz");

    // Range: bytes=0-9 (first 10 bytes)
    connection.send("GET", "/file", null, null, "Range: bytes=0-9\r\n");
    response = connection.read();
    assert(response.status == 206);
    assert(response.headers["content-range"] == "bytes 0-9/36");
    assert(response.body == "0123456789");

    // Range: bytes=10-15
    connection.send("GET", "/file", null, null, "Range: bytes=10-15\r\n");
    response = connection.read();
    assert(response.status == 206);
    assert(response.headers["content-range"] == "bytes 10-15/36");
    assert(response.body == "abcdef");

    // Range: bytes=30- (from 30 to end)
    connection.send("GET", "/file", null, null, "Range: bytes=30-\r\n");
    response = connection.read();
    assert(response.status == 206);
    assert(response.headers["content-range"] == "bytes 30-35/36");
    assert(response.body == "uvwxyz");

    // Unsatisfiable Range: bytes=100-200
    connection.send("GET", "/file", null, null, "Range: bytes=100-200\r\n");
    response = connection.read();
    assert(response.status == 416);
    assert(response.headers["content-range"] == "bytes */36");
}

// Built-in cors and securityHeaders middleware.
unittest
{
    auto app = new App;
    scope (exit) app.close();

    CorsOptions corsOpt;
    corsOpt.origin = "https://example.com";
    corsOpt.credentials = true;

    SecurityOptions secOpt;
    secOpt.strictTransportSecurity = "max-age=31536000";

    app.use(cors(corsOpt));
    app.use(securityHeaders(secOpt));

    app.get("/api/data", (req, res) { res.json(["ok": true]); });

    app.start(0, "127.0.0.1");
    auto connection = TestConnection.connect(app.port);
    scope (exit) connection.close();

    // Normal GET: should receive CORS headers and Security headers
    connection.send("GET", "/api/data");
    auto response = connection.read();
    assert(response.status == 200);
    assert(response.headers["access-control-allow-origin"] == "https://example.com");
    assert(response.headers["access-control-allow-credentials"] == "true");
    assert(response.headers["vary"] == "Origin");
    assert(response.headers["x-content-type-options"] == "nosniff");
    assert(response.headers["x-frame-options"] == "SAMEORIGIN");
    assert(response.headers["strict-transport-security"] == "max-age=31536000");

    // Preflight OPTIONS request
    connection.send("OPTIONS", "/api/data", null, null,
                    "Access-Control-Request-Method: POST\r\n" ~
                    "Access-Control-Request-Headers: Authorization\r\n");
    response = connection.read();
    assert(response.status == 204);
    assert(response.headers["access-control-allow-origin"] == "https://example.com");
    assert(response.headers["access-control-allow-methods"] == "GET, POST, PUT, PATCH, DELETE, OPTIONS");
    assert(response.headers["access-control-allow-headers"] == "Authorization");
}

// Built-in template engine unit tests.
unittest
{
    import std.json : JSONValue, parseJSON;
    import dex.view : renderTemplate, escapeHtml;

    // 1. Variable interpolation & HTML escaping
    auto locals1 = parseJSON(`{"name": "Alice & Bob <tag>", "raw": "<b>bold</b>"}`);
    string tpl1 = "Hello, {{name}}! {{{raw}}} {{&raw}}";
    string out1 = renderTemplate(tpl1, locals1);
    assert(out1 == "Hello, Alice &amp; Bob &lt;tag&gt;! <b>bold</b> <b>bold</b>");

    // 2. Dot notation & index access
    auto locals2 = parseJSON(`{"user": {"profile": {"city": "Vilnius"}}, "tags": ["dlang", "dex"]}`);
    string tpl2 = "City: {{user.profile.city}}, First tag: {{tags.0}}, Second tag: {{tags.1}}";
    string out2 = renderTemplate(tpl2, locals2);
    assert(out2 == "City: Vilnius, First tag: dlang, Second tag: dex");

    // 3. Conditionals (if, unless, else, mustache inverted ^)
    auto locals3 = parseJSON(`{"admin": true, "guest": false, "emptyList": []}`);
    string tpl3 = "{{#if admin}}Admin{{else}}User{{/if}} | {{#unless guest}}NotGuest{{/unless}} | {{^emptyList}}NoItems{{else}}HasItems{{/emptyList}}";
    string out3 = renderTemplate(tpl3, locals3);
    assert(out3 == "Admin | NotGuest | NoItems");

    // 4. Loops (array of objects, primitives, @index, @first, @last)
    auto locals4 = parseJSON(`{"items": [{"name": "A"}, {"name": "B"}], "tags": ["one", "two"]}`);
    string tpl4 = "{{#each items}}[{{@index}}:{{name}}:first={{@first}}:last={{@last}}]{{/each}} | {{#each tags}}({{this}}){{/each}}";
    string out4 = renderTemplate(tpl4, locals4);
    assert(out4 == "[0:A:first=true:last=false][1:B:first=false:last=true] | (one)(two)");

    // 5. Comments
    string tpl5 = "Start{{! this is a comment }}Middle{{!-- long comment --}}End";
    string out5 = renderTemplate(tpl5, JSONValue(string[string].init));
    assert(out5 == "StartMiddleEnd");
}

// End-to-end view rendering with App and res.render()
unittest
{
    import std.datetime.systime : Clock;
    import std.file : mkdirRecurse, rmdirRecurse, tempDir, write;
    import std.path : buildPath;

    string testViewsDir = buildPath(tempDir(), "dex_test_views_" ~ to!string(Clock.currTime().toUnixTime()));
    mkdirRecurse(testViewsDir);
    scope (exit)
    {
        if (exists(testViewsDir))
            rmdirRecurse(testViewsDir);
    }

    // Create partial and main template
    write(buildPath(testViewsDir, "header.html"), "<header>Title: {{title}}</header>");
    write(buildPath(testViewsDir, "profile.html"), "{{> header}}\n<main>Welcome, {{name}}!</main>");

    struct UserLocals
    {
        string title;
        string name;
    }

    auto app = new App;
    scope (exit) app.close();

    app.setViews(testViewsDir);
    app.cacheViews = true;

    app.get("/profile", (req, res)
    {
        res.render("profile", UserLocals("My App", "Ernestas Leliuga"));
    });

    // Custom engine test
    app.engine("upper", (path, locals)
    {
        import std.file : readText;
        import std.string : toUpper;
        return readText(path).toUpper();
    });
    write(buildPath(testViewsDir, "custom.upper"), "custom content");
    app.get("/custom", (req, res)
    {
        res.render("custom.upper");
    });

    app.start(0, "127.0.0.1");
    auto connection = TestConnection.connect(app.port);
    scope (exit) connection.close();

    // GET /profile: verify rendered HTML and Content-Type
    connection.send("GET", "/profile");
    auto response = connection.read();
    assert(response.status == 200);
    assert(response.headers["content-type"] == "text/html; charset=utf-8");
    assert(response.body == "<header>Title: My App</header>\n<main>Welcome, Ernestas Leliuga!</main>");

    // GET /custom: verify custom engine
    connection.send("GET", "/custom");
    response = connection.read();
    assert(response.status == 200);
    assert(response.body == "CUSTOM CONTENT");
}

// Built-in compression middleware tests.
unittest
{
    import std.array : replicate;
    import std.zlib : HeaderFormat, UnCompress;

    auto app = new App;
    scope (exit) app.close();

    // Use compression with small threshold (50 bytes) for testing
    CompressionOptions compOpts;
    compOpts.threshold = 50;
    app.use(compression(compOpts));

    string largePayload = "Hello, dex compression world! ".replicate(20); // ~600 bytes
    string smallPayload = "short"; // 5 bytes

    app.get("/large", (req, res)
    {
        res.type("text/plain").send(largePayload);
    });

    app.get("/small", (req, res)
    {
        res.type("text/plain").send(smallPayload);
    });

    app.get("/binary", (req, res)
    {
        res.type("bin").send(largePayload);
    });

    app.start(0, "127.0.0.1");
    auto connection = TestConnection.connect(app.port);
    scope (exit) connection.close();

    // 1. Gzip compression on large compressible payload
    connection.send("GET", "/large", null, null, "Accept-Encoding: gzip, deflate\r\n");
    auto response = connection.read();
    assert(response.status == 200);
    assert(response.headers["content-encoding"] == "gzip");
    assert(response.headers["vary"] == "Accept-Encoding");
    auto ucmp = new UnCompress(HeaderFormat.gzip);
    auto decompressed = cast(string) (ucmp.uncompress(cast(ubyte[]) response.body) ~ ucmp.flush());
    assert(decompressed == largePayload);

    // 2. Deflate compression when client only accepts deflate
    connection.send("GET", "/large", null, null, "Accept-Encoding: deflate\r\n");
    response = connection.read();
    assert(response.status == 200);
    assert(response.headers["content-encoding"] == "deflate");
    auto ucmpDeflate = new UnCompress(HeaderFormat.deflate);
    decompressed = cast(string) (ucmpDeflate.uncompress(cast(ubyte[]) response.body) ~ ucmpDeflate.flush());
    assert(decompressed == largePayload);

    // 3. Below threshold: must remain uncompressed
    connection.send("GET", "/small", null, null, "Accept-Encoding: gzip\r\n");
    response = connection.read();
    assert(response.status == 200);
    assert("content-encoding" !in response.headers);
    assert(response.body == smallPayload);

    // 4. Incompressible binary type: must remain uncompressed
    connection.send("GET", "/binary", null, null, "Accept-Encoding: gzip\r\n");
    response = connection.read();
    assert(response.status == 200);
    assert("content-encoding" !in response.headers);
    assert(response.body == largePayload);

    // 5. No Accept-Encoding header: must remain uncompressed
    connection.send("GET", "/large");
    response = connection.read();
    assert(response.status == 200);
    assert("content-encoding" !in response.headers);
    assert(response.body == largePayload);
}

// Built-in rate limiting middleware tests.
unittest
{
    import core.time : dur;

    auto app = new App;
    scope (exit) app.close();

    RateLimitOptions opts;
    opts.max = 2; // Allow only 2 requests
    opts.window = 5.dur!"seconds";
    opts.standardHeaders = true;
    opts.legacyHeaders = true;
    app.use(rateLimit(opts));

    app.get("/test", (req, res)
    {
        res.send("OK");
    });

    app.start(0, "127.0.0.1");
    auto connection = TestConnection.connect(app.port);
    scope (exit) connection.close();

    // 1. First request -> status 200, remaining = 1
    connection.send("GET", "/test");
    auto res1 = connection.read();
    assert(res1.status == 200);
    assert(res1.body == "OK");
    assert(res1.headers["ratelimit-limit"] == "2");
    assert(res1.headers["ratelimit-remaining"] == "1");
    assert("ratelimit-reset" in res1.headers);
    assert(res1.headers["x-ratelimit-limit"] == "2");
    assert(res1.headers["x-ratelimit-remaining"] == "1");

    // 2. Second request -> status 200, remaining = 0
    connection.send("GET", "/test");
    auto res2 = connection.read();
    assert(res2.status == 200);
    assert(res2.headers["ratelimit-remaining"] == "0");

    // 3. Third request -> status 429 Too Many Requests
    connection.send("GET", "/test");
    auto res3 = connection.read();
    assert(res3.status == 429);
    assert(res3.body == "Too Many Requests, please try again later.");
    assert("retry-after" in res3.headers);
    assert(res3.headers["ratelimit-remaining"] == "0");
}
