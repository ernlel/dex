module dex.tests;

import core.time : dur;
import std.array : join;
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
