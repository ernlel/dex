/// HTTP request wrapper.
module dex.request;

import std.array : join;
import std.datetime : SysTime;
import std.json : JSONException, JSONType, JSONValue, parseJSON;
import std.string : endsWith, icmp, indexOf, split, startsWith, strip, toLower;

import dex.app : App;
import dex.errors : HttpError;
import dex.http : decodePath, hostName, matchesIfNoneMatch, mediaType, mimeType,
                  negotiateAccept, parseCookies, parseHttpDate, parseQueryString,
                  TrustProxy;
import dex.jsonx : fromJSONValue, fromStringMap;
import dex.response : Response;
import dex.session : Session, unsignCookie;

/// An incoming HTTP request.
///
/// Handlers receive a `Request` and a `Response`. Route parameters are in
/// `params`, parsed query-string values in `query`, and parsed request bodies
/// in `body`.
class Request
{
    /// Uppercase HTTP method, e.g. `"GET"`.
    string method;
    /// HTTP protocol version, e.g. `"HTTP/1.1"`.
    string httpVersion;
    /// Raw (percent-encoded) request path, used for route matching.
    string rawPath;
    /// Decoded request path, useful for logging and static files.
    string path;
    /// Raw query string (without `?`).
    string queryString;
    /// Raw path plus query string.
    string url;
    /// Unmodified request target.
    string originalUrl;
    /// Mounted-router prefix accumulated so far.
    string baseUrl;

    /// Route parameters matched by the active route.
    string[string] params;
    /// Query parameters, last value wins. See `queryAll` for all values.
    string[string] query;
    /// All query parameter values, in order.
    string[][string] queryAll;
    /// Request headers, keyed by lowercased name.
    string[][string] headers;
    /// Parsed cookies.
    string[string] cookies;
    /// Verified signed cookies (populated when `app.cookieSecret` / `cookieSecrets` is set).
    string[string] signedCookies;

    /// Raw request body bytes as a string.
    ///
    /// Loaded from the socket on first access when deferred by the server.
    /// Throws `HttpError` (413) if the body exceeds `maxBodySize`.
    @property string rawBody()
    {
        ensureBodyLoaded();
        return _rawBody;
    }

    /// Maximum request body size permitted for this request, in bytes.
    @property size_t maxBodySize() const
    {
        return _maxBodySize;
    }

    private string _rawBody;
    private bool _bodyLoaded = true;
    package bool _bodyRejected;
    private Throwable _bodyLoadError;
    package size_t _maxBodySize = size_t.max;
    private size_t _declaredContentLength;
    private bool _hasPendingBody;
    private ubyte[] delegate(size_t maxBytes) _bodyLoader;

    private JSONValue _body;
    private bool _bodyParsed;

    /// Remote IP address (resolved through `app.trustProxy` when enabled).
    string ip;
    /// Proxy IP chain when `app.trustProxy` is enabled (from client to nearest proxy).
    string[] ips;
    /// `"http"` (or `"https"` for an absolute HTTPS request target or trusted `X-Forwarded-Proto`).
    string protocol = "http";
    /// Whether the request arrived over TLS (or trusted `X-Forwarded-Proto: https`).
    bool secure;
    /// Whether the request was made with `X-Requested-With: XMLHttpRequest`.
    bool xhr;

    private string _socketIp;
    private string _trustedHost;
    private Session _session;
    package App _app;
    package Response _response;

    /// The application instance handling this request.
    @property App app() { return _app; }

    /// Active server-side session attached by `session()` middleware, or `null`.
    @property Session session() { return _session; }

    package void setSession(Session s) { _session = s; }

    package this()
    {
    }

    package this(string method, string rawTarget, string httpVersion,
                 string[][string] headers, ubyte[] rawBodyBytes, string ip)
    {
        initFromTargetAndHeaders(method, rawTarget, httpVersion, headers, ip);
        _rawBody = cast(string) rawBodyBytes;
        _bodyLoaded = true;
    }

    package this(string method, string rawTarget, string httpVersion,
                 string[][string] headers, string ip, size_t maxBodySize,
                 bool hasPendingBody, size_t declaredContentLength,
                 ubyte[] delegate(size_t maxBytes) bodyLoader)
    {
        initFromTargetAndHeaders(method, rawTarget, httpVersion, headers, ip);
        _maxBodySize = maxBodySize;
        _hasPendingBody = hasPendingBody;
        _declaredContentLength = declaredContentLength;
        _bodyLoader = bodyLoader;
        _bodyLoaded = !hasPendingBody;
    }

    package void setBodyLimit(size_t maxBytes)
    {
        _maxBodySize = maxBytes;
        if (_bodyLoaded)
        {
            if (_rawBody.length > maxBytes)
            {
                _bodyRejected = true;
                throw new HttpError(413, "Payload Too Large");
            }
            return;
        }
        if (_hasPendingBody && _declaredContentLength > maxBytes)
        {
            _bodyRejected = true;
            _bodyLoaded = true;
            _bodyLoadError = new HttpError(413, "Payload Too Large");
            throw _bodyLoadError;
        }
    }

    private void ensureBodyLoaded()
    {
        if (_bodyLoadError !is null)
            throw _bodyLoadError;
        if (_bodyLoaded)
            return;
        _bodyLoaded = true;
        if (_bodyLoader is null)
            return;
        try
        {
            _rawBody = cast(string) _bodyLoader(_maxBodySize);
        }
        catch (Throwable error)
        {
            _bodyRejected = true;
            _bodyLoadError = error;
            throw error;
        }
    }

    private void initFromTargetAndHeaders(string method, string rawTarget,
                                          string httpVersion,
                                          string[][string] headers, string ip)
    {
        this.method = method;
        this.httpVersion = httpVersion;
        this.headers = headers;
        this.ip = ip;
        this._socketIp = ip;
        this.ips = ip.length ? [ip] : null;
        this.originalUrl = rawTarget.length ? rawTarget : "/";

        auto target = rawTarget;
        if (target.startsWith("http://") || target.startsWith("https://"))
        {
            secure = target.startsWith("https://");
            protocol = secure ? "https" : "http";
            const schemeEnd = target.indexOf("://");
            auto rest = target[schemeEnd + 3 .. $];
            const slash = rest.indexOf('/');
            const qmark = rest.indexOf('?');
            if (slash >= 0 && (qmark < 0 || slash < qmark))
                target = rest[slash .. $];
            else if (qmark >= 0)
                target = "/" ~ rest[qmark .. $];
            else
                target = "/";
        }

        if (target.length == 0)
            target = "/";

        const qmark = target.indexOf('?');
        if (qmark < 0)
        {
            rawPath = target;
            queryString = "";
        }
        else
        {
            rawPath = target[0 .. qmark];
            queryString = target[qmark + 1 .. $];
        }
        if (rawPath.length == 0)
            rawPath = "/";

        path = rawPath == "*" ? "*" : decodePath(rawPath);
        url = rawPath ~ (queryString.length ? "?" ~ queryString : "");

        foreach (pair; parseQueryString(queryString))
        {
            query[pair.key] = pair.value;
            queryAll[pair.key] ~= pair.value;
        }

        if (auto cookieHeader = "cookie" in headers)
            cookies = parseCookies((*cookieHeader).join("; "));

        if (auto xrw = "x-requested-with" in headers)
            xhr = (*xrw).length != 0 && icmp((*xrw)[0], "XMLHttpRequest") == 0;
    }

    /// Parsed JSON, URL-encoded, or text body. `JSONValue(null)` otherwise.
    ///
    /// Parsed lazily on first access, so routes that never read the body do
    /// not pay for it. Throws `HttpError` (400) for malformed JSON; like any
    /// handler error, it reaches the app's error middleware.
    @property ref JSONValue body() return
    {
        if (!_bodyParsed)
        {
            _body = parseBody();
            _bodyParsed = true;
        }
        return _body;
    }

    private JSONValue parseBody()
    {
        const raw = rawBody;
        if (raw.length == 0)
            return JSONValue(null);

        const ct = contentType;
        try
        {
            if (ct == "application/json" || ct.endsWith("+json"))
                return parseJSON(raw);
            if (ct == "application/x-www-form-urlencoded")
                return parseForm(raw);
            if (ct.startsWith("text/"))
                return JSONValue(raw);
            return JSONValue(null);
        }
        catch (JSONException e)
        {
            throw new HttpError(400, "Invalid JSON body", __FILE__, __LINE__, e);
        }
    }

    /// URL-encoded form as a JSON object; repeated keys become arrays.
    private static JSONValue parseForm(string input)
    {
        JSONValue[][string] values;
        foreach (pair; parseQueryString(input))
            values[pair.key] ~= JSONValue(pair.value);

        JSONValue[string] object;
        foreach (key, list; values)
            object[key] = list.length == 1 ? list[0] : JSONValue(list);
        return JSONValue(object);
    }

    /// Return a header value. Multiple values are joined with `", "`.
    /// Header names are case-insensitive.
    string get(string name) const
    {
        auto values = name.toLower in headers;
        if (values is null)
            return null;
        return (*values).length == 1 ? (*values)[0] : (*values).join(", ");
    }

    /// Return all values for a header. Header names are case-insensitive.
    string[] getValues(string name) const
    {
        auto values = name.toLower in headers;
        return values is null ? [] : (*values).dup;
    }

    /// Alias for `get`.
    string header(string name) const
    {
        return get(name);
    }

    /// Return a route parameter, or `null` if it is missing.
    string param(string name) const
    {
        auto value = name in params;
        return value is null ? null : *value;
    }

    /// Return the last value of a query parameter, or `null`.
    string queryParam(string name) const
    {
        auto value = name in query;
        return value is null ? null : *value;
    }

    /// Return all values of a query parameter, in order.
    string[] queryParams(string name) const
    {
        auto values = name in queryAll;
        return values is null ? [] : (*values).dup;
    }

    /// Return a cookie value, or `null`.
    string cookie(string name) const
    {
        auto value = name in cookies;
        return value is null ? null : *value;
    }

    /// Return a verified signed cookie value, or `null` if missing or invalid.
    string signedCookie(string name, string secret = null) const
    {
        if (secret.length == 0)
        {
            auto value = name in signedCookies;
            return value is null ? null : *value;
        }
        auto raw = name in cookies;
        if (raw is null)
            return null;
        string unwrapped;
        return unsignCookie(*raw, secret, unwrapped) ? unwrapped : null;
    }

    package void populateSignedCookies(const(string)[] secrets)
    {
        if (secrets.length == 0)
            return;
        foreach (name, raw; cookies)
        {
            string unwrapped;
            if (unsignCookie(raw, secrets, unwrapped))
                signedCookies[name] = unwrapped;
        }
    }

    package void applyTrustProxy(const ref TrustProxy policy)
    {
        if (!policy.isTrustedAddress(_socketIp))
        {
            ip = _socketIp;
            ips = _socketIp.length ? [_socketIp] : null;
            return;
        }

        if (auto fwdHost = get("x-forwarded-host"))
        {
            const comma = fwdHost.indexOf(',');
            const first = (comma >= 0 ? fwdHost[0 .. comma] : fwdHost).strip;
            if (first.length != 0)
                _trustedHost = first;
        }

        if (auto fwdProto = get("x-forwarded-proto"))
        {
            const comma = fwdProto.indexOf(',');
            const first = (comma >= 0 ? fwdProto[0 .. comma] : fwdProto).strip.toLower;
            if (first == "https")
            {
                protocol = "https";
                secure = true;
            }
            else if (first == "http")
            {
                protocol = "http";
                secure = false;
            }
        }

        if (auto xff = "x-forwarded-for" in headers)
        {
            string[] forwarded;
            foreach (part; (*xff).join(",").split(','))
            {
                const entry = part.strip;
                if (entry.length != 0)
                    forwarded ~= entry;
            }

            if (forwarded.length != 0)
            {
                string[] chain = forwarded ~ (_socketIp.length ? [_socketIp] : null);
                final switch (policy.mode)
                {
                    case TrustProxy.Mode.none:
                        break;
                    case TrustProxy.Mode.all:
                        ips = chain;
                        ip = chain[0];
                        break;
                    case TrustProxy.Mode.hops:
                        const idx = chain.length > policy.hopCount
                            ? chain.length - 1 - policy.hopCount
                            : 0;
                        ips = chain[idx .. $];
                        ip = ips[0];
                        break;
                    case TrustProxy.Mode.subnets:
                        size_t idx = forwarded.length - 1;
                        while (idx > 0 && policy.isTrustedAddress(forwarded[idx]))
                            --idx;
                        ips = forwarded[idx .. $] ~ (_socketIp.length ? [_socketIp] : null);
                        ip = ips[0];
                        break;
                }
            }
        }
    }

    /// Request `Host` header (or trusted `X-Forwarded-Host`) without the port.
    string hostname() const
    {
        return hostName(_trustedHost.length ? _trustedHost : get("host"));
    }

    /// Alias for `hostname`.
    string host() const
    {
        return hostname();
    }

    /// Base media type of the request body, e.g. `"application/json"`.
    string contentType() const
    {
        return mediaType(get("content-type"));
    }

    /// Check the request content type. Accepts a MIME type or extension
    /// (`"json"`, `"application/json"`).
    bool isType(string type) const
    {
        const actual = contentType;
        if (actual.length == 0)
            return false;
        const expected = type.indexOf('/') >= 0 ? type : mimeType(type);
        return icmp(actual, mediaType(expected)) == 0;
    }

    /// Retrieve a typed field from a JSON object or URL-encoded body.
    ///
    /// Throws `HttpError` (400) when the field is missing or has the wrong type.
    T bodyValue(T)(string name)
    {
        auto parsed = body;
        if (parsed.type != JSONType.object)
            throw new HttpError(400, "Request body is not a JSON object");
        auto value = name in parsed.object;
        if (value is null)
            throw new HttpError(400, "Missing body field: " ~ name);
        try
        {
            return (*value).get!T;
        }
        catch (Exception e)
        {
            throw new HttpError(400, "Invalid body field: " ~ name, __FILE__, __LINE__, e);
        }
    }

    /// Deserialize and validate the request body (JSON or URL-encoded form)
    /// into D struct/class `T`.
    ///
    /// Throws `HttpError` (`400` for malformed JSON, `errorStatus` defaulting
    /// to `422` for missing required fields or type mismatches).
    T bind(T)(ushort errorStatus = 422)
    {
        import std.traits : Unqual;

        const ct = contentType;
        if (ct == "application/x-www-form-urlencoded")
        {
            static if (is(Unqual!T == struct) || is(Unqual!T == class))
            {
                string[][string] formMap;
                foreach (pair; parseQueryString(rawBody))
                    formMap[pair.key] ~= pair.value;
                return fromStringMap!T(formMap, "", errorStatus);
            }
            else
            {
                throw new HttpError(415, "Form body cannot bind to non-object type");
            }
        }

        auto parsed = body;
        if (parsed.type == JSONType.null_ && rawBody.length == 0)
            parsed = JSONValue(string[string].init);
        return fromJSONValue!T(parsed, "", errorStatus);
    }

    /// Deserialize and validate query string parameters (`req.queryAll`)
    /// into D struct/class `T`.
    T bindQuery(T)(ushort errorStatus = 400) const
    {
        return fromStringMap!T(queryAll, "", errorStatus);
    }

    /// Select the best matching content type from `types` according to the
    /// request's `Accept` header. Accepts MIME types or extensions (`"json"`, `"html"`).
    /// Returns the winning entry from `types`, or `null` if none are acceptable.
    string accepts(const(string)[] types...) const
    {
        return negotiateAccept(get("accept"), types);
    }

    /// Whether the client's cached representation is still fresh (`304 Not Modified`)
    /// based on `If-None-Match` / `If-Modified-Since` and the response's `ETag` / `Last-Modified`.
    @property bool fresh() const
    {
        if (method != "GET" && method != "HEAD")
            return false;
        if (_response is null)
            return false;
        const status = _response.statusCode;
        if ((status < 200 || status >= 300) && status != 304)
            return false;
        return isFreshFor(_response.get("etag"), _response.get("last-modified"));
    }

    /// Inverse of `fresh`.
    @property bool stale() const
    {
        return !fresh;
    }

    package bool isFreshFor(string etag, string lastModified) const
    {
        if (method != "GET" && method != "HEAD")
            return false;

        const cc = get("cache-control");
        if (cc !is null && cc.toLower.indexOf("no-cache") >= 0)
            return false;

        const inm = get("if-none-match");
        const ims = get("if-modified-since");
        if (inm is null && ims is null)
            return false;

        if (inm !is null)
        {
            if (etag is null || !matchesIfNoneMatch(inm, etag))
                return false;
        }

        if (ims !is null && inm is null)
        {
            if (lastModified is null)
                return false;
            SysTime clientTime, resourceTime;
            if (!parseHttpDate(ims, clientTime) || !parseHttpDate(lastModified, resourceTime))
                return false;
            if (resourceTime > clientTime)
                return false;
        }

        return true;
    }
}
