import dex;
import std.base64 : Base64, Base64Exception;
import std.process : environment;
import std.string : icmp, indexOf, strip;
import std.stdio : writeln;

/// CORS configuration.
struct CorsOptions
{
    string origin = "*";
    string methods = "GET, POST, PUT, PATCH, DELETE, OPTIONS";
    string headers = "Content-Type, Authorization";
    string maxAge = "86400";
    bool credentials;
}

/// Add CORS headers and answer preflight requests.
Middleware cors(CorsOptions options = CorsOptions.init)
{
    if (options.credentials && options.origin == "*")
        throw new Exception("CORS credentials require an explicit origin");

    return (Request request, Response response, Next next)
    {
        response.set("Access-Control-Allow-Origin", options.origin);
        if (options.origin != "*")
            response.append("Vary", "Origin");

        response.set("Access-Control-Allow-Methods", options.methods);

        const requestedHeaders =
            request.get("access-control-request-headers");
        response.set("Access-Control-Allow-Headers",
                     requestedHeaders is null || requestedHeaders.length == 0
                         ? options.headers : requestedHeaders);

        if (options.credentials)
            response.set("Access-Control-Allow-Credentials", "true");
        if (options.maxAge.length)
            response.set("Access-Control-Max-Age", options.maxAge);

        if (request.method == "OPTIONS" &&
            request.get("access-control-request-method") !is null)
        {
            response.status(204).end();
            return;
        }

        next();
    };
}

/// HTTP Basic authentication.
///
/// Only use Basic auth behind TLS; credentials are only base64-encoded,
/// not encrypted.
Middleware basicAuth(string username, string password, string realm = "dex")
{
    return (Request request, Response response, Next next)
    {
        const header = request.get("authorization");
        if (header is null || header.length < 6 ||
            icmp(header[0 .. 5], "Basic") != 0 || header[5] != ' ')
        {
            challenge(response, realm);
            return;
        }

        const token = header[6 .. $].strip;
        string decoded;
        try
        {
            decoded = cast(string) Base64.decode(token);
        }
        catch (Base64Exception)
        {
            challenge(response, realm);
            return;
        }

        const colon = decoded.indexOf(':');
        if (colon < 0)
        {
            challenge(response, realm);
            return;
        }

        const user = decoded[0 .. colon];
        const secret = decoded[colon + 1 .. $];
        if (!constantTimeEqual(user, username) ||
            !constantTimeEqual(secret, password))
        {
            challenge(response, realm);
            return;
        }

        next();
    };
}

private void challenge(Response response, string realm)
{
    response.status(401)
            .set("WWW-Authenticate",
                 `Basic realm="` ~ realm ~ `", charset="UTF-8"`)
            .type("text")
            .send("Authentication required");
}

private bool constantTimeEqual(const(char)[] a, const(char)[] b)
{
    if (a.length != b.length)
        return false;

    ubyte difference;
    foreach (i; 0 .. a.length)
        difference |= cast(ubyte) (a[i] ^ b[i]);
    return difference == 0;
}

void main()
{
    auto app = new App;

    string username = environment.get("BASIC_AUTH_USER", "admin");
    string password = environment.get("BASIC_AUTH_PASS", "secret");
    string origin = environment.get("CORS_ORIGIN", "*");

    CorsOptions corsOptions;
    corsOptions.origin = origin;

    app.use(logger());

    // CORS must run before auth so preflight requests are not challenged.
    app.use(cors(corsOptions));

    app.get("/", (req, res)
    {
        res.send("Public endpoint. Try GET /api/me with Basic auth.");
    });

    app.get("/health", (req, res)
    {
        res.json(["status": "ok"]);
    });

    // Everything under /api requires Basic auth.
    app.use("/api", basicAuth(username, password, "dex-api"));

    app.get("/api/me", (req, res)
    {
        res.json(["user": username]);
    });

    app.get("/api/secret", (req, res)
    {
        res.send("42");
    });

    app.post("/api/echo", (req, res)
    {
        res.json(req.body);
    });

    app.listen(3000, ()
    {
        writeln("Basic auth + CORS example on http://localhost:3000");
        writeln("Credentials: ", username, " / ", password);
        writeln("CORS origin: ", origin);
    });
}
