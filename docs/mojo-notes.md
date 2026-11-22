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
  length=n))` copies the bytes without checking them.
- `--Werror` rejects a value assigned and then overwritten before use (`var s = String()`
  followed by assignments on every path): declare it as `var s: String`.

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
- A lone surrogate (`"\ud800"`) is refused ("Bad unicode codepoint"). Nesting is limited to
  1024 levels. EmberJson writes NaN as `null`, so `write_json` writes `$num` markers for NaN, the
  infinities and -0.0 first.
- Mojo's `atof` read all 20,003 probe doubles exactly; `String(Float64)` failed to round-trip 7.

## Language

- `def` is the function keyword; `fn` is not used in the 1.2 examples.
- Type aliases are declared with `comptime`.
