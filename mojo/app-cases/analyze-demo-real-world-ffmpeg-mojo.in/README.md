# ffmpeg-mojo

FFmpeg `libavutil` (tag `n7.1`, commit `b08d796`) ported to Mojo with mojo-anything, starting
with `rational.c`. Each unit is proven against recordings of the real ffmpeg functions and passes
`mojo-anything gate`. The Rust ports of the same units, made before mojo-anything targeted Mojo,
are in [`../ffmpeg-rs`](../ffmpeg-rs) and stay there as the reference.

## License

libavutil is LGPL-2.1-or-later. The Mojo in this folder ports it, so it is LGPL-2.1-or-later too
(the license text is [`LICENSE`](LICENSE)); each `port.mojo` names the file it ports and that
file's copyright holders. No ffmpeg source, test or recorded case is copied here: the scripts
clone ffmpeg and regenerate them.

## What is here

| Unit | Ports | Exports (C ABI, original signatures) | Cases |
| --- | --- | --- | ---: |
| `rational-mojo` | `rational.c` | `av_reduce`, `av_mul_q`, `av_div_q`, `av_add_q`, `av_sub_q`, `av_d2q`, `av_nearer_q`, `av_q2intfloat` | 46,764 |

Every recorded call is matched by the Mojo (2026-11-21, Ubuntu 24.04 in WSL, Mojo 1.2.0, gcc
13). The inputs are those of `../ffmpeg-rs/scripts/inputs.py`: the vectors of ffmpeg's own
rational tests plus seeded edge cases (`INT_MIN`/`INT_MAX` terms, zero and negative
denominators, NaN, infinities and subnormals for `av_d2q`), and mojo-anything's generated cases on
top. `av_gcd_q` and `av_find_nearest_q_idx` stay in C, as in the Rust port.

The unit builds `.mojo-anything/build/librational_mojo.so`, which exports the eight functions
under their C names with ffmpeg's signatures (`include/rational_mojo.h`): link it instead of
`rational.o` and callers do not change. `port.mojo` holds no pointers; `exports.mojo` reads and
writes them. This library needs nothing at run time (`readelf -d` lists no `NEEDED` entry), but
it carries an absolute RUNPATH into the unit's `.pixi`; a unit that uses more of the Mojo
standard library (the glibc facade does) also needs `libKGENCompilerRTShared.so` from there.
Packaging such a library to run elsewhere is not done yet.

## Found along the way

`av_q2intfloat` negates `q.num` and `q.den` with `*= -1`, which overflows for `INT_MIN`. The Rust
port matched ffmpeg's macOS build (clang 21, `-O3`), which tests the sign before the wrap and
returns `+inf` for any `x/0`. This recording compiles `rational.c` with gcc 13 at `-O1` (what
`record` uses), which wraps: `INT_MIN` stays negative through the log and the rescales, where
clang divided by 2^31. Like clang, gcc drops the sign of `x/0`. The Mojo port follows the
recording, so on the 75 inputs with an `INT_MIN` term and a nonzero denominator it gives gcc's
answer, not clang's; every other input agrees with both.

## Reproduce

Needs a C compiler, nasm, Python 3, pixi, git and make, on Linux or macOS. From the repository
root:

```sh
cargo build --release
WORK=$PWD/work demo/real-world/ffmpeg-rs/scripts/prepare.sh   # clone ffmpeg n7.1, build libavutil.a, assemble the tree
WORK=$PWD/work demo/real-world/ffmpeg-mojo/scripts/verify.sh  # per unit: record, build, diff, gate
```

The other nine units of `../ffmpeg-rs` (adler32, base64, mathematics, avstring, parseutils and
the four one-shot hash wrappers) are not ported to Mojo yet.
