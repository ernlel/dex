# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.5.0] - 2026-11-17

### Added
- **Reverse Proxy Support (`app.trustProxy`)**: Added [`TrustProxy`](file:///home/ernest/Projects/dex/source/dex/http.d) supporting `bool`, hop counts, and IPv4/IPv6 CIDR ranges (plus `"loopback"`, `"linklocal"`, `"uniquelocal"` aliases). Derives `req.ip`, `req.ips`, `req.protocol`, `req.secure`, and `req.hostname` from `X-Forwarded-For`, `X-Forwarded-Proto`, and `X-Forwarded-Host` when trusted, and integrates with `rateLimit()`.
- **HTTP Caching & File Download Ergonomics (`ETag`, `304`, `res.download`)**: Added strong SHA-256 `ETag` generation on dynamic responses (`app.etag`), weak stat-based `ETag` generation in `sendFile`, `If-None-Match` and `If-Modified-Since` conditional request evaluation (`req.fresh` / `req.stale` returning `304 Not Modified`), and `res.download(filePath, filename)` with sanitized `Content-Disposition` (including RFC 5987 `filename*`).
- **Typed Request Deserialization & Validation (`req.bind!T`, `req.bindQuery!T`)**: Added reflection-based `fromJSONValue!T` and `fromStringMap!T` in `dex.jsonx`, supporting nested structs, `Nullable!T`, enums, arrays, default field values, the `@optional` UDA, custom `fromJSON` hooks, and descriptive `422`/`400` `HttpError` messages.
- **Router & Content Negotiation Ergonomics**: Added variadic middleware/handler chains on route methods and `use()`, `router.param(name, callback)` parameter pre-handlers, `app.route(path)` fluent `RouteChain` chaining, `req.accepts()` / `res.format()` content negotiation (`406 Not Acceptable`), and optional `405 Method Not Allowed` (`app.handleMethodNotAllowed`) with `Allow` headers.
- **Signed Cookies & Session Middleware (`dex.session`)**: Added HMAC-SHA256 `signCookie` / `unsignCookie` with key rotation (`app.cookieSecrets`), `CookieOptions.signed`, `res.signedCookie()`, `req.signedCookies` / `req.signedCookie()`, `SessionStore` interface, thread-safe `MemorySessionStore` with TTL expiration, and `session()` middleware (`req.session`).
- **Updated & New Examples**: Added `examples/sessions` and updated `examples/api-server` and `examples/file-server` to demonstrate `v0.4.0`–`v0.5.0` features; synced `README.md`, `docs/`, and `CHANGELOG.md`.

### Fixed
- **`Set-Cookie` emission in `streamFile`**: File streaming responses (`200`, `206`, and `416`) now emit `Set-Cookie` headers consistently with buffered responses.
- **Weakened `ETag` on compressed responses**: `compression()` now weakens strong `ETag` headers (`W/"..."`) when applying `Content-Encoding`.

## [0.4.0] - 2026-11-17

### Added
- **Built-in View Engine & Template System (`res.render`)**: Integrated Handlebars/Mustache-style templating with zero external dependencies (`dex.view`). Features variable interpolation (`{{var}}`), raw output (`{{{raw}}}` / `{{&raw}}`), conditionals (`{{#if}}`, `{{#unless}}`, `{{^inverted}}`), loops (`{{#each}}`) with `@index`, `@first`, `@last`, `@key`, partials (`{{> header}}`), automatic XSS escaping, `app.setViews()`, `app.viewEngine()`, `app.engine()`, and thread-safe template caching (`app.cacheViews`). Added `examples/views` and template engine guide.
- **Response Compression Middleware (`compression()`)**: Added Gzip and Deflate streaming compression via `std.zlib` with configurable byte threshold (`1024` default), compression level, custom MIME filter, automatic `Vary: Accept-Encoding`, and uncompressed fallback when compression does not reduce size.
- **Rate Limiting Middleware (`rateLimit()`)**: Added thread-safe in-memory rate limiting middleware with configurable `window`, `max`, `keyGenerator`, `skip`, custom `handler`, `429 Too Many Requests` + `Retry-After` responses, RFC `RateLimit-*` headers, and optional legacy `X-RateLimit-*` headers.
- **Per-Route Body Size Limits (`bodyLimit()`)**: Added deferred request body loading in `HttpServer` and `Request`, plus `bodyLimit(size_t maxBytes)` middleware so individual routes or sub-routers can either tighten or raise `app.maxBodySize` (including chunked bodies and `Expect: 100-continue`).
- **Graceful Server Shutdown**: Added configurable `app.shutdownTimeout` (5s default) and `app.close(timeout)` drain behavior that stops accepting new connections, immediately closes idle keep-alive sockets, sends `Connection: close` on in-flight responses, and waits for active requests to finish. Added automatic POSIX `SIGINT`/`SIGTERM` signal hooks in `app.listen()` / `app.wait()` (configurable via `app.handleSignals`).
- **Standalone Build & Release Packaging**: Added root `Makefile` (`make`, `make test`, `make install`, `make dist`, `make dist-bin`), manual non-DUB installation docs, and automated GitHub Release packaging workflow.
- **Examples & Brand Identity**: Replaced `examples/auth-cors` with `examples/api-server` and `examples/file-server`, and added logo/favicon/OG brand assets.

## [0.3.0] - 2026-11-06

### Added
- **Express-style documentation site**: Added multi-page starter guides (`installing.html`, `hello-world.html`, `basic-routing.html`, `static-files.html`, `faq.html`), deep guides (`routing.html`, `middleware.html`, `error-handling.html`), and API reference (`app.html`, `request.html`, `response.html`, `router.html`).
- **Standard `cors()` & `securityHeaders()` middleware**: Promoted CORS and Helmet-style security headers middleware into `dex.middleware` and exported them from top-level `dex`.
- **CI, Docs & License badges**: Added workflow and release badges to `README.md` and updated author/copyright metadata.

## [0.2.0] - 2026-11-06

### Fixed
- **Overlapping buffer move in `SocketReader.fill()`**: Fixed a critical memory move bug where partial TCP segments in multi-packet HTTP requests caused slice assignment corruption and unexpected connection termination.
- **CRLF header injection in `Response.type()`**: Sanitized custom MIME types and file extensions passed to `res.type()` to prevent HTTP response splitting.
- **Sub-router error handling isolation**: Fixed an issue where error middleware on mounted sub-routers was invoked for errors raised by parent routers after the sub-router had finished executing.
- **Qualified and special type JSON serialization**: Added proper support in `dex.jsonx` for `const`/`immutable` types (including `const JSONValue` and `const Nullable!T`), UTF character types (`isSomeChar`), and non-UTF-8 strings (`wstring`, `dstring`).
- **Unhandled `ConvException` in Todos example**: Handled non-numeric IDs in `examples/todos` to return `400 Bad Request` instead of uncaught 500 errors.
- Cleaned up uncommitted scratch file (`del.d`).

### Performance & Memory
- **Response coalescing & `TCP_NODELAY`**: Small response bodies (up to 16 KiB) are now coalesced with HTTP response headers into a single buffer and written via a single `send()` syscall with `TCP_NODELAY`, significantly reducing syscall overhead and packet fragmentation (~26,000 req/sec on keep-alive loopback).
- **Lazy request body parsing**: `Request.body` is now parsed on first access rather than unconditionally during request ingress, saving JSON parsing cycles on routes that do not inspect the request body.
- **Zero-allocation route segment matching**: Replaced allocation-heavy string splitting in the router with a lazy `Segments` input range that traverses encoded paths without heap allocation.
- **Fast-path percent decoding**: `percentDecode` and `decodePath` now bypass allocations when the input string contains no `%` or `+` characters.
- **Zero-allocation header lookup**: `Request.get` now returns directly for single-value headers without calling `join(", ")`.
- **Pre-resolved static root**: `serveStatic` now computes the canonical base path once at initialization instead of on every file request.
- **Adaptive body streaming**: `SocketReader.readExact` now reads into a dynamically growing buffer instead of allocating the full `Content-Length` immediately.

### Added
- **Chunked file streaming & byte-range support**: `Response.sendFile` and `serveStatic` now stream files in 64 KiB chunks with $O(1)$ memory usage, advertising `Accept-Ranges: bytes` and supporting `Range` requests (`206 Partial Content` / `416 Range Not Satisfiable`).
- **`Response.onFinish`**: Added a public API to register lifecycle callbacks run when an HTTP response completes (used by `logger` middleware without accessing private fields).
- **Dual IPv4/IPv6 support**: The HTTP server now uses `getAddress(host, port)` during binding to support hostnames and IPv6 addresses.
- **Regression test suite**: Added tests covering fragmented HTTP headers, pipelined requests, large bodies (200 KiB), sub-router error isolation, lazy body error propagation, header injection prevention, chunked range requests, CORS preflights, and security headers.

---

## [0.1.0] - 2026-11-06

### Added
- **Initial release of dex**: An Express-inspired, lightweight, zero-external-dependency web framework for D.
- **HTTP/1.1 Server**: Built-in multi-threaded HTTP server supporting keep-alive, pipelining, chunked transfer encoding, and 100-continue expectations.
- **Express-style routing**:
  - HTTP verb shortcuts: `get`, `post`, `put`, `patch`, `delete`, `head`, `options`, `all`, and custom methods via `route()`.
  - Named route parameters (`:param`) and wildcards (`*`).
  - Sub-router mounting via `app.use("/prefix", subRouter)`.
  - Case-sensitive routing option (`app.caseSensitive`).
- **Middleware pipeline**: Sequential `next()` execution model, prefix-mounted middleware, and 4-argument error handlers (`error, req, res, next`).
- **Request & Response helpers**:
  - `Request`: headers, cookies, query parameters (`query`, `queryAll`), URL-encoded and JSON body parsing, route params, content-type checks, and typed field extraction (`req.bodyValue!T`).
  - `Response`: status chaining, headers, cookies with `SameSite` options, redirects, file responses (`sendFile`), and JSON serialization.
- **Built-in middleware**:
  - `logger()`: Request logging with status code and millisecond duration.
  - `serveStatic()`: Directory file serving with path traversal protection, symlink escape checks, `dotFiles` control, and `Cache-Control` settings.
- **Reflection-based JSON (`dex.jsonx`)**: Built-in serialization supporting primitives, enums, structs, classes, arrays, associative arrays, `Nullable`, and custom `toJSON()` hooks.
- **Examples & Documentation**:
  - `examples/hello`: Minimal hello-world application.
  - `examples/todos`: In-memory thread-safe JSON REST API.
  - `examples/auth-cors`: HTTP Basic authentication and CORS middleware example.
  - Interactive documentation site hosted under `docs/`.

