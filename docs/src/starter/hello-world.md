---
title: Hello World
description: Create the most fundamental dex application: an HTTP server responding to requests on port 3000.
---

In your project directory, open `source/app.d` and write the following code:

```d title="source/app.d"
import dex;
import std.stdio : writeln;

void main()
{
    auto app = new App;

    app.get("/", (req, res) {
        res.send("Hello, World!");
    });

    app.listen(3000, () {
        writeln("Example app listening on http://localhost:3000");
    });
}
```

## How It Works

1. `import dex;` brings in the `App` class, request/response models, and built-in middleware.
2. `auto app = new App;` creates a new application instance. `App` is also a `Router`, so you can register routes and middleware directly on it.
3. `app.get("/", (req, res) { ... })` registers a route handler for HTTP `GET` requests to the root path (`/`). The handler receives a `Request` object (`req`) and a `Response` object (`res`).
4. `res.send("Hello, World!")` ends the response, sets `Content-Type: text/html; charset=utf-8` (by default for strings), computes `Content-Length`, and sends the response.
5. `app.listen(3000, callback)` binds to `0.0.0.0:3000`, starts accepting HTTP/1.1 connections, and invokes the callback once the socket is successfully listening.

## Running the App

Run the application using DUB:

```sh title="Terminal"
$ dub run
```

Point your browser to `http://localhost:3000/` or test it in terminal with `curl`:

```sh title="Terminal"
$ curl -i http://localhost:3000/
HTTP/1.1 200 OK
Content-Type: text/html; charset=utf-8
Date: Fri, 06 Nov 2026 15:30:00 GMT
Server: dex
Content-Length: 13
Connection: keep-alive

Hello, World!
```
