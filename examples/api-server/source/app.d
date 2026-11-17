/// Production-structured REST API microservice demonstrating:
/// - Modular sub-routers (`/api/v1`) and `router.param` pre-handlers
/// - Typed request binding (`req.bind!T`, `req.bindQuery!T`)
/// - Bearer token authentication, rate limiting, compression, and `bodyLimit()`
/// - Reverse-proxy trust (`app.trustProxy`), `405 Method Not Allowed`, and graceful shutdown
/// - Centralized structured JSON error handling
module app;

import dex;
import core.time : MonoTime, dur;
import std.algorithm : canFind, filter;
import std.array : array;
import std.conv : ConvException, to;
import std.datetime : Clock;
import std.string : icmp, strip, toLower;
import std.stdio : writeln;
import std.typecons : Nullable;

/// Product data structure.
struct Product
{
    size_t id;
    string name;
    string category;
    double price;
    bool inStock;
}

/// In-memory product store with sample data.
private __gshared Product[] products = [
    Product(1, "Mechanical Keyboard", "electronics", 129.99, true),
    Product(2, "Ergonomic Mouse", "electronics", 79.50, true),
    Product(3, "USB-C Monitor Cable", "accessories", 18.00, true),
    Product(4, "Desk Mat (Large)", "accessories", 24.99, false)
];
private __gshared size_t nextId = 5;

/// Server start time for health check uptime.
private __gshared MonoTime startTime;

/// Bearer token authentication middleware.
/// In production, tokens would be signed JWTs or looked up in a session store.
Middleware requireAuth(string expectedToken = "secret-token-123")
{
    return (Request req, Response res, Next next)
    {
        const auth = req.get("authorization");
        if (auth is null || auth.length < 8 ||
            icmp(auth[0 .. 7], "Bearer ") != 0)
        {
            throw new HttpError(401, "Missing or invalid Authorization header. Expected 'Bearer <token>'");
        }

        const token = auth[7 .. $].strip;
        if (token != expectedToken)
            throw new HttpError(403, "Invalid or expired authentication token");

        next();
    };
}

/// Response payload for product listings.
struct ProductsResponse
{
    size_t count;
    Product[] items;
}

/// Response payload for deletion.
struct DeleteResponse
{
    bool deleted;
    size_t id;
}

/// Response payload for root endpoint.
struct RootResponse
{
    string name;
    string apiVersion;
    string[] endpoints;
}

/// Typed login payload.
struct LoginInput
{
    string username;
    string password;
}

/// Typed query filter for product listing.
struct ProductQuery
{
    Nullable!string search;
    Nullable!string category;
}

/// Typed payload for creating a product.
struct CreateProductInput
{
    string name;
    string category;
    double price;
    bool inStock = true;
}

/// Authentication sub-router.
Router authRouter()
{
    auto r = new Router;

    // POST /api/v1/auth/login
    r.post("/login", (req, res)
    {
        auto creds = req.bind!LoginInput();

        // Demo credentials check (admin / dexpass)
        if (creds.username == "admin" && creds.password == "dexpass")
        {
            res.json([
                "token": "secret-token-123",
                "tokenType": "Bearer",
                "expiresIn": 86400.to!string
            ]);
        }
        else
        {
            throw new HttpError(401, "Invalid username or password");
        }
    });

    return r;
}

/// Products sub-router.
Router productsRouter()
{
    auto r = new Router;

    // Validate `:id` once for all routes using `:id`.
    r.param("id", (req, res, next, rawId)
    {
        try
            to!size_t(rawId);
        catch (ConvException)
            throw new HttpError(400, "Product ID must be a positive integer");
        next();
    });

    // GET /api/v1/products - List with typed query binding
    r.get("/", (req, res)
    {
        auto q = req.bindQuery!ProductQuery();
        const search = q.search.isNull ? "" : q.search.get;
        const category = q.category.isNull ? "" : q.category.get;

        auto filtered = products.filter!(p =>
            (search.length == 0 || p.name.toLower.canFind(search.toLower)) &&
            (category.length == 0 || p.category.toLower == category.toLower)
        ).array;

        res.json(ProductsResponse(filtered.length, filtered));
    });

    // Fluent route chaining for `/products/:id`
    r.route("/:id")
        .get((req, res)
        {
            const id = to!size_t(req.param("id"));
            foreach (ref p; products)
            {
                if (p.id == id)
                {
                    res.json(p);
                    return;
                }
            }
            throw new HttpError(404, "Product not found");
        })
        .del(requireAuth(), (req, res)
        {
            const id = to!size_t(req.param("id"));
            size_t index = size_t.max;
            foreach (i, ref p; products)
            {
                if (p.id == id)
                {
                    index = i;
                    break;
                }
            }

            if (index == size_t.max)
                throw new HttpError(404, "Product not found");

            products = products[0 .. index] ~ products[index + 1 .. $];
            res.status(200).json(DeleteResponse(true, id));
        });

    // POST /api/v1/products - Create a new product (requires authentication)
    r.post("/", requireAuth(), (req, res)
    {
        auto input = req.bind!CreateProductInput();

        if (input.name.length == 0)
            throw new HttpError(422, "Product 'name' must not be empty");
        if (input.price < 0.0)
            throw new HttpError(422, "Product 'price' must be non-negative");

        auto newProduct = Product(nextId++, input.name, input.category,
                                  input.price, input.inStock);
        products ~= newProduct;

        res.status(201).json(newProduct);
    });

    // POST /api/v1/products/import - Raises body limit above the 64 KiB global cap
    r.post("/import", requireAuth(), bodyLimit(2 * 1024 * 1024), (req, res)
    {
        auto batch = req.bind!(CreateProductInput[])();
        foreach (item; batch)
            products ~= Product(nextId++, item.name, item.category, item.price, item.inStock);
        res.status(201).json(["imported": batch.length]);
    });

    return r;
}

void main()
{
    startTime = MonoTime.currTime;
    auto app = new App;

    // Production server configuration
    app.maxBodySize = 64 * 1024;
    app.shutdownTimeout = 5.dur!"seconds";
    app.trustProxy = ["loopback", "10.0.0.0/8"];
    app.handleMethodNotAllowed = true;

    // Standard middleware stack
    app.use(logger());
    app.use(compression());
    app.use(securityHeaders());

    // CORS configuration for REST APIs
    CorsOptions corsOpt;
    corsOpt.origin = "*";
    corsOpt.methods = "GET, POST, PUT, DELETE, OPTIONS";
    corsOpt.headers = "Content-Type, Authorization";
    app.use(cors(corsOpt));

    // Rate limiting on API endpoints (120 req/min per resolved client IP)
    RateLimitOptions rl;
    rl.max = 120;
    rl.window = 60.dur!"seconds";
    app.use("/api", rateLimit(rl));

    // Health check endpoint with content negotiation (JSON or plain text)
    app.get("/health", (req, res)
    {
        auto uptime = (MonoTime.currTime - startTime).total!"seconds";
        res.format([
            "json": (Request r, Response w)
            {
                w.json([
                    "status": "healthy",
                    "uptimeSeconds": uptime.to!string,
                    "clientIp": r.ip,
                    "timestamp": Clock.currTime().toISOExtString()
                ]);
            },
            "text": (Request r, Response w)
            {
                w.send("healthy (" ~ uptime.to!string ~ "s)");
            }
        ]);
    });

    // Mount modular v1 API router
    auto v1 = new Router;
    v1.use("/auth", authRouter());
    v1.use("/products", productsRouter());
    app.use("/api/v1", v1);

    // Root info route
    app.get("/", (req, res)
    {
        res.json(RootResponse(
            "REST API Example",
            "v1",
            [
                "GET  /health",
                "POST /api/v1/auth/login",
                "GET  /api/v1/products",
                "GET  /api/v1/products/:id",
                "POST /api/v1/products (Bearer auth)",
                "POST /api/v1/products/import (Bearer auth, 2 MiB limit)",
                "DELETE /api/v1/products/:id (Bearer auth)"
            ]
        ));
    });

    // Centralized JSON error handling middleware
    app.use((Throwable err, Request req, Response res, Next next)
    {
        int code = 500;
        string msg = "Internal Server Error";

        if (auto httpErr = cast(HttpError) err)
        {
            code = httpErr.status;
            msg = httpErr.msg;
        }

        res.status(code).json([
            "status": code.to!string,
            "error": msg,
            "path": req.path
        ]);
    });

    writeln("REST API server listening on http://localhost:3000");
    app.listen(3000);
}
