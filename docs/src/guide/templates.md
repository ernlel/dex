---
title: Template Engine & Views
description: dex includes a zero-dependency Handlebars/Mustache-style template engine built directly into the framework. You can render server-side HTML effortlessly using res.render().
---

## Quick Example

Create a template file at `views/index.html`:

```html
<!doctype html>
<html>
<head><title>{{title}}</title></head>
<body>
    <h1>Hello, {{user.name}}!</h1>
    <ul>
        {{#each items}}
        <li>{{this}} (index: {{@index}})</li>
        {{/each}}
    </ul>
</body>
</html>
```

In your D application code:

```d
import dex;

struct PageData
{
    string title;
    struct User { string name; }
    User user;
    string[] items;
}

void main()
{
    auto app = dex.app();

    app.setViews("./views"); // Optional: defaults to "./views"

    app.get("/", (req, res) {
        res.render("index", PageData(
            "Welcome Page",
            PageData.User("Example User"),
            ["Fast", "Zero dependencies", "Ergonomic"]
        ));
    });

    app.listen(3000);
}
```

When a client requests `GET /`, `res.render("index", locals)` compiles the template, binds the struct fields, sets `Content-Type: text/html; charset=utf-8`, and sends the rendered HTML.

## Template Syntax

### Variables & HTML Escaping

Variables are enclosed in double braces `{{expression}}` and are **automatically HTML-escaped** to prevent Cross-Site Scripting (XSS) attacks:

```html
<p>{{name}}</p>
```

### Raw Unescaped HTML

To render raw, unescaped HTML, use triple braces `{{{rawHtml}}}` or `{{&rawHtml}}`:

```html
<div>{{{trustedHtmlContent}}}</div>
```

### Dot Notation & Array Indices

Navigate nested structs, classes, associative arrays, or JSON objects using standard dot notation and numeric indices:

```html
<p>Author: {{post.author.email}}</p>
<p>First Tag: {{tags.0}}</p>
```

### Conditionals (`#if` & `#unless`)

Use `{{#if expr}}` to conditionally render content. You can also provide an `{{else}}` block:

```text
{{#if user.isAdmin}}
    <a href="/admin">Admin Dashboard</a>
{{else}}
    <p>Standard Member</p>
{{/if}}
```

Use `{{#unless expr}}` (or Mustache inverted sections `{{^expr}}...{{/expr}}`) to render content when a condition is falsy:

```text
{{#unless loggedIn}}
    <a href="/login">Sign In</a>
{{/unless}}
```

### Loops (`#each`)

Iterate through arrays or associative arrays with `{{#each items}}`. Inside the loop, the current item becomes the local context:

```html
<ul>
{{#each products}}
    <li>
        #{{@index}}: <strong>{{name}}</strong> — ${{price}}
        {{#if @first}}<span class="badge">Featured</span>{{/if}}
    </li>
{{else}}
    <li>No products found.</li>
{{/each}}
</ul>
```

Special loop variables include:

- `{{this}}`: The current element itself (useful for arrays of strings or numbers).
- `{{@index}}`: 0-based iteration index.
- `{{@first}}`: Boolean `true` for the first element.
- `{{@last}}`: Boolean `true` for the final element.
- `{{@key}}`: Key name when iterating over an associative array or object.

### Partials / Includes

Break templates into reusable components using `{{> partialName}}`:

```text
{{> partials/header}}

<main>
    <h1>{{title}}</h1>
</main>

{{> partials/footer}}
```

`dex` searches for partials relative to your `viewsDir` (e.g. `./views/partials/header.html` or `./views/partials/header`).

### Comments

Comments are stripped during compilation and never emitted in the resulting HTML:

```text
{{! Single-line comment }}
{{!-- Multi-line comment that can span
     multiple lines --}}
```

## Application Configuration

### Setting the Views Directory

By default, templates are loaded from `./views`. Change this using `app.setViews()`:

```d
app.setViews("./src/templates");
```

### Template Caching in Production

By default, templates are read and parsed on demand for instant reload during development. In production, enable in-memory thread-safe AST caching for maximum throughput:

```d
app.cacheViews = true;
```

### Custom Template Engines

You can register custom template renderers for any file extension with `app.engine(ext, renderer)`:

```d
// Register a custom Markdown or template renderer
app.engine("md", (string templatePath, JSONValue locals) {
    import std.file : readText;
    string markdownContent = readText(templatePath);
    return customMarkdownToHtml(markdownContent);
});

// Render with custom engine
app.get("/terms", (req, res) {
    res.render("terms.md");
});
```
