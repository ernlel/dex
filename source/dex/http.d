/// HTTP protocol helpers: status text, MIME types, dates, URL/cookie codecs.
module dex.http;

import std.algorithm.searching : canFind;
import std.base64 : Base64URLNoPadding;
import std.conv : ConvException, to;
import std.datetime : DateTime, SysTime, UTC;
import std.digest.sha : sha256Of;
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

/// RFC 9110 `tchar`: characters allowed in tokens (methods, header names).
bool isTokenChar(char c) pure nothrow @nogc @safe
{
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
           (c >= '0' && c <= '9') || c == '!' || c == '#' || c == '$' ||
           c == '%' || c == '&' || c == '\'' || c == '*' || c == '+' ||
           c == '-' || c == '.' || c == '^' || c == '_' || c == '`' ||
           c == '|' || c == '~';
}

/// Whether `value` is a non-empty RFC 9110 token.
bool isToken(const(char)[] value) pure nothrow @nogc @safe
{
    if (value.length == 0)
        return false;
    foreach (const char c; value)
        if (!isTokenChar(c))
            return false;
    return true;
}

/// Value of a hex digit, or -1.
int hexValue(char c) pure nothrow @nogc @safe
{
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

/// Decode `%XX` escapes. Malformed escapes are preserved verbatim.
///
/// Returns `input` itself (no allocation) when there is nothing to decode.
string percentDecode(string input, bool plusAsSpace = false)
{
    import std.exception : assumeUnique;

    if (input.indexOf('%') < 0 && (!plusAsSpace || input.indexOf('+') < 0))
        return input;

    auto out_ = new char[input.length];
    size_t n;
    for (size_t i = 0; i < input.length; ++i)
    {
        char c = input[i];
        if (plusAsSpace && c == '+')
        {
            c = ' ';
        }
        else if (c == '%' && i + 2 < input.length)
        {
            const hi = hexValue(input[i + 1]);
            const lo = hexValue(input[i + 2]);
            if (hi >= 0 && lo >= 0)
            {
                c = cast(char) ((hi << 4) | lo);
                i += 2;
            }
        }
        out_[n++] = c;
    }
    return assumeUnique(out_[0 .. n]);
}

/// Decode a URL path segment-by-segment. Slashes remain separators.
string decodePath(string rawPath)
{
    if (rawPath.indexOf('%') < 0)
        return rawPath;

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
    import std.exception : assumeUnique;

    static immutable char[] safe =
        "!#$&'()*+-./:<=>?@[]^_`{|}~";
    static immutable char[] hexDigits = "0123456789ABCDEF";
    char[] out_;
    out_.reserve(value.length);
    foreach (const char c; value)
    {
        if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
            (c >= '0' && c <= '9') || canFind(safe, c))
        {
            out_ ~= c;
        }
        else
        {
            const u = cast(ubyte) c;
            out_ ~= '%';
            out_ ~= hexDigits[u >> 4];
            out_ ~= hexDigits[u & 0xF];
        }
    }
    return assumeUnique(out_);
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

/// Compute a strong ETag (`"<base64url>"`) from response bytes using SHA-256.
string computeStrongETag(const(ubyte)[] data)
{
    auto digest = sha256Of(data);
    return `"` ~ Base64URLNoPadding.encode(digest[0 .. 16]).idup ~ `"`;
}

/// Compute a fast weak ETag (`W/"<hex-size>-<hex-mtime>"`) for static files.
string computeWeakETag(ulong size, long mtimeSecs)
{
    return format(`W/"%x-%x"`, size, cast(ulong) mtimeSecs);
}

/// Convert a strong ETag to a weak ETag (no-op if already weak).
string weakenETag(string etag)
{
    if (etag.length == 0 || etag.startsWith("W/"))
        return etag;
    return "W/" ~ etag;
}

/// Strip weak prefix (`W/`) for weak ETag comparison per RFC 9110.
private string opaqueETag(string tag)
{
    tag = tag.strip;
    if (tag.startsWith("W/"))
        return tag[2 .. $].strip;
    return tag;
}

/// Check whether an `If-None-Match` header matches `etag` using weak comparison.
bool matchesIfNoneMatch(string header, string etag)
{
    if (header.length == 0 || etag.length == 0)
        return false;

    const target = opaqueETag(etag);
    size_t i = 0;
    while (i < header.length)
    {
        while (i < header.length && (header[i] == ',' || header[i] == ' ' || header[i] == '\t'))
            ++i;
        if (i >= header.length)
            break;

        if (header[i] == '*')
        {
            const rest = header[i + 1 .. $].strip;
            if (rest.length == 0 || rest[0] == ',')
                return true;
        }

        const start = i;
        bool inQuotes = false;
        while (i < header.length)
        {
            const char c = header[i];
            if (c == '"')
                inQuotes = !inQuotes;
            else if (c == ',' && !inQuotes)
                break;
            ++i;
        }
        const candidate = opaqueETag(header[start .. i]);
        if (candidate.length != 0 && candidate == target)
            return true;
    }
    return false;
}

/// Parse an RFC 9110 HTTP date (IMF-fixdate, e.g. `Sun, 06 Nov 1994 08:49:37 GMT`).
bool parseHttpDate(string value, out SysTime result)
{
    static immutable string[12] months =
        ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];

    auto s = value.strip;
    const comma = s.indexOf(',');
    if (comma < 0)
        return false;
    s = s[comma + 1 .. $].strip;
    auto parts = s.split();
    if (parts.length < 5)
        return false;
    if (parts[4] != "GMT" && parts[4] != "UTC")
        return false;

    try
    {
        const day = to!int(parts[0]);
        int month = 0;
        foreach (idx, name; months)
        {
            if (name == parts[1])
            {
                month = cast(int) idx + 1;
                break;
            }
        }
        if (month == 0)
            return false;
        const year = to!int(parts[2]);
        auto hms = parts[3].split(':');
        if (hms.length != 3)
            return false;
        const hour = to!int(hms[0]);
        const minute = to!int(hms[1]);
        const second = to!int(hms[2]);

        result = SysTime(DateTime(year, month, day, hour, minute, second), UTC());
        return true;
    }
    catch (Exception)
    {
        return false;
    }
}

/// Build a safe `Content-Disposition: attachment` header value.
string contentDispositionAttachment(string filename)
{
    import std.path : baseName;

    auto name = baseName(filename);
    char[] ascii;
    ascii.reserve(name.length);
    bool hasNonAscii = false;

    foreach (const char c; name)
    {
        if (c == '\r' || c == '\n' || c == '\0')
            continue;
        if (cast(ubyte) c >= 0x80)
        {
            hasNonAscii = true;
            ascii ~= '_';
            continue;
        }
        if (c == '"' || c == '\\')
            ascii ~= '_';
        else
            ascii ~= c;
    }
    if (ascii.length == 0)
        ascii ~= "download".dup;

    auto header = `attachment; filename="` ~ ascii.idup ~ `"`;
    if (hasNonAscii)
    {
        static immutable char[] hex = "0123456789ABCDEF";
        char[] encoded;
        encoded.reserve(name.length * 3);
        foreach (const char c; name)
        {
            if (c == '\r' || c == '\n' || c == '\0')
                continue;
            if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
                (c >= '0' && c <= '9') || c == '-' || c == '.' ||
                c == '_' || c == '~')
            {
                encoded ~= c;
            }
            else
            {
                const u = cast(ubyte) c;
                encoded ~= '%';
                encoded ~= hex[u >> 4];
                encoded ~= hex[u & 0xF];
            }
        }
        header ~= "; filename*=UTF-8''" ~ encoded.idup;
    }
    return header;
}

/// Select the best matching candidate MIME/extension against an `Accept` header.
/// Returns `null` if no candidate is acceptable.
string negotiateAccept(string acceptHeader, const(string)[] candidates)
{
    if (candidates.length == 0)
        return null;
    if (acceptHeader is null || acceptHeader.strip.length == 0)
        return candidates[0];

    struct AcceptRule
    {
        string type;
        string subtype;
        double q;
        size_t specificity;
        size_t order;
    }

    AcceptRule[] rules;
    size_t idx = 0;
    foreach (part; acceptHeader.split(','))
    {
        auto pieces = part.split(';');
        auto range = pieces[0].strip.toLower;
        const slash = range.indexOf('/');
        if (slash <= 0 || slash == range.length - 1)
            continue;

        const type = range[0 .. slash].strip;
        const subtype = range[slash + 1 .. $].strip;
        double q = 1.0;
        foreach (param; pieces[1 .. $])
        {
            const p = param.strip.toLower;
            if (p.startsWith("q="))
            {
                try
                    q = to!double(p[2 .. $].strip);
                catch (Exception)
                    q = 0.0;
            }
        }
        if (q < 0.0) q = 0.0;
        if (q > 1.0) q = 1.0;

        size_t spec = 2;
        if (type == "*" && subtype == "*")
            spec = 0;
        else if (subtype == "*")
            spec = 1;

        rules ~= AcceptRule(type, subtype, q, spec, idx++);
    }

    if (rules.length == 0)
        return null;

    string bestCandidate = null;
    double bestQ = 0.0;
    long bestSpec = -1;
    size_t bestRuleOrder = size_t.max;

    foreach (cand; candidates)
    {
        const resolved = cand.indexOf('/') >= 0 ? cand : mimeType(cand);
        const media = mediaType(resolved);
        const slash = media.indexOf('/');
        if (slash <= 0)
            continue;
        const cType = media[0 .. slash];
        const cSub = media[slash + 1 .. $];

        // Find the most specific matching rule for this candidate.
        bool matched = false;
        AcceptRule matchedRule;
        foreach (const ref r; rules)
        {
            const matches = (r.type == "*" && r.subtype == "*") ||
                            (r.type == cType && (r.subtype == "*" || r.subtype == cSub));
            if (!matches)
                continue;
            if (!matched || r.specificity > matchedRule.specificity ||
                (r.specificity == matchedRule.specificity && r.q > matchedRule.q))
            {
                matched = true;
                matchedRule = r;
            }
        }

        if (!matched || matchedRule.q <= 0.0)
            continue;

        const better = bestCandidate is null ||
                       matchedRule.q > bestQ ||
                       (matchedRule.q == bestQ && cast(long) matchedRule.specificity > bestSpec) ||
                       (matchedRule.q == bestQ && cast(long) matchedRule.specificity == bestSpec &&
                        matchedRule.order < bestRuleOrder);
        if (better)
        {
            bestCandidate = cand;
            bestQ = matchedRule.q;
            bestSpec = cast(long) matchedRule.specificity;
            bestRuleOrder = matchedRule.order;
        }
    }

    return bestCandidate;
}

/// Parsed IPv4/IPv6 address normalized to 16 bytes (IPv4 uses IPv4-mapped `::ffff:a.b.c.d`).
struct ParsedIp
{
    ubyte[16] bytes;
    bool isV6;
}

/// Parse an IPv4 or IPv6 literal (with optional `%zone` or `[brackets]`).
bool parseIpAddress(string input, out ParsedIp parsed)
{
    auto s = input.strip;
    if (s.length == 0)
        return false;
    if (s[0] == '[' && s[$ - 1] == ']')
        s = s[1 .. $ - 1];
    const pct = s.indexOf('%');
    if (pct >= 0)
        s = s[0 .. pct];

    if (s.indexOf(':') < 0)
    {
        ubyte[4] v4;
        if (!parseIPv4Bytes(s, v4))
            return false;
        parsed.bytes[0 .. 10] = 0;
        parsed.bytes[10] = 0xff;
        parsed.bytes[11] = 0xff;
        parsed.bytes[12 .. 16] = v4[];
        parsed.isV6 = false;
        return true;
    }

    if (!parseIPv6Bytes(s, parsed.bytes))
        return false;
    parsed.isV6 = true;
    return true;
}

private bool parseIPv4Bytes(string s, out ubyte[4] outBytes)
{
    auto parts = s.split('.');
    if (parts.length != 4)
        return false;
    foreach (i, part; parts)
    {
        if (part.length == 0 || part.length > 3)
            return false;
        int val = 0;
        foreach (const char c; part)
        {
            if (c < '0' || c > '9')
                return false;
            val = val * 10 + (c - '0');
        }
        if (val > 255)
            return false;
        outBytes[i] = cast(ubyte) val;
    }
    return true;
}

private bool parseIPv6Bytes(string s, out ubyte[16] outBytes)
{
    const dbl = s.indexOf("::");
    string leftStr = s;
    string rightStr = null;
    bool hasCompressed = false;
    if (dbl >= 0)
    {
        if (s[dbl + 2 .. $].indexOf("::") >= 0)
            return false;
        hasCompressed = true;
        leftStr = s[0 .. dbl];
        rightStr = s[dbl + 2 .. $];
    }

    ushort[] parseGroups(string str, out bool hadIPv4Tail, out ubyte[4] v4Tail)
    {
        hadIPv4Tail = false;
        if (str.length == 0)
            return null;
        auto parts = str.split(':');
        ushort[] groups;
        foreach (idx, p; parts)
        {
            if (p.length == 0)
                throw new ConvException("Empty IPv6 group");
            if (p.indexOf('.') >= 0)
            {
                if (idx != parts.length - 1 || !parseIPv4Bytes(p, v4Tail))
                    throw new ConvException("Invalid IPv4 tail");
                hadIPv4Tail = true;
                groups ~= cast(ushort) ((v4Tail[0] << 8) | v4Tail[1]);
                groups ~= cast(ushort) ((v4Tail[2] << 8) | v4Tail[3]);
                continue;
            }
            if (p.length > 4)
                throw new ConvException("Invalid IPv6 group");
            ushort val = 0;
            foreach (const char c; p)
            {
                const hv = hexValue(c);
                if (hv < 0)
                    throw new ConvException("Invalid hex");
                val = cast(ushort) ((val << 4) | hv);
            }
            groups ~= val;
        }
        return groups;
    }

    try
    {
        bool leftV4, rightV4;
        ubyte[4] dummy;
        auto left = parseGroups(leftStr, leftV4, dummy);
        if (hasCompressed && leftV4)
            return false;
        auto right = hasCompressed ? parseGroups(rightStr, rightV4, dummy) : null;

        if (!hasCompressed && left.length != 8)
            return false;
        if (hasCompressed && left.length + right.length >= 8)
            return false;

        ushort[8] groups;
        foreach (i, g; left)
            groups[i] = g;
        if (hasCompressed)
        {
            const rightStart = 8 - right.length;
            foreach (i, g; right)
                groups[rightStart + i] = g;
        }

        foreach (i, g; groups)
        {
            outBytes[i * 2] = cast(ubyte) (g >> 8);
            outBytes[i * 2 + 1] = cast(ubyte) (g & 0xff);
        }
        return true;
    }
    catch (ConvException)
    {
        return false;
    }
}

/// Parsed CIDR range (normalized to 128-bit prefix over IPv4-mapped IPv6).
struct IpCidr
{
    ubyte[16] network;
    ubyte prefixLen;

    bool matches(const ref ParsedIp ip) const
    {
        const fullBytes = prefixLen / 8;
        const remBits = prefixLen % 8;
        for (size_t i = 0; i < fullBytes; ++i)
            if (ip.bytes[i] != network[i])
                return false;
        if (remBits != 0)
        {
            const mask = cast(ubyte) (0xff << (8 - remBits));
            if ((ip.bytes[fullBytes] & mask) != (network[fullBytes] & mask))
                return false;
        }
        return true;
    }
}

/// Parse an IP or CIDR string (e.g. `"10.0.0.0/8"`, `"127.0.0.1"`, `"::1/128"`).
bool parseIpCidr(string spec, out IpCidr cidr)
{
    const slash = spec.indexOf('/');
    const addrStr = (slash >= 0 ? spec[0 .. slash] : spec).strip;
    ParsedIp ip;
    if (!parseIpAddress(addrStr, ip))
        return false;

    uint prefix;
    if (slash < 0)
    {
        prefix = 128;
    }
    else
    {
        try
            prefix = to!uint(spec[slash + 1 .. $].strip);
        catch (ConvException)
            return false;

        if (ip.isV6)
        {
            if (prefix > 128)
                return false;
        }
        else
        {
            if (prefix > 32)
                return false;
            prefix += 96; // Normalize IPv4 /0..32 into ::ffff:0:0/96..128
        }
    }

    cidr.network = ip.bytes;
    cidr.prefixLen = cast(ubyte) prefix;
    return true;
}

/// Proxy trust configuration for `app.trustProxy`.
///
/// Controls how `X-Forwarded-For`, `X-Forwarded-Proto`, and `X-Forwarded-Host`
/// are interpreted for `req.ip`, `req.ips`, `req.protocol`, `req.secure`,
/// and `req.hostname`.
public struct TrustProxy
{
    enum Mode
    {
        none,
        all,
        hops,
        subnets
    }

    Mode mode = Mode.none;
    size_t hopCount;
    IpCidr[] trustedCidrs;

    this(bool enabled)
    {
        mode = enabled ? Mode.all : Mode.none;
    }

    this(size_t hops)
    {
        mode = hops == 0 ? Mode.none : Mode.hops;
        hopCount = hops;
    }

    this(int hops)
    {
        this(hops > 0 ? cast(size_t) hops : 0);
    }

    this(string spec)
    {
        this([spec]);
    }

    this(const(string)[] specs)
    {
        if (specs.length == 0)
        {
            mode = Mode.none;
            return;
        }
        mode = Mode.subnets;
        foreach (s; specs)
            addSpec(s);
    }

    static TrustProxy none() { return TrustProxy.init; }
    static TrustProxy all() { return TrustProxy(true); }
    static TrustProxy hops(size_t n) { return TrustProxy(n); }
    static TrustProxy subnets(const(string)[] specs...) { return TrustProxy(specs); }

    void opAssign(bool enabled)
    {
        mode = enabled ? Mode.all : Mode.none;
        hopCount = 0;
        trustedCidrs = null;
    }

    void opAssign(size_t hops)
    {
        mode = hops == 0 ? Mode.none : Mode.hops;
        hopCount = hops;
        trustedCidrs = null;
    }

    void opAssign(int hops)
    {
        opAssign(hops > 0 ? cast(size_t) hops : 0);
    }

    void opAssign(string spec)
    {
        opAssign([spec]);
    }

    void opAssign(const(string)[] specs)
    {
        trustedCidrs = null;
        hopCount = 0;
        if (specs.length == 0)
        {
            mode = Mode.none;
            return;
        }
        mode = Mode.subnets;
        foreach (s; specs)
            addSpec(s);
    }

    bool opCast(T : bool)() const
    {
        return mode != Mode.none;
    }

    bool isTrustedAddress(string ipStr) const
    {
        final switch (mode)
        {
            case Mode.none: return false;
            case Mode.all: return true;
            case Mode.hops: return hopCount > 0;
            case Mode.subnets:
                ParsedIp ip;
                if (!parseIpAddress(ipStr, ip))
                    return false;
                foreach (const ref cidr; trustedCidrs)
                    if (cidr.matches(ip))
                        return true;
                return false;
        }
    }

    private void addSpec(string spec)
    {
        const low = spec.strip.toLower;
        if (low == "loopback")
        {
            addCidr("127.0.0.0/8");
            addCidr("::1/128");
        }
        else if (low == "linklocal")
        {
            addCidr("169.254.0.0/16");
            addCidr("fe80::/10");
        }
        else if (low == "uniquelocal")
        {
            addCidr("10.0.0.0/8");
            addCidr("172.16.0.0/12");
            addCidr("192.168.0.0/16");
            addCidr("fc00::/7");
        }
        else
        {
            addCidr(spec);
        }
    }

    private void addCidr(string spec)
    {
        IpCidr cidr;
        if (!parseIpCidr(spec, cidr))
            throw new Exception("Invalid trusted proxy IP/CIDR: " ~ spec);
        trustedCidrs ~= cidr;
    }
}
