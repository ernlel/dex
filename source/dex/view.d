/// Built-in Handlebars/Mustache-style template engine and view system for dex.
module dex.view;

import core.sync.mutex : Mutex;
import std.array : Appender, appender, split;
import std.conv : to;
import std.file : exists, isFile, readText, timeLastModified;
import std.json : JSONType, JSONValue;
import std.math : isNaN;
import std.path : buildPath, extension, setExtension;
import std.string : indexOf, strip;

import dex.errors : HttpError;

/// Exception thrown when template parsing or rendering fails.
class TemplateException : Exception
{
    size_t line;
    size_t column;

    this(string msg, size_t line = 0, size_t column = 0, string file = __FILE__, size_t lineNum = __LINE__)
    {
        this.line = line;
        this.column = column;
        string fullMsg = msg;
        if (line > 0)
            fullMsg ~= " (at line " ~ to!string(line) ~ ", col " ~ to!string(column) ~ ")";
        super(fullMsg, file, lineNum);
    }
}

/// Renderer function signature for custom view engines.
alias ViewRenderer = string delegate(string templatePath, JSONValue locals);

/// AST Node kinds for compiled templates.
package enum NodeKind
{
    text,
    variable,
    condition,
    unless,
    eachLoop,
    partial
}

/// An AST node representing a compiled segment of a template.
package struct Node
{
    NodeKind kind;
    string text;       /// Literal text, variable path, or partial name
    bool raw;          /// True if HTML escaping should be bypassed ({{{raw}}} or {{&raw}})
    Node[] children;   /// Main body for blocks (#if, #unless, #each)
    Node[] elseBlock;  /// Alternative body for {{else}} branch
    size_t line;
    size_t column;
}

/// Compiled template AST.
package class CompiledTemplate
{
    Node[] nodes;
    string sourcePath;

    this(Node[] nodes, string sourcePath = "")
    {
        this.nodes = nodes;
        this.sourcePath = sourcePath;
    }
}

/// Thread-safe in-memory cache for compiled templates.
package class TemplateCache
{
    private struct CacheEntry
    {
        CompiledTemplate template_;
        long lastModified;
    }

    private CacheEntry[string] _entries;
    private Mutex _mutex;

    this()
    {
        _mutex = new Mutex;
    }

    CompiledTemplate get(string filePath)
    {
        synchronized (_mutex)
        {
            if (auto entry = filePath in _entries)
                return entry.template_;
            return null;
        }
    }

    void set(string filePath, CompiledTemplate t, long mtime)
    {
        synchronized (_mutex)
        {
            _entries[filePath] = CacheEntry(t, mtime);
        }
    }

    void clear()
    {
        synchronized (_mutex)
        {
            _entries.clear();
        }
    }
}

/// Escapes HTML special characters to prevent XSS. Fast-path allocation free
/// if no special characters are present.
string escapeHtml(string input) pure
{
    bool needsEscape = false;
    foreach (char c; input)
    {
        if (c == '&' || c == '<' || c == '>' || c == '"' || c == '\'')
        {
            needsEscape = true;
            break;
        }
    }
    if (!needsEscape)
        return input;

    auto app = appender!string();
    app.reserve(input.length + 16);
    foreach (char c; input)
    {
        switch (c)
        {
            case '&': app.put("&amp;"); break;
            case '<': app.put("&lt;"); break;
            case '>': app.put("&gt;"); break;
            case '"': app.put("&quot;"); break;
            case '\'': app.put("&#39;"); break;
            default: app.put(c); break;
        }
    }
    return app.data;
}

/// Determines the truthiness of a JSONValue according to template rules.
bool isTruthy(const ref JSONValue val) pure
{
    switch (val.type)
    {
        case JSONType.null_:
            return false;
        case JSONType.true_:
            return true;
        case JSONType.false_:
            return false;
        case JSONType.string:
            return val.str.length != 0;
        case JSONType.integer:
            return val.integer != 0;
        case JSONType.uinteger:
            return val.uinteger != 0;
        case JSONType.float_:
            return val.floating != 0.0 && !isNaN(val.floating);
        case JSONType.array:
            return val.array.length != 0;
        case JSONType.object:
            return val.object.length != 0;
        default:
            return false;
    }
}

/// Converts a JSONValue to its string representation for template output.
string jsonToString(const ref JSONValue val)
{
    switch (val.type)
    {
        case JSONType.string:
            return val.str;
        case JSONType.integer:
            return to!string(val.integer);
        case JSONType.uinteger:
            return to!string(val.uinteger);
        case JSONType.float_:
            return to!string(val.floating);
        case JSONType.true_:
            return "true";
        case JSONType.false_:
            return "false";
        case JSONType.null_:
            return "";
        default:
            return val.toString();
    }
}

/// Parses template source string into an AST.
package CompiledTemplate compileTemplate(string source, string filePath = "")
{
    Parser parser = Parser(source, filePath);
    return new CompiledTemplate(parser.parse(), filePath);
}

private struct Parser
{
    string source;
    string filePath;
    size_t pos;
    size_t line = 1;
    size_t col = 1;

    Node[] parse()
    {
        return parseBlock(null);
    }

    private Node[] parseBlock(string expectedClosingTag)
    {
        Node[] nodes;
        bool inElse = false;

        while (pos < source.length)
        {
            auto tagStart = source[pos .. $].indexOf("{{");
            if (tagStart < 0)
            {
                // Remainder is pure text
                string text = source[pos .. $];
                updateLineCol(text);
                pos = source.length;
                if (text.length != 0)
                    nodes ~= Node(NodeKind.text, text);
                break;
            }

            if (tagStart > 0)
            {
                string text = source[pos .. pos + tagStart];
                updateLineCol(text);
                pos += tagStart;
                nodes ~= Node(NodeKind.text, text);
            }

            // At '{{'
            size_t tagLine = line;
            size_t tagCol = col;
            pos += 2;
            col += 2;

            // Check for comments {{! ... }} or {{!-- ... --}}
            if (pos < source.length && source[pos] == '!')
            {
                pos++;
                col++;
                bool longComment = false;
                if (pos + 1 < source.length && source[pos .. pos + 2] == "--")
                {
                    longComment = true;
                    pos += 2;
                    col += 2;
                }

                string endMarker = longComment ? "--}}" : "}}";
                auto endIdx = source[pos .. $].indexOf(endMarker);
                if (endIdx < 0)
                    throw new TemplateException("Unclosed comment", tagLine, tagCol);

                string commentText = source[pos .. pos + endIdx];
                updateLineCol(commentText);
                pos += endIdx + endMarker.length;
                col += endMarker.length;
                continue;
            }

            // Raw variable {{{ ... }}}
            bool tripleBrace = false;
            if (pos < source.length && source[pos] == '{')
            {
                tripleBrace = true;
                pos++;
                col++;
            }

            string closingMarker = tripleBrace ? "}}}" : "}}";
            auto endIdx = source[pos .. $].indexOf(closingMarker);
            if (endIdx < 0)
                throw new TemplateException("Unclosed tag", tagLine, tagCol);

            string tagContent = source[pos .. pos + endIdx].strip;
            updateLineCol(source[pos .. pos + endIdx]);
            pos += endIdx + closingMarker.length;
            col += closingMarker.length;

            if (tagContent.length == 0)
                continue;

            // Raw variable with {{& ... }}
            if (!tripleBrace && tagContent[0] == '&')
            {
                string expr = tagContent[1 .. $].strip;
                nodes ~= Node(NodeKind.variable, expr, true, null, null, tagLine, tagCol);
                continue;
            }

            if (tripleBrace)
            {
                nodes ~= Node(NodeKind.variable, tagContent, true, null, null, tagLine, tagCol);
                continue;
            }

            // Partial {{> partialName }}
            if (tagContent[0] == '>')
            {
                string partialName = tagContent[1 .. $].strip;
                nodes ~= Node(NodeKind.partial, partialName, false, null, null, tagLine, tagCol);
                continue;
            }

            // Block end {{/tag}}
            if (tagContent[0] == '/')
            {
                string closingTag = tagContent[1 .. $].strip;
                if (expectedClosingTag is null)
                    throw new TemplateException("Unexpected closing tag: {{/" ~ closingTag ~ "}}", tagLine, tagCol);

                if (closingTag != expectedClosingTag &&
                    !(expectedClosingTag == "if" && (closingTag == "unless" || closingTag == "^")))
                {
                    throw new TemplateException("Mismatched closing tag: expected {{/" ~ expectedClosingTag ~ "}}, got {{/" ~ closingTag ~ "}}", tagLine, tagCol);
                }
                return nodes;
            }

            // Else tag {{else}} or {{^}}
            if (tagContent == "else" || tagContent == "^")
            {
                if (expectedClosingTag is null)
                    throw new TemplateException("Unexpected {{else}} outside of block", tagLine, tagCol);
                return nodes;
            }

            // Block starts
            if (tagContent[0] == '#')
            {
                string blockHeader = tagContent[1 .. $].strip;
                auto spaceIdx = blockHeader.indexOf(' ');
                string blockKeyword = spaceIdx < 0 ? blockHeader : blockHeader[0 .. spaceIdx];
                string expr = spaceIdx < 0 ? "" : blockHeader[spaceIdx + 1 .. $].strip;

                Node blockNode;
                blockNode.text = expr;
                blockNode.line = tagLine;
                blockNode.column = tagCol;

                if (blockKeyword == "if")
                {
                    blockNode.kind = NodeKind.condition;
                    blockNode.children = parseBlock("if");
                    if (pos < source.length && isNextElse())
                    {
                        skipElseTag();
                        blockNode.elseBlock = parseBlock("if");
                    }
                    nodes ~= blockNode;
                }
                else if (blockKeyword == "unless")
                {
                    blockNode.kind = NodeKind.unless;
                    blockNode.children = parseBlock("unless");
                    if (pos < source.length && isNextElse())
                    {
                        skipElseTag();
                        blockNode.elseBlock = parseBlock("unless");
                    }
                    nodes ~= blockNode;
                }
                else if (blockKeyword == "each")
                {
                    blockNode.kind = NodeKind.eachLoop;
                    blockNode.children = parseBlock("each");
                    if (pos < source.length && isNextElse())
                    {
                        skipElseTag();
                        blockNode.elseBlock = parseBlock("each");
                    }
                    nodes ~= blockNode;
                }
                else
                {
                    throw new TemplateException("Unknown block helper: #" ~ blockKeyword, tagLine, tagCol);
                }
                continue;
            }

            // Mustache inverted section {{^key}} ... {{/key}}
            if (tagContent[0] == '^')
            {
                string expr = tagContent[1 .. $].strip;
                Node blockNode;
                blockNode.kind = NodeKind.unless;
                blockNode.text = expr;
                blockNode.line = tagLine;
                blockNode.column = tagCol;
                blockNode.children = parseBlock(expr);
                if (pos < source.length && isNextElse())
                {
                    skipElseTag();
                    blockNode.elseBlock = parseBlock(expr);
                }
                nodes ~= blockNode;
                continue;
            }

            // Regular variable {{expr}}
            nodes ~= Node(NodeKind.variable, tagContent, false, null, null, tagLine, tagCol);
        }

        if (expectedClosingTag !is null)
            throw new TemplateException("Unclosed block: expected {{/" ~ expectedClosingTag ~ "}}");

        return nodes;
    }

    private bool isNextElse()
    {
        // Check if the previous parsed block ended on {{else}} or {{^}}
        // In our parser, parseBlock returns when it hits {{else}} or closing tag.
        // We inspect what tag was just hit before current pos.
        // We look backwards or peek pos.
        if (pos >= 4)
        {
            auto chunk = source[0 .. pos];
            auto lastTag = chunk.lastIndexOf("{{");
            if (lastTag >= 0)
            {
                auto inside = chunk[lastTag + 2 .. $].strip;
                if (inside.startsWith("else}}") || inside.startsWith("^}}") ||
                    inside.startsWith("else }}") || inside == "else" || inside == "^")
                    return true;
            }
        }
        return false;
    }

    private void skipElseTag()
    {
        // Already positioned past {{else}}
    }

    private void updateLineCol(string text)
    {
        foreach (char c; text)
        {
            if (c == '\n')
            {
                line++;
                col = 1;
            }
            else
            {
                col++;
            }
        }
    }
}

private ptrdiff_t lastIndexOf(string s, string sub)
{
    if (sub.length > s.length)
        return -1;
    for (ptrdiff_t i = s.length - sub.length; i >= 0; --i)
        if (s[i .. i + sub.length] == sub)
            return i;
    return -1;
}

private bool startsWith(string s, string prefix)
{
    return s.length >= prefix.length && s[0 .. prefix.length] == prefix;
}

/// Loop context metadata for special `@` variables.
private struct LoopMeta
{
    size_t index;
    bool first;
    bool last;
    string key;
    bool hasMeta;
}

/// Evaluator for compiled templates.
package struct Evaluator
{
    const(JSONValue)*[] contextStack;
    LoopMeta loopMeta;
    string viewsDir;
    string defaultEngine;
    TemplateCache cache;
    size_t depth;

    void renderNodes(const ref Node[] nodes, ref Appender!string outBuf)
    {
        foreach (const ref node; nodes)
        {
            final switch (node.kind)
            {
                case NodeKind.text:
                    outBuf.put(node.text);
                    break;

                case NodeKind.variable:
                    JSONValue val = resolveValue(node.text);
                    string str = jsonToString(val);
                    if (node.raw)
                        outBuf.put(str);
                    else
                        outBuf.put(escapeHtml(str));
                    break;

                case NodeKind.condition:
                    JSONValue condVal = resolveValue(node.text);
                    if (isTruthy(condVal))
                        renderNodes(node.children, outBuf);
                    else if (node.elseBlock.length != 0)
                        renderNodes(node.elseBlock, outBuf);
                    break;

                case NodeKind.unless:
                    JSONValue condVal = resolveValue(node.text);
                    if (!isTruthy(condVal))
                        renderNodes(node.children, outBuf);
                    else if (node.elseBlock.length != 0)
                        renderNodes(node.elseBlock, outBuf);
                    break;

                case NodeKind.eachLoop:
                    renderEach(node, outBuf);
                    break;

                case NodeKind.partial:
                    renderPartial(node.text, outBuf);
                    break;
            }
        }
    }

    private void renderEach(const ref Node node, ref Appender!string outBuf)
    {
        JSONValue target = resolveValue(node.text);
        if (target.type == JSONType.array && target.array.length != 0)
        {
            const size_t total = target.array.length;
            foreach (size_t i, ref const(JSONValue) item; target.array)
            {
                Evaluator sub = this;
                sub.contextStack = contextStack ~ &item;
                sub.loopMeta = LoopMeta(i, i == 0, i + 1 == total, "", true);
                sub.renderNodes(node.children, outBuf);
            }
        }
        else if (target.type == JSONType.object && target.object.length != 0)
        {
            const size_t total = target.object.length;
            size_t i = 0;
            foreach (string k, ref const(JSONValue) item; target.object)
            {
                Evaluator sub = this;
                sub.contextStack = contextStack ~ &item;
                sub.loopMeta = LoopMeta(i, i == 0, i + 1 == total, k, true);
                sub.renderNodes(node.children, outBuf);
                i++;
            }
        }
        else
        {
            if (node.elseBlock.length != 0)
                renderNodes(node.elseBlock, outBuf);
        }
    }

    private void renderPartial(string partialName, ref Appender!string outBuf)
    {
        if (depth > 32)
            throw new TemplateException("Maximum partial recursion depth exceeded: " ~ partialName);

        if (viewsDir.length == 0)
            throw new TemplateException("Cannot include partial without views directory configured: " ~ partialName);

        string targetPath = resolvePartialPath(viewsDir, partialName, defaultEngine);
        if (!exists(targetPath) || !isFile(targetPath))
            throw new TemplateException("Partial not found: " ~ partialName ~ " (looked at: " ~ targetPath ~ ")");

        CompiledTemplate partialTpl;
        if (cache !is null)
            partialTpl = cache.get(targetPath);

        if (partialTpl is null)
        {
            string content = readText(targetPath);
            partialTpl = compileTemplate(content, targetPath);
            if (cache !is null)
                cache.set(targetPath, partialTpl, timeLastModified(targetPath).toUnixTime());
        }

        Evaluator sub = this;
        sub.depth = depth + 1;
        sub.renderNodes(partialTpl.nodes, outBuf);
    }

    private JSONValue resolveValue(string expr)
    {
        expr = expr.strip;
        if (expr.length == 0)
            return JSONValue(null);

        // Special loop variables: @index, @first, @last, @key
        if (expr.length > 0 && expr[0] == '@' && loopMeta.hasMeta)
        {
            if (expr == "@index")
                return JSONValue(cast(long) loopMeta.index);
            if (expr == "@first")
                return JSONValue(loopMeta.first);
            if (expr == "@last")
                return JSONValue(loopMeta.last);
            if (expr == "@key")
                return JSONValue(loopMeta.key);
        }

        // 'this' or '.'
        if (expr == "this" || expr == ".")
        {
            if (contextStack.length != 0)
                return *contextStack[$ - 1];
            return JSONValue(null);
        }

        auto parts = expr.split('.');

        // If expression starts with 'this.something'
        if (parts[0] == "this")
        {
            if (contextStack.length == 0)
                return JSONValue(null);
            return walkProperties(*contextStack[$ - 1], parts[1 .. $]);
        }

        // Walk context stack from innermost (top) to outermost (root)
        for (ptrdiff_t i = contextStack.length - 1; i >= 0; --i)
        {
            const auto ctx = contextStack[i];
            if (ctx.type == JSONType.object)
            {
                if (auto val = parts[0] in ctx.object)
                {
                    if (parts.length == 1)
                        return *val;
                    return walkProperties(*val, parts[1 .. $]);
                }
            }
        }

        return JSONValue(null);
    }

    private static JSONValue walkProperties(const ref JSONValue current, string[] remaining)
    {
        const(JSONValue)* curr = &current;
        foreach (prop; remaining)
        {
            if (curr.type == JSONType.object)
            {
                if (auto next = prop in curr.object)
                    curr = next;
                else
                    return JSONValue(null);
            }
            else if (curr.type == JSONType.array)
            {
                try
                {
                    auto idx = to!size_t(prop);
                    if (idx < curr.array.length)
                        curr = &curr.array[idx];
                    else
                        return JSONValue(null);
                }
                catch (Exception)
                {
                    return JSONValue(null);
                }
            }
            else
            {
                return JSONValue(null);
            }
        }
        return *curr;
    }
}

/// Resolves the filesystem path for a partial view.
private string resolvePartialPath(string viewsDir, string partialName, string defaultEngine)
{
    // Check direct path
    string ext = extension(partialName);
    string candidate = ext.length ? buildPath(viewsDir, partialName)
                                 : buildPath(viewsDir, partialName ~ "." ~ defaultEngine);
    if (exists(candidate) && isFile(candidate))
        return candidate;

    // Check partials/ subfolder
    string partialsCandidate = ext.length ? buildPath(viewsDir, "partials", partialName)
                                         : buildPath(viewsDir, "partials", partialName ~ "." ~ defaultEngine);
    if (exists(partialsCandidate) && isFile(partialsCandidate))
        return partialsCandidate;

    return candidate;
}

/// Renders a template string with the provided JSON locals.
string renderTemplate(string templateContent, JSONValue locals,
                      string viewsDir = "", string defaultEngine = "html",
                      TemplateCache cache = null)
{
    auto compiled = compileTemplate(templateContent);
    auto app = appender!string();
    Evaluator evaluator;
    evaluator.contextStack = [&locals];
    evaluator.viewsDir = viewsDir;
    evaluator.defaultEngine = defaultEngine;
    evaluator.cache = cache;
    evaluator.renderNodes(compiled.nodes, app);
    return app.data;
}

/// Renders a template file from disk with caching and locals.
string renderTemplateFile(string filePath, JSONValue locals,
                          string viewsDir = "", string defaultEngine = "html",
                          TemplateCache cache = null)
{
    if (!exists(filePath) || !isFile(filePath))
        throw new HttpError(404, "View template not found: " ~ filePath);

    CompiledTemplate compiled;
    long mtime = 0;
    try
        mtime = timeLastModified(filePath).toUnixTime();
    catch (Exception) {}

    if (cache !is null)
        compiled = cache.get(filePath);

    if (compiled is null)
    {
        string content = readText(filePath);
        compiled = compileTemplate(content, filePath);
        if (cache !is null)
            cache.set(filePath, compiled, mtime);
    }

    auto app = appender!string();
    Evaluator evaluator;
    evaluator.contextStack = [&locals];
    evaluator.viewsDir = viewsDir;
    evaluator.defaultEngine = defaultEngine;
    evaluator.cache = cache;
    evaluator.renderNodes(compiled.nodes, app);
    return app.data;
}
