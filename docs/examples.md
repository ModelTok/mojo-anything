# Examples and case studies

Real modules ported with mojo-anything, with the commands. Back to the [README](../README.md).

## Real code in six languages

Go's `path`, Ruby's `shellwords`, Python's `colorsys` and `quopri`, vercel/ms, ffmpeg's
`rational.c`, and JDK and glibc behaviour behind small facades, each ported to Mojo and checked
against its recording: [Real code in six languages](real-world-languages.md) and
[vercel/ms](real-world.md#vercelms-on-mojo), each with the log of the run that checked it. The
ports are in [`demo/real-world`](../demo/real-world/README.md).

## Example: a Python module

`colorsys.py` from CPython, in a project with a `pyproject.toml`:

```sh
mojo-anything analyze .                                  # the units, and the bridge for each (mojo-py)
mojo-anything bridge . src/colorsys_pkg/                 # mojo/colorsys-pkg-mojo
mojo-anything record mojo/colorsys-pkg-mojo              # what the original does
# write port.mojo
mojo-anything build mojo/colorsys-pkg-mojo
mojo-anything diff mojo/colorsys-pkg-mojo
mojo-anything gate mojo/colorsys-pkg-mojo
```

`colorsys` has no type hints, and keeps ints through `+`, `-` and `*` (`hsv_to_rgb(0, 0, 7)` is
`(7, 7, 7)`, not `(7.0, 7.0, 7.0)`). A port computing in `Float64` fails `diff` on the cases where
ints go in and come back out; the port in
[`demo/real-world/python-colorsys-mojo`](../demo/real-world/python-colorsys-mojo) computes with a
small int-or-float type (`py_num.mojo`) instead, and matches every recorded case.

## Example: a whole CLI

CPython's `quopri` command line, from `python3 quopri.py` to a pure Mojo binary through one
bridged unit, a front door, glue for `main()` and `app lift`:
[the report](real-world-languages.md#a-whole-cli-lifted-to-mojo-cpythons-quopri) and
[`demo/real-world/python-quopri-mojo`](../demo/real-world/python-quopri-mojo/README.md).

## rust-anything's case studies

x18n's core, Fuse.js, json-server, Prettier, ffmpeg's libavutil and ESLint were ported to Rust
by rust-anything before this fork targeted Mojo. They are kept as
[history](real-world.md#rust-anything-history-rust-ports-not-mojo), and the plan
rust-anything wrote for all of x18n is in [`docs/examples/x18n.md`](examples/x18n.md); none of it
is a Mojo result.
