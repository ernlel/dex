---
title: Routing in Depth
description: Master route matching, wildcards, route chaining, and modular sub-routers with dex.
---

## HTTP Verb Methods

dex supports all standard HTTP verbs via helper methods on `App` and `Router`:

`get`, `post`, `put`, `patch`, `delete`, `head`, `options`, `trace`, `connect`, and `all`.

```d
// Matches any HTTP method on /secret
app.all("/secret", (req, res, next) {
    res.set("x-auth", "checked");
    next();
});
```

## Wildcard Route Patterns

Use `*` as the final segment to capture arbitrary path tails. The captured string is accessible via `req.params["0"]` or `req.params["*"]`:

```d
app.get("/files/*", (req, res) {
    const subpath = req.params["0"]; // e.g. "docs/readme.txt"
    res.send("Requested: " ~ subpath);
});
```

## Modular Sub-Routers

Use `dex.Router` to create modular, mountable route handlers. A `Router` instance is a complete middleware and routing system:

```d title="source/routes/users.d"
import dex;

Router userRouter()
{
    auto router = new Router;

    router.get("/", (req, res) {
        res.json(["users": ["User 1", "User 2"]]);
    });

    router.get("/:id", (req, res) {
        res.json(["id": req.params["id"]]);
    });

    return router;
}
```

Mount the router on a path in your main application:

```d title="source/app.d"
app.use("/api/users", userRouter());
```

Inside the mounted router:

- `req.baseUrl` reflects `"/api/users"`.
- `req.path` reflects the subpath (e.g. `"/"` or `"/42"`).
- `req.originalUrl` preserves the full raw URL (`"/api/users/42"`).
