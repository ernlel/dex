# dex

Express-inspired web framework for D. Small surface area, zero dependencies
outside Phobos, and a built-in HTTP/1.1 server.

```d
import dex;
import std.stdio : writeln;

void main()
{
    auto app = new App;

    app.use(logger());

    app.get("/", (req, res) {
        res.send("Hello, world!");
    });

    app.get("/users/:id", (req, res) {
        res.json([
            "id": req.params["id"],
            "name": "Ada"
        ]);
    });

    app.listen(3000, () {
        writeln("Listening on http://localhost:3000");
    });
}
```

## Features

- Express-style routing: `get`, `post`, `put`, `patch`, `delete`, `head`,
  `options`, `all`, plus `route(method, path, handler)` for custom methods.
- `:param` segments, `*` wildcards, case-insensitive matching by default,
  optional trailing slash, automatic `HEAD` fallback to `GET`.
- Middleware chains with `next()` and `next(error)`.
- Error middleware with the usual `(err, req, res, next)` shape.
- Mountable `Router`s with path stripping, `baseUrl`, and parameter merging.
- JSON, URL-encoded, and text request body parsing.
- Response helpers: `status`, `set`, `type`, `send`, `sendBytes`, `json`,
  `redirect`, `sendStatus`, `sendFile`, cookies.
- Static file middleware with traversal and symlink escape protection.
- Reflection-based JSON serialization for structs, classes, arrays,
  associative arrays, enums, and `Nullable`.
- HTTP/1.1 keep-alive, chunked request bodies, `Expect: 100-continue`,
  request size limits, and a capped thread-per-connection server.
- No third-party packages: only Phobos and druntime.

## Install

Add this repository as a path dependency:

```json
{
    "dependencies": {
        "dex": {
            "path": "../dex"
        }
    }
}
```

Then:

```sh
dub run
```

Requires a recent D compiler and Dub (tested with DMD 2.113 / Dub 1.42).

## Routing

```d
app.get("/", handler);
app.post("/users", handler);
app.put("/users/:id", handler);
app.patch("/users/:id", handler);
app.delete("/users/:id", handler);
```

Route parameters are available through `req.params`:

```d
app.get("/users/:id", (req, res) {
    res.json(["id": req.params["id"]]);
});
```

A wildcard captures the rest of the path in `params["0"]`:

```d
app.get("/static/*", (req, res) {
    res.send(req.params["0"]); // "css/site.css"
});
```

Handlers are `(Request, Response)`. Routes can also take middleware before the
final handler:

```d
app.get("/admin",
    (req, res, next) {
        if (req.queryParam("token") != "secret")
            return res.status(401).send("Unauthorized");
        next();
    },
    (req, res) {
        res.send("Welcome, admin");
    });
```

Multiple middleware + handler combinations are provided:

```d
app.get(path, middleware, handler);
app.get(path, first, second);                 // both two-argument handlers
app.get(path, middleware1, middleware2, handler);
```

### Routers

```d
auto api = new Router;

api.get("/users/:id", (req, res) {
    res.json([
        "id": req.params["id"],
        "baseUrl": req.baseUrl,
        "path": req.path
    ]);
});

app.use("/api/v1", api);
```

A request to `/api/v1/users/42` invokes the router with `req.path` set to
`/users/42`, `req.baseUrl` set to `/api/v1`, and `req.params["id"]` equal to
`42`. Mount prefixes may contain parameters; they are merged into the child
route parameters.

## Middleware

```d
app.use((req, res, next) {
    res.set("x-powered-by", "dex");
    next();
});
```

Middleware mounted on a prefix sees the stripped path and can call `next()`:

```d
app.use("/admin", (req, res, next) {
    writeln("admin request: ", req.path);
    next();
});
```

A middleware that sends a response stops the chain. A middleware that returns
without sending and without calling `next()` falls through automatically, so
small "before" hooks do not hang requests.

Error middleware receives the error first:

```d
app.get("/fail", (req, res) {
    throw new HttpError(418, "short and stout");
});

app.use((Throwable err, Request req, Response res, Next next) {
    if (auto httpErr = cast(HttpError) err)
        res.status(httpErr.status).send(httpErr.msg);
    else
        res.status(500).send("Internal Server Error");
});
```

Register error middleware after the routes that should use it. Use `next()`
inside an error handler to delegate to the next error handler, or
`next(newError)` to replace the error.

Calling `next(error)` from normal middleware enters the error chain:

```d
app.get("/private", (req, res, next) {
    next(new HttpError(403, "Forbidden"));
});
```

## Request

Useful members:

| Member | Description |
|---|---|
| `method` | Uppercase HTTP method |
| `rawPath`, `path` | Encoded path and decoded path |
| `url`, `originalUrl`, `baseUrl` | Relative URL, original target, mount prefix |
| `queryString` | Raw query string |
| `params` | Route parameters |
| `query`, `queryAll` | Last query value per key, all values per key |
| `headers` | Headers keyed by lowercase name |
| `cookies` | Parsed cookies |
| `body`, `rawBody` | Parsed body (`JSONValue`) and raw body |
| `ip`, `protocol`, `secure`, `xhr` | Connection information |
| `get(name)` / `getValues(name)` | Header access |
| `param(name)` | Route parameter |
| `queryParam(name)` / `queryParams(name)` | Query access |
| `cookie(name)` | Cookie access |
| `hostname()` | Host header without port |
| `contentType()` / `isType(type)` | Request content type check |
| `bodyValue!T(name)` | Typed body field |

`Request.is` cannot be used because `is` is a D keyword; use `isType`.

### Bodies

- `application/json` and `+json` types are parsed into `req.body`.
- `application/x-www-form-urlencoded` is parsed into an object; repeated keys
  become arrays.
- `text/*` becomes a JSON string.
- Other types leave `req.body` as `JSONValue(null)`; `req.rawBody` is always
  available.

Invalid JSON produces a `400` response before handlers run.

## Response

```d
res.status(201)
   .set("x-request-id", "abc")
   .type("json")
   .send(`{"ok":true}`);
```

| Helper | Description |
|---|---|
| `status(code)` | Set status, chainable |
| `set(name, value)` / `header` | Set a header |
| `append(name, value)` | Append a header value |
| `get(name)` / `has(name)` | Inspect response headers |
| `type(type)` / `contentType` | Set `Content-Type` from MIME or extension |
| `send(text)` | Send text; defaults to `text/html` |
| `sendBytes(bytes)` | Send binary data |
| `json(value)` / `sendJson` | Serialize and send JSON |
| `end([text])` | End the response without setting a content type |
| `sendStatus(code)` | Send the status reason phrase |
| `redirect([code], location)` | Redirect, default 302 |
| `sendFile(path)` | Send a file from disk |
| `cookie(name, value, options)` | Set a cookie |
| `clearCookie(name, options)` | Expire a cookie |
| `closeConnection()` | Close the TCP connection after the response |
| `onFinish(callback)` | Register a callback run when response ends |

`res.statusCode`, `res.headersSent`, `res.finished`, `res.bodyBytes`, and
`res.bodyString` are also available.

### JSON

`res.json` accepts any value supported by `dex.jsonx.toJSONValue`:

```d
struct User
{
    int id;
    string name;
    bool active;
}

enum Role { admin, user }

res.json(User(1, "Ada", true));
```

Struct and class fields are serialized by name (including inherited fields).
Enums serialize as member names, `Nullable` as its value or `null`, arrays and
associative arrays recursively. A type can define
`JSONValue toJSON() const` to customize output.

### Cookies

```d
CookieOptions options;
options.httpOnly = true;
options.maxAge = dur!"days"(7);
options.sameSite = SameSite.lax;

res.cookie("session", token, options);
```

Values are percent-encoded and round-trip through `req.cookie`.

### Static files

```d
app.use(serveStatic("./public"));
app.use("/assets", serveStatic("./assets"));
```

`StaticOptions` controls the index file, cache control header, and dotfile
serving. Missing files fall through to later handlers. Traversal attempts and
symlinks escaping the root are ignored.

## Configuration

Set these on `App` before `start`/`listen`. Register routes and middleware
before starting the server; handlers and routing layers are shared by all
connection threads.

| Field | Default | Meaning |
|---|---|---|
| `idleTimeout` | 60 seconds | Keep-alive / socket read timeout |
| `maxBodySize` | 10 MiB | Maximum request body |
| `maxHeaderSize` | 64 KiB | Maximum header block |
| `maxConnections` | 1024 | Concurrent connections (0 = unlimited) |
| `showStackTraces` | false | Include exception text in 500 responses |
| `logErrors` | true | Log unhandled 5xx errors to stderr |
| `caseSensitive` | false | Case-sensitive route matching |

## Server

```d
app.listen(3000);                    // blocks
app.start(0, "127.0.0.1");           // non-blocking; read app.port
app.wait();
app.close();
```

The built-in server supports HTTP/1.1 keep-alive, chunked request bodies,
`Expect: 100-continue`, and one thread per connection with a configurable cap.
TLS is not implemented; terminate TLS at a reverse proxy.

## Errors

- Handlers may throw `HttpError(status, message)`.
- Unhandled exceptions become `500 Internal Server Error`.
- An unmatched request becomes `404 Cannot METHOD /path`.
- Error middleware is invoked in registration order after the failing layer.

## Limitations

- Handlers are synchronous. Respond before returning; asynchronous responses
  are not supported. Use a mutex (`core.sync.mutex.Mutex`) for shared state, as
  concurrent connections run on separate threads.
- HTTP/1.x (1.0 and 1.1); no HTTP/2, TLS, WebSockets, or multipart/form-data parsing.
- Route patterns support literals, `:name` parameters, and trailing `*`
  wildcards; no regular expressions.
- The listener binds IPv4 host addresses (`0.0.0.0`, `127.0.0.1`, hostnames).

## Examples

- `examples/hello` — basic routes, parameters, JSON, logger.
- `examples/todos` — in-memory JSON CRUD API with a router and a mutex.
- `examples/auth-cors` — Basic Auth plus CORS/preflight middleware.

```sh
cd examples/hello && dub run
cd examples/todos && dub run
cd examples/auth-cors && dub run
```

`examples/auth-cors` reads optional environment variables:

```sh
BASIC_AUTH_USER=admin BASIC_AUTH_PASS=secret CORS_ORIGIN='*' \
    dub run
```

With the defaults:

```sh
curl -i http://localhost:3000/api/me
curl -u admin:secret http://localhost:3000/api/me

curl -i -X OPTIONS http://localhost:3000/api/echo \
    -H 'Origin: https://app.example' \
    -H 'Access-Control-Request-Method: POST' \
    -H 'Access-Control-Request-Headers: content-type, authorization'
```

## Landing page

The static site in `docs/` is ready for GitHub Pages. It has no build step,
no package manager, and no external JavaScript.

To publish it:

1. Push the repository to GitHub.
2. Open **Settings → Pages**.
3. Choose **Deploy from a branch**.
4. Select the `main` branch and the `/docs` folder.

`docs/.nojekyll` is included, so GitHub Pages serves the files as-is.

Preview locally:

```sh
python3 -m http.server 8080 --directory docs
# open http://localhost:8080
```

On a GitHub Pages project site, repository links are detected automatically.
If the site uses a custom domain, set `CONFIGURED_REPO_URL` in
`docs/script.js` to the repository URL. Example-directory links assume the
`main` branch; adjust them in `docs/script.js` if your default branch differs.

## Development

```sh
dub build
dub test
```

`dub test` runs the integration suite against a real server on an ephemeral
port.

## Releases & Changelog

See [CHANGELOG.md](CHANGELOG.md) for release history and migration notes.
See [ROADMAP.md](ROADMAP.md) for planned features, upcoming milestones, and wishlist items.

## License

MIT. See `LICENSE`.
