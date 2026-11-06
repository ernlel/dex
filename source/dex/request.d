/// HTTP request wrapper.
module dex.request;

import std.array : join;
import std.json : JSONException, JSONType, JSONValue, parseJSON;
import std.string : endsWith, icmp, indexOf, startsWith, toLower;

import dex.errors : HttpError;
import dex.http : decodePath, hostName, mediaType, mimeType, parseCookies,
                  parseQueryString;

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

    /// Parsed JSON, URL-encoded, or text body. `JSONValue(null)` otherwise.
    JSONValue body;
    /// Raw request body bytes as a string.
    string rawBody;

    /// Remote IP address.
    string ip;
    /// `"http"` (or `"https"` for an absolute HTTPS request target).
    string protocol = "http";
    /// Whether the request arrived over TLS.
    bool secure;
    /// Whether the request was made with `X-Requested-With: XMLHttpRequest`.
    bool xhr;

    package this()
    {
    }

    package this(string method, string rawTarget, string httpVersion,
                 string[][string] headers, ubyte[] rawBodyBytes, string ip)
    {
        this.method = method;
        this.httpVersion = httpVersion;
        this.headers = headers;
        this.ip = ip;
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

        this.rawBody = cast(string) rawBodyBytes;
        parseBody();
    }

    private void parseBody()
    {
        if (rawBody.length == 0)
        {
            body = JSONValue(null);
            return;
        }

        const ct = contentType;
        try
        {
            if (ct == "application/json" || ct.endsWith("+json"))
            {
                body = parseJSON(rawBody);
            }
            else if (ct == "application/x-www-form-urlencoded")
            {
                JSONValue[string] object;
                foreach (pair; parseQueryString(rawBody))
                {
                    if (pair.key !in object)
                    {
                        object[pair.key] = JSONValue(pair.value);
                    }
                    else
                    {
                        auto existing = object[pair.key];
                        if (existing.type == JSONType.array)
                            object[pair.key] = JSONValue(existing.array ~ JSONValue(pair.value));
                        else
                            object[pair.key] = JSONValue([existing, JSONValue(pair.value)]);
                    }
                }
                body = JSONValue(object);
            }
            else if (ct.startsWith("text/"))
            {
                body = JSONValue(rawBody);
            }
            else
            {
                body = JSONValue(null);
            }
        }
        catch (JSONException e)
        {
            throw new HttpError(400, "Invalid JSON body", __FILE__, __LINE__, e);
        }
    }

    /// Return a header value. Multiple values are joined with `", "`.
    /// Header names are case-insensitive.
    string get(string name) const
    {
        auto values = name.toLower in headers;
        if (values is null)
            return null;
        return (*values).join(", ");
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

    /// Request `Host` header without the port.
    string hostname() const
    {
        return hostName(get("host"));
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
    T bodyValue(T)(string name) const
    {
        if (body.type != JSONType.object)
            throw new HttpError(400, "Request body is not a JSON object");
        auto object = body.object;
        auto value = name in object;
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
}
