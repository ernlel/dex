# Roadmap & Wishlist

This document outlines planned features, upcoming priorities, and future architectural goals for **dex**.

Items are organized by target release phases and technical domain. Community feedback and contributions are welcome!

---

## 🚀 Target Milestone: v0.3.0 (Immediate Priorities)

Focus: **Core ergonomics, standard middleware, and streaming I/O.**

- [ ] **Standard CORS Middleware (`dex.middleware.cors`)**
  - Promote CORS middleware from `examples/auth-cors` into the core library.
  - Configurable origins (wildcard, explicit domain, or dynamic predicate `bool delegate(string)`).
  - Proper `Vary: Origin` header generation and preflight (`OPTIONS`) handling.
  - Exported directly from top-level `dex` module.

- [ ] **Streaming `sendFile` & `serveStatic` (O(1) Memory File Delivery)**
  - Replace `std.file.read(filePath)` with a chunked buffer streamer (e.g., 64 KiB chunks).
  - Serve large files (media, zip, PDFs) with constant memory footprint regardless of file size.
  - Respect `HEAD` requests without disk I/O beyond metadata resolution.

- [ ] **HTTP Range Requests (`206 Partial Content`)**
  - Support `Range: bytes=start-end` headers for video, audio, and resumable downloads.
  - Return `206 Partial Content` with `Content-Range` and `Accept-Ranges: bytes`.
  - Handle multiple / unsatisfiable byte ranges (`416 Range Not Satisfiable`).

- [ ] **Security Headers Middleware (`securityHeaders`)**
  - Provide a one-line security default (`app.use(securityHeaders())`) similar to Helmet.
  - Headers included:
    - `X-Content-Type-Options: nosniff`
    - `X-Frame-Options: SAMEORIGIN` (or `DENY`)
    - `Referrer-Policy: strict-origin-when-cross-origin`
    - `X-XSS-Protection: 0` (modern standard)
    - Optional `Strict-Transport-Security` (HSTS) when running over HTTPS.

---

## ⚡ Target Milestone: v0.4.0 (Performance & API Hardening)

Focus: **Payload optimization, protection, and operational readiness.**

- [ ] **View Engine & Template System (`res.render`)**
  - Express-style view engine integration:
    - `app.setViews(string dir)` (e.g. `"./views"`).
    - `app.engine(string ext, string delegate(string templatePath, JSONValue locals) renderer)`.
    - `res.render(T)(string view, auto ref T locals)` with automatic `text/html` header and layout support.
  - Built-in lightweight, zero-dependency template engine:
    - Variable interpolation (`{{title}}`, `{{user.name}}`).
    - Conditionals (`{{#if user}}...{{/if}}`) and loops (`{{#each items}}...{{/each}}`).
    - Automatic HTML escaping to prevent XSS.
  - Template caching with development auto-reload mode (`app.cacheViews = bool`).

- [ ] **Response Compression Middleware (`compression()`)**
  - Gzip and Deflate streaming compression using Phobos `std.zlib`.
  - Inspect `Accept-Encoding` header for client support.
  - Configurable compression threshold (e.g., skip payloads < 1 KiB) and content-type filter (`text/*`, `application/json`, `application/javascript`, `image/svg+xml`).

- [ ] **Rate Limiting Middleware (`rateLimit()`)**
  - Sliding-window or token-bucket rate limiter.
  - Configurable max requests per time window per IP or API key.
  - Standard headers: `RateLimit-Limit`, `RateLimit-Remaining`, `RateLimit-Reset`.
  - Status `429 Too Many Requests` with customizable response body.

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

