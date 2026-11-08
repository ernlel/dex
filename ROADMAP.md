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

## ⚡ Target Milestone: v0.4.0 (Performance & API Hardening)

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

- [ ] **Per-Route Body Size Limits**
  - Allow individual routes to override `app.maxBodySize`.
  - Example: Keep API JSON payloads capped at 64 KiB, while permitting 50 MiB on a specific upload route.

- [ ] **Graceful Server Shutdown**
  - Add signal hooks (`SIGINT`, `SIGTERM`) on POSIX systems.
  - Cease accepting new connections, signal existing connections with `Connection: close`, and wait up to a configurable drain timeout for in-flight requests to complete.

---

## 🏗️ Target Milestone: v1.0.0 (Scalability & Architecture)

Focus: **High concurrency, modern protocols, and production scale.**

- [ ] **Non-blocking / Event-Driven I/O Engine**
  - Current model: 1 OS thread per connection with `maxConnections = 1024`.
  - Goal: Pluggable or native event loop (`epoll` on Linux, `kqueue` on macOS/BSD, IOCP on Windows) or fiber scheduler.
  - Scale to 50,000+ concurrent idle keep-alive connections with low RAM overhead.

- [ ] **Streaming Response API (`res.write()`)**
  - Allow handlers to write chunked response streams manually (`Transfer-Encoding: chunked`).
  - Enables Server-Sent Events (SSE), live log streaming, and AI token-by-token streaming.

- [ ] **Streaming Multipart Form-Data Parser**
  - Parse `multipart/form-data` uploads on the fly with zero external dependencies.
  - Stream directly to temporary files or custom storage sinks without buffering large files in memory.

- [ ] **Native WebSocket Support (`app.ws`)**
  - HTTP `101 Switching Protocols` handshake and framing codec.
  - Ergonomic connection lifecycle: `onOpen`, `onMessage`, `onClose`, `onError`.

- [ ] **Native TLS / HTTPS Support**
  - Integrated OpenSSL / system TLS support for standalone deployment without requiring an external reverse proxy (like Nginx, Caddy, or Envoy).

---

## 💡 Wishlist & Exploration Ideas

Items under consideration for future exploration:

- [ ] **Compile-Time OpenAPI / Swagger Generator**
  - Leverage D's compile-time reflection (`__traits` / `std.traits`) to automatically inspect route handlers, request structs, and responses to generate `openapi.json` and Swagger UI.
- [ ] **External Template Engine Adapters (Diet, Mustache-D)**
  - Pre-packaged adapters for popular D ecosystem template engines:
    - Diet templates (Pug/Jade-style compile-time HTML from `diet-ng`).
    - Mustache-d (logicless mustache templates).
  - Compile-time type-safe HTML template string interpolation (zero runtime parsing cost).
- [ ] **Session Store Abstraction**
  - Pluggable session middleware interface (memory, signed cookie, Redis).
- [ ] **CLI Scaffolding Tool (`dex new <app-name>`)**
  - Rapidly bootstrap project templates (Minimal, REST API, Full-stack).
- [ ] **Benchmarking Harness & CI Tracking**
  - Automated continuous performance benchmarking in GitHub Actions to detect allocation regressions and latency spikes across releases.

