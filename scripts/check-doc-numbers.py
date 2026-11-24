#!/usr/bin/env python3
"""Every measured number in the docs names its measurement log.

    python3 scripts/check-doc-numbers.py [--root DIR] [FILE ...]

Lists every number with a unit or a ratio (`0.5x`, `3 ms`, `12%`, `481/481`, `900 req/s`,
`190 KB`, `192,854 bytes`, ...) in the files below and fails unless the same paragraph links a
file under `docs/measurements/` that exists. A paragraph is a block between blank lines; a table
row, a list item and a heading are paragraphs of their own, and a fenced code block belongs to
the paragraph before it. Text in inline code (`...`), HTML tags, link targets and bare URLs is not read.

A section of history is exempt: a heading whose text names rust-anything, followed by the line
`<!-- doc-numbers: history -->`, up to the next heading of the same or a higher level. Those
numbers were measured on rust-anything's Rust ports, not on Mojo, and are kept only as history.

The website's English sources are checked too (`--website` checks only them), more strictly:

- A Markdown page under `website/pages/en/` is read with its `<!-- include: FILE#anchor -->`
  lines expanded, as `website/scripts/md-include.mjs` expands them; an included paragraph keeps
  the links of the file it comes from, and a page's own paragraphs may link a log by its GitHub
  URL (`https://github.com/ModelTok/mojo-anything/blob/main/docs/measurements/...`). The
  history mark exempts nothing there: the website shows no rust-anything numbers.
- The website shows no timing at all, with or without a log, until the Mojo timings are
  measured on a quiet machine: no time unit, no `req/s`, and no `Nx` ratio unless its paragraph
  speaks of lines (`336 lines of Mojo for 184 of TS (1.8x)` is a size).
- Page code (`.ts` and `.tsx` under `website/components`, `website/lib` and `website/pages`)
  has no paragraph to link a log from, so it may show no number with a unit or ratio at all.

`cargo test --test tools docs_numbers_have_sources` runs it.
"""
import json
import os
import re
import sys

FILES = [
    "README.md",
    "docs/STATUS.md",
    "docs/real-world.md",
    "docs/real-world-languages.md",
    "docs/how-it-works.md",
    "docs/whole-apps.md",
    "docs/packaging.md",
    "docs/install.md",
    "docs/faq.md",
    "docs/tools.md",
    "docs/examples.md",
    "docs/privacy.md",
    "CONTRIBUTING.md",
    "SECURITY.md",
    "CHANGELOG.md",
]

HISTORY_MARK = "<!-- doc-numbers: history -->"

# Not part of a longer number or a name such as `UTF-8` or `x86-64`.
NUM = r"(?<![\w.,])(?<![A-Za-z]-)\d(?:[\d,]*\d)?(?:\.\d+)?"
PATTERNS = [
    re.compile(NUM + r"\s?(?:x|×)(?![\w])"),
    re.compile(NUM + r"\s?(?:ns|µs|μs|us|ms|s|secs?|seconds?|minutes?|min)\b"),
    re.compile(NUM + r"\s?%"),
    re.compile(r"(?<![\w./-])\d[\d,]*/\d[\d,]*(?![\w/])"),
    re.compile(NUM + r"\s?req/s\b"),
    re.compile(NUM + r"\s?(?:B|kB|KB|KiB|MB|MiB|GB|GiB|bytes)\b"),
]

# What the website may not show yet, whatever it links: speed ratios, times and request rates.
TIMINGS = [PATTERNS[0], PATTERNS[1], PATTERNS[4]]
LINES_RATIO = re.compile(r"\blines?\b")
REPO_BLOB = "https://github.com/ModelTok/mojo-anything/blob/main/"
INCLUDE = re.compile(r"^<!--\s*include:\s*(\S+)\s*-->\s*$")
CODE_DIRS = ["website/components", "website/lib", "website/pages"]

HEADING = re.compile(r"^(#{1,6})\s+(.*)$")
FENCE = re.compile(r"^\s*(```|~~~)")
LIST_ITEM = re.compile(r"^\s*(?:[-*+]|\d+\.)\s+")
LINK = re.compile(r"\]\(([^)\s]+)\)")


def visible(text):
    """The text a reader sees as prose: no inline code, link targets, URLs or comments."""
    text = re.sub(r"<!--.*?-->", " ", text)
    text = re.sub(r"<[^>]+>", " ", text)  # HTML tags and their attributes (`width="25%"`)
    text = re.sub(r"`[^`]*`", " ", text)
    text = LINK.sub("] ", text)
    return re.sub(r"https?://\S+", " ", text)


def paragraphs(lines, history=True):
    """(first line number, text, exempt) for each paragraph of a markdown file; with
    `history=False` a history mark exempts nothing."""
    out = []
    current = None
    history_level = None
    pending_heading = None
    in_fence = False

    def close():
        nonlocal current
        if current is not None:
            out.append(current)
            current = None

    for number, line in enumerate(lines, 1):
        if in_fence:
            target = out[-1] if current is None and out else current
            if target is not None:
                target[1] += "\n" + line
            if FENCE.match(line):
                in_fence = False
            continue
        if FENCE.match(line):
            in_fence = True
            continue
        if pending_heading is not None and line.strip():
            level, title, heading_line = pending_heading
            pending_heading = None
            if line.strip() == HISTORY_MARK:
                if "rust-anything" not in title:
                    out.append([heading_line, "", False, "history mark on a heading that does not name rust-anything"])
                if history:
                    history_level = level
                continue
        heading = HEADING.match(line)
        if heading:
            close()
            level = len(heading.group(1))
            if history_level is not None and level <= history_level:
                history_level = None
            pending_heading = (level, heading.group(2), number)
            out.append([number, line, history_level is not None, None])
            continue
        exempt = history_level is not None
        if not line.strip():
            close()
        elif line.lstrip().startswith("|") or LIST_ITEM.match(line):
            close()
            current = [number, line, exempt, None]
        elif current is None:
            current = [number, line, exempt, None]
        else:
            current[1] += "\n" + line
    close()
    return out


def sourced(text, doc_dir, measurements):
    root = os.path.dirname(os.path.dirname(measurements))
    for target in LINK.findall(text):
        path = target.split("#", 1)[0]
        if path.startswith(REPO_BLOB):
            full = os.path.normpath(os.path.join(root, path[len(REPO_BLOB):]))
        elif not path or "://" in path:
            continue
        else:
            full = os.path.normpath(os.path.join(doc_dir, path))
        if full.startswith(measurements + os.sep) and os.path.isfile(full):
            return True
    return False


def found_in(prose, patterns):
    found = [m.group(0) for p in patterns for m in p.finditer(prose)]
    return sorted(set(found), key=found.index)


def check_lines(rel, lines, doc_dir, measurements, website=False):
    problems = []
    for first, text, exempt, error in paragraphs(lines, history=not website):
        if error:
            problems.append(f"{rel}:{first}: {error}")
            continue
        if exempt:
            continue
        prose = visible(text)
        found = found_in(prose, PATTERNS)
        if found and not sourced(text, doc_dir, measurements):
            shown = ", ".join(found[:6])
            problems.append(f"{rel}:{first}: {shown} -- no link to docs/measurements/ in this paragraph")
        if website:
            timings = [t for t in found_in(prose, TIMINGS)
                       if not (re.search(r"(?:x|×)$", t) and LINES_RATIO.search(prose))]
            if timings:
                problems.append(f"{rel}:{first}: {', '.join(timings[:6])} -- the website shows no timing "
                                "until the Mojo timings are measured")
    return problems


def check(root, files):
    measurements = os.path.normpath(os.path.join(root, "docs", "measurements"))
    problems = []
    for rel in files:
        path = os.path.join(root, rel)
        if not os.path.isfile(path):
            problems.append(f"{rel}: missing (listed in check-doc-numbers.py)")
            continue
        with open(path, encoding="utf-8") as f:
            lines = f.read().splitlines()
        doc_dir = os.path.dirname(os.path.normpath(path))
        problems += check_lines(rel, lines, doc_dir, measurements)
    return problems


def github_slug(text):
    """The anchor GitHub (and md-include.mjs's `githubSlug`) gives a heading."""
    text = re.sub(r"<[^>]+>", "", text.strip().lower())
    text = "".join(c for c in text if c.isalnum() or c in "_-" or c.isspace())
    return re.sub(r"\s", "-", text)


def extract(lines, anchor):
    """The lines md-include.mjs takes for `FILE#anchor`: below the heading, up to the next
    heading of the same or a higher level (with no anchor: everything below the first `#`)."""
    headings = []
    fence = None
    for i, line in enumerate(lines):
        f = re.match(r"^\s{0,3}(`{3,}|~{3,})", line)
        if f:
            if not fence:
                fence = f.group(1)
            elif line.strip().startswith(fence):
                fence = None
            continue
        h = None if fence else re.match(r"^(#{1,6})\s+(.+?)\s*#*\s*$", line)
        if h:
            headings.append((i, len(h.group(1)), h.group(2)))
    if not anchor:
        first = next((i for i, level, _ in headings if level == 1), None)
        return lines if first is None else lines[first + 1:]
    start = next(((i, level) for i, level, text in headings if github_slug(text) == anchor), None)
    if start is None:
        return None
    end = next((i for i, level, _ in headings if i > start[0] and level <= start[1]), len(lines))
    return lines[start[0] + 1:end]


def cli_help_lines(root):
    with open(os.path.join(root, "website", "content", "cli-help.json"), encoding="utf-8") as f:
        data = json.load(f)
    out = []
    for c in data["commands"]:
        out += ["", "## " + (c["command"] or "mojo-anything"), "```text", *c["help"].rstrip().splitlines(), "```"]
    return out


def website_files(root):
    pages, code = [], []
    for base, dirs, names in os.walk(os.path.join(root, "website")):
        dirs[:] = sorted(d for d in dirs if d not in ("node_modules", "dist", ".void"))
        rel_base = os.path.relpath(base, root).replace(os.sep, "/")
        for name in sorted(names):
            rel = f"{rel_base}/{name}"
            if rel.startswith("website/pages/en/") and name.endswith(".md"):
                pages.append(rel)
            elif any(rel.startswith(d + "/") for d in CODE_DIRS) and name.endswith((".ts", ".tsx")):
                code.append(rel)
    return pages, code


def check_website(root):
    measurements = os.path.normpath(os.path.join(root, "docs", "measurements"))
    pages, code = website_files(root)
    problems = []
    for rel in pages:
        path = os.path.join(root, rel)
        with open(path, encoding="utf-8") as f:
            lines = f.read().splitlines()
        if lines and lines[0] == "---":  # frontmatter: title and description are prose too
            end = lines.index("---", 1) if "---" in lines[1:] else 0
            lines = ["" if i in (0, end) else l.split(":", 1)[-1] if i < end else l for i, l in enumerate(lines)]
        own = []
        for number, line in enumerate(lines, 1):
            m = INCLUDE.match(line)
            if not m:
                own.append(line)
                continue
            own.append("")
            spec = m.group(1)
            if spec == "cli-help":
                problems += check_lines(f"{rel} (cli-help)", cli_help_lines(root), os.path.dirname(path),
                                        measurements, website=True)
                continue
            file, _, anchor = spec.partition("#")
            source = os.path.join(root, file)
            if not os.path.isfile(source):
                problems.append(f"{rel}:{number}: includes {file}, which does not exist")
                continue
            with open(source, encoding="utf-8") as f:
                included = extract(f.read().splitlines(), anchor)
            if included is None:
                problems.append(f"{rel}:{number}: {file} has no heading #{anchor}")
                continue
            problems += check_lines(f"{rel} ({spec})", included, os.path.dirname(source), measurements, website=True)
        problems += check_lines(rel, own, os.path.dirname(path), measurements, website=True)
    for rel in code:
        with open(os.path.join(root, rel), encoding="utf-8") as f:
            text = f.read()
        text = re.sub(r"//[^\n]*|/\*.*?\*/", " ", text, flags=re.S)
        # Class names and SVG path data are not shown as text.
        text = re.sub(r"(?:className|\bd)=(\"[^\"]*\"|\{`[^`]*`\})", " ", text)
        for number, line in enumerate(text.splitlines(), 1):
            found = found_in(line, PATTERNS)
            if found:
                problems.append(f"{rel}:{number}: {', '.join(found[:6])} -- page code shows no number with a unit; "
                                "put it in a Markdown page that links its log")
    return problems, len(pages) + len(code)


def main(argv):
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    files = []
    website_only = False
    args = iter(argv)
    for arg in args:
        if arg == "--root":
            root = os.path.abspath(next(args))
        elif arg == "--website":
            website_only = True
        else:
            files.append(arg)
    problems, count = [], 0
    if not website_only:
        problems += check(root, files or FILES)
        count += len(files or FILES)
    if website_only or not files:
        site_problems, site_count = check_website(root)
        problems += site_problems
        count += site_count
    for p in problems:
        print(p)
    if problems:
        print(f"{len(problems)} paragraph(s) with numbers that name no measurement log or show a timing")
        return 1
    print(f"every number with a unit names a log under docs/measurements/ ({count} files)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
