# Mojo notes

The Mojo APIs and commands the generated code relies on, each confirmed against the pinned Mojo
(`MOJO_VERSION` in `src/mojo.rs`, `mojo = "==1.2.0"` in `pixi.toml`) by building
`tests/fixtures/mojo-probe/_native.mojo` (`tests/mojo_toolchain.rs`). Source references are to
`Mojo/stdlib/std/` in github.com/modular/modular; that tree tracks the nightly (1.3.0.dev on
2026-11-21), so an API is listed here only once the 1.2.0 compiler has accepted it.

Mojo builds only on Linux and macOS. On Windows, work in the WSL clone
(`~/github/mojo-anything` in Ubuntu 24.04), not under `/mnt/c`.

## Toolchain

| What | Command or spelling | Checked |
| --- | --- | --- |
| Install | pixi, channels `https://conda.modular.com/max` then `conda-forge` | `pixi add mojo` resolved 1.2.0 |
| Version | `pixi run mojo --version` → `Mojo 1.2.0 (2016d0cd)` | 2026-11-21 |
| Build a Python extension | `mojo build <file>.mojo --emit shared-lib -o <dir>/<module>.so` | probe, about 1 s |
| Warnings as errors | `mojo build --Werror` | `mojo build --help` |
| Format | `mojo format <files>`; there is no check mode, so compare against a formatted copy | `mojo format --help` |
| Tests | no `mojo test` in 1.2 (`error: no such command 'test'`); run `mojo run test_<name>.mojo`, with `std.testing` asserts | `mojo --help` |

## Python extension modules

- Imports: `from std.python import Python, PythonObject` and
  `from std.python.bindings import PythonModuleBuilder`; `from std.os import abort`.
- Entry point: `@export` on `def PyInit_<module>() abi("C") -> PythonObject:`, which builds
  `PythonModuleBuilder("<module>")`, calls `module.def_function[<fn>]("<python name>")` for each
  function and returns `module.finalize()`; on error, `abort(String("...", e))`.
- Bound functions take only `PythonObject` arguments and return `PythonObject` or `None`, and may
  `raise` (`python/bindings.mojo`, `def_function`).
- Conversions from Python: `Float64(py=obj)`, `Int(py=obj)`, `String(py=obj)` (`raises`).
  To Python: `PythonObject(x)` for `Float64`, `Int`, `String`, `Bool`; tuples with
  `Python.tuple(a, b, ...)`, lists with `Python.list(...)` (`python/python.mojo`).
- Bytes: a port's `List[UInt8]` is built from `builtins.bytes(v)` item by item
  (`UInt8(Int(py=item))`) and returned as `builtins.bytes(list)` of a `Python.list()` of
  `PythonObject(Int(b))` (`tests/mojo_py_bytes.rs`, 2026-11-22).
- Errors: a raised Mojo `Error` reaches Python as `Exception` with the error's text as its
  message (`_set_python_error`, default `ExceptionType.Exception`). There is no public way to pick
  the type from a bound function. Generated code therefore raises `Error("<PythonType>: <msg>")`,
  and the generated wrapper package re-raises it as `<PythonType>(<msg>)`.
- The built `.so` loads in the system `python3` (3.12 on Ubuntu 24.04) as well as pixi's.

## C ABI

Confirmed by `tests/fixtures/mojo-c-probe/exports.mojo`, called from `probe.c` compiled by the
system `cc` (`tests/mojo_c_toolchain.rs`, x86-64 Linux, 2026-11-21). The stdlib ships compiled
(`std.mojoc`), so these spellings come from the 1.2.0 compiler's own errors and the probe runs.

- Export: `@export` on `def <c_name>(...) abi("C") -> T:`; the symbol is the function's name.
  `mojo build --Werror exports.mojo --emit shared-lib -o lib<name>.so` exports only the
  `@export` functions as global text symbols (`nm -D --defined-only` lists nothing else as `T`).
- Scalars: `int` `Int32`, `unsigned` `UInt32`, `int64_t` `Int64`, `uint64_t` `UInt64`, `size_t`
  `UInt` (64-bit hosts), `double` `Float64`, `float` `Float32`, `char` `Int8`, `unsigned char`
  `UInt8`. `UInt.MAX` is `(size_t)-1`.
- Pointers: `UnsafePointer` is deprecated in 1.2 (an error under `--Werror`); use
  `Pointer[T, ImmutAnyOrigin]` (`const T *`) and `Pointer[T, MutAnyOrigin]` (`T *`), from
  `std.memory`. A `Pointer` is never null; a C pointer that may be `NULL` is
  `Optional[Pointer[...]]`, which crosses the C ABI as a plain pointer (`NULL` is `None`).
- Pointer access: `p[unsafe_offset=i]` reads and writes element `i`, `p[]` the first,
  `p.unsafe_offset(n)` is `p + n`. Positional `p[i]` and `p + n` are deprecated.
- Structs by value: `@fieldwise_init struct S(Copyable, Movable, TrivialRegisterPassable)` with
  the C fields in declaration order matches the C layout and calling convention, also for
  `struct { int a; double b; }` passed and returned by value.

- C memory: `from std.ffi import external_call`;
  `external_call["malloc", Optional[Pointer[UInt8, MutAnyOrigin]]](n)` and
  `external_call["free", NoneType](p)`. The dispatcher hands answers to C this way, so the
  caller's `free` and the library's agree (`tests/mojo_dispatcher.rs`, 2026-11-22).
- C bytes to a string: `String(unsafe_from_utf8=Span[UInt8, ImmutAnyOrigin](unsafe_ptr=p,
  length=n))` copies the bytes without checking them; `String(from_utf8=span)` checks them and
  raises `Cannot construct a String from invalid UTF-8 data` (byte 255, 2026-11-22). C++ units'
  `_str` uses the checked one.
- `--Werror` rejects a value assigned and then overwritten before use (`var s = String()`
  followed by assignments on every path): declare it as `var s: String`.
- Contraction: `mojo build` contracts `a * b + c` on `Float64` into one multiply-add (`vfmadd`
  on x86-64) by default, `--fp-mode contract=fast`; `--fp-mode contract=off` turns it off
  (`mojo build --help`). Seen in the EnergyPlus psychrometrics port (2026-11-22): at the default,
  1,391 of 9,658 cases one or more units in the last place off against g++ 13.3 `-O1` for x86-64,
  five `vfmadd` in the library's code; built with `contract=off`, the statements as the C++
  writes them match all 9,658 with no `vfmadd`. C ABI units (C and C++) are built with
  `--fp-mode contract=off`, and `record` compiles the original with `-ffp-contract=off`, so both
  sides round each product and each sum. A recording is only as representative as its flags:
  g++ fuses at `-O2 -march=native` or with `-mfma` unless told not to, so a unit whose real build
  uses such flags is recorded with them only if they reach `CFLAGS`/`CXXFLAGS`, after ours.
- C++ through a C ABI: Mojo has no C++ ABI, so a C++ port exports `extern "C"` symbols and a
  generated C++ file (`cpp/wrapper.cpp`) gives C++ callers the original signatures. Strings
  and vectors cross as a pointer and a length; results the port `malloc`s are freed by the
  wrapper with `free` (`tests/cpp_mojo.rs`, 2026-11-22).

## JSON

Units with structured values use `src/mojo/json.mojo`, a thin layer over EmberJson
(github.com/bgreni/EmberJson, Apache-2.0), checked by `tests/mojo_json.rs` (2026-11-22).

- EmberJson comes from its git tag `0.5.0`, the release that pins `mojo ==1.2.0`, built by
  pixi-build (`preview = ["pixi-build"]` in the workspace). The conda package (0.4.0) is
  precompiled for Mojo 1.1 and does not load under 1.2.0; EmberJson's main tracks the nightly.
- API: `from_json[Value](text)` and `to_json(value)`; `Value` is an int (`Int64`), uint
  (`UInt64`), float, string, bool, `Object` (keys keep their order), `Array` or null.
- Floats round-trip bit for bit (473 lines of V8 output, including 154 cases where Mojo's
  `String(Float64)` picks other digits than V8), but the layout is not V8's (`1e21`, `100.0`).
  The other ends parse numbers, so only the value has to survive.
- Integers are exact up to the 64-bit limits. A bare integer beyond them reads as a float (V8 and
  Go write large floats that way); `parse_json(text, refuse_big_ints=True)` raises instead, for
  Ruby, whose such tokens are bignums.
- A lone surrogate (`"\ud800"`) is refused ("Bad unicode codepoint"). An escaped pair is joined
  with `|` instead of `+` (`_parser_helper.mojo`), so `"𠈀"` reads as U+10200, not
  U+20200, on planes 2, 4, ... 16: send such characters unescaped (the Java codec does,
  `tests/jvm_codegen.rs`, 2026-11-22). Nesting is limited to
  1024 levels. EmberJson writes NaN as `null`, so `write_json` writes `$num` markers for NaN, the
  infinities and -0.0 first.
- Mojo's `atof` read all 20,003 probe doubles exactly; `String(Float64)` failed to round-trip 7.

## Processes and the environment (front door)

Confirmed by building and running the generated front door (`src/mojo/original.mojo`,
`tests/app.rs` `fallback_*`, `tests/app_fresh.rs` `front_door_found_through_symlink`,
2026-11-22) and the spike before it.

- `from std.subprocess import run`: `run(cmd)` runs a shell line and returns its stdout as a
  `String`; the exit status is dropped (`run("echo hi; exit 3")` returns `"hi"`) and stdin is not
  given. Not enough to stand in for the original.
- Starting a child: `external_call["fork", Int32]()`, `external_call["execvp", Int32](file,
  argv)` with `argv` a `Pointer[Optional[Pointer[UInt8, MutAnyOrigin]], MutAnyOrigin]` from
  `malloc` (an `Optional[Pointer]` entry crosses as a plain pointer, `None` as the closing NULL),
  `external_call["waitpid", Int32](pid, status_ptr, Int32(0))`, `external_call["_exit",
  NoneType](Int32(127))`. `external_call` may declare `malloc`'s result as any pointer type.
- Pipes and descriptors: `pipe`, `dup2`, `close`, `write` (`external_call["write", Int](fd,
  p.unsafe_offset(done), n)`), `chdir`, `readlink("/proc/self/exe", buf, size)`, `perror`.
- Signals: `external_call["signal", Int](Int32(13), Int(1))` ignores SIGPIPE (`SIG_IGN` is 1,
  `SIG_DFL` 0 on Linux); `external_call["raise", Int32](Int32(sig))` raises on the process itself.
  A wait status `s` exited when `s & 0x7F == 0` (code `(s >> 8) & 0xFF`), else was killed by
  signal `s & 0x7F`.
- `from std.sys import argv, exit, get_defined_string`: `argv()` (index 0 is the program; convert
  each with `String(...)`), `exit(code)`, and `get_defined_string["NAME", ""]()` for a value passed
  as `mojo build -D NAME=value` (bind it with `comptime`). There is no `std.sys.param_env` and no
  `env_get_string` in 1.2.
- `from std.os.path import exists, isfile`; `from std.os import getenv, listdir`.
- Files: `open(path, "a")` appends; `f.write(text)`, `f.close()`.
- Strings: `s.startswith("--")`, `s.find("=")` (-1 when absent), `String(s[byte=0:n])` for a
  byte slice, `"x" in some_list` on `List[String]`, `s.as_bytes()[i]` for a byte;
  `String(unsafe_from_utf8=Span[UInt8, ImmutAnyOrigin](unsafe_ptr=p, length=n))` from C memory.
- `print("", end="", flush=True)` flushes stdout before a fork.
- `comptime if FLAG:` compiles a branch only when the `comptime` Bool is true.
- Modules beside `main.mojo` import as `import original` and are called as `original.run(...)`;
  `mojo build main.mojo` finds them in the same folder.
- Present in 1.2: `std.logger` (`Logger()`), `std.pathlib` (`Path`), `std.base64`
  (`b64encode`), `std.collections` (`Dict`), `std.testing`, `std.time` (`perf_counter_ns`),
  `std.random` (`random_float64`). `std.algorithm` has no `parallelize` in 1.2.

## Packages and glue (front door `wire`)

Confirmed by the spikes before M6 Task 3 and by `tests/app.rs` `wire_*`, `wired_command_runs_in_mojo`,
`glue_declines_with_stdin` (2026-11-22).

- `mojo build -I <dir>` adds an import root; a folder under it with `__init__.mojo` is a package:
  `from textops import port`, `from textops.port import upper`, `import textops.helper as helper`.
- A module of a package cannot import a sibling by its bare name (`from helper import` inside
  `textops/port.mojo`: "unable to locate module"), and a file reachable both as `helper` and
  `textops.helper` is refused ("name the same module; remove the duplicate import root"). Inside
  the package, `from textops.helper import` works.
- A module in a subfolder (`glue/textops.mojo`) imports a module beside `main.mojo` by its bare
  name (`import original`).
- `comptime` constants in a plain `if` fail `--Werror` ("'if' condition always evaluates to
  'True'", "unreachable code on right side of 'False and ...'"): branch with `comptime if` /
  `else`.
- stdin as bytes: `open("/dev/stdin", "r").read_bytes()` (a `List[UInt8]`, any bytes).
- `print(..., file=stderr)` with `from std.sys import stderr`; `exit(code)` flushes what was
  printed.
- `String.upper()` maps the full Unicode case (`ß` to `SS`), but from tables older than
  Unicode 16 and with the Greek ypogegrammeni letters (U+1F80-1FFC) going to title case: 90 code
  points differ from Java 25's `toUpperCase` (`demo/real-world/java-jdk-mojo`, 2026-11-22); `s.count_codepoints()`,
  `s.byte_length()`, `for c in s.codepoint_slices()` (`String(c)` for each); `Int("7")` parses and
  raises on anything else; `//` and `%` on `Int` floor as Python's do; `from std.time import
  perf_counter_ns`.

## Packages (library front door)

Confirmed by spikes before M6 Task 6 and by `tests/library.rs` (2026-11-22).

- `mojo precompile [--Werror] <dir> -o <name>.mojoc` builds a package from a folder holding
  `__init__.mojo`; the package is named after the folder. `mojo package` is deprecated in 1.2
  ("use 'precompile' instead") and refuses any output not ending in `.mojoc`. A package whose
  modules hold only comments precompiles.
- An importer finds it with `mojo build -I <folder holding the .mojoc>`; the `.mojoc` is tied to
  the compiler version that wrote it.
- `__init__.mojo` can re-export a sub-module under another name:
  `from pkg.units.text import port as text`, and importers write `from pkg import text` and call
  `text.shout(...)`. Modules inside the package import each other by their full name
  (`from pkg.units.text.helper import twice`).

## Sockets and HTTP (server front door)

Confirmed by the server-route spike (M6 Task 7, `docs/superpowers/specs/2026-11-21-mojo-server-route.md`,
2026-11-22): a proxy built with `mojo build --Werror` that passed 42/42 recorded cases.

- Sockets through `external_call`: `socket(Int32(2), Int32(1), Int32(0))` (AF_INET,
  SOCK_STREAM), `setsockopt(fd, level, option, int_ptr, Int32(4))` (`SOL_SOCKET` 1 /
  `SO_REUSEADDR` 2; `IPPROTO_TCP` 6 / `TCP_NODELAY` 1), `bind(fd, addr, Int32(16))` and
  `connect(fd, addr, Int32(16))` with a 16-byte `sockaddr_in` built by hand (family 2 in byte 0,
  the port big-endian in bytes 2 and 3, the address in bytes 4 to 7), `listen(fd, Int32(512))`,
  `accept(fd, Optional[Pointer](None), Optional[Pointer](None))`, `getsockname(fd, addr, len_ptr)`,
  `recv(fd, buf, n, Int32(0))` and `send(fd, buf, n, Int32(0x4000))` (`MSG_NOSIGNAL`: a closed peer
  is an error, not SIGPIPE), both returning `Int`.
- `poll(fds, Int(2), Int32(ms))` with `struct pollfd` as two `Int32` per entry: the fd, then
  `events` in the low and `revents` in the high 16 bits (`POLLIN` 1).
- `external_call["open", ...]` fails to build ("existing function with conflicting signature":
  the stdlib declares `open` itself); glibc's `open64(path, Int32(0))` works.
- `prctl(Int32(1), Int(15))` (`PR_SET_PDEATHSIG`, SIGTERM) in the forked child: the original gets
  SIGTERM when the front door ends. Linux only.
- `waitpid(pid, status, Int32(1))` (`WNOHANG`) tells whether a child exited without blocking;
  `usleep(UInt32(us))`.
- `from std.os import getenv, setenv, unsetenv`: `setenv(name, value)` and `unsetenv(name)`
  return `Bool`. Setting them in the parent before `fork` gives the child its environment.
- Bytes: `List[UInt8](capacity=n)`, `list.resize(n, 0)`; `String(from_utf8_lossy=Span(list))`
  (bad bytes become U+FFFD), `String(from_utf8=Span(list))` raises on bad bytes,
  `String(unsafe_from_utf8=Span(list))`; `list.unsafe_ptr()` builds; `s.split("\r\n")`,
  `s.split(" ", 2)` (at most 3 parts), `s.strip()`, `s.lower()`, `s.replace(a, b)`, `"x" in s`.
- `@fieldwise_init struct Header(Copyable, Movable)` with `String` fields; `Optional.take()`
  moves the value out; `a or b` on two `Optional[String]` is true when either holds a value.
- `std.python`: `Python.import_module("builtins").exec(code, Python.dict())` runs Python source
  from a Mojo binary; a Python server started that way cannot call back into Mojo functions.

## WebAssembly (`--kind wasm`)

Confirmed by the spike before M4 Task 8 and by `tests/mojo_wasm.rs` (2026-11-22), with
mojo-wasm (github.com/lee101/mojo-wasm at 3551aa4: clang 22.1.8, wasm-ld) and Node 24.

- Mojo has no wasm backend: `mojo build --emit llvm -O3 --target-cpu x86-64 -o f.ll f.mojo`,
  then the IR with the wasm64 data layout and triple, `clang --target=wasm64-unknown-unknown -c`,
  `wasm-ld -mwasm64 --no-entry --export-dynamic`. A host `--target-cpu` emits SSE intrinsics.
- `--target-triple` accepts `riscv32-unknown-linux-gnu`, `i686-unknown-linux-gnu` and
  `x86_64-unknown-linux-gnux32` (`Int` is 32-bit on all three), but `Variant` layouts are wrong
  there (see pitfalls); 64-bit IR read as wasm32 loops for ever.
- The stdlib and EmberJson leave undefined: `malloc`, `free`, `strlen`, `memcpy`/`memmove`/
  `memset`/`memcmp`, `KGEN_CompilerRT_AlignedAlloc`/`AlignedFree`, `KGEN_CompilerRT_GetStackTrace`
  (any raised `Error`), `write`, `dup`, `fdopen`, `fflush`, `fclose`, `KGEN_CompilerRT_fprintf`,
  `__multi3`, `__ashlti3`, `__lshrti3` (`src/mojo/wasm_runtime.c`). With a stub stack trace,
  `raises Error` works.
- Mojo 1.2's LLVM spells special floats in a syntax clang 22 cannot read: `+inf`, `-qnan`,
  `+nan(0x<payload>)` (quiet; the payload is the significand below the quiet bit), `-snan(0x1)`
  and `f0x<bits>`, also as untyped operands (`fmul double %a, +inf`). `harness_mojo_wasm`
  rewrites them to `0x<16 hex>` (`double` and `float`), `0xH` (`half`) and `0xR` (`bfloat`).
- On wasm64, `String(Float64)` returns (it hung on mojo-wasm's wasm32 route) and EmberJson's
  float writer round-tripped 99,952 random doubles.
- mojo-wasm's pinned Mojo (1.2.0.dev2026092605) is older than 1.2.0: no `std.hash`, no
  `reflect[T].annotations()`, so EmberJson 0.5.0 does not compile with it.

## Language

- `def` is the function keyword; `fn` is not used in the 1.2 examples.
- Type aliases are declared with `comptime`.

## The Mojo tool (Phase 2, `tool/`)

Confirmed by building `tool/src/main.mojo` with `mojo build --Werror` and by
`tests/mojo_front_door.rs` (2026-11-23).

- Fallback route: `external_call["execv", Int32](path, argv)` replaces the front door with the
  Phase 1 binary; the descriptors and `environ` carry over, so stdin, the environment, the exit
  code and stderr reach the caller unchanged with no copying. Chosen over Python's `os.execv`,
  which would load CPython just to leave. `execv` returns only on failure; errno then comes
  from `__errno_location`.
- `def` functions do not raise unless marked: `def f() raises:`. `std.testing`'s `assert_equal`
  and `assert_true` raise, so every test function and the test's `main` say `raises`.
- `from std.os import setenv, unsetenv` work inside `mojo run` tests.
- Tests run with `mojo run -I tool/src tool/tests/test_<name>.mojo` (no `mojo test` in 1.2); the
  format check formats a copy and compares it (`tool/check.sh`).
- Running other programs (`tool/src/mojo_anything/process.mojo`, `tool/tests/test_process.mojo`):
  Python's `subprocess.Popen(..., stdin=DEVNULL, process_group=0)` started from Python source
  run by `Python.import_module("builtins").exec(src, scope)`; the function is called
  positionally as `scope["run"](a, b, ...)`. At the limit `os.killpg(pid, SIGKILL)` stops the
  whole group. Output goes to `tempfile.mkstemp` files and is read with
  `open(path, "r").read_bytes()`, so no byte crosses the interop one at a time. Chosen over
  fork/exec through libc, which would need `poll` on two pipes by hand.
- Interop spellings that build: `Python.list()` and `.append(PythonObject(s))`, `Python.dict()`
  and `d[PythonObject(k)] = PythonObject(v)`, `result[i]` on a returned tuple, `Int(py=o)`,
  `Bool(py=o)`, `Float64(py=o)`, `String(py=o)`; `PythonObject(x)` for `Float64` and `Bool`.
- `@fieldwise_init struct S(Copyable, Movable)` with a hand-written `__init__(out self, ...)`
  besides the field-wise one; `Dict[String, String]` iterates with `for item in d.items()`
  (`item.key`, `item.value`); a `List` field is returned with `^`.
- `String(from_utf8_lossy=Span(list))` maps bad bytes to U+FFFD, as Rust's
  `String::from_utf8_lossy` does for a lone `\xff`.
- Running other programs (`tool/src/mojo_anything/process.mojo`, `tool/tests/test_process.mojo`):
  Python's `subprocess.Popen(..., stdin=DEVNULL, process_group=0)` started from Python source
  run by `Python.import_module("builtins").exec(src, scope)`; the function is called
  positionally as `scope["run"](a, b, ...)`. At the limit `os.killpg(pid, SIGKILL)` stops the
  whole group. Output goes to `tempfile.mkstemp` files and is read with
  `open(path, "r").read_bytes()`, so no byte crosses the interop one at a time. Chosen over
  fork/exec through libc, which would need `poll` on two pipes by hand.
- Interop spellings that build: `Python.list()` and `.append(PythonObject(s))`, `Python.dict()`
  and `d[PythonObject(k)] = PythonObject(v)`, `result[i]` on a returned tuple, `Int(py=o)`,
  `Bool(py=o)`, `Float64(py=o)`, `String(py=o)`; `PythonObject(x)` for `Float64` and `Bool`.
- `@fieldwise_init struct S(Copyable, Movable)` with a hand-written `__init__(out self, ...)`
  besides the field-wise one; `Dict[String, String]` iterates with `for item in d.items()`
  (`item.key`, `item.value`); a `List` field is returned with `^`.
- `String(from_utf8_lossy=Span(list))` maps bad bytes to U+FFFD, as Rust's
  `String::from_utf8_lossy` does for a lone `\xff`.
- Running other programs (`tool/src/mojo_anything/process.mojo`, `tool/tests/test_process.mojo`):
  Python's `subprocess.Popen(..., stdin=DEVNULL, process_group=0)` started from Python source
  run by `Python.import_module("builtins").exec(src, scope)`; the function is called
  positionally as `scope["run"](a, b, ...)`. At the limit `os.killpg(pid, SIGKILL)` stops the
  whole group. Output goes to `tempfile.mkstemp` files and is read with
  `open(path, "r").read_bytes()`, so no byte crosses the interop one at a time. Chosen over
  fork/exec through libc, which would need `poll` on two pipes by hand.
- Interop spellings that build: `Python.list()` and `.append(PythonObject(s))`, `Python.dict()`
  and `d[PythonObject(k)] = PythonObject(v)`, `result[i]` on a returned tuple, `Int(py=o)`,
  `Bool(py=o)`, `Float64(py=o)`, `String(py=o)`; `PythonObject(x)` for `Float64` and `Bool`.
- `@fieldwise_init struct S(Copyable, Movable)` with a hand-written `__init__(out self, ...)`
  besides the field-wise one; `Dict[String, String]` iterates with `for item in d.items()`
  (`item.key`, `item.value`); a `List` field is returned with `^`.
- `String(from_utf8_lossy=Span(list))` maps bad bytes to U+FFFD, as Rust's
  `String::from_utf8_lossy` does for a lone `\xff`.
- Running other programs (`tool/src/mojo_anything/process.mojo`, `tool/tests/test_process.mojo`):
  Python's `subprocess.Popen(..., stdin=DEVNULL, process_group=0)` started from Python source
  run by `Python.import_module("builtins").exec(src, scope)`; the function is called
  positionally as `scope["run"](a, b, ...)`. At the limit `os.killpg(pid, SIGKILL)` stops the
  whole group. Output goes to `tempfile.mkstemp` files and is read with
  `open(path, "r").read_bytes()`, so no byte crosses the interop one at a time. Chosen over
  fork/exec through libc, which would need `poll` on two pipes by hand.
- Interop spellings that build: `Python.list()` and `.append(PythonObject(s))`, `Python.dict()`
  and `d[PythonObject(k)] = PythonObject(v)`, `result[i]` on a returned tuple, `Int(py=o)`,
  `Bool(py=o)`, `Float64(py=o)`, `String(py=o)`; `PythonObject(x)` for `Float64` and `Bool`.
- `@fieldwise_init struct S(Copyable, Movable)` with a hand-written `__init__(out self, ...)`
  besides the field-wise one; `Dict[String, String]` iterates with `for item in d.items()`
  (`item.key`, `item.value`); a `List` field is returned with `^`.
- `String(from_utf8_lossy=Span(list))` maps bad bytes to U+FFFD, as Rust's
  `String::from_utf8_lossy` does for a lone `\xff`.
- Running other programs (`tool/src/mojo_anything/process.mojo`, `tool/tests/test_process.mojo`):
  Python's `subprocess.Popen(..., stdin=DEVNULL, process_group=0)` started from Python source
  run by `Python.import_module("builtins").exec(src, scope)`; the function is called
  positionally as `scope["run"](a, b, ...)`. At the limit `os.killpg(pid, SIGKILL)` stops the
  whole group. Output goes to `tempfile.mkstemp` files and is read with
  `open(path, "r").read_bytes()`, so no byte crosses the interop one at a time. Chosen over
  fork/exec through libc, which would need `poll` on two pipes by hand.
- Interop spellings that build: `Python.list()` and `.append(PythonObject(s))`, `Python.dict()`
  and `d[PythonObject(k)] = PythonObject(v)`, `result[i]` on a returned tuple, `Int(py=o)`,
  `Bool(py=o)`, `Float64(py=o)`, `String(py=o)`; `PythonObject(x)` for `Float64` and `Bool`.
- `@fieldwise_init struct S(Copyable, Movable)` with a hand-written `__init__(out self, ...)`
  besides the field-wise one; `Dict[String, String]` iterates with `for item in d.items()`
  (`item.key`, `item.value`); a `List` field is returned with `^`.
- `String(from_utf8_lossy=Span(list))` maps bad bytes to U+FFFD, as Rust's
  `String::from_utf8_lossy` does for a lone `\xff`.
- Running other programs (`tool/src/mojo_anything/process.mojo`, `tool/tests/test_process.mojo`):
  Python's `subprocess.Popen(..., stdin=DEVNULL, process_group=0)` started from Python source
  run by `Python.import_module("builtins").exec(src, scope)`; the function is called
  positionally as `scope["run"](a, b, ...)`. At the limit `os.killpg(pid, SIGKILL)` stops the
  whole group. Output goes to `tempfile.mkstemp` files and is read with
  `open(path, "r").read_bytes()`, so no byte crosses the interop one at a time. Chosen over
  fork/exec through libc, which would need `poll` on two pipes by hand.
- Interop spellings that build: `Python.list()` and `.append(PythonObject(s))`, `Python.dict()`
  and `d[PythonObject(k)] = PythonObject(v)`, `result[i]` on a returned tuple, `Int(py=o)`,
  `Bool(py=o)`, `Float64(py=o)`, `String(py=o)`; `PythonObject(x)` for `Float64` and `Bool`.
- `@fieldwise_init struct S(Copyable, Movable)` with a hand-written `__init__(out self, ...)`
  besides the field-wise one; `Dict[String, String]` iterates with `for item in d.items()`
  (`item.key`, `item.value`); a `List` field is returned with `^`.
- `String(from_utf8_lossy=Span(list))` maps bad bytes to U+FFFD, as Rust's
  `String::from_utf8_lossy` does for a lone `\xff`.
