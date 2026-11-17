/// Production-structured REST API microservice demonstrating:
/// - Modular sub-routers (`/api/v1`)
/// - Bearer token authentication middleware
/// - Built-in CORS and Helmet-style security headers
/// - Request parameter and body validation
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

/// Authentication sub-router.
Router authRouter()
{
    auto r = new Router;

    // POST /api/v1/auth/login
    r.post("/login", (req, res)
    {
        string username;
        string password;

        try
        {
            username = req.bodyValue!string("username");
            password = req.bodyValue!string("password");
        }
        catch (Exception)
        {
            throw new HttpError(400, "Request body must include 'username' and 'password' fields");
        }

        // Demo credentials check (admin / dexpass)
        if (username == "admin" && password == "dexpass")
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

    // GET /api/v1/products - List with optional filtering
    r.get("/", (req, res)
    {
        string search = req.queryParam("search");
        string category = req.queryParam("category");

        auto filtered = products.filter!(p =>
            (search.length == 0 || p.name.toLower.canFind(search.toLower)) &&
            (category.length == 0 || p.category.toLower == category.toLower)
        ).array;

        res.json(ProductsResponse(filtered.length, filtered));
    });

    // GET /api/v1/products/:id - Get product by ID
    r.get("/:id", (req, res)
    {
        size_t id;
        try
            id = to!size_t(req.param("id"));
        catch (ConvException)
            throw new HttpError(400, "Product ID must be a positive integer");

        foreach (ref p; products)
        {
            if (p.id == id)
            {
                res.json(p);
                return;
            }
        }

        throw new HttpError(404, "Product not found");
    });

    // POST /api/v1/products - Create a new product (requires authentication)
    r.post("/", requireAuth(), (req, res)
    {
        string name;
        string category;
        double price;

        try
        {
            name = req.bodyValue!string("name");
            category = req.bodyValue!string("category");
            price = req.bodyValue!double("price");
        }
        catch (Exception)
        {
            throw new HttpError(400, "Product requires 'name' (string), 'category' (string), and 'price' (number)");
        }

        if (name.length == 0)
            throw new HttpError(400, "Product 'name' must not be empty");
        if (price < 0.0)
            throw new HttpError(400, "Product 'price' must be non-negative");

        auto newProduct = Product(nextId++, name, category, price, true);
        products ~= newProduct;

        res.status(201).json(newProduct);
    });

    // DELETE /api/v1/products/:id - Delete product (requires authentication)
    r.delete("/:id", requireAuth(), (req, res)
    {
        size_t id;
        try
            id = to!size_t(req.param("id"));
        catch (ConvException)
            throw new HttpError(400, "Product ID must be a positive integer");

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

    return r;
}

void main()
{
    startTime = MonoTime.currTime;
    auto app = new App;

    // Standard middleware stack
    app.use(logger());

    // Security headers (Helmet-style defaults)
    app.use(securityHeaders());

    // CORS configuration for REST APIs
    CorsOptions corsOpt;
    corsOpt.origin = "*";
    corsOpt.methods = "GET, POST, PUT, DELETE, OPTIONS";
    corsOpt.headers = "Content-Type, Authorization";
    app.use(cors(corsOpt));

    // Health check endpoint
    app.get("/health", (req, res)
    {
        auto uptime = (MonoTime.currTime - startTime).total!"seconds";
        res.json([
            "status": "healthy",
            "uptimeSeconds": uptime.to!string,
            "timestamp": Clock.currTime().toISOExtString(),
            "version": "1.0.0"
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
