<p align="center">
  <a href="https://ernlel.github.io/dex/">
    <img src="docs/src/assets/dex-icon.png" width="120" height="120" alt="dex logo">
  </a>
</p>

<h1 align="center">dex</h1>

<p align="center">
  <b>Express-inspired, ergonomic web framework for the D programming language.</b><br>
  Zero dependencies outside Phobos · Built-in HTTP/1.1 server · Native compiled speed
</p>

<p align="center">
  <a href="https://github.com/ernlel/dex/actions/workflows/ci.yml"><img src="https://github.com/ernlel/dex/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <a href="https://ernlel.github.io/dex/"><img src="https://img.shields.io/badge/docs-GitHub%20Pages-blue.svg" alt="Documentation"></a>
  <a href="https://github.com/ernlel/dex/releases"><img src="https://img.shields.io/github/v/release/ernlel/dex?color=orange" alt="Release"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-yellow.svg" alt="License: MIT"></a>
</p>

---

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
            "name": "User Name"
        ]);
    });

    app.listen(3000, () {
        writeln("Listening on http://localhost:3000");
    });
}
```

## Features

- Express-style routing: `get`, `post`, `put`, `patch`, `delete`, `head`,
  `options`, `all`, `route(path)` fluent chaining, `router.param`, variadic
  handler chains, plus `route(method, path, handler)` for custom methods.
- `:param` segments, `*` wildcards, case-insensitive matching by default,
  optional trailing slash, automatic `HEAD` fallback to `GET`, and optional
  `405 Method Not Allowed` (`Allow` header).
- Middleware chains with `next()` and `next(error)`.
- Error middleware with the usual `(err, req, res, next)` shape.
- Mountable `Router`s with path stripping, `baseUrl`, and parameter merging.
- Lazy JSON, URL-encoded, and text request body parsing, plus typed
  reflection binding (`req.bind!T`, `req.bindQuery!T`) with `Nullable!T`,
  default values, and `@optional` support.
- Response helpers: `status`, `set`, `type`, `send`, `sendBytes`, `json`,
  `render`, `redirect`, `sendStatus`, `sendFile` / `download`, `etag`,
  content negotiation (`req.accepts` / `res.format`), and signed cookies.
- Automatic `ETag` generation and `If-None-Match` / `If-Modified-Since`
  `304 Not Modified` conditional request handling (`req.fresh` / `req.stale`).
- Reverse proxy awareness (`app.trustProxy`) for `req.ip`, `req.ips`,
  `req.protocol`, `req.secure`, and `req.hostname`.
- Static file middleware with traversal/symlink protection and `206 Partial Content`
  HTTP Range streaming.
- Reflection-based JSON serialization and deserialization (`dex.jsonx`) for
  structs, classes, arrays, associative arrays, enums, and `Nullable`.
- HTTP/1.1 keep-alive, chunked request bodies, `Expect: 100-continue`,
  configurable and per-route request size limits (`bodyLimit`), graceful
  shutdown with POSIX signal hooks, and a capped thread-per-connection server.
- Built-in middleware: `logger`, `serveStatic`, `cors`, `securityHeaders`,
  `compression` (gzip/deflate), `rateLimit`, `bodyLimit`, and `session`
  (HMAC-SHA256 signed cookies + `MemorySessionStore`).
- Built-in Handlebars/Mustache template engine (`res.render`) with variables,
  conditionals (`#if`, `#unless`), loops (`#each`), partials (`{{> partial}}`),
  and automatic XSS escaping.
- No third-party packages: only Phobos and druntime.

## Install

### Option 1: Using DUB (Package Manager)

Add `dex` to your `dub.json`:

```sh
dub add dex
```

Or add it to your `dub.json` dependencies manually:

```json
{
    "dependencies": {
        "dex": "~>0.5.0"
    }
}
```

Or as a local path dependency during development:

```json
{
    "dependencies": {
        "dex": {
            "path": "../dex"
        }
    }
}
```

Then run:

```sh
dub run
```

---

### Option 2: Manual Installation & Compilation (Without DUB)

Because `dex` has **zero external runtime dependencies** (it uses only standard Phobos and druntime), you do not need DUB to build or run applications. You can compile directly with **DMD** or **LDC**.

#### A. Direct Compilation with `-i` (Recommended)

Clone `dex` into your project or add it as a git submodule:

```sh
git clone https://github.com/ernlel/dex.git
# or: git submodule add https://github.com/ernlel/dex.git
```

Use D's compiler-assisted dependency resolution flag (`-i`) to automatically discover, compile, and link `dex` alongside your application:

```sh
# Using DMD:
dmd -i -Idex/source app.d -of=myapp

# Using LDC:
ldc2 -i -Idex/source app.d -of=myapp
```

Run your application:

```sh
./myapp
```

#### B. Build as a Static Library (`libdex.a`) via Makefile

You can build `libdex.a` using the included `Makefile`:

```sh
git clone https://github.com/ernlel/dex.git
cd dex

# Build release static library libdex.a:
make

# Run the test suite:
make test

# (Optional) Install libdex.a and module interfaces to /usr/local:
sudo make install
```

Compile and link your application against the static library:

```sh
# If installed system-wide:
dmd -I/usr/local/include/d/dex app.d -L-ldex -of=myapp

# Or using the local archive file:
dmd -Idex/source app.d dex/libdex.a -of=myapp
```

#### C. Download Pre-Packaged Release Archives

If you prefer not to use `git clone`, you can download minimal standalone release archives (~38 KiB) directly from the [GitHub Releases](https://github.com/ernlel/dex/releases) page. These contain only the essential library files (`source/dex/*.d`), `LICENSE`, `dub.json`, and `Makefile`:

```sh
# Download and extract the minimal source package:
curl -fsSL https://github.com/ernlel/dex/releases/download/v0.5.0/dex-0.5.0.tar.gz | tar -xz

# Compile your app against the unpacked sources:
dmd -i -Idex-0.5.0/source app.d -of=myapp
```

Precompiled Linux x86_64 binaries (`dex-0.5.0-linux-x86_64.tar.gz`) containing `libdex.a` are also available on each release.

Requires a recent D compiler (tested with DMD 2.113 / LDC 1.40).

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
| `cookies` / `signedCookies` | Parsed cookies and HMAC-verified signed cookies |
| `body`, `rawBody`, `maxBodySize` | Parsed body (`JSONValue`), deferred raw body, and active limit |
| `ip`, `ips`, `protocol`, `secure`, `xhr` | Connection & trusted-proxy information |
| `session` | Active `Session` when `session()` middleware is mounted |
| `get(name)` / `getValues(name)` | Header access |
| `param(name)` | Route parameter |
| `queryParam(name)` / `queryParams(name)` | Query access |
| `cookie(name)` / `signedCookie(name)` | Cookie and signed-cookie access |
| `hostname()` | `Host` (or trusted `X-Forwarded-Host`) without port |
| `contentType()` / `isType(type)` | Request content type check |
| `accepts(types...)` | `Accept` content negotiation |
| `fresh` / `stale` | Conditional caching freshness (`If-None-Match` / `If-Modified-Since`) |
| `bodyValue!T(name)` | Typed single body field |
| `bind!T()` / `bindQuery!T()` | Typed struct deserialization & validation for body / query |

`Request.is` cannot be used because `is` is a D keyword; use `isType`.

### Bodies

- `application/json` and `+json` types are parsed into `req.body`.
- `application/x-www-form-urlencoded` is parsed into an object; repeated keys
  become arrays.
- `text/*` becomes a JSON string.
- Other types leave `req.body` as `JSONValue(null)`; `req.rawBody` is always
  available.

Bodies are read and parsed lazily on first access (`req.rawBody`, `req.body`,
or `req.bind!T`), so invalid JSON produces a `400` `HttpError` when read (routes
that never inspect the body are unaffected) and per-route `bodyLimit()` rules
apply before reading oversized payloads.

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
| `render(view, [locals])` | Render a template via `dex.view` or custom engine |
| `end([text])` | End the response without setting a content type |
| `sendStatus(code)` | Send the status reason phrase |
| `redirect([code], location)` | Redirect, default 302 |
| `sendFile(path)` / `download(path, [name])` | Stream a file (with `ETag`/`304`/`206`) or download attachment |
| `etag(tag)` / `format(handlers)` | Set `ETag` or negotiate response by `Accept` header |
| `cookie(name, value, options)` / `signedCookie` | Set a plain or HMAC-SHA256 signed cookie |
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

res.json(User(1, "User Name", true));
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
serving. Files stream in 64 KiB chunks with `ETag`, `Last-Modified`,
`304 Not Modified`, and `206 Partial Content` byte-range support. Missing files
fall through to later handlers; traversal attempts and symlinks escaping the
root are ignored.

## Configuration

Set these on `App` before `start`/`listen`. Register routes and middleware
before starting the server; handlers and routing layers are shared by all
connection threads.

| Field | Default | Meaning |
|---|---|---|
| `idleTimeout` | 60 seconds | Keep-alive / socket read timeout |
| `shutdownTimeout` | 5 seconds | Graceful shutdown drain timeout for in-flight requests |
| `handleSignals` | true | Handle POSIX `SIGINT`/`SIGTERM` in `listen()` / `wait()` |
| `maxBodySize` | 10 MiB | Maximum request body (overridable per route via `bodyLimit`) |
| `maxHeaderSize` | 64 KiB | Maximum header block |
| `maxConnections` | 1024 | Concurrent connections (0 = unlimited) |
| `trustProxy` | disabled | Proxy trust policy (`bool`, hop count, or IP/CIDR list) |
| `etag` | true | Automatic `ETag` generation & `304 Not Modified` handling |
| `handleMethodNotAllowed` | false | Return `405` with `Allow` header when path exists for other methods |
| `cookieSecret` / `cookieSecrets` | null | HMAC-SHA256 secret(s) for signed cookies (supports rotation) |
| `showStackTraces` | false | Include exception text in 500 responses |
| `logErrors` | true | Log unhandled 5xx errors to stderr |
| `caseSensitive` | false | Case-sensitive route matching |

## Server

```d
app.listen(3000);                    // blocks; handles SIGINT/SIGTERM gracefully
app.start(0, "127.0.0.1");           // non-blocking; read app.port
app.wait();
app.close();                         // drains up to app.shutdownTimeout
app.close(dur!"seconds"(2));         // custom drain timeout
```

The built-in server supports HTTP/1.1 keep-alive, chunked request bodies,
`Expect: 100-continue`, graceful shutdown draining, and one thread per
connection with a configurable cap. TLS is not implemented; terminate TLS at a
reverse proxy and enable `app.trustProxy`.

## Errors

- Handlers may throw `HttpError(status, message)`.
- Unhandled exceptions become `500 Internal Server Error`.
- An unmatched request becomes `404 Cannot METHOD /path` (or `405 Method Not Allowed` when `app.handleMethodNotAllowed = true`).
- Error middleware is invoked in registration order after the failing layer.

## Limitations

- Handlers are synchronous. Respond before returning; asynchronous responses
  are not supported. Use a mutex (`core.sync.mutex.Mutex`) for shared state, as
  concurrent connections run on separate threads.
- HTTP/1.x (1.0 and 1.1); no HTTP/2, TLS, WebSockets, or multipart/form-data parsing.
- Route patterns support literals, `:name` parameters, and trailing `*`
  wildcards; no regular expressions.
- The listener binds IPv4 and IPv6 addresses via `getAddress(host, port)`
  (`0.0.0.0`, `127.0.0.1`, `::`, `::1`, hostnames).

## Examples

- `examples/hello` — minimal hello world with basic routes, parameters, JSON, and logger.
- `examples/todos` — thread-safe in-memory JSON CRUD API with sub-routers and mutex locking.
- `examples/api-server` — REST microservice featuring `trustProxy`, `rateLimit`, `compression`, `bodyLimit`, `router.param`, `req.bind!T` / `req.bindQuery!T`, `res.format`, Bearer auth, CORS, security headers, `405` handling, and graceful shutdown.
- `examples/file-server` — static asset and chunked media streaming server with `ETag`/`304`, `res.download`, custom cache headers, compression, and HTTP Range (`206 Partial Content`) support.
- `examples/views` — server-side HTML rendering using dex's built-in Handlebars/Mustache template engine, partials, and typed D structs.
- `examples/sessions` — HMAC-SHA256 signed cookies with key rotation and `session()` middleware (`MemorySessionStore`, `regenerate()`, `destroy()`).

```sh
cd examples/hello && dub run
cd examples/todos && dub run
cd examples/api-server && dub run
cd examples/file-server && dub run
cd examples/views && dub run
cd examples/sessions && dub run
```

### Testing `examples/api-server`:

```sh
# Health check
curl -i http://localhost:3000/health

# List products
curl -i http://localhost:3000/api/v1/products

# Filter products by category and search term
curl -i "http://localhost:3000/api/v1/products?category=electronics&search=mouse"

# Authenticate and get a Bearer token
curl -i -X POST http://localhost:3000/api/v1/auth/login \
  -H "Content-Type: application/json" \
  -d '{"username": "admin", "password": "dexpass"}'

# Create a product (requires Bearer token)
curl -i -X POST http://localhost:3000/api/v1/products \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer secret-token-123" \
  -d '{"name": "Wireless Headset", "category": "electronics", "price": 99.99}'
```

### Testing `examples/file-server`:

```sh
# Fetch static homepage
curl -i http://localhost:3000/

# Fetch file metadata list
curl -i http://localhost:3000/api/files

# Test HTTP Range streaming (206 Partial Content)
curl -i -H "Range: bytes=0-20" http://localhost:3000/media.txt

# Download file as attachment
curl -i http://localhost:3000/download/sample.txt
```

### Testing `examples/views`:

```sh
# Render homepage template with typed D struct locals
curl -i http://localhost:3000/

# Render about page
curl -i http://localhost:3000/about

# Render projects page
curl -i http://localhost:3000/projects
```

## Documentation site

All website and documentation sources live under `docs/src/`. The build
script (`docs/build.py`) copies the static landing page/assets and renders the
Markdown docs into the git-ignored `docs/dist/` directory alongside
`docs/dist/search-index.json` for client-side search.

```sh
python3 -m pip install -r docs/requirements.txt
make docs
```

Preview locally:

```sh
make docs-serve
# open http://localhost:8080
```

### Adding a page

1. Add `docs/src/<section>/<slug>.md` with front matter:

   ```md
   ---
   title: Page title
   description: One-sentence summary used in metadata and search results.
   ---
   ```

2. Add the slug to `docs/src/nav.json` in the desired section and order.
3. Run `make docs`.

Fenced code blocks are rendered with Pygments. Add a title for the code-frame
bar:

````md
```d title="source/app.d"
import dex;
```
````

Search indexes page titles, section headings, and body text. The docs header
has a search field; press `/` to focus it. Use <kbd>↑</kbd>/<kbd>↓</kbd> and
<kbd>Enter</kbd> to navigate results.

### Publish

On every release tag (`v*.*.*`), the [release workflow](.github/workflows/release.yml)
builds `docs/dist/` and deploys it to GitHub Pages automatically. You can also
trigger a manual deploy via the [Pages workflow](.github/workflows/pages.yml).

On a GitHub Pages project site, repository links are detected automatically.
If the site uses a custom domain, set `CONFIGURED_REPO_URL` in
`docs/src/script.js` to the repository URL. Example-directory links assume the
`main` branch; adjust them in `docs/src/script.js` if your default branch differs.

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

## Author

[@ernlel](https://github.com/ernlel)

## License

MIT &copy; 2026 [ernlel](https://github.com/ernlel). See [LICENSE](LICENSE).
