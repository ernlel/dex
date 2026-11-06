(function () {
    "use strict";

    // Auto-detection works on GitHub Pages project/user sites. Set this
    // explicitly when serving from a custom domain.
    const CONFIGURED_REPO_URL = "";

    const doc = document;
    const root = doc.documentElement;

    function resolveRepoUrl() {
        if (CONFIGURED_REPO_URL) {
            return CONFIGURED_REPO_URL.replace(/\/+$/, "");
        }

        if (location.hostname.endsWith(".github.io")) {
            const user = location.hostname.split(".")[0];
            if (!user) return null;

            const segments = location.pathname.split("/").filter(Boolean);
            const repo = segments.length ? segments[0] : `${user}.github.io`;
            return `https://github.com/${user}/${repo}`;
        }

        return null;
    }

    const repoUrl = resolveRepoUrl();
    if (repoUrl) {
        doc.querySelectorAll("[data-github]").forEach(function (link) {
            link.href = repoUrl;
        });

        doc.querySelectorAll("[data-repo-file]").forEach(function (link) {
            link.href = `${repoUrl}/blob/HEAD/${link.dataset.repoFile}`;
            link.target = "_blank";
            link.rel = "noopener";
        });

        doc.querySelectorAll("[data-repo-path]").forEach(function (link) {
            link.href = `${repoUrl}/tree/main/${link.dataset.repoPath}`;
            link.target = "_blank";
            link.rel = "noopener";
        });
    }

    const yearTargets = doc.querySelectorAll("[data-year]");
    yearTargets.forEach(function (target) {
        target.textContent = String(new Date().getFullYear());
    });

    /* Header --------------------------------------------------------------- */

    const header = doc.querySelector("[data-header]");
    if (header) {
        const updateHeader = function () {
            header.classList.toggle("is-scrolled", window.scrollY > 8);
        };

        updateHeader();
        window.addEventListener("scroll", updateHeader, { passive: true });
    }

    /* Mobile navigation ---------------------------------------------------- */

    const navToggle = doc.querySelector("[data-nav-toggle]");
    const nav = doc.querySelector("[data-nav]");

    function closeNav() {
        if (!nav || !navToggle) return;
        nav.classList.remove("is-open");
        navToggle.setAttribute("aria-expanded", "false");
        navToggle.setAttribute("aria-label", "Open navigation");
    }

    if (nav && navToggle) {
        navToggle.addEventListener("click", function () {
            const isOpen = navToggle.getAttribute("aria-expanded") === "true";
            nav.classList.toggle("is-open", !isOpen);
            navToggle.setAttribute("aria-expanded", String(!isOpen));
            navToggle.setAttribute("aria-label", isOpen ? "Open navigation" : "Close navigation");
        });

        nav.querySelectorAll("a").forEach(function (link) {
            link.addEventListener("click", closeNav);
        });

        doc.addEventListener("keydown", function (event) {
            if (event.key === "Escape") closeNav();
        });

        doc.addEventListener("click", function (event) {
            if (!nav.classList.contains("is-open")) return;
            if (nav.contains(event.target) || navToggle.contains(event.target)) return;
            closeNav();
        });

        const desktop = window.matchMedia("(min-width: 861px)");
        const handleDesktop = function (event) {
            if (event.matches) closeNav();
        };

        if (desktop.addEventListener) {
            desktop.addEventListener("change", handleDesktop);
        } else if (desktop.addListener) {
            desktop.addListener(handleDesktop);
        }
    }

    /* Copy code ------------------------------------------------------------ */

    const copyStatus = doc.getElementById("copy-status");

    function announce(message) {
        if (!copyStatus) return;
        copyStatus.textContent = "";
        window.setTimeout(function () {
            copyStatus.textContent = message;
        }, 20);
    }

    function copyText(text) {
        if (navigator.clipboard && window.isSecureContext) {
            return navigator.clipboard.writeText(text);
        }

        return new Promise(function (resolve, reject) {
            const textarea = doc.createElement("textarea");
            textarea.value = text;
            textarea.setAttribute("readonly", "");
            textarea.style.position = "fixed";
            textarea.style.top = "0";
            textarea.style.left = "-9999px";
            textarea.style.opacity = "0";
            doc.body.appendChild(textarea);
            textarea.focus();
            textarea.select();

            try {
                const copied = doc.execCommand("copy");
                textarea.remove();
                if (copied) resolve();
                else reject(new Error("Copy command failed"));
            } catch (error) {
                textarea.remove();
                reject(error);
            }
        });
    }

    doc.querySelectorAll("[data-copy]").forEach(function (button) {
        const target = doc.getElementById(button.getAttribute("data-copy"));
        if (!target) return;

        const label = button.querySelector(".copy-label");
        const originalLabel = button.getAttribute("aria-label") || "";

        button.addEventListener("click", function () {
            const code = target.querySelector("code") || target;
            const text = code.textContent.replace(/\n$/, "");

            copyText(text).then(function () {
                button.classList.add("is-copied");
                button.setAttribute("aria-label", "Copied");
                if (label) label.textContent = "Copied";
                announce("Copied to clipboard.");

                if (button.__copyTimer) {
                    window.clearTimeout(button.__copyTimer);
                }
                button.__copyTimer = window.setTimeout(function () {
                    button.classList.remove("is-copied");
                    button.setAttribute("aria-label", originalLabel);
                    if (label) label.textContent = "Copy";
                }, 1600);
            }).catch(function () {
                announce("Copy failed. Select the code and copy it manually.");
            });
        });
    });

    /* Scroll reveal -------------------------------------------------------- */

    const reveals = Array.prototype.slice.call(doc.querySelectorAll(".reveal"));
    const reduceMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;

    if ("IntersectionObserver" in window && !reduceMotion) {
        const revealObserver = new IntersectionObserver(function (entries) {
            entries.forEach(function (entry) {
                if (!entry.isIntersecting) return;
                entry.target.classList.add("is-visible");
                revealObserver.unobserve(entry.target);
            });
        }, {
            rootMargin: "0px 0px -8% 0px",
            threshold: 0.08
        });

        reveals.forEach(function (element, index) {
            element.style.setProperty("--reveal-delay", `${(index % 4) * 45}ms`);
            revealObserver.observe(element);
        });
    } else {
        reveals.forEach(function (element) {
            element.classList.add("is-visible");
        });
    }

    /* Scroll spy ----------------------------------------------------------- */

    const navLinks = Array.prototype.slice.call(
        doc.querySelectorAll(".nav a[href^='#']")
    );

    const sections = navLinks.map(function (link) {
        return doc.querySelector(link.getAttribute("href"));
    }).filter(Boolean);

    function setActiveSection(id) {
        navLinks.forEach(function (link) {
            if (link.getAttribute("href") === `#${id}`) {
                link.setAttribute("aria-current", "location");
            } else {
                link.removeAttribute("aria-current");
            }
        });
    }

    if (sections.length) {
        let spyFrame = 0;

        const updateActiveSection = function () {
            if (spyFrame) return;
            spyFrame = window.requestAnimationFrame(function () {
                spyFrame = 0;
                const offset = 140;
                let current = null;

                sections.forEach(function (section) {
                    if (section.getBoundingClientRect().top <= offset) {
                        current = section.id;
                    }
                });

                if (current) setActiveSection(current);
                else navLinks.forEach(function (link) { link.removeAttribute("aria-current"); });
            });
        };

        window.addEventListener("scroll", updateActiveSection, { passive: true });
        window.addEventListener("resize", updateActiveSection);
        updateActiveSection();
    }

    window.__dexPageReady = true;
}());
