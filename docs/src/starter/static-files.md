---
title: Serving Static Files
description: Serve images, CSS stylesheets, client-side JavaScript, and media assets using the built-in serveStatic middleware.
---

## Basic Usage

Pass the path to your static directory to `serveStatic()`:

```d title="source/app.d"
app.use(serveStatic("public"));
```

Now you can load files residing inside the `public` directory from the root URL:

```d
http://localhost:3000/images/kitten.jpg
http://localhost:3000/css/style.css
http://localhost:3000/js/app.js
http://localhost:3000/hello.html
```

## Virtual Path Prefix

To create a virtual path prefix (where the prefix does not actually exist in the file system), mount `serveStatic` under a path:

```d
app.use("/static", serveStatic("public"));
```

Files can now be accessed via the `/static` path prefix:

```text
http://localhost:3000/static/images/kitten.jpg
http://localhost:3000/static/css/style.css
```

## Static Configuration Options

Customize static file serving behavior using `StaticOptions`:

```d
StaticOptions options;
options.index = "index.html";                   // Default file for directory requests
options.cacheControl = "public, max-age=86400";  // Custom Cache-Control header
options.dotFiles = false;                        // Ignore hidden files (.env, .git)

app.use(serveStatic("./public", options));
```

## Sending Individual Files from Disk

Use `res.sendFile(filePath)` to send a specific file from disk inside any route handler. Files are streamed in **64 KiB chunks** with zero memory accumulation and full support for **HTTP Range requests** (`206 Partial Content`):

```d title="Streaming File"
app.get("/download/report.pdf", (req, res) {
    res.sendFile("./data/annual_report.pdf");
});
```

> **Audio & Video Seeking Support**
>
> Because `sendFile` and `serveStatic` implement `Accept-Ranges: bytes`, HTML5 `<audio>` and `<video>` players can seek seamlessly forward and backward without downloading the entire media file.
