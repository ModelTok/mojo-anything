# Real code in six languages

mojo-anything was run end to end (analyze, bridge, record, port, build, diff, gate) on real code
in each language it ports to Mojo. The code had to be already on this machine: code downloaded
from the internet was not executed. So the targets are standard-library modules shipped with the
installed toolchains, ffmpeg's `rational.c`, and, for Java and C, the JDK and glibc themselves as
the oracle behind a thin facade.

The ports, recorded cases and extra inputs are in [`demo/real-world`](../demo/real-world/README.md).
Every row below was checked again on 2026-11-22 with Mojo 1.2.0 on x86-64 Linux (WSL2, Ubuntu
24.04, Ryzen 9 3900X): `build`, `diff` and `gate` on a copy of the demo folder next to the
original, logged under [`docs/measurements`](measurements/).

| Language | Code | Functions | Recorded cases | Result |
| --- | --- | ---: | ---: | --- |
| Go | `path` from Go 1.24's standard library ([`go-path-mojo`](../demo/real-world/go-path-mojo/README.md)) | 7 (+1 kept) | 2,042 (and the 2,642 of the recording rust-anything's Rust port passed) | 2,042/2,042 and 2,642/2,642; gate passes ([log](measurements/2026-11-22-go-path.md)) |
| Ruby | `shellwords.rb` from Ruby 3.3 ([`ruby-shellwords-mojo`](../demo/real-world/ruby-shellwords-mojo/README.md)) | 3 | 1,626 (and the 1,617 of the Rust-era recording) | 1,626/1,626 and 1,617/1,617; gate passes, 210 lines of Mojo for 54 of Ruby, 3.9x ([log](measurements/2026-11-22-shellwords.md)) |
| Python | `colorsys.py`, recorded from CPython 3.13 ([`python-colorsys-mojo`](../demo/real-world/python-colorsys-mojo/README.md)) | 6 | 2,400 | 2,400/2,400; gate passes ([log](measurements/2026-11-22-colorsys.md)) |
| Python | CPython 3.12's `quopri` command line, as a whole app ([`python-quopri-mojo`](../demo/real-world/python-quopri-mojo/README.md)) | 2 (+7 kept), bridged | 481 unit cases, 163 CLI cases | unit 481/481 (4 by `known-diffs.jsonl`), gate passes; the lifted pure Mojo binary passes 163/163 with the original moved away ([log](measurements/2026-11-22-quopri.md); [below](#a-whole-cli-lifted-to-mojo-cpythons-quopri)) |
| Java | OpenJDK 25 behind a facade (`Integer`, `Long`, `Math`, `Double.toString`, `URLEncoder`, `Base64`, `toUpperCase`) ([`java-jdk-mojo`](../demo/real-world/java-jdk-mojo/README.md)) | 11 | 4,782 on Java 25 (and the 4,492 of the JDK 21 recording the Rust port passed) | 4,782/4,782 and 4,492/4,492, exceptions compared by class and message; gate passes ([log](measurements/2026-11-22-jdk-facade.md)) |
| C | glibc behind a facade (`strtol`, `atoi`, `strtod`, `strspn`, `strcmp`, ctype) ([`c-libc-mojo`](../demo/real-world/c-libc-mojo/README.md)) | 9 | 2,488 | 2,488/2,488; gate passes; `size` does not compare the 236 lines of Mojo with the facade's 15 lines of C, which call glibc ([log](measurements/2026-11-22-glibc-facade.md)) |
| C | ffmpeg libavutil n7.1's `rational.c` ([`ffmpeg-mojo`](../demo/real-world/ffmpeg-mojo/README.md)) | 8 (+2 kept) | 46,764 (recorded again) | 46,764/46,764; gate passes ([log](measurements/2026-11-22-ffmpeg-rational.md)) |

The two `size` failures are ports that reimplement what the original borrows: `shellescape`
takes any Ruby value, so the port carries Ruby's `to_s` and `inspect` for numbers, nil, arrays
and hashes; the glibc facade is a few lines of C over glibc, and the port is the glibc behaviour
itself. Both demos were gated before `gate` counted Mojo lines.

The JDK port was also checked once, earlier on 2026-11-22 and before `diff` compared exception
messages, on a wider set of 446,916 cases (random doubles through `Double.toString`, every BMP
character through `parseRadix`, every code point through `toUpperCase`, `URLEncoder` and
`Base64`), all matching. That run found that Mojo's case tables predate Unicode 16 (the port keeps
90 code points apart) and that EmberJson read an escaped surrogate pair on planes 2, 4, ... 16 as
the plane below; it was not run again here.

## Speed

Not published yet. The Mojo timings (`bench` against each original, compile times) wait for a
run on a quiet machine: the runs above were taken while other builds and benchmarks used the
machine, which is fine for case counts and sizes and useless for time. The speed results of
rust-anything's Rust ports of the same code are kept as
[history](real-world.md#rust-anything-history-rust-ports-not-mojo) and do not describe these
ports.

## A whole CLI lifted to Mojo: CPython's `quopri`

CPython's `quopri` command line (`python3 -m quopri`: getopt `-t`, `-d`, then each file or stdin,
bytes out) was taken to a pure Mojo binary on 2026-11-22, with Mojo 1.2.0 on x86-64 Linux (WSL,
Ubuntu 24.04): its core functions through the per-unit loop as a bridged Python unit, then the
command line through the whole-app loop. quopri fits because `main()` does all its work through
two module functions of bytes to bytes, its errors name no install path (a missing file is
`name: can't open ([Errno 2] ...)`, a bad option getopt's message and the usage), and its other
functions take file objects or serve only the pure-Python fallback. Everything is in
[`demo/real-world/python-quopri-mojo`](../demo/real-world/python-quopri-mojo/README.md).

| Step | What it did |
| --- | --- |
| `bridge . quopri.py` (7 functions kept, each with its reason) | `quopri-mojo` with `encodestring`, `decodestring`; `s` has no type hint, so the stub had `PythonObject`, changed to `List[UInt8]` in the port |
| `record --inputs` (322 unit inputs) | 481 cases, 155 of them raise |
| port, `refresh`, `build`, `diff` | four mismatches on the first diff, all `decodestring("x")`, kept as known diffs (below) |
| `gate` | passes |
| `app record --inputs` (94 lines, traps on) | 163 cases (93 from inputs, 70 traps) |
| `app front-door` | every case passes, all answered by the original |
| `app wire . quopri-mojo --command quopri`, glue written | every case passes with no fallback, on the first replay |
| `app lift` | lifted, no checklist item failed |

Checked again on 2026-11-22 from a copy of the demo ([log](measurements/2026-11-22-quopri.md)):
the original passes 163/163 of the CLI cases, the unit 481/481 with 4 by `known-diffs.jsonl` and
`gate` passes, and the lifted binary, rebuilt as the demo's README says, passes 163/163 with
`quopri.py` moved away. The binary is 84,752 bytes and links the Mojo runtime libraries from the
app's pixi environment.

quopri hands its work to `binascii.b2a_qp` and `a2b_qp` (C) whenever they exist, which they
always do in CPython, so the recording is binascii's behaviour and the port follows
`Modules/binascii.c`, not the pure-Python code in `quopri.py`. The 4 known diffs are
`decodestring("x")`: `a2b_qp` also takes an ASCII `str`, while a bytes parameter of a Mojo port
takes bytes-like objects only.

The run found two gaps in the tool, both fixed with a failing test first:

- **Bytes could not cross the Python bridge.** A port declaring `List[UInt8]` failed `refresh`
  (`` `UInt8` cannot cross the Python bridge``). The bindings now take any bytes-like object
  (`bytes`, `bytearray`, `memoryview`) into `List[UInt8]`, refuse a list of ints and a `str` with
  `TypeError`, and return `bytes` (`tests/mojo_py_bytes.rs`, `codegen_mojo_py`
  `bytes_cross_as_a_list_of_uint8`).
- **A CLI with recorded usage errors could not be lifted.** The front door sends a command line
  with an option the recording never saw to the original, and options were taken from
  successful cases only (the first front door listed `-d` and `-t`), so the 4 cases with `-x`,
  `-h`, `--help` and `--mode=fast`, recorded with their exit 2, could never leave the original,
  and `lift` needs no fallback. Options from failing cases now count as seen
  (`front_door::tests::options_of_failing_cases_were_seen_too`): the recorded case checks the
  glue's answer.

## Behaviour a port has to match

Each line was a mismatch in a first port, caught by the recorded cases, or handled in the first
port and confirmed by them. They are facts about the originals, so they hold for any port.

- Go `path.Clean`: Go's `lazybuf` reads the byte at the write index after it moves back, not the
  last kept byte (from Go's own test table).
- Go `strings.ToLower` and Ruby `downcase` lower each rune alone: `ΣΊΣΥΦΟΣ` becomes `σίσυφοσ`,
  with no final-sigma rule. Go also maps `İ` to `i`.
- Go slices strings by bytes; a cut through a rune reaches JSON as one U+FFFD per byte.
- Ruby `Array#sum` uses Kahan-Babuska summation and starts from integer 0, so `[-0.0].sum` is `0.0`.
- Ruby `Float#to_s` uses exponent form from 1e15 up (`1e15.to_s` is `1.0e+15`, `1e14.to_s` is
  `100000000000000.0`); `nil.inspect` inside arrays is `nil`.
- Java `\s` is ASCII-only, so U+00A0 is not whitespace.
- Java `Integer.parseInt` accepts any Unicode decimal digit (`١٢`, `２`) through `Character.digit`.
- Java `Double.toString` (JDK 19+) prints the shortest decimal, but never fewer than two digits:
  `4.9E-324`.
- Python's int-or-float results: `colorsys` keeps ints through `+`, `-` and `*`, so the faithful
  port computes with a small int-or-float type (`py_num.mojo`) instead of `Float64`.
- Python's `max(nan, 1, 2)` is `nan` (the first value wins unless a later one compares greater);
  `-0.0 % 1.0` is `0.0`.
- glibc `strtod("-")` converts nothing and returns `+0.0`, not `-0.0`; `toupper(-128)` is `128`
  (its tables accept signed `char` values); `strtol` with base 0 reads `077` as octal and `0x`
  without a hex digit as `0`.

Limits these runs show:

- **Dynamic typing costs code.** The `shellwords` port reimplements Ruby's `to_s` and `inspect`,
  and the `colorsys` port needs Python's numeric tower. A typed port is shorter, but changes
  behaviour for some callers; `diff` shows exactly which.
- **Undefined behaviour that does not crash.** `ispunct(1000)` reads past glibc's table and
  returns 1. No port should copy that; the one case was removed from `cases.jsonl` by hand.
- **The facades.** The Java and C runs test real JDK and glibc behaviour, but through facades
  written for the run, not through a library's own API.

## How each language runs

| | Record | Diff | Bridge | Shadow |
| --- | --- | --- | --- | --- |
| Go | generated driver, built as its own module with a `replace` to the original | the same driver over the cgo wrapper | cgo calls into the Mojo port's JSON dispatcher, in a package with the original API | package with the original API, runs both |
| Ruby | generated driver loads the original files | the same driver loads the Fiddle wrapper | Fiddle calls into the Mojo port's JSON dispatcher, defining the same modules | file to require after the original: `prepend`s both |
| Java | reflection driver compiled with the original sources | the same driver compiled with the wrapper classes | the Mojo dispatcher, called through the Foreign Function & Memory API (Java 22+) from wrapper classes with the original static methods | `<Class>Shadow` classes |
| Python | in-process driver imports the original | the same driver imports the Mojo extension module | a Python extension module built by Mojo | module with the original API |
| C | `cc -shared` of the original, called through ctypes, one fork per case | ctypes over the Mojo shared library | Mojo exports with the original names and signatures, and a header | a second library with renamed exports (`exports_shadow.mojo`) |
