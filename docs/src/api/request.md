---
title: Request (req)
description: Represents the incoming HTTP request, including headers, query parameters, route parameters, cookies, and body.
---

## Properties

- `app: App` — The application instance handling this request.
- `method: string` — Uppercase HTTP method (e.g. `"GET"`, `"POST"`).
- `httpVersion: string` — HTTP protocol version (e.g. `"HTTP/1.1"`).
- `url: string` — Request path plus query string (e.g. `"/search?q=dlang"`).
- `path: string` — Decoded URL path (e.g. `"/files/my doc.pdf"`).
- `rawPath: string` — Raw percent-encoded URL path.
- `originalUrl: string` — Unmodified request target before any router prefix trimming.
- `baseUrl: string` — URL path prefix where the current router was mounted.
- `queryString: string` — Raw query string without leading `?`.
- `params: string[string]` — Associative array of named route parameters (e.g. `req.params["id"]`).
- `query: string[string]` — Parsed query parameters (last value wins).
- `queryAll: string[][string]` — All query parameter values in order.
- `headers: string[][string]` — Request headers keyed by lowercased name.
- `cookies: string[string]` — Parsed request cookies.
- `signedCookies: string[string]` — HMAC-verified signed cookies (populated when `app.cookieSecret` is set).
- `session: Session` — Active server-side session attached by `session()` middleware, or `null`.
- `body: JSONValue` — Parsed request body (lazily evaluated on first access).
- `rawBody: string` — Raw unparsed request body as a string (lazily loaded from socket).
- `maxBodySize: size_t` — Effective maximum body size in bytes for this request (from `app.maxBodySize` or `bodyLimit()`).
- `ip: string` — Client IP address string (resolved through `app.trustProxy` when enabled).
- `ips: string[]` — Proxy IP chain from client to nearest proxy when `app.trustProxy` is enabled.
- `protocol: string` — `"http"` or `"https"`.
- `secure: bool` — True if the request arrived over TLS or trusted `X-Forwarded-Proto: https`.
- `xhr: bool` — True if `X-Requested-With: XMLHttpRequest` was present.
- `fresh: bool` / `stale: bool` — Whether the client's conditional request (`If-None-Match` / `If-Modified-Since`) matches the response.

## Methods

### req.get(name) / req.header(name)

Returns the value of the specified HTTP header (case-insensitive). If multiple values are present, they are joined with commas.

### req.getValues(name)

Returns all raw values for the header as a `string[]` array.

### req.param(name)

Returns a matched route parameter, or `null` if missing.

### req.queryParam(name)

Returns the query parameter value, or `null`.

### req.queryParams(name)

Returns all query parameter values matching `name` as a `string[]`.

### req.cookie(name)

Returns the parsed cookie value, or `null`.

### req.signedCookie(name, [secret])

Returns the HMAC-SHA256 verified signed cookie value, or `null` if missing or tampered.

### req.bodyValue!T(name)

Extracts a typed field from a JSON object or URL-encoded body. Throws `HttpError(400)` if the field is missing or has the wrong type.

### req.bind!T([errorStatus = 422]) / req.bindQuery!T([errorStatus = 400])

Deserializes and validates JSON/form bodies (`bind!T`) or query parameters (`bindQuery!T`) into nested D structs with support for `Nullable!T`, default field values, enums, arrays, and `@optional`. Throws descriptive `HttpError` messages on missing or mismatched fields.

### req.accepts(types...)

Negotiates the best matching MIME type or extension against the request's `Accept` header, or returns `null` when unacceptable.

### req.isType(type)

Checks if the request `Content-Type` matches a given MIME type or extension (e.g. `req.isType("json")`).
