/// Express-style router: middleware, routes, parameters and error handlers.
module dex.router;

import std.string : icmp, split;

import dex.errors : HttpError;
import dex.http : decodePath, percentDecode;
import dex.request : Request;
import dex.response : Response;

/// Call the next matching handler or middleware in the chain.
struct Next
{
    private void delegate() _next;
    private void delegate(Throwable) _error;

    package this(void delegate() next, void delegate(Throwable) error)
    {
        _next = next;
        _error = error;
    }

    /// Continue with the next handler.
    void opCall()
    {
        if (_next is null)
            return;
        auto next = _next;
        _next = null;
        _error = null;
        next();
    }

    /// Skip remaining handlers and enter error handling. A null error is
    /// equivalent to `next()`.
    void opCall(Throwable error)
    {
        if (error is null)
        {
            opCall();
            return;
        }
        if (_error is null)
            return;
        auto onError = _error;
        _next = null;
        _error = null;
        onError(error);
    }
}

/// A terminal handler: sends a response.
alias Handler = void delegate(Request request, Response response);

/// Middleware: may call `next` to continue the chain.
alias Middleware = void delegate(Request request, Response response, Next next);

/// Error middleware: receives the error and may send a response or call `next`.
alias ErrorHandler = void delegate(Throwable error, Request request,
                                   Response response, Next next);

private enum LayerKind
{
    route,
    middleware,
    error
}

private enum PartKind
{
    literal,
    param,
    wildcard
}

private struct RoutePart
{
    PartKind kind;
    /// Parameter name (param/wildcard) or decoded text (literal).
    string text;
}

/// Result of matching a request path against a `RoutePattern`.
private struct PathMatch
{
    string[string] params;
    /// Byte offset in the raw path just past the last matched segment.
    size_t consumedEnd;
}

private struct RoutePattern
{
    string normalized;
    RoutePart[] parts;

    static RoutePattern compile(string pattern)
    {
        pattern = normalizePath(pattern);

        RoutePart[] parts;
        bool wildcardSeen = false;
        foreach (part; pattern.split('/'))
        {
            if (part.length == 0)
                continue;
            if (wildcardSeen)
                throw new Exception("Wildcard must be the last route segment: " ~ pattern);
            if (part[0] == ':')
            {
                if (part.length == 1)
                    throw new Exception("Route parameter must have a name: " ~ pattern);
                parts ~= RoutePart(PartKind.param, part[1 .. $]);
            }
            else if (part[0] == '*')
            {
                parts ~= RoutePart(PartKind.wildcard,
                                   part.length > 1 ? part[1 .. $] : "0");
                wildcardSeen = true;
            }
            else
            {
                parts ~= RoutePart(PartKind.literal, percentDecode(part));
            }
        }
        return RoutePattern(pattern, parts);
    }

    /// Match `rawPath` segment by segment. With `asPrefix`, trailing segments
    /// are allowed (used for mounted middleware and routers).
    bool matches(string rawPath, bool asPrefix, bool caseSensitive,
                 out PathMatch match) const
    {
        auto segments = Segments(rawPath);

        foreach (const ref part; parts)
        {
            final switch (part.kind)
            {
                case PartKind.wildcard:
                    string joined;
                    for (; !segments.empty; segments.popFront())
                    {
                        if (joined.length)
                            joined ~= "/";
                        joined ~= percentDecode(segments.front);
                    }
                    match.params[part.text] = joined;
                    if (part.text == "0")
                        match.params["*"] = joined;
                    match.consumedEnd = rawPath.length;
                    return true;

                case PartKind.param:
                    if (segments.empty)
                        return false;
                    match.params[part.text] = percentDecode(segments.front);
                    break;

                case PartKind.literal:
                    if (segments.empty)
                        return false;
                    const decoded = percentDecode(segments.front);
                    if (caseSensitive ? decoded != part.text
                                      : icmp(decoded, part.text) != 0)
                        return false;
                    break;
            }
            match.consumedEnd = segments.frontEnd;
            segments.popFront();
        }

        return asPrefix || segments.empty;
    }
}

/// Lazy range over the non-empty, still-encoded segments of a raw path.
private struct Segments
{
    private string path;
    private size_t start; // start of `front`
    private size_t end;   // one past the end of `front`

    this(string rawPath)
    {
        // `*` is the asterisk-form target (`OPTIONS *`), not a segment.
        path = rawPath == "*" ? null : rawPath;
        advanceFrom(0);
    }

    @property bool empty() const { return start >= path.length; }
    @property string front() const { return path[start .. end]; }
    /// Byte offset just past `front`.
    @property size_t frontEnd() const { return end; }
    void popFront() { advanceFrom(end); }

    private void advanceFrom(size_t i)
    {
        while (i < path.length && path[i] == '/')
            ++i;
        start = i;
        while (i < path.length && path[i] != '/')
            ++i;
        end = i;
    }
}

/// Ensure a leading slash and strip trailing slashes. Empty becomes `/`.
private string normalizePath(string path)
{
    if (path.length == 0 || path[0] != '/')
        path = "/" ~ path;
    while (path.length > 1 && path[$ - 1] == '/')
        path = path[0 .. $ - 1];
    return path;
}

private string[string] mergeParams(string[string] base, string[string] additions)
{
    if (additions.length == 0)
        return base;
    string[string] merged;
    foreach (key, value; base)
        merged[key] = value;
    foreach (key, value; additions)
        merged[key] = value;
    return merged;
}

private struct Layer
{
    LayerKind kind;
    string method;
    RoutePattern pattern;
    bool hasPrefix;
    void delegate(Request, Response, Next) invoke;
    ErrorHandler errorHandler;
}

private struct LayerMatch
{
    string[string] params;
    /// Path left for a mounted layer, always starting with `/`.
    string remainder;
    /// Raw path prefix consumed by a mounted layer.
    string consumedRaw;
}

/// Base class for `App`; can also be mounted as a sub-router.
class Router
{
    package Layer[] _layers;

    /// Enable case-sensitive path matching. Defaults to false (Express-like).
    bool caseSensitive;

    /// Register middleware that runs for every request.
    void use(Handler handler)
    {
        addMiddleware("", handler);
    }

    /// Register middleware.
    void use(Middleware middleware)
    {
        addMiddleware("", middleware);
    }

    /// Register middleware mounted under a path prefix.
    void use(string prefix, Handler handler)
    {
        addMiddleware(prefix, handler);
    }

    /// Register middleware mounted under a path prefix.
    void use(string prefix, Middleware middleware)
    {
        addMiddleware(prefix, middleware);
    }

    /// Register error middleware. Error middleware runs only when an error is
    /// raised and no earlier error handler responded.
    void use(ErrorHandler handler)
    {
        Layer layer;
        layer.kind = LayerKind.error;
        layer.errorHandler = handler;
        _layers ~= layer;
    }

    /// Mount a router.
    void use(Router router)
    {
        addRouter("", router);
    }

    /// Mount a router under a path prefix.
    void use(string prefix, Router router)
    {
        addRouter(prefix, router);
    }

    mixin(verbMethods("all", ""));
    mixin(verbMethods("get", "GET"));
    mixin(verbMethods("post", "POST"));
    mixin(verbMethods("put", "PUT"));
    mixin(verbMethods("patch", "PATCH"));
    mixin(verbMethods("delete", "DELETE"));
    mixin(verbMethods("head", "HEAD"));
    mixin(verbMethods("options", "OPTIONS"));
    mixin(verbMethods("connect", "CONNECT"));
    mixin(verbMethods("trace", "TRACE"));

    /// Register a handler for a custom method.
    void route(string method, string path, Handler handler)
    {
        addRoute(method, path, handler);
    }

    /// Register middleware for a custom method.
    void route(string method, string path, Middleware middleware)
    {
        addRoute(method, path, middleware);
    }

    /// Dispatch a request through this router. Calls `done` when no handler
    /// produced a response.
    package void dispatch(Request request, Response response,
                          void delegate() done)
    {
        DispatchState state;
        state.request = request;
        state.response = response;
        state.done = done;

        try
        {
            dispatchFrom(0, state);
        }
        catch (Throwable error)
        {
            if (!state.errorSet)
                throw error;

            if (error !is state.error)
                state.error = error;

            if (response._finished)
                throw error;

            if (!runErrorHandlers(state, state.errorStart))
                throw state.error;
        }
    }

    private void addMiddleware(string prefix, Handler handler)
    {
        addMiddleware(prefix, (Request request, Response response, Next next)
        {
            handler(request, response);
        });
    }

    private void addMiddleware(string prefix, Middleware middleware)
    {
        Layer layer;
        layer.kind = LayerKind.middleware;
        const normalized = normalizePath(prefix);
        if (normalized != "/")
        {
            layer.hasPrefix = true;
            layer.pattern = RoutePattern.compile(normalized);
        }
        layer.invoke = middleware;
        _layers ~= layer;
    }

    private void addRouter(string prefix, Router router)
    {
        if (router is null)
            throw new Exception("Cannot mount a null router");
        if (router is this)
            throw new Exception("Cannot mount a router on itself");
        addMiddleware(prefix, (Request request, Response response, Next next)
        {
            router.dispatch(request, response, () { next(); });
        });
    }

    private void addRoute(string method, string path, Handler handler)
    {
        addRoute(method, path,
                 (Request request, Response response, Next next)
                 {
                     handler(request, response);
                 });
    }

    private void addRoute(string method, string path, Middleware middleware)
    {
        Layer layer;
        layer.kind = LayerKind.route;
        layer.method = method;
        layer.pattern = RoutePattern.compile(path);
        layer.invoke = middleware;
        _layers ~= layer;
    }

    private bool matchLayer(const ref Layer layer, Request request,
                            out LayerMatch match)
    {
        final switch (layer.kind)
        {
            case LayerKind.error:
                return false;

            case LayerKind.route:
                if (layer.method.length != 0 && layer.method != request.method)
                {
                    // Express falls back to GET handlers for HEAD requests.
                    if (!(request.method == "HEAD" && layer.method == "GET"))
                        return false;
                }
                PathMatch path;
                if (!layer.pattern.matches(request.rawPath, false, caseSensitive, path))
                    return false;
                match.params = path.params;
                return true;

            case LayerKind.middleware:
                if (!layer.hasPrefix)
                    return true;
                PathMatch path;
                if (!layer.pattern.matches(request.rawPath, true, caseSensitive, path))
                    return false;

                auto remainder = request.rawPath[path.consumedEnd .. $];
                while (remainder.length > 1 && remainder[1] == '/')
                    remainder = remainder[1 .. $];
                match.params = path.params;
                match.remainder = remainder.length ? remainder : "/";
                match.consumedRaw = request.rawPath[0 .. path.consumedEnd];
                return true;
        }
    }

    private void dispatchFrom(size_t start, ref DispatchState state)
    {
        size_t i = start;
        while (i < _layers.length)
        {
            if (state.response._finished)
                return;

            auto layer = &_layers[i];
            ++i;

            LayerMatch match;
            if (!matchLayer(*layer, state.request, match))
                continue;

            auto request = state.request;
            auto response = state.response;

            const savedRawPath = request.rawPath;
            const savedPath = request.path;
            const savedUrl = request.url;
            const savedBaseUrl = request.baseUrl;
            auto savedParams = request.params;

            const prefixAdjusted = layer.kind == LayerKind.middleware && layer.hasPrefix;
            const paramsChanged = layer.kind == LayerKind.route || prefixAdjusted;

            if (prefixAdjusted)
            {
                request.baseUrl = savedBaseUrl ~ match.consumedRaw;
                request.rawPath = match.remainder;
                request.path = decodePath(request.rawPath);
                request.url = request.rawPath ~
                    (request.queryString.length ? "?" ~ request.queryString : "");
            }
            if (paramsChanged)
                request.params = mergeParams(savedParams, match.params);

            bool restored = false;
            void restore()
            {
                if (restored)
                    return;
                restored = true;
                if (prefixAdjusted)
                {
                    request.rawPath = savedRawPath;
                    request.path = savedPath;
                    request.url = savedUrl;
                    request.baseUrl = savedBaseUrl;
                }
                if (paramsChanged)
                    request.params = savedParams;
            }

            bool advanced = false;
            void advance()
            {
                if (advanced)
                    return;
                advanced = true;
                restore();
                dispatchFrom(i, state);
            }

            void fail(Throwable error)
            {
                if (advanced)
                    return;
                advanced = true;
                restore();
                if (error is null)
                {
                    dispatchFrom(i, state);
                    return;
                }
                recordError(state, error, i);
                throw error;
            }

            Next next = Next(&advance, &fail);

            try
            {
                layer.invoke(request, response, next);
            }
            catch (Throwable error)
            {
                restore();
                recordError(state, error, i);
                throw error;
            }

            restore();

            if (state.response._finished)
                return;
            if (advanced)
                return;
            // A handler that neither responded nor called next falls through,
            // which keeps `use` middleware from hanging the request.
        }

        if (!state.response._finished)
        {
            state.exited = true;
            state.done();
        }
    }

    /// Remember the first error raised by this router's layers, and where
    /// error handling should resume.
    private static void recordError(ref DispatchState state, Throwable error,
                                    size_t resumeAt)
    {
        // Once `done` ran, control belongs to the parent router; errors it
        // raises must not reach this router's error handlers.
        if (state.errorSet || state.exited)
            return;
        state.errorSet = true;
        state.error = error;
        state.errorStart = resumeAt;
    }

    private bool runErrorHandlers(ref DispatchState state, size_t start)
    {
        Throwable error = state.error;
        size_t i = start;
        while (i < _layers.length)
        {
            auto layer = &_layers[i];
            ++i;
            if (layer.kind != LayerKind.error)
                continue;

            bool advanced = false;
            Throwable nextError;
            void nextFn() { advanced = true; }
            void errorFn(Throwable e) { advanced = true; nextError = e; }
            Next next = Next(&nextFn, &errorFn);

            try
            {
                layer.errorHandler(error, state.request, state.response, next);
            }
            catch (Throwable e)
            {
                error = e;
                if (state.response._finished)
                    return true;
                continue;
            }

            if (state.response._finished)
                return true;
            if (nextError !is null)
            {
                error = nextError;
                continue;
            }
            if (advanced)
                continue;
            // No response and no next(): let the default error handler run.
            state.error = error;
            return false;
        }

        state.error = error;
        return false;
    }
}

private struct DispatchState
{
    Request request;
    Response response;
    void delegate() done;
    /// Set once `done` was called, i.e. control returned to the parent.
    bool exited;
    bool errorSet;
    size_t errorStart;
    Throwable error;
}

private string verbMethods(string name, string method)
{
    return
        "void " ~ name ~ "(string path, Handler handler) { addRoute(\"" ~ method ~
            "\", path, handler); }\n" ~
        "void " ~ name ~ "(string path, Middleware middleware) { addRoute(\"" ~ method ~
            "\", path, middleware); }\n" ~
        "void " ~ name ~ "(string path, Handler first, Handler last) " ~
            "{ addRoute(\"" ~ method ~ "\", path, first); addRoute(\"" ~ method ~
            "\", path, last); }\n" ~
        "void " ~ name ~ "(string path, Middleware first, Handler last) " ~
            "{ addRoute(\"" ~ method ~ "\", path, first); addRoute(\"" ~ method ~
            "\", path, last); }\n" ~
        "void " ~ name ~ "(string path, Middleware first, Middleware second, Handler last) " ~
            "{ addRoute(\"" ~ method ~ "\", path, first); addRoute(\"" ~ method ~
            "\", path, second); addRoute(\"" ~ method ~ "\", path, last); }\n";
}
