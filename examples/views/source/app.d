/// Server-side HTML rendering example using dex's built-in Handlebars/Mustache template engine.
///
/// Demonstrates:
/// - Configuring the views directory with `app.setViews("./views")`
/// - Passing strongly-typed D structs as template locals
/// - Partials inclusion with `{{> partials/header}}` and `{{> partials/footer}}`
/// - Conditionals `{{#if}}`, loops `{{#each}}`, and raw HTML escaping
/// - Serving static CSS assets alongside server-rendered views
module app;

import dex;
import std.datetime : Clock;
import std.stdio : writeln;

/// User profile representation.
struct User
{
    string name;
    string email;
}

/// Project item representation.
struct Project
{
    string name;
    string description;
    string category;
    bool active;
}

/// Strongly-typed locals passed to index.html.
struct IndexLocals
{
    string title;
    int currentYear;
    string author;
    User user;
    bool hasNotifications;
    Project[] projects;
    string escapedSample;
    string rawHtmlSample;
}

/// Simple locals passed to about.html.
struct AboutLocals
{
    string title;
    int currentYear;
    string author;
}

void main()
{
    auto app = new App;

    // Request logging
    app.use(logger());

    // Serve public stylesheet and assets
    app.use(serveStatic("./public"));

    // Configure view engine
    app.setViews("./views");
    app.viewEngine("html");
    app.cacheViews = false; // Set to true in production for fast in-memory AST caching

    // Route: Homepage
    app.get("/", (req, res)
    {
        auto locals = IndexLocals(
            title: "Home",
            currentYear: Clock.currTime().year,
            author: "Example Author",
            user: User("Example User", "user@example.com"),
            hasNotifications: true,
            projects: [
                Project("dex Web Framework", "Express-inspired, zero-dependency web framework for D", "Frameworks", true),
                Project("Built-in View Engine", "Handlebars/Mustache template compiler in Phobos", "Templates", true),
                Project("Legacy HTTP Proxy", "Old experimental proxy prototype", "Archived", false)
            ],
            escapedSample: "<script>alert('xss prevented')</script> & safe",
            rawHtmlSample: `<em style="color: #38bdf8;">Rendered with &lt;em&gt; tag intact!</em>`
        );

        res.render("index", locals);
    });

    // Route: About page
    app.get("/about", (req, res)
    {
        res.render("about", AboutLocals(
            title: "About",
            currentYear: Clock.currTime().year,
            author: "Example Author"
        ));
    });

    // Route: Projects page (demonstrates rendering the same template with different data)
    app.get("/projects", (req, res)
    {
        auto locals = IndexLocals(
            title: "Projects",
            currentYear: Clock.currTime().year,
            author: "Example Author",
            user: User("Developer", "dev@example.com"),
            hasNotifications: false,
            projects: [
                Project("dex Web Framework", "Zero-dependency web framework for D", "Frameworks", true),
                Project("dex Template Engine", "Server-rendered HTML templates", "Core", true)
            ],
            escapedSample: "<b>Escaped string</b>",
            rawHtmlSample: `<strong>Unescaped bold markup</strong>`
        );

        res.render("index", locals);
    });

    writeln("Views example server listening on http://localhost:3000");
    app.listen(3000);
}

