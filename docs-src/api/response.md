---
title: Response (res)
description: The Response object represents the HTTP response that an HTTP server sends when it receives an HTTP request.
---

In handlers, the response object is customarily referred to as `res` (or `response`). Most methods on `Response` return `this` to allow method chaining.

## Properties

### res.app

The `App` instance handling this response.

### res.statusCode

The integer HTTP status code that will be sent to the client (e.g. `200`, `404`, `500`). Defaults to `200`.

### res.headersSent / res.finished

Boolean property that indicates if the response has been sent/finished. Once true, subsequent header or body writes are ignored.

## Methods

### res.status(code)

Sets the HTTP status code. Returns `this` for chaining.

```d
res.status(404).send("Page Not Found");
res.status(201).json(createdRecord);
```

### res.set(name, value) / res.header(name, value)

Sets an HTTP header field to the specified value. Header names are case-insensitive. Values are checked to prevent CRLF injection.

```d
res.set("X-Powered-By", "dex")
   .set("Cache-Control", "no-cache");
```

### res.append(name, value)

Appends a value to an existing header. If the header does not yet exist, it creates it. For regular headers, values are separated by a comma and space. For `Set-Cookie`, multiple headers are emitted.

```d
res.append("Warning", "199 Miscellaneous warning");
```

### res.get(name)

Returns the value of the HTTP response header specified by `name` (case-insensitive), or `null` if not set.

### res.has(name)

Returns `true` if the specified response header has been set, `false` otherwise.

### res.type(contentType) / res.contentType(contentType)

Sets the `Content-Type` HTTP header to the MIME type looked up by extension (e.g. `"json"`, `"html"`, `"png"`, `"pdf"`) or a full MIME type string.

```d
res.type("json");    // Content-Type: application/json; charset=utf-8
res.type("html");    // Content-Type: text/html; charset=utf-8
res.type("png");     // Content-Type: image/png
```

### res.send(body)

Sends the HTTP response with a text/HTML body and ends the response. If no `Content-Type` has been set, it defaults to `text/html; charset=utf-8`.

```d
res.send("Hello World");
res.type("text/plain").send("Raw plaintext content");
```

### res.sendBytes(bytes)

Sends raw binary data (`const(ubyte)[]`) and ends the response. Defaults to `application/octet-stream` if no `Content-Type` has been set.

### res.json(value) / res.sendJson(value)

Serializes any D value (struct, class, array, associative array, primitive, or `JSONValue`) to a JSON string, sets `Content-Type: application/json; charset=utf-8`, and ends the response.

```d
struct User { string name; int id; }
res.json(User("Alice", 42));
```

### res.render(viewName, [locals])

Renders a view template using the application's view engine, sets `Content-Type: text/html; charset=utf-8`, and ends the response. `locals` can be any D struct, class, associative array, or `JSONValue`. See the [Template Engine Guide](../guide/templates.html) for details.

```d
struct PageData { string title; string user; }
res.render("index", PageData("Home", "Example User"));

// Without locals:
res.render("about");
```

### res.sendFile(filePath)

Streams a file from the filesystem to the client in 64 KiB chunks. Automatically detects `Content-Type`, sets `Last-Modified` and weak `ETag`, handles `304 Not Modified` conditional requests, announces `Accept-Ranges: bytes`, and handles `Range` requests (`206 Partial Content` / `416 Range Not Satisfiable`).

```d
res.sendFile("./public/downloads/manual.pdf");
```

### res.download(filePath, [filename])

Sends `filePath` as an attachment download with a sanitized `Content-Disposition: attachment; filename="..."` header (and RFC 5987 `filename*` for non-ASCII names).

```d
res.download("./reports/q4.pdf", "quarterly-report.pdf");
```

### res.etag(tag)

Sets the `ETag` response header explicitly. Dynamic 200 responses also receive an automatic SHA-256 `ETag` when `app.etag` is enabled.

### res.format(handlers)

Performs content negotiation on the request's `Accept` header, sets the matched `Content-Type`, and invokes the matching handler (or `"default"`, or throws `HttpError(406)`).

```d
res.format([
    "html": (Request req, Response res) { res.send("<p>Hello</p>"); },
    "json": (Request req, Response res) { res.json(["hello": "world"]); }
]);
```

### res.sendStatus(code)

Sets the response HTTP status code to `code` and sends the text reason phrase as the response body.

```d
res.sendStatus(404); // Sends "404 Not Found" with status 404
res.sendStatus(204); // Sends "204 No Content" with status 204
```

### res.redirect([code], location)

Performs an HTTP redirect to `location`. The default status code is `302 Found`.

```d
res.redirect("/login");
res.redirect(301, "https://example.com/new-url");
```

### res.cookie(name, value, [options]) / res.signedCookie(name, value, [options])

Sets a cookie in the `Set-Cookie` header. Values are percent-encoded for safe transport; pass `signed: true` (or use `signedCookie`) to sign the value with HMAC-SHA256 using `options.secret` or `app.cookieSecret`.

```d
import core.time : dur;
import dex : CookieOptions, SameSite;

res.cookie("session_id", "xyz123", CookieOptions(
    path: "/",
    httpOnly: true,
    secure: true,
    sameSite: SameSite.strict,
    maxAge: 7.dur!"days"
));
```

### res.clearCookie(name, [options])

Expires a cookie immediately by setting its `Expires` to the Unix epoch and `Max-Age=0`.

```d
res.clearCookie("session_id", CookieOptions(path: "/"));
```

### res.closeConnection()

Instructs the server to add `Connection: close` and shut down the underlying TCP connection immediately after sending this response, even on HTTP/1.1 keep-alive connections.

### res.onFinish(callback)

Registers a delegate `void delegate(Response)` that executes as soon as the response is ended. Useful for request logging, metrics collection, and resource cleanup.

```d
res.onFinish((r) {
    writeln("Finished status: ", r.statusCode);
});
```

### res.bodyBytes() / res.bodyString()

Utility inspectors to access the response body as bytes or string. If `sendFile` was called, `bodyBytes()` safely reads the file contents into memory.
