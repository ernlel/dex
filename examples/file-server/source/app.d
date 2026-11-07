/// Static file and chunked media streaming server demonstrating:
/// - Directory static asset delivery with custom Cache-Control headers
/// - Streaming file downloads with `res.sendFile` and `Content-Disposition`
/// - HTTP Range requests (`Range: bytes=start-end`) returning `206 Partial Content`
/// - File inspection metadata API (`/api/files`)
/// - Custom 404 handler for missing assets
module app;

import dex;
import std.algorithm : filter, map;
import std.array : array;
import std.file : dirEntries, exists, getSize, isFile, SpanMode, timeLastModified;
import std.path : baseName, buildPath;
import std.stdio : writeln;

/// File metadata description.
struct FileInfo
{
    string name;
    ulong sizeBytes;
    string lastModified;
}

void main()
{
    auto app = new App;
    const publicDir = "./public";

    // Request logger
    app.use(logger());

    // Security headers (protects against content sniffing and clickjacking)
    app.use(securityHeaders());

    // Serve public directory with 1-hour cache header
    StaticOptions staticOpts;
    staticOpts.cacheControl = "public, max-age=3600";
    staticOpts.index = "index.html";
    app.use(serveStatic(publicDir, staticOpts));

    // API: list available files in the public directory
    app.get("/api/files", (req, res)
    {
        FileInfo[] list;
        if (exists(publicDir))
        {
            foreach (entry; dirEntries(publicDir, SpanMode.shallow))
            {
                if (entry.isFile)
                {
                    list ~= FileInfo(
                        entry.name.baseName,
                        entry.size,
                        entry.timeLastModified.toISOExtString()
                    );
                }
            }
        }
        res.json(list);
    });

    // Download endpoint: forces browser download with Content-Disposition
    app.get("/download/:filename", (req, res)
    {
        // Sanitize filename to prevent directory traversal
        const safeName = baseName(req.param("filename"));
        const targetPath = buildPath(publicDir, safeName);

        if (!exists(targetPath) || !isFile(targetPath))
            throw new HttpError(404, "Requested file not found: " ~ safeName);

        // Instruct the client to download as an attachment
        res.set("Content-Disposition", `attachment; filename="` ~ safeName ~ `"`);

        // Stream file to client (supports 206 Partial Content range requests)
        res.sendFile(targetPath);
    });

    // Custom 404 handler
    app.use((req, res, next)
    {
        res.status(404)
           .type("html")
           .send(`<!doctype html>
<html>
<head><title>404 Not Found</title><link rel="stylesheet" href="/styles.css"></head>
<body>
<div class="container">
    <h1>404 — Not Found</h1>
    <p class="lead">The requested file or route was not found on this server.</p>
    <p><a href="/">&larr; Return to Home</a></p>
</div>
</body>
</html>`);
    });

    writeln("File & media streaming server listening on http://localhost:3000");
    app.listen(3000);
}

