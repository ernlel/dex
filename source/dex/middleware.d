/// Built-in middleware.
module dex.middleware;

import core.time : MonoTime;
import std.datetime : SysTime;
import std.file : isDir, isFile, read, timeLastModified;
import std.format : format;
import std.path : absolutePath, buildNormalizedPath, dirSeparator, extension;
import std.stdio : stderr;
import std.string : indexOf, split, startsWith;

import dex.http : httpDate;
import dex.request : Request;
import dex.response : Response;
import dex.router : Middleware, Next;

/// Options for `serveStatic`.
struct StaticOptions
{
    /// File served for directory requests.
    string index = "index.html";
    /// `Cache-Control` value added to file responses.
    string cacheControl = "public, max-age=0";
    /// Serve files and directories whose names start with a dot.
    bool dotFiles;
}

/// Log one line per request to stderr (or a custom sink).
///
/// ---
/// app.use(logger());
/// ---
Middleware logger(void delegate(string) sink = null)
{
    return (Request request, Response response, Next next)
    {
        const started = MonoTime.currTime;
        response.onFinish((Response finished)
        {
            const elapsed = (MonoTime.currTime - started).total!"msecs";
            auto line = format("%s %s %d %dms", request.method,
                               request.originalUrl, finished.statusCode,
                               elapsed);
            if (sink is null)
                stderr.writeln(line);
            else
                sink(line);
        });
        next();
    };
}

/// Serve files from a directory. Missing files fall through to later handlers.
///
/// ---
/// app.use(serveStatic("./public"));
/// app.use("/assets", serveStatic("./assets"));
/// ---
Middleware serveStatic(string root, StaticOptions options = StaticOptions.init)
{
    // Resolved once; the root itself may not exist yet.
    const rootAbsolute = buildNormalizedPath(absolutePath(root));
    const rootPrefix = withTrailingSeparator(rootAbsolute);

    return (Request request, Response response, Next next)
    {
        if (request.method != "GET" && request.method != "HEAD")
        {
            next();
            return;
        }

        auto relative = request.path;
        while (relative.length && relative[0] == '/')
            relative = relative[1 .. $];
        if (relative.length == 0)
            relative = options.index;

        if (relative.indexOf('\0') >= 0)
        {
            next();
            return;
        }

        foreach (part; relative.split('/'))
        {
            if (part.length == 0)
                continue;
            if (part == ".." || part == "." ||
                (!options.dotFiles && part.startsWith(".")))
            {
                next();
                return;
            }
        }

        auto filePath = buildNormalizedPath(rootAbsolute, relative);
        if (filePath != rootAbsolute && !filePath.startsWith(rootPrefix))
        {
            next();
            return;
        }

        bool found;
        try
        {
            if (isDir(filePath))
                filePath = buildNormalizedPath(filePath, options.index);
            if (isFile(filePath))
            {
                // Resolve symlinks before serving, so links cannot escape the root.
                const realRoot = canonicalPath(rootAbsolute);
                const realFile = canonicalPath(filePath);
                if (realFile == realRoot ||
                    realFile.startsWith(withTrailingSeparator(realRoot)))
                {
                    found = true;
                }
            }
        }
        catch (Exception)
        {
            found = false;
        }

        if (!found)
        {
            next();
            return;
        }

        if (!response.has("cache-control"))
            response.set("cache-control", options.cacheControl);
        response.sendFile(filePath);
    };
}

/// CORS configuration options.
struct CorsOptions
{
    /// Allowed origin or `"*"` (default).
    string origin = "*";
    /// Allowed HTTP methods.
    string methods = "GET, POST, PUT, PATCH, DELETE, OPTIONS";
    /// Allowed HTTP headers.
    string headers = "Content-Type, Authorization";
    /// Access-Control-Max-Age header value in seconds.
    string maxAge = "86400";
    /// Whether credentials (cookies, HTTP auth) are allowed.
    bool credentials;
}

/// Add CORS headers and automatically handle preflight `OPTIONS` requests.
Middleware cors(CorsOptions options = CorsOptions.init)
{
    if (options.credentials && options.origin == "*")
        throw new Exception("CORS credentials require an explicit origin");

    return (Request request, Response response, Next next)
    {
        response.set("Access-Control-Allow-Origin", options.origin);
        if (options.origin != "*")
            response.append("Vary", "Origin");

        response.set("Access-Control-Allow-Methods", options.methods);

        const requestedHeaders = request.get("access-control-request-headers");
        response.set("Access-Control-Allow-Headers",
                     requestedHeaders !is null && requestedHeaders.length != 0
                         ? requestedHeaders : options.headers);

        if (options.credentials)
            response.set("Access-Control-Allow-Credentials", "true");
        if (options.maxAge.length)
            response.set("Access-Control-Max-Age", options.maxAge);

        if (request.method == "OPTIONS" &&
            request.get("access-control-request-method") !is null)
        {
            response.status(204).end();
            return;
        }

        next();
    };
}

/// Security headers configuration options.
struct SecurityOptions
{
    /// `X-Content-Type-Options` value. Defaults to `"nosniff"`.
    string xContentTypeOptions = "nosniff";
    /// `X-Frame-Options` value. Defaults to `"SAMEORIGIN"`.
    string xFrameOptions = "SAMEORIGIN";
    /// `Referrer-Policy` value. Defaults to `"strict-origin-when-cross-origin"`.
    string referrerPolicy = "strict-origin-when-cross-origin";
    /// `X-XSS-Protection` value. Defaults to `"0"`.
    string xXssProtection = "0";
    /// `Cross-Origin-Opener-Policy` value. Defaults to `"same-origin"`.
    string crossOriginOpenerPolicy = "same-origin";
    /// `Cross-Origin-Resource-Policy` value. Defaults to `"same-origin"`.
    string crossOriginResourcePolicy = "same-origin";
    /// Optional `Strict-Transport-Security` (HSTS) value.
    string strictTransportSecurity;
}

/// Standard security headers middleware with Helmet-style defaults.
Middleware securityHeaders(SecurityOptions options = SecurityOptions.init)
{
    return (Request request, Response response, Next next)
    {
        if (options.xContentTypeOptions.length && !response.has("x-content-type-options"))
            response.set("x-content-type-options", options.xContentTypeOptions);
        if (options.xFrameOptions.length && !response.has("x-frame-options"))
            response.set("x-frame-options", options.xFrameOptions);
        if (options.referrerPolicy.length && !response.has("referrer-policy"))
            response.set("referrer-policy", options.referrerPolicy);
        if (options.xXssProtection.length && !response.has("x-xss-protection"))
            response.set("x-xss-protection", options.xXssProtection);
        if (options.crossOriginOpenerPolicy.length && !response.has("cross-origin-opener-policy"))
            response.set("cross-origin-opener-policy", options.crossOriginOpenerPolicy);
        if (options.crossOriginResourcePolicy.length && !response.has("cross-origin-resource-policy"))
            response.set("cross-origin-resource-policy", options.crossOriginResourcePolicy);
        if (options.strictTransportSecurity.length && !response.has("strict-transport-security"))
            response.set("strict-transport-security", options.strictTransportSecurity);
        next();
    };
}

private string withTrailingSeparator(string path)
{
    return path.length && path[$ - 1] == dirSeparator[0]
        ? path : path ~ dirSeparator;
}

private string canonicalPath(string path)
{
    version (Posix)
    {
        import core.stdc.stdlib : free;
        import core.sys.posix.stdlib : realpath;
        import std.string : fromStringz, toStringz;

        auto resolved = realpath(path.toStringz, null);
        if (resolved is null)
            throw new Exception("Cannot resolve path: " ~ path);
        scope (exit) free(resolved);
        return resolved.fromStringz.idup;
    }
    else
    {
        return path;
    }
}
