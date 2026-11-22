"""Writes inputs.jsonl for CPython's `base64` CLI (`python3 -m base64`): encode and decode of
stdin and files, as people use it. Every case is checked to exit 0 against the original first,
since a failing case prints a traceback naming the install path of base64.py."""

import base64
import json
import subprocess
import sys

ORIGINAL = sys.argv[1]
OUT = sys.argv[2]

lorem = (
    "Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor "
    "incididunt ut labore et dolore magna aliqua. Ut enim ad minim veniam, quis nostrud "
    "exercitation ullamco laboris nisi ut aliquip ex ea commodo consequat.\n"
)
texts = {
    "empty": "",
    "one-byte": "a",
    "two-bytes": "ab",
    "three-bytes": "abc",
    "hello": "Hello, world!\n",
    "no-newline": "no trailing newline",
    "56-bytes": "x" * 56,
    "57-bytes": "y" * 57,
    "58-bytes": "z" * 58,
    "113-bytes": "q" * 113,
    "114-bytes": "r" * 114,
    "115-bytes": "s" * 115,
    "lorem": lorem,
    "lorem-x40": lorem * 40,
    "polish": "Zażółć gęślą jaźń\n",
    "emoji": "naïve café 😀🎉 ✓\n",
    "nul-and-controls": "a\u0000b\u0001\u001f\u007f\n\r\t",
    "json-config": json.dumps({"user": "admin", "token": "s3cr3t", "retries": 3}) + "\n",
    "crlf-text": "line one\r\nline two\r\n",
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
add("encode-e-stdin", ["-e"], stdin=lorem)
add("encode-dash", ["-"], stdin="read from a dash\n")
add("encode-e-dash", ["-e", "-"], stdin="dash after -e\n")
for name in ["hello", "lorem-x40", "polish", "emoji", "empty", "57-bytes", "nul-and-controls"]:
    add(f"encode-file-{name}", ["in.txt"], files={"in.txt": texts[name]})
add("encode-e-file", ["-e", "in.txt"], files={"in.txt": lorem})
add("encode-file-extra-args", ["in.txt", "ignored.txt"], files={"in.txt": "only the first\n"})
add("encode-file-in-folder", ["data/notes.txt"], files={"data/notes.txt": "nested\n"})
add("encode-double-dash", ["--", "in.txt"], files={"in.txt": "after --\n"})
add("encode-last-option-wins", ["-d", "-e"], stdin="encoded after all\n")
add("encode-ignores-stdin-with-file", ["in.txt"], stdin="not read", files={"in.txt": "file wins\n"})

encoded = {name: base64.encodebytes(text.encode()).decode() for name, text in texts.items()}
for name in ["empty", "one-byte", "two-bytes", "three-bytes", "hello", "57-bytes", "58-bytes",
             "114-bytes", "lorem-x40", "polish", "emoji", "nul-and-controls", "big"]:
    add(f"decode-stdin-{name}", ["-d"], stdin=encoded[name])
add("decode-u-stdin", ["-u"], stdin=encoded["lorem"])
add("decode-d-dash", ["-d", "-"], stdin=encoded["hello"])
add("decode-file", ["-d", "in.b64"], files={"in.b64": encoded["lorem-x40"]})
add("decode-u-file", ["-u", "in.b64"], files={"in.b64": encoded["polish"]})
add("decode-last-option-wins", ["-e", "-d"], stdin=encoded["hello"])
add("decode-combined-options", ["-ed"], stdin=encoded["hello"])

binary = {
    "ff": "/w==\n",
    "00-ff-00": "AP8A\n",
    "fe-ff": "/v8=\n",
    "all-bytes": base64.encodebytes(bytes(range(256))).decode(),
    "png-header": base64.encodebytes(b"\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR").decode(),
    "invalid-utf8": base64.encodebytes(b"caf\xe9 \xc3\x28 \xa0\xa1").decode(),
}
for name, text in binary.items():
    add(f"decode-binary-{name}", ["-d"], stdin=text)

odd = {
    "one-long-line": base64.b64encode((lorem * 5).encode()).decode() + "\n",
    "no-final-newline": base64.b64encode(b"no newline at the end").decode(),
    "crlf-lines": encoded["lorem-x40"].replace("\n", "\r\n"),
    "spaces-inside": "SGVs bG8s IHdv cmxk IQ==\n",
    "tabs-and-spaces": "\tSGVsbG8=  \n",
    "stray-characters": "SGV*sbG8!sIHd@vcmxkIQ==\n",
    "url-safe-chars-dropped": "-_-_SGVsbG8=\n",
    "data-after-padding": "YQ==YWJj\n",
    "two-padded-lines": "YQ==\nYWI=\n",
    "padding-only": "====\n",
    "blank-lines": "\n\nSGVsbG8=\n\n",
    "pem-like": "-----BEGIN DATA-----\n" + encoded["lorem"] + "-----END DATA-----\n",
    "mime-wrapped-64": "\n".join(
        base64.b64encode((lorem * 3).encode()).decode()[i:i + 64]
        for i in range(0, len(base64.b64encode((lorem * 3).encode())), 64)
    ) + "\n",
    "unicode-noise": "SGVs€bG8=\n",
}
for name, text in odd.items():
    add(f"decode-{name}", ["-d"], stdin=text)

kept = []
for entry in lines:
    workdir = subprocess.run(["mktemp", "-d"], capture_output=True, text=True).stdout.strip()
    for path, content in entry.get("files", {}).items():
        full = f"{workdir}/{path}"
        subprocess.run(["mkdir", "-p", full.rsplit("/", 1)[0]])
        with open(full, "w", encoding="utf-8") as f:
            f.write(content)
    run = subprocess.run(
        ["python3", ORIGINAL] + entry["args"],
        input=entry.get("stdin", "").encode(),
        capture_output=True,
        cwd=workdir,
    )
    if run.returncode != 0:
        print("dropped (fails):", entry["name"], run.stderr.decode()[-200:], file=sys.stderr)
        continue
    kept.append(entry)

with open(OUT, "w", encoding="utf-8") as f:
    for entry in kept:
        f.write(json.dumps(entry, ensure_ascii=False) + "\n")
print(len(lines), "inputs,", len(kept), "kept")
