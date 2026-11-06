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
        response._finishCallbacks ~= (Response finished)
        {
            const elapsed = (MonoTime.currTime - started).total!"msecs";
            auto line = format("%s %s %d %dms", request.method,
                               request.originalUrl, finished.statusCode,
                               elapsed);
            if (sink is null)
                stderr.writeln(line);
            else
                sink(line);
        };
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

        const parts = relative.split('/');
        foreach (part; parts)
        {
            if (part.length == 0)
                continue;
            if (part == ".." || part == ".")
            {
                next();
                return;
            }
            if (!options.dotFiles && part.startsWith("."))
            {
                next();
                return;
            }
        }

        auto rootAbsolute = buildNormalizedPath(absolutePath(root));
        const rootPrefix = rootAbsolute == dirSeparator ||
                           rootAbsolute[$ - 1] == dirSeparator[0]
            ? rootAbsolute : rootAbsolute ~ dirSeparator;
        auto filePath = buildNormalizedPath(rootAbsolute, relative);
        if (filePath != rootAbsolute &&
            !filePath.startsWith(rootPrefix))
        {
            next();
            return;
        }

        bool found;
        ubyte[] data;
        SysTime lastModified;
        try
        {
            if (isDir(filePath))
                filePath = buildNormalizedPath(filePath, options.index);
            if (isFile(filePath))
            {
                // Resolve symlinks before serving, so links cannot escape the root.
                const realRoot = canonicalPath(rootAbsolute);
                const realFile = canonicalPath(filePath);
                const realPrefix = realRoot == dirSeparator ||
                                   realRoot[$ - 1] == dirSeparator[0]
                    ? realRoot : realRoot ~ dirSeparator;
                if (realFile == realRoot ||
                    realFile.startsWith(realPrefix))
                {
                    data = cast(ubyte[]) read(filePath);
                    lastModified = timeLastModified(filePath);
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

        if (!response.has("content-type"))
        {
            const ext = extension(filePath);
            response.type(ext.length ? ext[1 .. $] : "");
        }
        if (!response.has("cache-control"))
            response.set("cache-control", options.cacheControl);
        response.set("last-modified", httpDate(lastModified));
        response.sendBytes(data);
    };
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
