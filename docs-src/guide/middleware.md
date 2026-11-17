---
title: Writing & Using Middleware
description: Middleware functions have access to the request object, response object, and the next middleware function in the application’s request-response cycle.
---

## Anatomy of a Middleware Function

A middleware function is a delegate taking three parameters:

```text
(Request req, Response res, Next next) {
    // Do work...
    next(); // Pass execution to the next handler
}
```

Middleware functions can perform the following tasks:

- Execute any code.
- Make changes to the request and the response objects.
- End the request-response cycle by sending data (e.g. `res.status(403).send("Forbidden")`).
- Call the next middleware function in the stack using `next()`.

## Custom Timing Middleware Example

```d title="source/app.d"
app.use((req, res, next) {
    const start = MonoTime.currTime;
    
    res.onFinish((finishedRes) {
        const ms = (MonoTime.currTime - start).total!"msecs";
        writefln("[%s] %s took %d ms", req.method, req.url, ms);
    });

    next();
});
```

## Built-in Middleware

`dex` includes essential, production-ready middleware right out of the box:

### 1. Logger (`logger()`)

Logs incoming requests, status codes, and latency to `stderr` (or a custom log sink delegate):

```d
app.use(logger());
```

### 2. Static Files (`serveStatic()`)

Streams static assets from disk in 64 KiB chunks with range support:

```d
app.use(serveStatic("./public"));
```

### 3. CORS (`cors()`)

Handles Cross-Origin Resource Sharing headers and preflight `OPTIONS` requests:

```d
// Allow any origin
app.use(cors());

// Or with custom configuration
CorsOptions options;
options.origin = "https://frontend.com";
options.credentials = true;
options.methods = "GET, POST, PUT, DELETE";
app.use(cors(options));
```

### 4. Security Headers (`securityHeaders()`)

Sets standard defensive headers (equivalent to Express Helmet):

```d
app.use(securityHeaders());
```

### 5. Compression (`compression()`)

Compresses response bodies using Gzip or Deflate based on client `Accept-Encoding` headers and content type (HTML, JSON, JS, CSS, SVG, text). Configure via `CompressionOptions` (`threshold`, `level`, `filter`):

```d
import dex;

// Default compression (threshold 1024 bytes)
app.use(compression());

// Custom threshold or compression level (1-9)
CompressionOptions options;
options.threshold = 512; // Compress payloads >= 512 bytes
options.level = 6;
app.use(compression(options));
```

### 6. Rate Limiting (`rateLimit()`)

Restricts incoming request volume per client key within a configured time window to protect APIs against abuse and DDoS. Configure via `RateLimitOptions` (`window`, `max`, `statusCode`, `message`, `standardHeaders`, `legacyHeaders`, `keyGenerator`, `handler`, `skip`):

```d
import dex;
import core.time : dur;

// Default rate limiter (60 requests per 1 minute per IP)
app.use(rateLimit());

// Custom rate limit rules on API routes
RateLimitOptions options;
options.max = 100;
options.window = 15.dur!"minutes";
options.message = "API rate limit exceeded. Please wait before retrying.";
app.use("/api", rateLimit(options));
```

### 7. Per-Route Body Size Limits (`bodyLimit()`)

Overrides `app.maxBodySize` for specific routes or sub-routers, allowing tight caps on JSON endpoints while permitting larger uploads on dedicated routes:

```d
import dex;

// Tight global default (64 KiB)
app.maxBodySize = 64 * 1024;

// Allow up to 50 MiB on a specific upload route
app.post("/upload", bodyLimit(50 * 1024 * 1024), (req, res) {
    res.send("Uploaded " ~ req.rawBody.length.to!string ~ " bytes");
});
```

### 8. Sessions & Signed Cookies (`session()`)

Manages server-side sessions backed by HMAC-SHA256 signed cookies and a pluggable `SessionStore` (defaulting to thread-safe `MemorySessionStore`). Configure via `SessionOptions` (`secret`, `secrets`, `cookieName`, `ttl`, `cookie`, `store`, `saveUninitialized`, `rolling`, `resave`):

```d
import dex;
import core.time : dur;

app.cookieSecrets = ["primary-secret", "previous-secret"];
app.use(session(SessionOptions(ttl: 24.dur!"hours")));

app.post("/login", (req, res) {
    req.session.regenerate();
    req.session["user"] = "alice";
    res.send("logged in");
});
```
