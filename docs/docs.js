(function () {
    "use strict";

    const doc = document;
    const body = doc.body;
    const root = body ? (body.getAttribute("data-docs-root") || "") : "";

    function fold(value) {
        return String(value || "")
            .normalize("NFKD")
            .replace(/[\u0300-\u036f]/g, "")
            .toLowerCase();
    }

    function escapeHtml(value) {
        return String(value)
            .replace(/&/g, "&amp;")
            .replace(/</g, "&lt;")
            .replace(/>/g, "&gt;")
            .replace(/"/g, "&quot;")
            .replace(/'/g, "&#39;");
    }

    function escapeRegExp(value) {
        return value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
    }

    function markTerms(value, terms) {
        const alternatives = terms
            .filter(Boolean)
            .map(function (term) { return escapeRegExp(escapeHtml(term)); })
            .sort(function (a, b) { return b.length - a.length; });

        if (!alternatives.length) return escapeHtml(value);

        return escapeHtml(value).replace(
            new RegExp("(" + alternatives.join("|") + ")", "gi"),
            "<mark>$1</mark>"
        );
    }

    function makeSnippet(text, terms) {
        const source = String(text || "");
        const lower = fold(source);
        let best = -1;

        terms.forEach(function (term) {
            const found = lower.indexOf(term);
            if (found >= 0 && (best < 0 || found < best)) best = found;
        });

        if (best < 0) best = 0;
        const start = Math.max(0, best - 70);
        const end = Math.min(source.length, best + 170);
        return (start > 0 ? "…" : "") +
            source.slice(start, end).trim() +
            (end < source.length ? "…" : "");
    }

    /* Search --------------------------------------------------------------- */

    const search = doc.querySelector(".docs-search");
    const input = doc.getElementById("docs-search-input");
    const results = doc.getElementById("docs-search-results");
    const searchStatus = doc.getElementById("docs-search-status");

    if (search && input && results) {
        const indexUrl = root + "search-index.json";
        let records = null;
        let loadPromise = null;
        let active = -1;
        let current = [];
        let debounce = 0;

        function announce(message) {
            if (!searchStatus) return;
            searchStatus.textContent = "";
            window.setTimeout(function () {
                searchStatus.textContent = message;
            }, 20);
        }

        function loadIndex() {
            if (loadPromise) return loadPromise;

            announce("Loading search index.");
            loadPromise = fetch(indexUrl, { cache: "no-cache" })
                .then(function (response) {
                    if (!response.ok) throw new Error("Search index unavailable");
                    return response.json();
                })
                .then(function (data) {
                    records = (data.records || []).map(function (record) {
                        return {
                            title: record.title || "",
                            page: record.page || "",
                            section: record.section || "",
                            url: record.url || "",
                            text: record.text || "",
                            _title: fold(record.title),
                            _page: fold(record.page),
                            _section: fold(record.section),
                            _text: fold(record.text),
                            _haystack: fold([
                                record.title,
                                record.page,
                                record.section,
                                record.text
                            ].join(" "))
                        };
                    });
                    return records;
                })
                .catch(function (error) {
                    loadPromise = null;
                    announce("Search is unavailable.");
                    throw error;
                });

            return loadPromise;
        }

        function closeResults() {
            active = -1;
            results.hidden = true;
            results.innerHTML = "";
            input.setAttribute("aria-expanded", "false");
            input.removeAttribute("aria-activedescendant");
            current = [];
        }

        function setActive(index) {
            const items = results.querySelectorAll(".docs-search-result");
            if (!items.length) return;

            active = (index + items.length) % items.length;
            items.forEach(function (item, itemIndex) {
                const selected = itemIndex === active;
                item.classList.toggle("is-active", selected);
                item.setAttribute("aria-selected", selected ? "true" : "false");
            });

            const item = items[active];
            input.setAttribute("aria-activedescendant", item.id);
            item.scrollIntoView({ block: "nearest" });
        }

        function render(query, matches) {
            current = matches;
            active = -1;
            results.innerHTML = "";

            if (!matches.length) {
                const empty = doc.createElement("p");
                empty.className = "docs-search-empty";
                empty.textContent = "No matches for “" + query + "”.";
                results.appendChild(empty);
            } else {
                matches.forEach(function (record, index) {
                    const link = doc.createElement("a");
                    link.className = "docs-search-result";
                    link.id = "docs-search-result-" + index;
                    link.href = root + record.url;
                    link.setAttribute("role", "option");
                    link.setAttribute("aria-selected", "false");
                    link.innerHTML =
                        '<span class="docs-search-result-title">' +
                        markTerms(record.title, query.split(/\s+/)) +
                        '</span>' +
                        '<span class="docs-search-result-meta">' +
                        escapeHtml(record.section) + " · " + escapeHtml(record.page) +
                        '</span>' +
                        '<span class="docs-search-result-snippet">' +
                        markTerms(makeSnippet(record.text, query.split(/\s+/)), query.split(/\s+/)) +
                        '</span>';
                    results.appendChild(link);
                });
            }

            results.hidden = false;
            input.setAttribute("aria-expanded", "true");
            input.removeAttribute("aria-activedescendant");
            announce(matches.length
                ? matches.length + (matches.length === 1 ? " result." : " results.")
                : "No results.");
        }

        function searchDocs() {
            const query = input.value.trim();
            const terms = fold(query).split(/\s+/).filter(Boolean);

            if (terms.length === 0 || query.length < 2) {
                closeResults();
                return;
            }

            loadIndex().then(function (allRecords) {
                if (input.value.trim() !== query) return;

                const matches = allRecords
                    .filter(function (record) {
                        return terms.every(function (term) {
                            return record._haystack.indexOf(term) >= 0;
                        });
                    })
                    .map(function (record) {
                        let score = 0;
                        const foldedQuery = fold(query);

                        terms.forEach(function (term) {
                            if (record._title.indexOf(term) >= 0) score += 24;
                            if (record._page.indexOf(term) >= 0) score += 7;
                            if (record._section.indexOf(term) >= 0) score += 4;
                            if (record._text.indexOf(term) >= 0) score += 1;
                        });

                        if (record._title === foldedQuery) score += 100;
                        else if (record._title.indexOf(foldedQuery) === 0) score += 40;

                        return { record: record, score: score };
                    })
                    .sort(function (a, b) {
                        return b.score - a.score ||
                            a.record.title.localeCompare(b.record.title);
                    })
                    .slice(0, 12)
                    .map(function (entry) { return entry.record; });

                render(query, matches);
            }).catch(function () {
                results.hidden = false;
                results.innerHTML =
                    '<p class="docs-search-empty">Search is unavailable. ' +
                    'Try again from the GitHub Pages site.</p>';
                input.setAttribute("aria-expanded", "true");
            });
        }

        input.addEventListener("input", function () {
            window.clearTimeout(debounce);
            debounce = window.setTimeout(searchDocs, 70);
        });

        input.addEventListener("focus", function () {
            if (input.value.trim().length >= 2) searchDocs();
        });

        input.addEventListener("keydown", function (event) {
            if (event.key === "ArrowDown") {
                event.preventDefault();
                setActive(active + 1);
            } else if (event.key === "ArrowUp") {
                event.preventDefault();
                setActive(active - 1);
            } else if (event.key === "Enter") {
                const items = results.querySelectorAll(".docs-search-result");
                if (items.length) {
                    event.preventDefault();
                    (items[active >= 0 ? active : 0]).click();
                }
            } else if (event.key === "Escape") {
                event.preventDefault();
                closeResults();
                input.blur();
            }
        });

        doc.addEventListener("pointerdown", function (event) {
            if (!search.contains(event.target)) closeResults();
        });

        doc.addEventListener("keydown", function (event) {
            if (event.key !== "/" || event.metaKey || event.ctrlKey || event.altKey) return;
            const target = event.target;
            if (target instanceof HTMLElement) {
                if (target.isContentEditable) return;
                if (["INPUT", "TEXTAREA", "SELECT"].indexOf(target.tagName) >= 0) return;
            }
            event.preventDefault();
            input.focus();
            input.select();
        });
    }

    /* On-this-page table of contents -------------------------------------- */

    const tocLinks = Array.prototype.slice.call(
        doc.querySelectorAll(".docs-toc a[href^='#']")
    );

    const tocHeadings = tocLinks
        .map(function (link) {
            try {
                return doc.getElementById(decodeURIComponent(link.hash.slice(1)));
            } catch (error) {
                return null;
            }
        })
        .filter(Boolean);

    function setActiveHeading(id) {
        tocLinks.forEach(function (link) {
            if (link.hash === "#" + id) {
                link.classList.add("active");
                link.setAttribute("aria-current", "location");
            } else {
                link.classList.remove("active");
                link.removeAttribute("aria-current");
            }
        });
    }

    if (tocHeadings.length) {
        let tocFrame = 0;

        const updateToc = function () {
            if (tocFrame) return;
            tocFrame = window.requestAnimationFrame(function () {
                tocFrame = 0;
                let currentHeading = null;

                tocHeadings.forEach(function (heading) {
                    if (heading.getBoundingClientRect().top <= 140) {
                        currentHeading = heading;
                    }
                });

                if (currentHeading) setActiveHeading(currentHeading.id);
            });
        };

        window.addEventListener("scroll", updateToc, { passive: true });
        window.addEventListener("resize", updateToc);
        updateToc();
    }
}());
