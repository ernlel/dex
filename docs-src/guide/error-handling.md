---
title: Error Handling
description: Learn how dex catches synchronous and asynchronous exceptions and routes them through your error middleware pipeline.
---

## Throwing HttpError

When an error occurs in your business logic that corresponds to a specific HTTP status code (such as `400 Bad Request` or `404 Not Found`), throw `HttpError`:

```d title="Throwing HttpError"
app.get("/users/:id", (req, res) {
    const user = findUser(req.params["id"]);
    if (user is null)
        throw new HttpError(404, "User not found");
    res.json(user);
});
```

## Writing Error-Handling Middleware

Error-handling middleware functions are defined with four arguments: `(Throwable error, Request req, Response res, Next next)`. They only execute when an exception is thrown or when `next(error)` is called:

```d title="Error Middleware"
app.use((Throwable error, Request req, Response res, Next next) {
    if (auto httpError = cast(HttpError) error) {
        res.status(httpError.status).json([
            "status": httpError.status,
            "error": httpError.msg
        ]);
    } else {
        res.status(500).json([
            "status": 500,
            "error": "Internal Server Error"
        ]);
    }
});
```

## Default Server Error Handler

If an error is thrown and no error-handling middleware ends the response:

- `dex` catches the error, sets status `500 Internal Server Error` (or the `HttpError.status` code), and returns a plain text error message.
- When `app.logErrors = true` (default), 5xx server errors are written to `stderr` with stack traces.
- When `app.showStackTraces = true`, the full exception string is sent to the HTTP client (useful during development).
