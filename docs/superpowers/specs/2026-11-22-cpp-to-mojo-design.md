# C++ to Mojo (design)

Approved by the user on 2026-11-22. Plan: `docs/superpowers/plans/2026-11-22-cpp-to-mojo.md`.

## Intent

Port C++ units to Mojo the way C units are ported: record the original, port one function at a
time, and check the port against the recording with `diff`, `bench` and `gate`. C++ callers of
the ported functions keep compiling and linking unchanged.

## Goals

- `analyze` and `bridge` read `.cpp`, `.cc`, `.cxx`, `.h`, `.hpp` (and `.hh`, `.hxx`) files.
- A first callable subset: free functions, in namespaces or not, whose parameters and results
  are integers, floating-point numbers, `bool`, `std::string` (by value or `const&`) and
  `std::vector` of numbers (by value or `const&`).
- Everything else is refused with a reason, as `analyze` and `bridge` refuse other constructs.
- One real routine from EnergyPlus's psychrometrics, ported bit for bit, as a demo.

## Non-goals

- Classes, member functions, templates, overloads, references or pointers to state objects
  (EnergyPlus's `EnergyPlusData &state`): refused. The user writes a small free-function facade
  over them and bridges that.
- Functions defined only in headers (`inline`, `constexpr`, templates): there is no symbol for
  a shim in another file to call.
- `shadow`, `--batch`, front doors and `lift` for C++ units.
- Published benchmark numbers: the machine is shared; `bench` is run once to show it works.

## Approaches considered

1. **A separate C++ bridge.** A new kind with its own driver that understands `std::string` and
   `std::vector`, its own build and its own diff. Every check would need a C++ twin of the C
   code it already has, and the Mojo side would need a C++-facing ABI that Mojo does not have.
2. **Reuse the C path through a generated `extern "C"` shim (chosen).** The only layer that sees
   C++ types is generated C++: a shim that gives each function a C signature for recording, and
   a wrapper that gives the Mojo port the original C++ signatures for callers. Between them the
   unit is a C ABI unit (`kind: c-abi`, `language: cpp`): the ctypes driver records and diffs
   it, `mojo build` builds it, and `gate` checks it, with a few kinds added where C has no
   equivalent (strings with a length, arrays of numbers, results the callee allocates, an
   error slot).

## Design

- Parsing: tree-sitter-cpp, a new dependency added with `cargo add` (the version that works with
  `tree-sitter = 0.27`).
- Each exported function crosses as one C symbol, `cpp__<namespace>__<name>` (`psy::rho` is
  `cpp__psy__rho`). Strings cross as a pointer and a byte length, vectors as a pointer and an
  element count; a `std::string` or `std::vector` result comes back in memory the callee
  `malloc`s, its length through a `size_t *` out-parameter, freed by the caller with `free`.
  Every symbol takes a final `char **` error slot.
- Recording: `bridge` writes `cpp/shim.cpp`, one `extern "C"` function per export that converts
  the C arguments, calls the original, and converts the result. `record` compiles the original
  sources and the shim with `c++` into one shared library and records it with the C driver.
- Exceptions do not cross the boundary: the shim catches every exception and writes
  `<type>: <what()>` (the type demangled, `std::invalid_argument: ...`) into the error slot,
  which the driver records as the case's error. A port raises the same text.
- Port: `port.mojo` has one function per export over Mojo types (`String`, `List[Float64]`,
  `Int32`, ...); `exports.mojo` exports the shim's C signatures and converts. `cpp/wrapper.cpp`
  defines the original namespaced functions with their original signatures and forwards to the
  Mojo exports, rethrowing an error as the same standard exception type, so C++ callers link
  against the wrapper and the Mojo library unchanged.
- Checks: `diff`, `bench` and `gate` as for C units. `gate` adds a `cpp api` check: the wrapper
  must define the same mangled symbols the original defines.
- Tests: a C++ fixture (`tests/fixtures/cpp`) with every type in the subset and every refusal;
  a C++ caller compiled against the original header and linked against the wrapper and the
  Mojo library prints what it prints against the original.
- Demo: one EnergyPlus psychrometrics routine (NREL/EnergyPlus, its BSD-style licence kept) in
  `demo/real-world/`, ported bit for bit; its `diff` count in the README, benchmark numbers
  pending a quiet machine.

## Left to the builder

How a throwing function is detected and handled (ruled: not detected, every shim catches), how
names cross, how `bench` times a C++ unit, how `using namespace std` and type aliases are read,
and which EnergyPlus routine the demo ports. Each ruling is in the plan's ledger.
