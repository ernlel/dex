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

private struct RoutePart
{
    bool isParam;
    bool isWildcard;
    string name;
    string literal;
}

private struct RoutePattern
{
    string normalized;
    RoutePart[] parts;

    static RoutePattern compile(string pattern)
    {
        if (pattern.length == 0)
            pattern = "/";
        if (pattern[0] != '/')
            pattern = "/" ~ pattern;
        while (pattern.length > 1 && pattern[$ - 1] == '/')
            pattern = pattern[0 .. $ - 1];

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
                parts ~= RoutePart(true, false, part[1 .. $], null);
            }
            else if (part[0] == '*')
            {
                parts ~= RoutePart(false, true,
                                   part.length > 1 ? part[1 .. $] : "0", null);
                wildcardSeen = true;
            }
            else
            {
                parts ~= RoutePart(false, false, null, percentDecode(part));
            }
        }
        return RoutePattern(pattern, parts);
    }

    bool matches(string rawPath, bool asPrefix, bool caseSensitive,
                 out string[string] params, out size_t consumed) const
    {
        params = null;
        const segments = rawSegments(rawPath);
        size_t si = 0;

        foreach (const ref part; parts)
        {
            if (part.isWildcard)
            {
                string joined;
                for (; si < segments.length; ++si)
                {
                    const decoded = percentDecode(segments[si].text);
                    if (joined.length)
                        joined ~= "/";
                    joined ~= decoded;
                }
                params[part.name] = joined;
                if (part.name == "0")
                    params["*"] = joined;
                break;
            }

            if (si >= segments.length)
                return false;
            const decoded = percentDecode(segments[si].text);
            if (part.isParam)
            {
                params[part.name] = decoded;
            }
            else if (caseSensitive ? decoded != part.literal
                                   : icmp(decoded, part.literal) != 0)
            {
                return false;
            }
            ++si;
        }

        if (!asPrefix && si != segments.length)
            return false;
        consumed = si;
        return true;
    }
}

private struct RawSegment
{
    string text;
    size_t start;
    size_t end;
}

/// Split an encoded path into non-empty segments.
private RawSegment[] rawSegments(string rawPath)
{
    RawSegment[] result;
    if (rawPath.length == 0 || rawPath == "*")
        return result;

    size_t i = rawPath[0] == '/' ? 1 : 0;
    while (i <= rawPath.length)
    {
        size_t j = i;
        while (j < rawPath.length && rawPath[j] != '/')
            ++j;
        if (j > i)
            result ~= RawSegment(rawPath[i .. j], i, j);
        if (j >= rawPath.length)
            break;
        i = j + 1;
    }
    return result;
}

private string remainderPath(string rawPath, size_t consumed)
{
    if (consumed == 0)
        return rawPath.length ? rawPath : "/";
    const segments = rawSegments(rawPath);
    if (consumed >= segments.length)
        return "/";
    size_t start = segments[consumed].start;
    if (start > 0 && rawPath[start - 1] == '/')
        --start;
    return rawPath[start .. $];
}

private string consumedPath(string rawPath, size_t consumed)
{
    if (consumed == 0)
        return "";
    const segments = rawSegments(rawPath);
    if (consumed > segments.length)
        consumed = segments.length;
    return rawPath[0 .. segments[consumed - 1].end];
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
    size_t consumed;
    string remainder;
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
        const normalized = normalizePrefix(prefix);
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
        Layer layer;
        layer.kind = LayerKind.middleware;
        const normalized = normalizePrefix(prefix);
        if (normalized != "/")
        {
            layer.hasPrefix = true;
            layer.pattern = RoutePattern.compile(normalized);
        }
        layer.invoke = (Request request, Response response, Next next)
        {
            router.dispatch(request, response, () { next(); });
        };
        _layers ~= layer;
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

    private static string normalizePrefix(string prefix)
    {
        if (prefix.length == 0)
            return "/";
        if (prefix[0] != '/')
            prefix = "/" ~ prefix;
        while (prefix.length > 1 && prefix[$ - 1] == '/')
            prefix = prefix[0 .. $ - 1];
        return prefix;
    }

    private bool matchLayer(const ref Layer layer, Request request,
                            out LayerMatch match)
    {
        match = LayerMatch.init;
        if (layer.kind == LayerKind.error)
            return false;

        if (layer.kind == LayerKind.route)
        {
            if (layer.method.length != 0 && layer.method != request.method)
            {
                // Express falls back to GET handlers for HEAD requests.
                if (!(request.method == "HEAD" && layer.method == "GET"))
                    return false;
            }
            return layer.pattern.matches(request.rawPath, false, caseSensitive,
                                         match.params, match.consumed);
        }

        if (!layer.hasPrefix)
            return true;

        if (!layer.pattern.matches(request.rawPath, true, caseSensitive,
                                   match.params, match.consumed))
            return false;
        match.remainder = remainderPath(request.rawPath, match.consumed);
        match.consumedRaw = consumedPath(request.rawPath, match.consumed);
        return true;
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
                request.rawPath = match.remainder.length ? match.remainder : "/";
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
                if (!state.errorSet)
                {
                    state.errorSet = true;
                    state.error = error;
                    state.errorStart = i;
                }
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
                if (!state.errorSet)
                {
                    state.errorSet = true;
                    state.error = error;
                    state.errorStart = i;
                }
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
            state.done();
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
