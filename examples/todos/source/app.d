import core.sync.mutex : Mutex;
import dex;
import std.algorithm.mutation : remove;
import std.conv : to;
import std.stdio : writeln;

struct Todo
{
    int id;
    string title;
    bool done;
}

void main()
{
    auto app = new App;
    auto mutex = new Mutex;
    Todo[] todos;
    int nextId = 1;

    app.use(logger());

    app.get("/todos", (req, res)
    {
        Todo[] snapshot;
        synchronized (mutex)
        {
            snapshot = todos.dup;
        }
        res.json(snapshot);
    });

    app.get("/todos/:id", (req, res)
    {
        const id = to!int(req.params["id"]);
        Todo found;
        bool exists;

        synchronized (mutex)
        {
            foreach (ref todo; todos)
            {
                if (todo.id == id)
                {
                    found = todo;
                    exists = true;
                    break;
                }
            }
        }

        if (!exists)
            throw new HttpError(404, "Todo not found");
        res.json(found);
    });

    app.post("/todos", (req, res)
    {
        const title = req.bodyValue!string("title");
        Todo created;

        synchronized (mutex)
        {
            created = Todo(nextId++, title, false);
            todos ~= created;
        }

        res.status(201).json(created);
    });

    app.put("/todos/:id", (req, res)
    {
        const id = to!int(req.params["id"]);
        const title = req.bodyValue!string("title");
        bool done = false;

        auto object = req.body.object;
        if (auto value = "done" in object)
            done = (*value).get!bool;

        Todo updated;
        bool exists;

        synchronized (mutex)
        {
            foreach (ref todo; todos)
            {
                if (todo.id == id)
                {
                    todo.title = title;
                    todo.done = done;
                    updated = todo;
                    exists = true;
                    break;
                }
            }
        }

        if (!exists)
            throw new HttpError(404, "Todo not found");
        res.json(updated);
    });

    app.delete("/todos/:id", (req, res)
    {
        const id = to!int(req.params["id"]);
        bool removed;

        synchronized (mutex)
        {
            foreach (i, todo; todos)
            {
                if (todo.id == id)
                {
                    todos = todos.remove(i);
                    removed = true;
                    break;
                }
            }
        }

        if (!removed)
            throw new HttpError(404, "Todo not found");
        res.status(204).end();
    });

    app.use((Throwable error, Request req, Response res, Next next)
    {
        if (auto httpError = cast(HttpError) error)
            res.status(httpError.status).json(["error": httpError.msg]);
        else
            res.status(500).json(["error": "Internal Server Error"]);
    });

    app.listen(3000, ()
    {
        writeln("Todo API listening on http://localhost:3000/todos");
    });
}
