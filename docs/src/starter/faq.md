---
title: Frequently Asked Questions
description: Quick answers and best practices for common tasks in dex.
---

## How do I handle 404 responses?

In `dex`, a 404 response is not the result of an error; it simply indicates that none of your registered route handlers responded to the request. You can define a catch-all handler as the very last middleware:

```d
// Defined at the bottom after all other routes
app.use((req, res) {
    res.status(404).type("text").send("Sorry, can’t find that!");
});
```

## How do I set up custom error handling?

Define an error-handling middleware function that takes four parameters: `(Throwable error, Request req, Response res, Next next)`:

```d
app.use((Throwable error, Request req, Response res, Next next) {
    if (auto httpError = cast(HttpError) error) {
        res.status(httpError.status).json(["error": httpError.msg]);
    } else {
        res.status(500).json(["error": "Internal Server Error"]);
    }
});
```

## How do I read JSON POST bodies?

Request bodies with `application/json` are parsed lazily on first access into `req.body`. You can extract typed fields directly using `req.bodyValue!T("field")`:

```d
app.post("/users", (req, res) {
    const name = req.bodyValue!string("name");
    const age  = req.bodyValue!int("age");
    res.status(201).json(["created": name]);
});
```

## How do I enable CORS?

Use the built-in `cors()` middleware:

```d
// Allow all origins
app.use(cors());

// Or configure specific origins and credentials
CorsOptions corsOptions;
corsOptions.origin = "https://myfrontend.com";
corsOptions.credentials = true;
app.use(cors(corsOptions));
```

## How do I add security headers (Helmet-style)?

Use the built-in `securityHeaders()` middleware to set `X-Content-Type-Options: nosniff`, `X-Frame-Options: SAMEORIGIN`, `Referrer-Policy`, and more:

```d
app.use(securityHeaders());
```

## How do I bind JSON or query parameters into typed D structs?

Use `req.bind!T()` for JSON/form bodies and `req.bindQuery!T()` for query strings. Both support nested structs, `Nullable!T`, default values, enums, and `@optional`, raising descriptive `422`/`400` `HttpError` responses when required fields are missing or invalid.

## How do I run dex behind Nginx or Caddy?

Configure `app.trustProxy` (e.g. `app.trustProxy = 1;` or `app.trustProxy = ["loopback", "10.0.0.0/8"];`) so `req.ip`, `req.protocol`, `req.secure`, `req.hostname`, and `rateLimit()` use `X-Forwarded-*` headers safely.

## How do I use sessions, compression, rate limiting, and per-route body limits?

All four ship built-in in `dex`: `app.use(compression())`, `app.use(rateLimit())`, `app.use(session(SessionOptions(secret: "...")))`, and `app.post("/upload", bodyLimit(50 * 1024 * 1024), handler)`. See the [Middleware Guide](../guide/middleware.html) and [Template Engine Guide](../guide/templates.html) for details.

## How does graceful shutdown work?

`app.listen()` automatically catches POSIX `SIGINT` and `SIGTERM` (when `app.handleSignals = true`), stops accepting new connections, closes idle keep-alive sockets, sends `Connection: close` on in-flight responses, and drains up to `app.shutdownTimeout` (5 seconds by default).
