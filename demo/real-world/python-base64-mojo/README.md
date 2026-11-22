# python-base64-mojo

CPython's `base64` command line (`python3 -m base64`, the `main()` at the end of
`Lib/base64.py`) lifted to a pure Mojo binary by mojo-anything: the binary answers every
recorded case with no Python behind it.

The original is `Lib/base64.py` from CPython 3.12.3 as Ubuntu 24.04 ships it
(`libpython3.12-stdlib` 3.12.3-1ubuntu0.17, `/usr/lib/python3.12/base64.py`, SHA-256
`65c70b5b6361c6f7a71ecc2df0f55315474b669221dd8d81d7c1ae8d56748ada`), copied as `base64.py` into an
empty folder and run as `python3 base64.py`. It is not copied here (PSF licence). The work it does
is in `binascii`, CPython's C module: `encode` feeds 57-byte chunks to `binascii.b2a_base64`, and
`decode` feeds each line to `binascii.a2b_base64` in its non-strict mode, which skips bytes outside
the alphabet and stops at a complete padding.

| Folder | What it is |
| --- | --- |
| `mojo/app-cases` | 74 cases recorded from the original on 2026-11-22 (`app record --inputs inputs.jsonl --no-traps`) |
| `mojo/b64codec-mojo` | the unit: `port.mojo` (`encode`, `decode`, `b2a_base64`, `a2b_base64`) and `test_port.mojo` (RFC 4648 vectors, binascii's non-strict cases and errors), written by hand |
| `mojo/app` | the lifted front door: `main.mojo`, `units.mojo` and `glue/b64codec.mojo` (getopt `hdeu`, one file or stdin, bytes to stdout) |
| `inputs.jsonl`, `scripts/inputs.py` | the inputs, and the script that wrote them |

## What was run

```sh
mojo-anything app record . --inputs inputs.jsonl --no-traps -- python3 base64.py   # 74 cases
mojo-anything app front-door .                       # 74/74 at 100% fallback
mojo-anything app wire . b64codec-mojo --command base64
# glue written in mojo/app/glue/b64codec.mojo, then:
mojo-anything app wire . b64codec-mojo               # 74/74 at 0% fallback
mojo-anything app lift .                             # lifted: no item fails (one warns: CI runs app replay)
mv base64.py base64.py.hidden
mojo-anything app replay . --build mojo/app/.mojo-anything/build/base64   # 74/74
```

The glue was right the first time: the first replay with it passed 74/74 with no fallback. Mojo
1.2.0, x86-64 Linux (WSL, Ubuntu 24.04), 2026-11-22.

## The cases

Encoding stdin, `-`, and files (`in.txt`, a file in a folder, after `--`, with an extra argument
the original ignores) for empty input, 1-3 bytes, 56-58, 113-115 and 20,001 bytes, Polish text,
emoji, NUL and control bytes, CRLF. Decoding with `-d` and `-u` from stdin, `-` and files; the
last of `-e` and `-d` wins, and `-ed` decodes; decoded bytes that are not UTF-8 (`ff`, `00 ff 00`,
all 256 byte values, a PNG header); one long unwrapped line, CRLF lines, no final newline, spaces,
tabs and stray characters inside, URL-safe `-_` (skipped), data after a complete padding
(ignored), `====`, blank lines, a non-ASCII character. The original writes no files, so the
`*.out` folders are empty by nature.

Left out, because the original's output names the machine it runs on: `-h` and unknown options
(the usage text starts with `sys.argv[0]`, the path `base64.py` was started from), and every
failure (a missing file, bad padding), which Python reports with a traceback naming that path.
The lifted binary prints the usage with its own path, and for a failure the traceback's last
line (`binascii.Error: Incorrect padding`, `FileNotFoundError: ...`) with exit 1; none of that is
checked by a case. `scripts/inputs.py` runs every input against the original first and keeps
only those that exit 0 (one of 75 was dropped: a PEM header line, whose letters decode to a
partial group).

## Rerun

Put CPython 3.12's `base64.py` in this folder, then:

```sh
mojo-anything app replay .                      # the original: 74/74
cd mojo/app
mkdir -p .mojo-anything/build/units/b64codec
cp ../b64codec-mojo/port.mojo .mojo-anything/build/units/b64codec/
touch .mojo-anything/build/units/b64codec/__init__.mojo
pixi run mojo build --Werror -I .mojo-anything/build/units main.mojo -o .mojo-anything/build/base64
cd ../..
mojo-anything app replay . --build mojo/app/.mojo-anything/build/base64   # 74/74
(cd mojo/b64codec-mojo && pixi run mojo run test_port.mojo)
```

A lifted app has no `wire` left to build it, so the package `units.mojo` imports is put together
by hand as above (it is what `app wire` and `app lift` write under `.mojo-anything/build/units`).
