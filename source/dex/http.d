/// HTTP protocol helpers: status text, MIME types, dates, URL/cookie codecs.
module dex.http;

import std.algorithm.searching : canFind;
import std.datetime : SysTime;
import std.format : format;
import std.string : indexOf, split, startsWith, strip, toLower;

package:

/// ASCII reason phrase for a status code.
string reasonPhrase(int status)
{
    switch (status)
    {
        case 100: return "Continue";
        case 101: return "Switching Protocols";
        case 200: return "OK";
        case 201: return "Created";
        case 202: return "Accepted";
        case 203: return "Non-Authoritative Information";
        case 204: return "No Content";
        case 205: return "Reset Content";
        case 206: return "Partial Content";
        case 300: return "Multiple Choices";
        case 301: return "Moved Permanently";
        case 302: return "Found";
        case 303: return "See Other";
        case 304: return "Not Modified";
        case 307: return "Temporary Redirect";
        case 308: return "Permanent Redirect";
        case 400: return "Bad Request";
        case 401: return "Unauthorized";
        case 403: return "Forbidden";
        case 404: return "Not Found";
        case 405: return "Method Not Allowed";
        case 406: return "Not Acceptable";
        case 408: return "Request Timeout";
        case 409: return "Conflict";
        case 410: return "Gone";
        case 411: return "Length Required";
        case 412: return "Precondition Failed";
        case 413: return "Payload Too Large";
        case 414: return "URI Too Long";
        case 415: return "Unsupported Media Type";
        case 417: return "Expectation Failed";
        case 418: return "I'm a Teapot";
        case 422: return "Unprocessable Entity";
        case 429: return "Too Many Requests";
        case 431: return "Request Header Fields Too Large";
        case 500: return "Internal Server Error";
        case 501: return "Not Implemented";
        case 502: return "Bad Gateway";
        case 503: return "Service Unavailable";
        case 504: return "Gateway Timeout";
        case 505: return "HTTP Version Not Supported";
        default: return "Unknown";
    }
}

/// Resolve a MIME type from either a full MIME type or a file extension.
string mimeType(string type)
{
    auto t = type.strip.toLower;
    if (t.startsWith("."))
        t = t[1 .. $];
    if (t.indexOf('/') >= 0)
        return type.strip;

    switch (t)
    {
        case "html", "htm": return "text/html; charset=utf-8";
        case "txt", "text", "log": return "text/plain; charset=utf-8";
        case "json", "map": return "application/json; charset=utf-8";
        case "js", "mjs", "cjs": return "text/javascript; charset=utf-8";
        case "css": return "text/css; charset=utf-8";
        case "xml": return "application/xml; charset=utf-8";
        case "csv": return "text/csv; charset=utf-8";
        case "md", "markdown": return "text/markdown; charset=utf-8";
        case "yaml", "yml": return "application/yaml; charset=utf-8";
        case "png": return "image/png";
        case "jpg", "jpeg": return "image/jpeg";
        case "gif": return "image/gif";
        case "svg": return "image/svg+xml";
        case "webp": return "image/webp";
        case "avif": return "image/avif";
        case "ico": return "image/x-icon";
        case "woff": return "font/woff";
        case "woff2": return "font/woff2";
        case "ttf": return "font/ttf";
        case "otf": return "font/otf";
        case "pdf": return "application/pdf";
        case "wasm": return "application/wasm";
        case "zip": return "application/zip";
        case "gz": return "application/gzip";
        case "tar": return "application/x-tar";
        case "mp4": return "video/mp4";
        case "webm": return "video/webm";
        case "mp3": return "audio/mpeg";
        case "ogg": return "audio/ogg";
        case "wav": return "audio/wav";
        default: return "application/octet-stream";
    }
}

/// Base media type without parameters, lowercased. E.g. `application/json`.
string mediaType(string contentType)
{
    auto semi = contentType.indexOf(';');
    auto base_ = semi >= 0 ? contentType[0 .. semi] : contentType;
    return base_.strip.toLower;
}

/// Format a time as an RFC 1123 HTTP date.
string httpDate(SysTime time)
{
    auto t = time.toUTC();
    static immutable string[] days = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
    static immutable string[] months =
        ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
    return format("%s, %02d %s %04d %02d:%02d:%02d GMT",
                  days[cast(size_t) t.dayOfWeek],
                  t.day,
                  months[cast(int) t.month - 1],
                  t.year,
                  t.hour,
                  t.minute,
                  t.second);
}

private int hexValue(char c) pure nothrow @safe
{
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

/// Decode `%XX` escapes. Malformed escapes are preserved verbatim.
string percentDecode(string input, bool plusAsSpace = false)
{
    char[] out_;
    out_.reserve(input.length);

    for (size_t i = 0; i < input.length; ++i)
    {
        const c = input[i];
        if (plusAsSpace && c == '+')
        {
            out_ ~= ' ';
        }
        else if (c == '%' && i + 2 < input.length)
        {
            const hi = hexValue(input[i + 1]);
            const lo = hexValue(input[i + 2]);
            if (hi >= 0 && lo >= 0)
            {
                out_ ~= cast(char) ((hi << 4) | lo);
                i += 2;
            }
            else
            {
                out_ ~= c;
            }
        }
        else
        {
            out_ ~= c;
        }
    }
    return out_.idup;
}

/// Decode a URL path segment-by-segment. Slashes remain separators.
string decodePath(string rawPath)
{
    char[] out_;
    out_.reserve(rawPath.length);
    size_t start = 0;
    while (true)
    {
        const slash = rawPath[start .. $].indexOf('/');
        if (slash < 0)
        {
            out_ ~= percentDecode(rawPath[start .. $]);
            break;
        }
        out_ ~= percentDecode(rawPath[start .. start + slash]);
        out_ ~= '/';
        start += slash + 1;
    }
    return out_.idup;
}

/// Percent-encode a cookie value so it round-trips through `parseCookies`.
string encodeCookieValue(string value)
{
    static immutable char[] safe =
        "!#$&'()*+-./:<=>?@[]^_`{|}~";
    char[] out_;
    out_.reserve(value.length);
    foreach (const char c; value)
    {
        const u = cast(ubyte) c;
        if ((u >= 'a' && u <= 'z') || (u >= 'A' && u <= 'Z') ||
            (u >= '0' && u <= '9') || canFind(safe, c))
        {
            out_ ~= c;
        }
        else
        {
            out_ ~= format("%%%02X", u);
        }
    }
    return out_.idup;
}

private bool isCookieNameChar(char c) pure nothrow @safe
{
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
           (c >= '0' && c <= '9') || c == '_' || c == '-' || c == '.' ||
           c == '!';
}

/// Validate an outgoing cookie name.
bool validCookieName(string name) pure nothrow @safe
{
    if (name.length == 0)
        return false;
    foreach (const char c; name)
        if (!isCookieNameChar(c))
            return false;
    return true;
}

/// Parse a request `Cookie` header into name/value pairs.
string[string] parseCookies(string header)
{
    string[string] cookies;
    foreach (part; header.split(';'))
    {
        auto p = part.strip;
        if (p.length == 0)
            continue;
        const eq = p.indexOf('=');
        if (eq <= 0)
            continue;
        const name = p[0 .. eq].strip;
        auto value = p[eq + 1 .. $].strip;
        if (value.length >= 2 && value[0] == '"' && value[$ - 1] == '"')
            value = value[1 .. $ - 1];
        cookies[name] = percentDecode(value);
    }
    return cookies;
}

/// One decoded key/value pair from a query string or form body.
struct QueryPair
{
    string key;
    string value;
}

/// Parse an `application/x-www-form-urlencoded` string.
QueryPair[] parseQueryString(string input)
{
    QueryPair[] pairs;
    if (input.length == 0)
        return pairs;

    size_t start = 0;
    while (true)
    {
        const amp = input[start .. $].indexOf('&');
        const part = amp < 0 ? input[start .. $] : input[start .. start + amp];
        if (part.length != 0)
        {
            const eq = part.indexOf('=');
            const key = eq < 0 ? part : part[0 .. eq];
            const value = eq < 0 ? "" : part[eq + 1 .. $];
            pairs ~= QueryPair(percentDecode(key, true), percentDecode(value, true));
        }
        if (amp < 0)
            break;
        start += amp + 1;
    }
    return pairs;
}

/// Extract the host name from a `Host` header, dropping a port.
string hostName(string host)
{
    host = host.strip;
    if (host.length && host[0] == '[')
    {
        const close = host.indexOf(']');
        return close > 0 ? host[1 .. close] : host;
    }
    const colon = host.indexOf(':', 0);
    if (colon > 0)
    {
        const tail = host[colon + 1 .. $];
        bool digits = tail.length != 0;
        foreach (const char c; tail)
            digits = digits && (c >= '0' && c <= '9');
        if (digits)
            return host[0 .. colon];
    }
    return host;
}
