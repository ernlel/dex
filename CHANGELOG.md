# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
- **`cors` & `securityHeaders` middleware**: Added standard built-in CORS configuration and Helmet-style HTTP security headers middleware (`x-content-type-options`, `x-frame-options`, `referrer-policy`, `x-xss-protection`, `cross-origin-opener-policy`, `cross-origin-resource-policy`, and HSTS).
- **Chunked file streaming & byte-range support**: `Response.sendFile` and `serveStatic` now stream files in 64 KiB chunks with $O(1)$ memory usage, advertising `Accept-Ranges: bytes` and supporting `Range` requests (`206 Partial Content` / `416 Range Not Satisfiable`).
- **Express-style starter documentation & guides**: Comprehensive multi-page documentation under `docs/` matching Express.js starters (`installing.html`, `hello-world.html`, `basic-routing.html`, `static-files.html`, `faq.html`), deep guides (`routing.html`, `middleware.html`, `error-handling.html`), and full API reference (`app.html`, `request.html`, `response.html`, `router.html`).
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

