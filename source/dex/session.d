/// Signed cookie helpers and server-side session state/store abstractions.
module dex.session;

import core.sync.mutex : Mutex;
import core.time : Duration, dur, MonoTime;
import std.base64 : Base64URLNoPadding;
import std.digest.hmac : hmac;
import std.digest.sha : SHA256;
import std.json : JSONType, JSONValue;
import std.string : indexOf;

import dex.jsonx : fromJSONValue, toJSONValue;

/// Sign a cookie value using HMAC-SHA256 (`s:<value>.<signature>`).
string signCookie(string value, string secret)
{
    if (secret.length == 0)
        throw new Exception("Cookie signing requires a non-empty secret");
    auto mac = hmac!SHA256(cast(const(ubyte)[]) value, cast(const(ubyte)[]) secret);
    const sig = Base64URLNoPadding.encode(mac[]);
    return "s:" ~ value ~ "." ~ sig.idup;
}

/// Verify and unwrap a signed cookie (`s:<value>.<signature>`) against one or
/// more secrets (supporting key rotation). Returns `true` and populates `value`
/// when valid.
bool unsignCookie(string signedValue, const(string)[] secrets, out string value)
{
    if (signedValue.length < 4 || signedValue[0 .. 2] != "s:")
        return false;
    const payload = signedValue[2 .. $];
    const dot = lastIndexOfChar(payload, '.');
    if (dot <= 0 || dot == payload.length - 1)
        return false;

    const rawVal = payload[0 .. dot];
    const providedSig = payload[dot + 1 .. $];

    foreach (secret; secrets)
    {
        if (secret.length == 0)
            continue;
        auto mac = hmac!SHA256(cast(const(ubyte)[]) rawVal, cast(const(ubyte)[]) secret);
        const expectedSig = Base64URLNoPadding.encode(mac[]);
        if (constantTimeEquals(providedSig, expectedSig))
        {
            value = rawVal;
            return true;
        }
    }
    return false;
}

/// Convenience overload verifying against a single secret.
bool unsignCookie(string signedValue, string secret, out string value)
{
    if (secret.length == 0)
        return false;
    string[1] arr = [secret];
    return unsignCookie(signedValue, arr[], value);
}

private sizediff_t lastIndexOfChar(string s, char ch) pure nothrow @nogc @safe
{
    for (size_t i = s.length; i > 0; --i)
        if (s[i - 1] == ch)
            return cast(sizediff_t) (i - 1);
    return -1;
}

private bool constantTimeEquals(const(char)[] a, const(char)[] b) pure nothrow @nogc @safe
{
    if (a.length != b.length)
        return false;
    ubyte diff = 0;
    foreach (i, const char c; a)
        diff |= cast(ubyte) (c ^ b[i]);
    return diff == 0;
}

/// Generate a cryptographically random URL-safe session identifier.
string generateSessionId()
{
    ubyte[24] buf;
    bool filled = false;

    version (Posix)
    {
        import core.stdc.stdio : fclose, fopen, fread;

        auto f = fopen("/dev/urandom", "rb");
        if (f !is null)
        {
            scope (exit) fclose(f);
            if (fread(buf.ptr, 1, buf.length, f) == buf.length)
                filled = true;
        }
    }

    if (!filled)
    {
        import std.random : unpredictableSeed, Xorshift;

        auto rng = Xorshift(unpredictableSeed);
        foreach (i; 0 .. buf.length)
        {
            buf[i] = cast(ubyte) (rng.front & 0xff);
            rng.popFront();
        }
    }

    return Base64URLNoPadding.encode(buf[]).idup;
}

/// Pluggable persistence backend for `session()` middleware.
interface SessionStore
{
    /// Load session data by ID. Returns `false` if absent or expired.
    bool get(string id, out JSONValue[string] data);

    /// Save session data with a time-to-live duration.
    void set(string id, JSONValue[string] data, Duration ttl);

    /// Refresh expiration for an existing session without rewriting data.
    void touch(string id, Duration ttl);

    /// Remove a session from the store.
    void destroy(string id);
}

/// Thread-safe in-memory `SessionStore` with TTL expiration and periodic cleanup.
class MemorySessionStore : SessionStore
{
    private struct Entry
    {
        JSONValue[string] data;
        MonoTime expiresAt;
    }

    private Entry[string] _entries;
    private Mutex _mutex;
    private MonoTime _lastCleanup;

    this()
    {
        _mutex = new Mutex;
        _lastCleanup = MonoTime.currTime;
    }

    override bool get(string id, out JSONValue[string] data)
    {
        const now = MonoTime.currTime;
        synchronized (_mutex)
        {
            pruneIfNeeded(now);
            auto entry = id in _entries;
            if (entry is null)
                return false;
            if (now >= entry.expiresAt)
            {
                _entries.remove(id);
                return false;
            }
            data = cloneMap(entry.data);
            return true;
        }
    }

    override void set(string id, JSONValue[string] data, Duration ttl)
    {
        const expiresAt = MonoTime.currTime + (ttl > Duration.zero ? ttl : dur!"seconds"(1));
        synchronized (_mutex)
        {
            pruneIfNeeded(MonoTime.currTime);
            _entries[id] = Entry(cloneMap(data), expiresAt);
        }
    }

    override void touch(string id, Duration ttl)
    {
        const now = MonoTime.currTime;
        const expiresAt = now + (ttl > Duration.zero ? ttl : dur!"seconds"(1));
        synchronized (_mutex)
        {
            if (auto entry = id in _entries)
            {
                if (now >= entry.expiresAt)
                    _entries.remove(id);
                else
                    entry.expiresAt = expiresAt;
            }
        }
    }

    override void destroy(string id)
    {
        synchronized (_mutex)
        {
            _entries.remove(id);
        }
    }

    private void pruneIfNeeded(MonoTime now)
    {
        if (now - _lastCleanup < dur!"seconds"(60) && _entries.length <= 1024)
            return;
        string[] expired;
        foreach (k, ref entry; _entries)
        {
            if (now >= entry.expiresAt)
                expired ~= k;
        }
        foreach (k; expired)
            _entries.remove(k);
        _lastCleanup = now;
    }

    private static JSONValue[string] cloneMap(const JSONValue[string] src)
    {
        JSONValue[string] copy;
        foreach (k, v; src)
            copy[k] = v;
        return copy;
    }
}

/// Per-request session state attached by `session()` middleware as `req.session`.
class Session
{
    private string _id;
    private JSONValue[string] _data;
    private bool _isNew;
    private bool _modified;
    private bool _destroyed;
    private bool _regenerated;
    private string _replacedId;

    package this(string id, JSONValue[string] data, bool isNew)
    {
        _id = id;
        _data = data;
        _isNew = isNew;
    }

    /// Current session identifier.
    @property string id() const { return _id; }

    /// Whether this session was created during the current request.
    @property bool isNew() const { return _isNew; }

    /// Whether session data was modified during the current request.
    @property bool isModified() const { return _modified; }

    /// Whether `destroy()` was called on this session.
    @property bool isDestroyed() const { return _destroyed; }

    package @property bool wasRegenerated() const { return _regenerated; }
    package @property string replacedId() const { return _replacedId; }
    package @property JSONValue[string] rawData() { return _data; }

    /// Read a key as `JSONValue`, or `JSONValue(null)` if missing.
    JSONValue opIndex(string key) const
    {
        auto v = key in _data;
        return v is null ? JSONValue(null) : *v;
    }

    /// Store any JSON-serializable D value under `key`.
    void opIndexAssign(T)(auto ref T value, string key)
    {
        set(key, value);
    }

    /// Store any JSON-serializable D value under `key`.
    void set(T)(string key, auto ref T value)
    {
        _data[key] = toJSONValue(value);
        _modified = true;
        _destroyed = false;
    }

    /// Read a typed value from the session, or `defaultValue` when missing/null.
    T get(T)(string key, T defaultValue = T.init) const
    {
        auto v = key in _data;
        if (v is null || v.type == JSONType.null_)
            return defaultValue;
        return fromJSONValue!T(*v, key, 500);
    }

    /// Whether `key` is present in the session.
    bool has(string key) const
    {
        return (key in _data) !is null;
    }

    /// Remove `key` from the session.
    void remove(string key)
    {
        if (_data.remove(key))
            _modified = true;
    }

    /// Clear all keys in the session.
    void clear()
    {
        if (_data.length != 0)
        {
            _data.clear();
            _modified = true;
        }
    }

    /// Rotate the session ID (recommended on login to prevent session fixation).
    void regenerate()
    {
        if (_replacedId.length == 0)
            _replacedId = _id;
        _id = generateSessionId();
        _isNew = true;
        _modified = true;
        _destroyed = false;
        _regenerated = true;
    }

    /// Mark the session for deletion and clear its cookie on response finish.
    void destroy()
    {
        _data.clear();
        _destroyed = true;
        _modified = true;
    }
}
