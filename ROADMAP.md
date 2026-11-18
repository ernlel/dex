# Roadmap & Wishlist

This document outlines planned features, upcoming priorities, and future architectural goals for **dex**.

Items are organized by target release phases and technical domain. Community feedback and contributions are welcome!

---

## 🚀 Target Milestone: v0.3.0 (Immediate Priorities) — *Completed*

Focus: **Core ergonomics, standard middleware, and streaming I/O.**

- [x] **Standard CORS Middleware (`dex.middleware.cors`)**
  - Promote CORS middleware from `examples/auth-cors` into the core library.
  - Configurable origins (wildcard, explicit domain).
  - Proper `Vary: Origin` header generation and preflight (`OPTIONS`) handling.
  - Exported directly from top-level `dex` module.

- [x] **Streaming `sendFile` & `serveStatic` (O(1) Memory File Delivery)**
  - Replace full file in-memory loading with a chunked buffer streamer (64 KiB chunks).
  - Serve large files (media, zip, PDFs) with constant memory footprint regardless of file size.
  - Respect `HEAD` requests without streaming payload data.

- [x] **HTTP Range Requests (`206 Partial Content`)**
  - Support `Range: bytes=start-end` headers for video, audio, and resumable downloads.
  - Return `206 Partial Content` with `Content-Range` and `Accept-Ranges: bytes`.
  - Handle multiple / unsatisfiable byte ranges (`416 Range Not Satisfiable`).

- [x] **Security Headers Middleware (`securityHeaders`)**
  - Provide a one-line security default (`app.use(securityHeaders())`) similar to Helmet.
  - Headers included:
    - `X-Content-Type-Options: nosniff`
    - `X-Frame-Options: SAMEORIGIN` (or `DENY`)
    - `Referrer-Policy: strict-origin-when-cross-origin`
    - `X-XSS-Protection: 0` (modern standard)
    - COOP (`Cross-Origin-Opener-Policy: same-origin`) and CORP (`Cross-Origin-Resource-Policy: same-origin`)
    - Optional `Strict-Transport-Security` (HSTS) when running over HTTPS.

---

## ⚡ Target Milestone: v0.4.0 (Performance & API Hardening) — *Completed*

Focus: **Payload optimization, protection, and operational readiness.**

- [x] **View Engine & Template System (`res.render`)**
  - Express-style view engine integration:
    - `app.setViews(string dir)` (defaults to `"./views"`).
    - `app.engine(string ext, string delegate(string templatePath, JSONValue locals) renderer)`.
    - `res.render(T)(string view, auto ref T locals)` with automatic `text/html; charset=utf-8` header and typed D locals.
  - Built-in lightweight, zero-dependency template engine (`dex.view`):
    - Variable interpolation (`{{title}}`, `{{user.name}}`).
    - Raw unescaped output (`{{{raw}}}` and `{{&raw}}`).
    - Conditionals (`{{#if user}}...{{else}}...{{/if}}`, `{{#unless guest}}...{{/unless}}`, and Mustache inverted `{{^empty}}...{{/empty}}`).
    - Loops (`{{#each items}}...{{else}}...{{/each}}`) with `@index`, `@first`, `@last`, `@key`, and `{{this}}`.
    - Partials (`{{> header}}`).
    - Automatic fast-path HTML escaping to prevent XSS.
  - In-memory thread-safe template caching (`app.cacheViews = bool`).

- [x] **Response Compression Middleware (`compression()`)**
  - Gzip and Deflate streaming compression using Phobos `std.zlib`.
  - Inspect `Accept-Encoding` header for client support.
  - Configurable compression threshold (defaults to 1 KiB) and content-type filter (`text/*`, `application/json`, `application/javascript`, `image/svg+xml`, `application/wasm`).
  - Automatic `Vary: Accept-Encoding` header and fallback to raw payload if compression doesn't decrease size.

- [x] **Rate Limiting Middleware (`rateLimit()`)**
  - Sliding-window and fixed-window in-memory rate limiter with thread-safe mutex store.
  - Configurable max requests per time window per IP, API key, or custom `keyGenerator`.
  - Standard RFC draft headers: `RateLimit-Limit`, `RateLimit-Remaining`, `RateLimit-Reset` and optional legacy `X-RateLimit-*`.
  - Status `429 Too Many Requests` with automatic `Retry-After` header and customizable response handler.

- [x] **Per-Route Body Size Limits**
  - Allow individual routes to override `app.maxBodySize` via `bodyLimit(size_t maxBytes)` middleware (with deferred body loading so routes can both cap tighter or permit larger upload payloads).
  - Example: Keep API JSON payloads capped at 64 KiB, while permitting 50 MiB on a specific upload route.

- [x] **Graceful Server Shutdown**
  - Add signal hooks (`SIGINT`, `SIGTERM`) on POSIX systems (`app.handleSignals`).
  - Cease accepting new connections, close idle connections immediately, signal in-flight connections with `Connection: close`, and wait up to `app.shutdownTimeout` (or `app.close(timeout)`) for in-flight requests to complete.

---

## 🔧 Target Milestone: v0.5.0 (Proxy Readiness, Caching & Developer Ergonomics) — *Completed*

Focus: **Reverse-proxy awareness, HTTP caching semantics, typed request binding, and Express-grade routing ergonomics.**

- [x] **Reverse Proxy Support (`app.trustProxy`)**
  - Configurable proxy trust policy (boolean, trusted hop count, or explicit proxy IP/CIDR list).
  - Derive `req.ip`, `req.protocol`, `req.secure`, and `req.hostname` from `X-Forwarded-For`, `X-Forwarded-Proto`, and `X-Forwarded-Host` when trusted.
  - Ensure `rateLimit()` uses the resolved client IP cleanly behind Nginx, Caddy, or cloud load balancers.

- [x] **HTTP Caching & File Download Ergonomics (`ETag`, `304`, `res.download`)**
  - Generate weak/strong `ETag` headers and evaluate `If-None-Match` / `If-Modified-Since` conditional requests (`req.fresh` / `req.stale`) to return `304 Not Modified` in `sendFile`, `serveStatic`, and dynamic responses.
  - Add `res.download(string filePath, string filename = null)` helper setting `Content-Disposition: attachment` safely.
  - Emit `Set-Cookie` headers in `streamFile` responses (aligning file streaming with buffered responses).

- [x] **Typed Request Deserialization & Validation (`req.bind!T`)**
  - Complement `dex.jsonx` serialization with compile-time reflection deserialization (`fromJSONValue!T`) for JSON/form bodies and query structs.
  - Support `Nullable!T`, default field values, nested structs, and descriptive `HttpError` (`400`/`422`) messages on missing or mismatched fields.

- [x] **Router & Content Negotiation Ergonomics**
  - Support variadic handler/middleware chains on route methods (`app.get(path, mw1, mw2, ..., handler)`), lifting the current 3-handler overload cap.
  - Add `router.param("id", callback)` parameter pre-handlers and `app.route(path)` fluent method chaining (`.get(...).post(...)`).
  - Add `req.accepts(...)` and `res.format(...)` content negotiation helpers and optional automatic `405 Method Not Allowed` (`Allow` header) handling.

- [x] **Signed Cookies & Session Middleware (`dex.middleware.session`)**
  - HMAC-SHA256 cookie signing and verification (`res.cookie` signing / `req.signedCookies`).
  - Pluggable `SessionStore` interface with a thread-safe in-memory default store and TTL expiration.

- [x] **Documentation & Reference Sync**
  - Fix stale `README.md` statements (lazy JSON body error timing, dual IPv4/IPv6 listener support, `res.render`, `req.maxBodySize`, `app.close(timeout)`, and `206` Range streaming).
  - Replace raw Markdown backticks in `docs/guide/middleware.html` headings (`compression()`, `rateLimit()`, `bodyLimit()`) with `<code>` tags and document all middleware `*Options` structs.
  - Complete API & landing page docs (`docs/api/request.html`, `docs/api/response.html`, `docs/api/router.html`, `docs/starter/faq.html`, `docs/index.html`) and deduplicate `[0.2.0]` vs `[0.3.0]`/`[0.4.0]` entries in `CHANGELOG.md`.

- [x] **Examples for v0.4.0–v0.5.0 Features**
  - Update existing examples (`examples/api-server`, `examples/file-server`) and/or add dedicated examples demonstrating `compression()`, `rateLimit()`, `bodyLimit()`, graceful shutdown (`shutdownTimeout`), `app.trustProxy`, `ETag`/`304`/`res.download()`, `req.bind!T`, `router.param()`, and signed-cookie sessions.
  - Add any new example apps to `.github/workflows/ci.yml` and `README.md`.

---

## 🌊 Target Milestone: v0.6.0 (Streaming I/O, WebSockets & Observability)

Focus: **Incremental streaming responses, native WebSockets, multipart file uploads, template/static refinements, and production observability.**

- [ ] **Streaming Response API (`res.write()`, SSE)**
  - Support `Transfer-Encoding: chunked` incremental responses via `res.write()`, `res.flush()`, and `res.end()`.
  - Built-in Server-Sent Events (`text/event-stream`) helper for live log streaming, notifications, and AI token-by-token streaming.

- [ ] **Native WebSocket Support (`app.ws` / `router.ws`)**
  - Zero-dependency RFC 6455 HTTP `101 Switching Protocols` upgrade handshake (`Sec-WebSocket-Key` / `Sec-WebSocket-Accept` via `std.digest.sha` & `std.base64`) and subprotocol negotiation (`Sec-WebSocket-Protocol`).
  - Full framing codec supporting text/binary frames, continuation/fragmented messages, masking/unmasking, automatic `Ping`/`Pong` keep-alive heartbeats, and graceful close status codes.
  - Ergonomic connection lifecycle (`onOpen`, `onMessage`, `onClose`, `onError`), thread-safe `ws.send()` / `ws.close()`, configurable max payload size & idle timeouts, and compatibility with standard middleware (`cors`, auth, mounted sub-routers).

- [ ] **Streaming Multipart Form-Data Parser**
  - Zero-dependency `multipart/form-data` boundary parser supporting form fields and uploaded files (`req.files`).
  - Stream uploaded file parts directly to temporary disk files or custom storage sinks with configurable per-file and total upload limits.

- [ ] **View Engine & Static Asset Refinements**
  - Layout/block inheritance (`{{#> layout}}` / `{{{body}}}`) in `dex.view`.
  - Use stored `lastModified` timestamps in `TemplateCache` to automatically invalidate stale cached templates on disk changes.
  - Optional pre-compressed (`.gz`) static asset serving and `Accept-Encoding` quality-factor (`q=`) preference sorting in `compression()`.

- [ ] **Observability, Health Checks & Structured Logging**
  - Structured JSON log formatter option in `logger()` and configurable request ID propagation (`X-Request-Id`).
  - Lightweight built-in `/health` / readiness endpoint helper and server metrics hooks (active connections, request counts, status distribution, latency).

- [ ] **Real-Time, Streaming & Upload Examples**
  - Add runnable examples showcasing WebSockets (`app.ws`), chunked streaming / Server-Sent Events (`res.write()`), multipart file uploads, and `/health` + structured logging.
  - Wire new examples into `.github/workflows/ci.yml` and document curl/browser usage in `README.md`.

---

## 📊 Target Milestone: v0.7.0 (Benchmarking, Performance & Pre-1.0 Hardening)

Focus: **Establish reproducible performance baselines, eliminate hot-path allocations, and harden protocol compliance ahead of `v1.0.0`.**

- [ ] **Benchmark Suite & CI Regression Tracking**
  - Create a reproducible benchmark suite (`benchmarks/`) covering plaintext/JSON responses, `:param` & sub-router dispatch, `req.bind!T` / `dex.jsonx`, middleware stack overhead (`cors`, `compression`, `rateLimit`, `session`), static file / Range streaming, and WebSocket throughput.
  - Measure req/sec, p50/p95/p99 latency, RSS memory, and GC/heap allocations across DMD and LDC builds.
  - Add automated CI benchmark reporting and regression thresholds to establish a baseline before the `v1.0.0` I/O engine transition.

- [ ] **Router & Hot-Path Allocation Optimization**
  - Accelerate route lookup for large route tables (radix/segment-trie or method/prefix indexing) while preserving Express middleware execution order.
  - Reuse per-connection scratch buffers and minimize GC allocations in HTTP parsing, header lookup, and template rendering.

- [ ] **Protocol Fuzzing & Conformance Hardening**
  - Add adversarial fuzz/property tests for HTTP/1.1 framing, chunked encoding, `Range` headers, multipart boundaries, and WebSocket frames (RFC 9110 / RFC 9112 / RFC 6455).

- [ ] **Pre-1.0 API Audit & Stabilization**
  - Review public signatures across `dex.*` modules for ergonomics, consistency, and semver readiness prior to `v1.0.0`.

---

## 🏗️ Target Milestone: v1.0.0 (Scalability & Architecture)

Focus: **High concurrency, modern protocols, and production scale.**

- [ ] **Non-blocking / Event-Driven I/O Engine**
  - Current model: 1 OS thread per connection with `maxConnections = 1024`.
  - Goal: Pluggable or native event loop (`epoll` on Linux, `kqueue` on macOS/BSD, IOCP on Windows) or fiber scheduler.
  - Scale to 50,000+ concurrent idle keep-alive HTTP and WebSocket connections with low RAM overhead.

- [ ] **Native TLS / HTTPS Support**
  - Integrated OpenSSL / system TLS support for standalone deployment without requiring an external reverse proxy (like Nginx, Caddy, or Envoy).
  - ALPN negotiation (`h2`, `http/1.1`), SNI, and hot-reloadable certificate/key pairs.

- [ ] **HTTP/2 Protocol Support (`h2` / `h2c`)**
  - Binary framing layer, HPACK header compression/decompression, and multiplexed request/response streams over a single connection.
  - Per-stream and connection-level flow control (`WINDOW_UPDATE`), `SETTINGS` negotiation, and `GOAWAY` graceful shutdown.
  - ALPN `h2` over TLS and optional cleartext `h2c` (prior knowledge) for internal service-to-service traffic.

---

## 💡 Wishlist & Exploration Ideas

Items under consideration for future exploration:

- [ ] **HTTP/3 & QUIC Protocol Support (`h3`)**
  - UDP-based QUIC transport integration on top of the event-driven I/O engine with TLS 1.3 handshake and connection migration.
  - HTTP/3 frame codec and QPACK dynamic/static header compression over independent QUIC streams (eliminating TCP head-of-line blocking).
  - Automatic `Alt-Svc` header advertisement (`h3=":443"`) on HTTP/1.1 and HTTP/2 responses and 0-RTT early data support (guarded for idempotent requests).
- [ ] **Compile-Time OpenAPI / Swagger Generator**
  - Leverage D's compile-time reflection (`__traits` / `std.traits`) to automatically inspect route handlers, request structs, and responses to generate `openapi.json` and Swagger UI.
- [ ] **External Template Engine Adapters (Diet, Mustache-D)**
  - Pre-packaged adapters for popular D ecosystem template engines:
    - Diet templates (Pug/Jade-style compile-time HTML from `diet-ng`).
    - Mustache-d (logicless mustache templates).
  - Compile-time type-safe HTML template string interpolation (zero runtime parsing cost).
- [ ] **CLI Scaffolding Tool (`dex new <app-name>`)**
  - Rapidly bootstrap project templates (Minimal, REST API, Full-stack).

