# vercel/ms on Mojo as a wasm module (`mojo-wasm`)

- Date: 2026-11-22T21:11:45Z
- Machine: AMD Ryzen 9 3900X, 12 cores / 24 threads, WSL2 Ubuntu 24.04 (6.18.33.2-microsoft-standard-WSL2)
- Mojo: Mojo 1.2.0 (2016d0cd)
- mojo-anything: 4031c71 (mojo-anything 0.1.0), `target/release/mojo-anything`
- Original: vercel/ms at commit 4ff48ce (src/index.ts), Node v24.22.3, mojo-wasm 3551aa4
- Load average (1, 5, 15 min) during the run: 7.94, 13.04, 15.22; 7.42, 12.55, 15.00. The machine is shared with other sessions' builds and benchmarks: this run checks correctness and sizes only, and times nothing.

A fresh `bridge --kind wasm` of vercel/ms at commit `4ff48ce`, given the `port.mojo` and the recordings of `demo/real-world/vercel-ms-mojo` and then `refresh`ed (so the dispatcher takes the port's `JsonValue` parameters), on Node 24 with mojo-wasm's clang and wasm-ld. The second `diff` replays `cases.rust-era.jsonl`. An earlier run on 2026-11-22, at 1bc29c5, stopped in `build`: the dispatcher's IR held `double +nan(0x7FFFFFFFFFFFF)` (a NaN with a payload) and `+inf` as untyped operands, which the IR rewriter did not read until 4031c71. Correctness and size only: nothing is timed.

`<work>` is the scratch folder the run used, `<repo>` this repository.

## Output

```text
date: 2026-11-22T21:11:45Z
machine: AMD Ryzen 9 3900X, 12 cores / 24 threads, WSL2 Ubuntu 24.04 (6.18.33.2-microsoft-standard-WSL2)
mojo: Mojo 1.2.0 (2016d0cd)
mojo-anything: 4031c71 (mojo-anything 0.1.0)
uptime:  22:11:45 up 2 days,  1:01,  3 users,  load average: 7.94, 13.04, 15.22
original: vercel/ms at commit 4ff48ce (src/index.ts), Node v24.22.3, mojo-wasm 3551aa4
$ <repo>/target/release/mojo-anything bridge <work>/ms-wasm src/index.ts --kind wasm
Created <work>/ms-wasm/mojo/index-mojo (MojoWasm) for ms, parse, parseStrict, format
  port.mojo
  .gitignore
  README.md
  mojo-anything.json
  pixi.toml
  json.mojo
  dispatcher.mojo
  index.cjs
- Port each function in port.mojo, then: mojo-anything record <work>/ms-wasm/mojo/index-mojo && mojo-anything build <work>/ms-wasm/mojo/index-mojo && mojo-anything diff <work>/ms-wasm/mojo/index-mojo
[exit 0]
unit folder: mojo/index-mojo
# port.mojo, cases.jsonl, cases.rust-era.jsonl and recorded-from.json copied from demo/real-world/vercel-ms-mojo
# refresh regenerates the dispatcher from the copied port.mojo's signatures
$ <repo>/target/release/mojo-anything refresh <work>/ms-wasm/mojo/index-mojo
Regenerated pixi.toml, json.mojo, dispatcher.mojo, index.cjs for ms, parse, parseStrict, format
[exit 0]
$ <repo>/target/release/mojo-anything build <work>/ms-wasm/mojo/index-mojo
Built <work>/ms-wasm/mojo/index-mojo/index_mojo.wasm
[exit 0]
$ <repo>/target/release/mojo-anything diff <work>/ms-wasm/mojo/index-mojo
1128/1128 cases match
[exit 0]
# the same diff on cases.rust-era.jsonl (the recording the Rust port passed)
$ <repo>/target/release/mojo-anything diff <work>/ms-wasm/mojo/index-mojo
975/975 cases match
[exit 0]
uptime:  22:12:11 up 2 days,  1:01,  3 users,  load average: 7.42, 12.55, 15.00
$ <repo>/target/release/mojo-anything gate <work>/ms-wasm/mojo/index-mojo
pass  mojo format port.mojo is formatted
pass  mojo test  no test_*.mojo files
pass  ported     every function in port.mojo is ported
pass  unsafe     no unexplained abort, pointer or external_call
pass  error cases each of the 3 functions that fail in the original has a recorded failing case
pass  size       336 lines of Mojo for 184 lines of TypeScript/JavaScript (1.8x)
pass  build      built <work>/ms-wasm/mojo/index-mojo/index_mojo.wasm
pass  coverage   the recorded cases ran 215 of the original's 227 lines (95%); never ran: src/index.ts: 105, 123-125, 129-131, 141-145 (add inputs that reach them, e.g. `record --from-tests`)
pass  api        exports ms, parse, parseStrict, format
pass  behavior   1128/1128 recorded cases match
Gate passed.
[exit 0]
# built files (bytes)
289144 .mojo-anything/build/index_mojo.wasm
289144 index_mojo.wasm
```
