#!/usr/bin/env python3
"""Build the GitHub Pages documentation from Markdown sources.

Source: docs-src/**/*.md
Output: docs/**/*.html + docs/search-index.json

The build is intentionally dependency-light: Markdown, Pygments, and lxml.
"""

from __future__ import annotations

import html
import json
import posixpath
import re
import sys
from pathlib import Path

import markdown
from lxml import html as lxml_html
from markdown.extensions import Extension
from markdown.preprocessors import Preprocessor
from pygments import highlight
from pygments.formatters import HtmlFormatter
from pygments.lexers import get_lexer_by_name

ROOT = Path(__file__).resolve().parents[1]
DOCS_SRC = ROOT / "docs-src"
DOCS_OUT = ROOT / "docs"

LANG_LABELS = {
    "d": "D",
    "sh": "Shell",
    "json": "JSON",
    "html": "HTML",
    "hbs": "Handlebars",
    "css": "CSS",
    "js": "JavaScript",
    "text": "Text",
}

LEXER_NAMES = {
    "d": "d",
    "sh": "sh",
    "json": "json",
    "html": "html",
    "hbs": "handlebars",
    "css": "css",
    "js": "js",
    "text": "text",
}

FENCE_RE = re.compile(r"^```([^\n]*)\n(.*?)^```[ \t]*$", re.MULTILINE | re.DOTALL)


def clean(text: str) -> str:
    return " ".join(text.split())


def render_code(code: str, lang: str, title: str, index: int) -> str:
    lang = lang.strip().lower()
    lexer_name = LEXER_NAMES.get(lang, lang)
    try:
        lexer = get_lexer_by_name(lexer_name)
    except Exception:
        lexer = get_lexer_by_name("text")

    body = highlight(code.rstrip("\n"), lexer, HtmlFormatter(nowrap=True))
    label = title.strip() or LANG_LABELS.get(lang, lang.upper() or "Code")
    code_id = f"code-{index}"

    return f"""<div class="code-frame">
  <div class="code-bar">
    <span class="code-title">{html.escape(label)}</span>
    <button class="copy-button" type="button" data-copy="{code_id}" aria-label="Copy {html.escape(label)}">
      <svg class="icon icon-copy" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><rect x="9" y="9" width="12" height="12" rx="2"/><path d="M5 15V5a2 2 0 0 1 2-2h10"/></svg>
      <svg class="icon icon-check" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="m5 12 4 4L19 6"/></svg>
    </button>
  </div>
  <pre class="code" id="{code_id}" tabindex="0" aria-label="{html.escape(label)} code example"><code class="language-{html.escape(lang or 'text')}">{body}</code></pre>
</div>"""


class CodeFencePreprocessor(Preprocessor):
    def run(self, lines):
        text = "\n".join(lines)
        counter = {"n": 0}

        def replace(match):
            info = match.group(1).strip()
            code = match.group(2)
            counter["n"] += 1

            lang = info.split()[0] if info else ""
            title_match = re.search(r'title="([^"]*)"', info)
            title = title_match.group(1) if title_match else ""
            rendered = render_code(code, lang, title, counter["n"])
            return self.md.htmlStash.store(rendered)

        return [FENCE_RE.sub(replace, text)]


class CodeFenceExtension(Extension):
    def extendMarkdown(self, md):
        md.preprocessors.register(CodeFencePreprocessor(md), "docs_code_fence", 30)


def parse_front_matter(text: str):
    meta = {}
    if text.startswith("---\n"):
        end = text.find("\n---\n", 4)
        if end < 0:
            raise ValueError("unterminated front matter")
        raw = text[4:end]
        for line in raw.splitlines():
            if ":" in line:
                key, value = line.split(":", 1)
                meta[key.strip()] = value.strip()
        text = text[end + 5:]
    return meta, text


def rel_link(from_slug: str, to_slug: str) -> str:
    from_dir = posixpath.dirname(from_slug) or "."
    return posixpath.relpath(f"{to_slug}.html", start=from_dir)


def make_sidebar(nav, current_slug: str) -> str:
    groups = []
    for section in nav["sections"]:
        items = []
        for page in section["pages"]:
            slug = page["slug"]
            active = slug == current_slug
            cls = "docs-nav-link active" if active else "docs-nav-link"
            current = ' aria-current="page"' if active else ""
            items.append(
                f'<li><a class="{cls}" href="{rel_link(current_slug, slug)}"{current}>'
                f'{html.escape(page["label"])}</a></li>'
            )
        groups.append(
            '<div class="docs-nav-group">'
            f'<div class="docs-nav-heading">{html.escape(section["title"])}</div>'
            f'<ul class="docs-nav-list">{"".join(items)}</ul>'
            '</div>'
        )
    return "\n".join(groups)


def make_pager(pages, current_slug: str) -> str:
    slugs = [page["slug"] for page in pages]
    try:
        index = slugs.index(current_slug)
    except ValueError:
        return ""

    parts = []
    if index > 0:
        previous = pages[index - 1]
        parts.append(
            f'<a class="pager-btn pager-prev" href="{rel_link(current_slug, previous["slug"])}">'
            '<span class="pager-label">&larr; Previous</span>'
            f'<span class="pager-title">{html.escape(previous["label"])}</span></a>'
        )
    if index + 1 < len(pages):
        following = pages[index + 1]
        parts.append(
            f'<a class="pager-btn pager-next" href="{rel_link(current_slug, following["slug"])}">'
            '<span class="pager-label">Next &rarr;</span>'
            f'<span class="pager-title">{html.escape(following["label"])}</span></a>'
        )

    if not parts:
        return ""
    return '<nav class="docs-pager" aria-label="Docs pagination">' + "".join(parts) + "</nav>"


def make_toc(md, toc_html: str) -> str:
    if not getattr(md, "toc_tokens", None):
        return ""
    return (
        '<aside class="docs-toc" aria-label="On this page">'
        '<p class="docs-toc-heading">On this page</p>'
        f'<div class="docs-toc-list">{toc_html}</div>'
        '</aside>'
    )


def build_search_records(slug: str, section: str, page_title: str,
                         description: str, content_html: str):
    records = []
    if not content_html.strip():
        return records

    tree = lxml_html.fragment_fromstring(content_html, create_parent="div")
    page_text = clean(tree.text_content())
    records.append({
        "title": page_title,
        "page": page_title,
        "section": section,
        "url": f"{slug}.html",
        "text": clean(description + " " + page_text)[:5000],
    })

    headings = tree.xpath(".//h2[@id] | .//h3[@id]")
    for heading in headings:
        text = clean(heading.text_content())
        if not text:
            continue
        body_parts = []
        node = heading.getnext()
        while node is not None:
            if isinstance(node.tag, str) and node.tag.lower() in ("h2", "h3") and node.get("id"):
                break
            if isinstance(node.tag, str) and node.tag.lower() in ("p", "ul", "ol", "pre", "blockquote", "div", "table"):
                body_parts.append(clean(node.text_content()))
            node = node.getnext()

        text_body = clean(" ".join(body_parts))
        if text_body:
            records.append({
                "title": text,
                "page": page_title,
                "section": section,
                "url": f"{slug}.html#{heading.get('id')}",
                "text": text_body[:4000],
            })
    return records


def main() -> int:
    nav = json.loads((DOCS_SRC / "nav.json").read_text(encoding="utf-8"))
    template = (DOCS_SRC / "template.html").read_text(encoding="utf-8")
    pages = [page for section in nav["sections"] for page in section["pages"]]

    section_for = {}
    for section in nav["sections"]:
        for page in section["pages"]:
            section_for[page["slug"]] = section["title"]

    search_records = []

    for page in pages:
        slug = page["slug"]
        source = DOCS_SRC / f"{slug}.md"
        if not source.exists():
            print(f"missing markdown: {source}", file=sys.stderr)
            return 1

        meta, body = parse_front_matter(source.read_text(encoding="utf-8"))
        title = clean(meta.get("title", slug.rsplit("/", 1)[-1].replace("-", " ").title()))
        description = clean(meta.get("description", ""))
        section = section_for[slug]

        md = markdown.Markdown(
            extensions=[
                CodeFenceExtension(),
                "tables",
                "sane_lists",
                "toc",
                "attr_list",
                "md_in_html",
            ],
            extension_configs={
                "toc": {
                    "permalink": False,
                    "toc_depth": "2-3",
                }
            },
        )
        content_html = md.convert(body)
        toc_html = getattr(md, "toc", "")

        output = DOCS_OUT / f"{slug}.html"
        output.parent.mkdir(parents=True, exist_ok=True)
        depth = len(Path(slug).parent.parts)
        root = "../" * depth

        breadcrumb = (
            f'<a href="{root}index.html">Home</a>'
            '<span class="separator">/</span>'
            f'<span>{html.escape(section)}</span>'
            '<span class="separator">/</span>'
            f'<span aria-current="page">{html.escape(title)}</span>'
        )

        rendered = (template
                    .replace("{{ROOT}}", root)
                    .replace("{{PAGE_TITLE}}", html.escape(title))
                    .replace("{{DESCRIPTION}}", html.escape(description))
                    .replace("{{BREADCRUMB}}", breadcrumb)
                    .replace("{{SIDEBAR}}", make_sidebar(nav, slug))
                    .replace("{{CONTENT}}", content_html)
                    .replace("{{PAGER}}", make_pager(pages, slug))
                    .replace("{{TOC_ASIDE}}", make_toc(md, toc_html)))
        output.write_text(rendered, encoding="utf-8")

        search_records.extend(build_search_records(slug, section, title, description, content_html))
        print(f"docs: {source.relative_to(ROOT)} -> {output.relative_to(ROOT)}"
              f" ({len(content_html)} bytes, {len(search_records)} search records)")

    index_path = DOCS_OUT / "search-index.json"
    index_path.write_text(
        json.dumps({"records": search_records}, ensure_ascii=False, separators=(",", ":")),
        encoding="utf-8",
    )
    print(f"docs: wrote {index_path.relative_to(ROOT)} ({len(search_records)} records)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
