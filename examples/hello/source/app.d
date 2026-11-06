import dex;
import std.stdio : writeln;

void main()
{
    auto app = new App;

    app.use(logger());

    app.get("/", (req, res)
    {
        res.send("Hello from dex!");
    });

    app.get("/hello/:name", (req, res)
    {
        res.send("Hello, " ~ req.params["name"] ~ "!");
    });

    app.get("/api/info", (req, res)
    {
        res.json([
            "framework": "dex",
            "message": "It works"
        ]);
    });

    app.listen(3000, ()
    {
        writeln("Listening on http://localhost:3000");
    });
}
