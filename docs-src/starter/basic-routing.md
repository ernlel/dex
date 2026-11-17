---
title: Basic Routing
description: Routing refers to how an application’s endpoints respond to client requests. You define routing using methods of the dex App instance.
---

## Route Structure

Route definitions follow this straightforward structure:

```d
app.METHOD(PATH, HANDLER);
```

Where:

- `app` is an instance of `dex.App`.
- `METHOD` is an HTTP request method, in lowercase (e.g., `get`, `post`, `put`, `delete`).
- `PATH` is a path string on the server.
- `HANDLER` is a callback executed when the route matches: `(req, res) { ... }`.

## Basic Examples

```d title="source/app.d"
// Respond to GET request on the root URL (/)
app.get("/", (req, res) {
    res.send("GET request to homepage");
});

// Respond to POST request on the root URL (/)
app.post("/", (req, res) {
    res.send("POST request to homepage");
});

// Respond to a PUT request to the /user route
app.put("/user", (req, res) {
    res.send("Got a PUT request at /user");
});

// Respond to a DELETE request to the /user route
app.delete("/user", (req, res) {
    res.send("Got a DELETE request at /user");
});
```

## Route Parameters

Route parameters are named URL segments used to capture values at specified positions in the URL. Captured values populate the `req.params` associative array:

```d title="Parameters"
app.get("/users/:userId/books/:bookId", (req, res) {
    const userId = req.params["userId"];
    const bookId = req.params["bookId"];
    res.send("User: " ~ userId ~ ", Book: " ~ bookId);
});
```

## Query Parameters

Read query parameters from the request URL using `req.queryParam()` or `req.queryParams()`:

```d
// GET /search?q=dlang&tag=web&tag=fast
app.get("/search", (req, res) {
    const query = req.queryParam("q");       // "dlang"
    const tags  = req.queryParams("tag");    // ["web", "fast"]
    res.json(["query": query]);
});
```

## Response Methods

The `Response` object (`res`) provides methods to send data back to the client and conclude the request-response cycle:

- `res.send(text)` — Sends a string body, defaults to `text/html; charset=utf-8`.
- `res.json(value)` — Serializes any D struct, class, array, or associative array to JSON and sets `application/json`.
- `res.sendStatus(statusCode)` — Sets the status code and sends its reason phrase (e.g., `res.sendStatus(404)`).
- `res.redirect([status], url)` — Issues an HTTP redirect (default `302 Found`).
- `res.sendFile(filePath)` — Streams a file from disk in 64 KiB chunks with range support.
