/// Signed cookies and server-side session middleware example demonstrating:
/// - HMAC-SHA256 cookie signing and key rotation (`app.cookieSecrets`)
/// - `session()` middleware with `MemorySessionStore`
/// - Session fixation protection via `req.session.regenerate()`
/// - Typed JSON login binding (`req.bind!LoginPayload`)
module app;

import dex;
import core.time : dur;
import std.json : JSONValue;
import std.stdio : writeln;

struct LoginPayload
{
    string username;
    string password;
}

void main()
{
    auto app = new App;
    app.cookieSecrets = ["dev-signing-secret-v2", "dev-signing-secret-v1"];

    app.use(logger());
    app.use(session(SessionOptions(
        ttl: 12.dur!"hours"
    )));

    app.post("/login", (req, res)
    {
        auto creds = req.bind!LoginPayload();
        if (creds.username != "alice" || creds.password != "secret")
            throw new HttpError(401, "Invalid credentials");

        req.session.regenerate();
        req.session["user"] = creds.username;
        req.session["visits"] = 1;
        res.signedCookie("prefs", "theme=dark");
        res.json(["loggedIn": JSONValue(true), "user": JSONValue(creds.username)]);
    });

    app.get("/profile", (req, res)
    {
        if (!req.session.has("user"))
            throw new HttpError(401, "Not logged in");

        const visits = req.session.get!int("visits", 0) + 1;
        req.session["visits"] = visits;

        const prefs = req.signedCookie("prefs");
        res.json([
            "user": JSONValue(req.session.get!string("user")),
            "visits": JSONValue(visits),
            "prefs": JSONValue(prefs is null ? "default" : prefs),
            "sessionId": JSONValue(req.session.id)
        ]);
    });

    app.post("/logout", (req, res)
    {
        req.session.destroy();
        res.clearCookie("prefs");
        res.json(["loggedOut": true]);
    });

    writeln("Sessions example listening on http://localhost:3000");
    app.listen(3000);
}
