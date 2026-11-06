/// Express-style application.
module dex.app;

import core.thread : Thread;
import core.time : Duration, dur;
import std.json : JSONValue;
import std.stdio : stderr;

import dex.errors : HttpError;
import dex.request : Request;
import dex.response : Response;
import dex.router : Router;
import dex.server : HttpServer;
import dex.view : TemplateCache, ViewRenderer, renderTemplateFile;

/// A `dex` application.
///
/// ---
/// auto app = new App;
/// app.get("/", (req, res) { res.send("Hello, world!"); });
/// app.listen(3000);
/// ---
class App : Router
{
    /// Keep-alive idle timeout. Defaults to 60 seconds.
    Duration idleTimeout = dur!"seconds"(60);

    /// Maximum accepted request body. Defaults to 10 MiB.
    size_t maxBodySize = 10 * 1024 * 1024;

    /// Maximum accepted header bytes. Defaults to 64 KiB.
    size_t maxHeaderSize = 64 * 1024;

    /// Maximum concurrent connections. Zero means unlimited. Defaults to 1024.
    size_t maxConnections = 1024;

    /// Include exception text in 500 responses. Disabled by default.
    bool showStackTraces;

    /// Write unhandled 5xx errors to stderr. Enabled by default.
    bool logErrors = true;

    /// Directory where view templates reside. Defaults to `"./views"`.
    string viewsDir = "./views";

    /// Default view file extension. Defaults to `"html"`.
    string defaultViewEngine = "html";

    /// Whether to cache compiled view templates in memory. Defaults to `false`.
    bool cacheViews;

    private ViewRenderer[string] _viewEngines;
    private TemplateCache _templateCache;
    private HttpServer _server;

    /// Set the directory containing view templates.
    App setViews(string dir)
    {
        viewsDir = dir;
        return this;
    }

    /// Set the default view engine extension (e.g. `"html"`).
    App viewEngine(string ext)
    {
        defaultViewEngine = ext.length && ext[0] == '.' ? ext[1 .. $] : ext;
        return this;
    }

    /// Register a custom template renderer for a given file extension.
    App engine(string ext, ViewRenderer renderer)
    {
        const key = ext.length && ext[0] == '.' ? ext[1 .. $] : ext;
        _viewEngines[key] = renderer;
        return this;
    }

    /// Render a view template file and return the rendered string.
    string renderView(string viewName, JSONValue locals)
    {
        import std.path : buildPath, extension;
        import std.file : exists, isFile;

        string ext = extension(viewName);
        string targetFile = viewName;
        string engineKey = defaultViewEngine;

        if (ext.length)
        {
            engineKey = ext[1 .. $];
        }
        else
        {
            targetFile = viewName ~ "." ~ defaultViewEngine;
        }

        string fullPath = exists(targetFile) && isFile(targetFile)
            ? targetFile
            : buildPath(viewsDir, targetFile);

        if (auto customEngine = engineKey in _viewEngines)
            return (*customEngine)(fullPath, locals);

        if (cacheViews && _templateCache is null)
            _templateCache = new TemplateCache;

        return renderTemplateFile(fullPath, locals, viewsDir, defaultViewEngine,
                                  cacheViews ? _templateCache : null);
    }

    /// Start the server without blocking. Pass port 0 to pick an ephemeral port;
    /// read the actual port from `port`.
    void start(ushort port, string host = "0.0.0.0",
               void delegate() onReady = null)
    {
        if (_server !is null && _server.isRunning)
            throw new Exception("Server is already running");

        _server = new HttpServer(this);
        _server.start(port, host);
        if (onReady !is null)
        {
            try
            {
                onReady();
            }
            catch (Throwable error)
            {
                _server.close();
                throw error;
            }
        }
    }

    /// Start the server without blocking.
    void start(ushort port, void delegate() onReady)
    {
        start(port, "0.0.0.0", onReady);
    }

    /// Start the server and block until `close()` is called.
    void listen(ushort port, string host = "0.0.0.0",
                void delegate() onReady = null)
    {
        start(port, host, onReady);
        while (isListening)
            Thread.sleep(dur!"msecs"(50));
    }

    /// Start the server and block until `close()` is called.
    void listen(ushort port, void delegate() onReady)
    {
        listen(port, "0.0.0.0", onReady);
    }

    /// Block until the server stops.
    void wait()
    {
        while (isListening)
            Thread.sleep(dur!"msecs"(50));
    }

    /// Stop accepting connections and close active ones.
    void close()
    {
        if (_server !is null)
            _server.close();
    }

    /// Whether the server is accepting connections.
    @property bool isListening() const
    {
        return _server !is null && _server.isRunning;
    }

    /// Bound TCP port. Useful with `start(0)`.
    @property ushort port() const
    {
        return _server is null ? 0 : _server.port;
    }

    /// Handle one HTTP request. Called by the server.
    package void handle(Request request, Response response)
    {
        response._app = this;
        request._app = this;
        try
        {
            dispatch(request, response, () { finalHandler(request, response); });
        }
        catch (Throwable error)
        {
            report(request, error);

            if (response.finished)
            {
                // The response is already committed; make sure the client
                // does not reuse this connection after the error.
                response.closeConnection();
            }
            else
            {
                int status = 500;
                string message = "Internal Server Error";
                if (auto httpError = cast(HttpError) error)
                {
                    status = httpError.status;
                    message = httpError.msg;
                }
                else if (showStackTraces)
                {
                    message = error.toString();
                }
                response.status(status).type("text").send(message);
            }
        }

        if (!response.finished)
            finalHandler(request, response);
    }

    private void finalHandler(Request request, Response response)
    {
        if (response.finished)
            return;
        response.status(404).type("text")
                .send("Cannot " ~ request.method ~ " " ~ request.originalUrl);
    }

    private void report(Request request, Throwable error)
    {
        if (!logErrors)
            return;

        int status = 500;
        if (auto httpError = cast(HttpError) error)
            status = httpError.status;

        // Client errors are expected; only log server failures.
        if (status < 500 && !showStackTraces)
            return;

        stderr.writefln("dex: %s %s: %s", request.method,
                        request.originalUrl, error.toString());
    }
}
