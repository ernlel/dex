---
title: Router
description: A Router instance is a complete middleware and routing system; for this reason, it is often referred to as a "mini-app".
---

Every `dex` application (`App`) inherits from `Router`. You can also instantiate isolated `Router` instances and mount them on paths using `app.use("/prefix", router)`.

## Instantiation

```d
import dex;

auto router = new Router();
```

## Properties

### router.caseSensitive

Enables case-sensitive route matching. Defaults to `false` (meaning `/Users` matches `/users`).

```d
router.caseSensitive = true;
```

## Methods

### router.use([path], [middleware...])

Mounts middleware or a sub-router on this router. If `path` is specified, the middleware only runs for paths matching that prefix.

```d
// Runs on every request passing through this router
router.use((req, res, next) {
    // perform check or authentication
    next();
});

// Runs only under /api
router.use("/api", (req, res, next) {
    next();
});
```

### router.use(ErrorHandler)

Registers an error-handling middleware delegate with signature `void delegate(Throwable error, Request req, Response res, Next next)`.

```d
router.use((err, req, res, next) {
    res.status(500).send("Router Error: " ~ err.msg);
});
```

### router.use([path], Router)

Mounts a sub-router. When requests match `path`, `req.baseUrl` is updated to include the prefix and `req.path` is adjusted to the remainder of the path.

```d
auto api = new Router();
auto v1 = new Router();

v1.get("/users", (req, res) => res.json(["Alice", "Bob"]));
api.use("/v1", v1);
app.use("/api", api);
// Matches GET /api/v1/users
```

### router.METHOD(path, [middleware...], handler)

Registers one or more middlewares followed by a route handler for specific HTTP methods (variadic handler chains are supported). Supported methods include:

- `router.get(path, ...)` (also responds to `HEAD` requests)
- `router.post(path, ...)`
- `router.put(path, ...)`
- `router.delete(path, ...)` (or `delete_`)
- `router.patch(path, ...)`
- `router.head(path, ...)`
- `router.options(path, ...)`
- `router.connect(path, ...)`
- `router.trace(path, ...)`

### router.param(name, callback)

Registers a parameter pre-handler `void delegate(Request req, Response res, Next next, string value)` invoked once per request whenever route parameter `name` is matched.

```d
router.param("id", (req, res, next, id) {
    // validate or preload entity by id
    next();
});
```

### router.route(path)

Returns a fluent `RouteChain` builder for registering multiple HTTP methods on the same path (use `.del(...)` or `.delete_(...)` for `DELETE`):

```d
router.route("/items/:id")
    .get((req, res) { res.send("get " ~ req.param("id")); })
    .put((req, res) { res.send("put " ~ req.param("id")); })
    .del((req, res) { res.send("del " ~ req.param("id")); });
```

```d
router.get("/items", (req, res) {
    res.json(items);
});

router.post("/items", (req, res) {
    // create item
    res.status(201).json(created);
});
```

### router.all(path, handler | middleware)

Matches any HTTP method for the given path.

```d
router.all("/secret", (req, res, next) {
    // runs for GET, POST, PUT, DELETE, etc.
    next();
});
```

### router.route(method, path, handler | middleware)

Registers a route handler for an arbitrary custom or extended HTTP verb (e.g. `SEARCH`, `PURGE`, `LINK`).

```d
router.route("PURGE", "/cache", (req, res) {
    clearCache();
    res.send("Cache purged");
});
```

## Modular Architecture Example

Separate your application into domain-driven modules:

```d
// routes/users.d
module routes.users;

import dex;

Router usersRouter()
{
    auto r = new Router();

    r.get("/", (req, res) => res.json(allUsers()));
    r.get("/:id", (req, res) {
        auto user = findUser(req.param("id"));
        if (!user.found)
            throw new HttpError(404, "User not found");
        res.json(user);
    });

    return r;
}

// app.d
import dex;
import routes.users;

void main()
{
    auto app = dex.app();
    app.use("/users", usersRouter());
    app.listen(3000);
}
```
