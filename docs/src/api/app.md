---
title: App
description: The top-level application class inheriting from Router and managing the HTTP/1.1 lifecycle.
---

## Properties & Configuration

- `idleTimeout: Duration` — Keep-alive socket idle timeout (default: `60.seconds`).
- `shutdownTimeout: Duration` — Maximum time `close()` waits for in-flight requests to drain (default: `5.seconds`).
- `handleSignals: bool` — Install POSIX `SIGINT`/`SIGTERM` graceful shutdown hooks during `listen()` and `wait()` (default: `true`).
- `maxBodySize: size_t` — Maximum accepted request body in bytes (default: 10 MiB).
- `maxHeaderSize: size_t` — Maximum accepted header bytes (default: 64 KiB).
- `maxConnections: size_t` — Max concurrent TCP connections; 0 means unlimited (default: 1024).
- `trustProxy: TrustProxy` — Reverse-proxy trust policy (`bool`, hop count, or IP/CIDR list) for `X-Forwarded-*` headers (default: disabled).
- `etag: bool` — Automatically generate `ETag` headers and return `304 Not Modified` on matching conditional requests (default: `true`).
- `handleMethodNotAllowed: bool` — Respond with `405 Method Not Allowed` and an `Allow` header when a path matches other HTTP methods (default: `false`).
- `cookieSecret: string` / `cookieSecrets: string[]` — HMAC-SHA256 secret(s) for signed cookies (supports key rotation).
- `showStackTraces: bool` — Send exception stack traces to clients on 500 errors (default: false).
- `logErrors: bool` — Write unhandled 5xx errors to stderr (default: true).
- `caseSensitive: bool` — Enable case-sensitive route matching (default: false).
- `viewsDir: string` — Directory where templates reside (default: `"./views"`).
- `defaultViewEngine: string` — Default view extension (default: `"html"`).
- `cacheViews: bool` — Enable in-memory compiled template caching (default: `false`).
- `isListening: bool` — Whether the server is currently accepting connections.
- `port: ushort` — The bound TCP port (especially useful with ephemeral port `listen(0)`).

## Methods

### app.listen(port, host = "0.0.0.0", onReady = null)

Binds the HTTP server to the given port and blocks until the server closes. If `port == 0`, the OS assigns an ephemeral free port.

### app.start(port, host = "0.0.0.0", onReady = null)

Starts accepting connections on a background accept thread without blocking the calling thread. Read the bound port from `app.port`.

### app.close([timeout])

Stops accepting incoming connections, closes idle keep-alive sockets immediately, signals in-flight responses with `Connection: close`, and waits up to `timeout` (defaults to `shutdownTimeout`) for active requests to complete before forcing remaining connections closed.

### app.use([prefix], handler | middleware | router)

Registers middleware or mounts a sub-router, optionally under a URL prefix.

### app.setViews(directory)

Sets the filesystem directory where view templates are located. Defaults to `"./views"`. Returns `this`.

### app.viewEngine(extension)

Sets the default view file extension (e.g. `"html"`) used when `res.render()` is called without a file extension. Returns `this`.

### app.engine(extension, renderer)

Registers a custom template engine delegate for the specified file extension with signature `string delegate(string templatePath, JSONValue locals)`. Returns `this`.

### app.renderView(viewName, locals)

Compiles and renders a view template file by name with the given JSON locals. Used internally by `res.render()`.
