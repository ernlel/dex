/// HTTP response builder.
module dex.response;

import core.time : Duration, dur;
import std.array : join;
import std.conv : to;
import std.datetime : Clock;
import std.file : isFile, read, timeLastModified;
import std.path : extension;
import std.string : toLower;

import dex.errors : HttpError;
import dex.http : encodeCookieValue, httpDate, mimeType,
                  reasonPhrase, validCookieName;
import dex.jsonx : toJSONValue;
import dex.request : Request;

/// Cookie `SameSite` policy.
enum SameSite
{
    unset,
    lax,
    strict,
    none
}

/// Options accepted by `Response.cookie`.
struct CookieOptions
{
    /// Cookie path. Defaults to `/`.
    string path = "/";
    /// Optional cookie domain.
    string domain;
    /// Relative lifetime. Zero means a session cookie.
    Duration maxAge;
    /// Hide the cookie from JavaScript.
    bool httpOnly;
    /// Send the cookie over HTTPS only.
    bool secure;
    /// `SameSite` policy.
    SameSite sameSite = SameSite.unset;
}

/// The response object passed to handlers.
class Response
{
    /// HTTP status code. Prefer `status()` for chaining.
    int statusCode = 200;

    package:
    Request _request;
    string[string] _headers;
    string[] _setCookies;
    const(ubyte)[] _body;
    bool _finished;
    bool _forceClose;
    void delegate(Response)[] _finishCallbacks;

    public:

    package this(Request request)
    {
        _request = request;
    }

    /// Set the status code.
    Response status(int code)
    {
        if (_finished)
            return this;
        if (code < 100 || code > 999)
            throw new Exception("Invalid HTTP status code: " ~ to!string(code));
        statusCode = code;
        return this;
    }

    /// Set a response header. Header names are case-insensitive.
    Response set(string name, string value)
    {
        if (_finished)
            return this;
        validateHeader(name, value);
        const key = name.toLower;
        if (key == "set-cookie")
        {
            _setCookies ~= value;
            return this;
        }
        _headers[key] = value;
        return this;
    }

    /// Alias for `set`.
    Response header(string name, string value)
    {
        return set(name, value);
    }

    /// Append to a response header, creating it when absent.
    Response append(string name, string value)
    {
        if (_finished)
            return this;
        validateHeader(name, value);
        const key = name.toLower;
        if (key == "set-cookie")
        {
            _setCookies ~= value;
            return this;
        }
        if (auto current = key in _headers)
            *current ~= ", " ~ value;
        else
            _headers[key] = value;
        return this;
    }

    /// Get a response header, or `null`.
    string get(string name) const
    {
        const key = name.toLower;
        if (key == "set-cookie")
            return _setCookies.length ? _setCookies.join(", ") : null;
        auto value = key in _headers;
        return value is null ? null : *value;
    }

    /// Whether a response header has been set.
    bool has(string name) const
    {
        const key = name.toLower;
        if (key == "set-cookie")
            return _setCookies.length != 0;
        return (key in _headers) !is null;
    }

    /// Set the `Content-Type` header from a MIME type or extension.
    Response type(string contentType)
    {
        if (_finished)
            return this;
        _headers["content-type"] = mimeType(contentType);
        return this;
    }

    /// Alias for `type`.
    Response contentType(string contentType)
    {
        return type(contentType);
    }

    /// Send a text/HTML body. Sets `Content-Type` to `text/html` when absent.
    Response send(const(char)[] body)
    {
        if (_finished)
            return this;
        if (!has("content-type"))
            type("html");
        _body = cast(const(ubyte)[]) body;
        finish();
        return this;
    }

    /// Send raw bytes. Sets `Content-Type` to `application/octet-stream` when absent.
    Response sendBytes(const(ubyte)[] bytes)
    {
        if (_finished)
            return this;
        if (!has("content-type"))
            type("bin");
        _body = bytes;
        finish();
        return this;
    }

    /// Send a JSON body for any value supported by `toJSONValue`.
    Response json(T)(auto ref T value)
    {
        if (_finished)
            return this;
        type("json");
        return send(toJSONValue(value).toString());
    }

    /// Alias for `json`.
    Response sendJson(T)(auto ref T value)
    {
        return json(value);
    }

    /// End the response with an optional raw body and no automatic content type.
    Response end(const(char)[] data = null)
    {
        if (_finished)
            return this;
        _body = data is null ? null : cast(const(ubyte)[]) data;
        finish();
        return this;
    }

    /// End the response with a status code and its reason phrase.
    Response sendStatus(int code)
    {
        return status(code).type("text").send(reasonPhrase(code));
    }

    /// Redirect to `location` with status 302.
    Response redirect(string location)
    {
        return redirect(302, location);
    }

    /// Redirect to `location` with a specific status code.
    Response redirect(int code, string location)
    {
        if (_finished)
            return this;
        status(code);
        set("location", location);
        return type("text").send(reasonPhrase(code) ~ ". Redirecting to " ~ location);
    }

    /// Send a file read from disk. Throws `HttpError` (404) if it is missing.
    Response sendFile(string filePath)
    {
        if (_finished)
            return this;
        if (!isFile(filePath))
            throw new HttpError(404, "Not Found");
        auto data = cast(ubyte[]) read(filePath);
        if (!has("content-type"))
        {
            const ext = extension(filePath);
            type(ext.length ? ext[1 .. $] : "");
        }
        set("last-modified", httpDate(timeLastModified(filePath)));
        return sendBytes(data);
    }

    /// Set a cookie. Values are percent-encoded and round-trip through
    /// `Request.cookie`.
    Response cookie(string name, string value,
                    CookieOptions options = CookieOptions.init)
    {
        return appendCookie(name, value, options, false);
    }

    /// Expire a cookie immediately.
    Response clearCookie(string name, CookieOptions options = CookieOptions.init)
    {
        return appendCookie(name, "", options, true);
    }

    /// Close the TCP connection after this response.
    Response closeConnection()
    {
        _forceClose = true;
        return this;
    }

    /// Whether the response has been ended.
    @property bool headersSent() const
    {
        return _finished;
    }

    /// Whether the response has been ended.
    @property bool finished() const
    {
        return _finished;
    }

    /// Raw response body bytes.
    const(ubyte)[] bodyBytes() const
    {
        return _body;
    }

    /// Response body as a string.
    string bodyString() const
    {
        return cast(string) _body;
    }

    private void finish()
    {
        if (_finished)
            return;
        _finished = true;
        auto callbacks = _finishCallbacks;
        _finishCallbacks = null;
        foreach (callback; callbacks)
        {
            try
                callback(this);
            catch (Throwable) {}
        }
    }

    private Response appendCookie(string name, string value,
                                  CookieOptions options, bool expired)
    {
        if (_finished)
            return this;
        if (!validCookieName(name))
            throw new Exception("Invalid cookie name: " ~ name);
        if (options.path.length && !headerSafe(options.path))
            throw new Exception("Invalid cookie path");
        if (options.domain.length && !headerSafe(options.domain))
            throw new Exception("Invalid cookie domain");
        if (!expired && options.maxAge < Duration.zero)
            throw new Exception("Cookie maxAge must not be negative");

        auto cookieValue = expired ? "" : encodeCookieValue(value);
        auto header = name ~ "=" ~ cookieValue;
        if (options.path.length)
            header ~= "; Path=" ~ options.path;
        if (options.domain.length)
            header ~= "; Domain=" ~ options.domain;
        if (expired)
        {
            header ~= "; Max-Age=0; Expires=Thu, 01 Jan 1970 00:00:00 GMT";
        }
        else if (options.maxAge != Duration.zero)
        {
            header ~= "; Max-Age=" ~ to!string(options.maxAge.total!"seconds");
            header ~= "; Expires=" ~ httpDate(Clock.currTime() + options.maxAge);
        }
        if (options.httpOnly)
            header ~= "; HttpOnly";
        if (options.secure)
            header ~= "; Secure";
        final switch (options.sameSite)
        {
            case SameSite.unset: break;
            case SameSite.lax: header ~= "; SameSite=Lax"; break;
            case SameSite.strict: header ~= "; SameSite=Strict"; break;
            case SameSite.none: header ~= "; SameSite=None"; break;
        }
        _setCookies ~= header;
        return this;
    }
}

private bool headerSafe(string value) pure nothrow @safe
{
    foreach (const char c; value)
        if (c == '\r' || c == '\n' || c == '\0')
            return false;
    return true;
}

private bool isTokenChar(char c) pure nothrow @safe
{
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
           (c >= '0' && c <= '9') || c == '!' || c == '#' || c == '$' ||
           c == '%' || c == '&' || c == '\'' || c == '*' || c == '+' ||
           c == '-' || c == '.' || c == '^' || c == '_' || c == '`' ||
           c == '|' || c == '~';
}

private void validateHeader(string name, string value)
{
    if (name.length == 0)
        throw new Exception("Response header name must not be empty");
    foreach (const char c; name)
        if (!isTokenChar(c))
            throw new Exception("Invalid response header name: " ~ name);
    if (!headerSafe(value))
        throw new Exception("Invalid response header value for " ~ name);
}

// `join` is only needed by `get`.
private import std.array : join;
