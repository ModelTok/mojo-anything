"""Writes the inputs for CPython's `quopri` command line (`python3 -m quopri`): encoding and
decoding of stdin and files as people use it, and the errors `main()` reports itself.

    python3 scripts/inputs.py quopri.py inputs.jsonl unit-inputs.jsonl

`inputs.jsonl` is for `app record --inputs`, `unit-inputs.jsonl` for `record --inputs` on the
bridged unit (`encodestring` and `decodestring` called with bytes). Every CLI input is run
against the original first and its exit code printed, so a line that does not do what its name
says shows up here, not in the recording."""

import json
import subprocess
import sys
import tempfile
import os

ORIGINAL, OUT, UNIT_OUT = sys.argv[1], sys.argv[2], sys.argv[3]

lorem = (
    "Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor "
    "incididunt ut labore et dolore magna aliqua.\n"
)
texts = {
    "empty": "",
    "hello": "Hello, world!\n",
    "no-newline": "no trailing newline",
    "equals": "a=b, 1+1=2, ==, =\n",
    "trailing-space": "line ends in a space \nand a tab\t\n",
    "trailing-space-no-newline": "ends in a space ",
    "trailing-tab-last": "tab at the very end\t",
    "spaces-and-tabs": "a b\tc  d\t\te\n",
    "long-line": "x" * 200 + "\n",
    "long-line-75": "y" * 75 + "\n",
    "long-line-76": "z" * 76 + "\n",
    "long-line-77": "w" * 77 + "\n",
    "long-words": ("word " * 40).strip() + "\n",
    "long-escapes": "é" * 60 + "\n",
    "escape-at-break": "a" * 74 + "=" + "b" * 10 + "\n",
    "lorem": lorem,
    "lorem-x20": lorem * 20,
    "polish": "Zażółć gęślą jaźń\n",
    "emoji": "naïve café 😀🎉 ✓\n",
    "nul-and-controls": "a\u0000b\u0001\u001f\u007f\n",
    "crlf-text": "line one\r\nline two \r\n",
    "lone-cr": "one\rtwo\n",
    "dot-line": "first\n.\nlast\n",
    "dot-alone": ".",
    "underscores": "snake_case_name\n",
    "blank-lines": "\n\n\nend\n",
    "html": '<p class="x">5 > 3 & 2 < 4</p>\n',
    "big": "".join(chr(32 + (i * 7) % 95) for i in range(20000)) + "\n",
}

lines = []


def add(name, args, stdin=None, files=None):
    entry = {"name": name, "args": args}
    if stdin is not None:
        entry["stdin"] = stdin
    if files:
        entry["files"] = files
    lines.append(entry)


for name, text in texts.items():
    add(f"encode-stdin-{name}", [], stdin=text)
for name in ["spaces-and-tabs", "trailing-space", "lorem", "polish", "empty", "long-words"]:
    add(f"encode-t-stdin-{name}", ["-t"], stdin=texts[name])
add("encode-dash", ["-"], stdin="read from a dash = here\n")
add("encode-t-dash", ["-t", "-"], stdin="tabs\tand spaces \n")
for name in ["hello", "lorem-x20", "polish", "emoji", "empty", "trailing-space", "big"]:
    add(f"encode-file-{name}", ["in.txt"], files={"in.txt": texts[name]})
add("encode-t-file", ["-t", "in.txt"], files={"in.txt": texts["spaces-and-tabs"]})
add("encode-two-files", ["a.txt", "b.txt"], files={"a.txt": "first file\n", "b.txt": "second=file\n"})
add("encode-file-then-stdin", ["a.txt", "-"], stdin="from stdin \n", files={"a.txt": "from a file\n"})
add("encode-stdin-twice", ["-", "-"], stdin="read once\n")
add("encode-file-in-folder", ["data/notes.txt"], files={"data/notes.txt": "nested é\n"})
add("encode-double-dash", ["--", "in.txt"], files={"in.txt": "after -- \n"})
add("encode-t-double-dash", ["-t", "--", "in.txt"], files={"in.txt": "tab\tafter --\n"})
add("encode-option-after-file", ["in.txt", "-d"], files={"in.txt": "-d here is a file name\n"})
add("encode-ignores-stdin-with-file", ["in.txt"], stdin="not read", files={"in.txt": "file wins\n"})
add("encode-missing-file", ["missing.txt"])
add("encode-missing-then-file", ["missing.txt", "in.txt"], files={"in.txt": "still encoded\n"})
add("encode-directory", ["data"], files={"data/x.txt": "x\n"})

encoded = {
    "soft-breaks": "This is a long line that was wrapped with a soft line break at the=\n end of it.\n",
    "soft-break-crlf": "wrapped with =\r\nCRLF soft break\r\n",
    "soft-break-cr-junk": "junk after =  \t\r\nthe equals sign\n",
    "hex-upper": "caf=C3=A9 =3D equals\n",
    "hex-lower": "caf=c3=a9 lower case hex\n",
    "bad-escape": "=ZZ and =4 and =G1 stay\n",
    "double-equals": "a==3Db\n",
    "equals-at-end": "ends with an equals=",
    "equals-at-end-of-line": "soft=\nbreak\n",
    "trailing-whitespace": "kept   \t\nlines\n",
    "binary-ff": "=FF",
    "binary-00-ff-00": "=00=FF=00",
    "binary-all-bytes": "".join(f"={b:02X}" for b in range(256)),
    "binary-png-header": "=89PNG=0D=0A=1A=0A=00=00=00=0DIHDR",
    "binary-invalid-utf8": "caf=E9 =C3=28 =A0=A1\n",
    "underscores": "snake_case_stays\n",
    "polish": "Za=C5=BC=C3=B3=C5=82=C4=87 g=C4=99=C5=9Bl=C4=85 ja=C5=BA=C5=84\n",
    "raw-utf8": "already raw é ✓\n",
    "blank-lines": "\n\n=3D\n\n",
    "crlf-lines": "line one\r\nline two\r\n",
}
for name, text in encoded.items():
    add(f"decode-stdin-{name}", ["-d"], stdin=text)
for name in ["lorem-x20", "polish", "emoji", "trailing-space", "big", "long-escapes", "crlf-text"]:
    add(f"decode-roundtrip-{name}", ["-d"], stdin=None)
add("decode-dash", ["-d", "-"], stdin=encoded["hex-upper"])
add("decode-file", ["-d", "in.qp"], files={"in.qp": encoded["soft-breaks"]})
add("decode-two-files", ["-d", "a.qp", "b.qp"], files={"a.qp": "one=3D1\n", "b.qp": "two=\n"})
add("decode-missing-file", ["-d", "missing.qp"])
add("decode-combined-option-dd", ["-dd"], stdin=encoded["hex-upper"])

add("error-t-and-d", ["-t", "-d"], stdin="x\n")
add("error-td-combined", ["-td"], stdin="x\n")
add("error-unknown-option", ["-x"], stdin="x\n")
add("error-unknown-option-after-t", ["-tx"], stdin="x\n")
add("error-long-option", ["--help"], stdin="x\n")
add("error-long-option-with-value", ["--mode=fast"], stdin="x\n")
add("error-help-short", ["-h"], stdin="x\n")

# Round trips: decode what the original encodes.
roundtrip = {}
for entry in lines:
    if entry["name"].startswith("decode-roundtrip-"):
        source = texts[entry["name"][len("decode-roundtrip-"):]]
        run = subprocess.run(["python3", ORIGINAL], input=source.encode(), capture_output=True)
        entry["stdin"] = run.stdout.decode("ascii")

for entry in lines:
    with tempfile.TemporaryDirectory() as workdir:
        for path, content in entry.get("files", {}).items():
            full = os.path.join(workdir, path)
            os.makedirs(os.path.dirname(full), exist_ok=True)
            with open(full, "w", encoding="utf-8", newline="") as f:
                f.write(content)
        run = subprocess.run(
            ["python3", os.path.abspath(ORIGINAL)] + entry["args"],
            input=entry.get("stdin", "").encode(),
            capture_output=True,
            cwd=workdir,
        )
    print(run.returncode, entry["name"], file=sys.stderr)

with open(OUT, "w", encoding="utf-8") as f:
    for entry in lines:
        f.write(json.dumps(entry, ensure_ascii=False) + "\n")
print(len(lines), "CLI inputs")

# Unit inputs: bytes cross as {"$bytes": [...]}, which is how the recording encodes them.
unit = []


def b(data):
    return {"$bytes": list(data)}


samples = [t.encode() for t in texts.values()] + [
    bytes(range(256)),
    bytes(range(255, -1, -1)),
    b"\xff",
    b"\x00\xff\x00",
    b"\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR",
    b"caf\xe9 \xc3\x28 \xa0\xa1",
    b"\r\n",
    b"a\rb\r\nc\n",
    b"x" * 75 + b" \n",
    b"=" * 30,
    b" " * 80,
    b"\t" * 80 + b"\n",
    b"_ _ _\n",
    b"." ,
    b".\r\n",
    b".\x00",
]
for data in samples:
    for quotetabs in (False, True):
        for header in (False, True):
            unit.append({"fn": "encodestring", "args": [b(data), quotetabs, header]})
    unit.append({"fn": "encodestring", "args": [b(data)]})
qp = [t.encode() for t in encoded.values()] + [
    b"",
    b"=",
    b"==",
    b"=\r",
    b"=\rabc\ndef",
    b"=\r\r\nx",
    b"=4",
    b"=4g",
    b"=a",
    b"=aF",
    b"_",
    b"a_b=5F",
    b"=\n=\n=\n",
    bytes(range(256)),
]
for data in qp:
    for header in (False, True):
        unit.append({"fn": "decodestring", "args": [b(data), header]})
    unit.append({"fn": "decodestring", "args": [b(data)]})
with open(UNIT_OUT, "w", encoding="utf-8") as f:
    for entry in unit:
        f.write(json.dumps(entry) + "\n")
print(len(unit), "unit inputs")
