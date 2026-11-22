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

`cargo test --test tools docs_numbers_have_sources` runs it.
"""
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


def paragraphs(lines):
    """(first line number, text, exempt) for each paragraph of a markdown file."""
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
    for target in LINK.findall(text):
        path = target.split("#", 1)[0]
        if not path or "://" in path:
            continue
        full = os.path.normpath(os.path.join(doc_dir, path))
        if full.startswith(measurements + os.sep) and os.path.isfile(full):
            return True
    return False


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
        for first, text, exempt, error in paragraphs(lines):
            if error:
                problems.append(f"{rel}:{first}: {error}")
                continue
            if exempt:
                continue
            prose = visible(text)
            found = [m.group(0) for p in PATTERNS for m in p.finditer(prose)]
            if found and not sourced(text, doc_dir, measurements):
                shown = ", ".join(sorted(set(found), key=found.index)[:6])
                problems.append(f"{rel}:{first}: {shown} -- no link to docs/measurements/ in this paragraph")
    return problems


def main(argv):
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    files = []
    args = iter(argv)
    for arg in args:
        if arg == "--root":
            root = os.path.abspath(next(args))
        else:
            files.append(arg)
    problems = check(root, files or FILES)
    for p in problems:
        print(p)
    if problems:
        print(f"{len(problems)} paragraph(s) with numbers that name no measurement log")
        return 1
    print(f"every number with a unit names a log under docs/measurements/ ({len(files or FILES)} files)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
