# vercel/ms on Mojo as a wasm module (`mojo-wasm`)

- Date: 2026-11-22T19:46:12Z
- Machine: AMD Ryzen 9 3900X, 12 cores / 24 threads, WSL2 Ubuntu 24.04 (6.18.33.2-microsoft-standard-WSL2)
- Mojo: Mojo 1.2.0 (2016d0cd)
- mojo-anything: 1bc29c5 (mojo-anything 0.1.0), `target/release/mojo-anything`
- Original: vercel/ms at commit 4ff48ce (src/index.ts), Node v24.22.3, mojo-wasm 3551aa4
- Load average (1, 5, 15 min) during the run: 28.32, 20.50, 21.60; 22.80, 19.84, 21.35. The machine was busy (other sessions' builds and benchmarks): this run checks correctness and sizes only, and times nothing.

A fresh `bridge --kind wasm` of vercel/ms at commit `4ff48ce`, given the `port.mojo` and the recordings of `demo/real-world/vercel-ms-mojo`, on Node 24 with mojo-wasm's clang and wasm-ld. **The build failed**, so `diff` and `gate` had no module to load: the dispatcher's LLVM IR holds a NaN with a payload, `double +nan(0x7FFFFFFFFFFFF)`, a float spelling the IR rewriter in `src/harness_mojo_wasm.rs` does not translate for clang. No wasm module, so no module size.

`<work>` is the scratch folder the run used, `<repo>` this repository.

## Output

```text
date: 2026-11-22T19:46:12Z
machine: AMD Ryzen 9 3900X, 12 cores / 24 threads, WSL2 Ubuntu 24.04 (6.18.33.2-microsoft-standard-WSL2)
mojo: Mojo 1.2.0 (2016d0cd)
mojo-anything: 1bc29c5 (mojo-anything 0.1.0)
uptime:  20:46:12 up 1 day, 23:35,  3 users,  load average: 28.32, 20.50, 21.60
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
$ <repo>/target/release/mojo-anything build <work>/ms-wasm/mojo/index-mojo
error: the dispatcher's IR has a float constant clang cannot read: `double +nan`
[exit 2]
$ <repo>/target/release/mojo-anything diff <work>/ms-wasm/mojo/index-mojo
error: node failed (exit status: 1):
node:fs:621
  return binding.open(
                 ^

Error: ENOENT: no such file or directory, open '<work>/ms-wasm/mojo/index-mojo/index_mojo.wasm'
    at Object.openSync (node:fs:621:18)
    at Object.readFileSync (node:fs:487:35)
    at <work>/ms-wasm/mojo/index-mojo/index.cjs:9:38
    at Object.<anonymous> (<work>/ms-wasm/mojo/index-mojo/index.cjs:51:3)
    at Module._compile (node:internal/modules/cjs/loader:1929:14)
    at Object..js (node:internal/modules/cjs/loader:2060:10)
    at Module.load (node:internal/modules/cjs/loader:1651:32)
    at Module._load (node:internal/modules/cjs/loader:1443:12)
    at wrapModuleLoad (node:internal/modules/cjs/loader:261:19)
    at loadCJSModuleWithModuleLoad (node:internal/modules/esm/translators:372:15) {
  errno: -2,
  code: 'ENOENT',
  syscall: 'open',
  path: '<work>/ms-wasm/mojo/index-mojo/index_mojo.wasm'
}

Node.js v24.22.3
[exit 2]
# the same diff on cases.rust-era.jsonl (the recording the Rust port passed)
$ <repo>/target/release/mojo-anything diff <work>/ms-wasm/mojo/index-mojo
error: node failed (exit status: 1):
node:fs:621
  return binding.open(
                 ^

Error: ENOENT: no such file or directory, open '<work>/ms-wasm/mojo/index-mojo/index_mojo.wasm'
    at Object.openSync (node:fs:621:18)
    at Object.readFileSync (node:fs:487:35)
    at <work>/ms-wasm/mojo/index-mojo/index.cjs:9:38
    at Object.<anonymous> (<work>/ms-wasm/mojo/index-mojo/index.cjs:51:3)
    at Module._compile (node:internal/modules/cjs/loader:1929:14)
    at Object..js (node:internal/modules/cjs/loader:2060:10)
    at Module.load (node:internal/modules/cjs/loader:1651:32)
    at Module._load (node:internal/modules/cjs/loader:1443:12)
    at wrapModuleLoad (node:internal/modules/cjs/loader:261:19)
    at loadCJSModuleWithModuleLoad (node:internal/modules/esm/translators:372:15) {
  errno: -2,
  code: 'ENOENT',
  syscall: 'open',
  path: '<work>/ms-wasm/mojo/index-mojo/index_mojo.wasm'
}

Node.js v24.22.3
[exit 2]
uptime:  20:46:37 up 1 day, 23:36,  3 users,  load average: 22.80, 19.84, 21.35
$ <repo>/target/release/mojo-anything gate <work>/ms-wasm/mojo/index-mojo
pass  mojo format port.mojo is formatted
pass  mojo test  no test_*.mojo files
pass  ported     every function in port.mojo is ported
pass  unsafe     no unexplained abort, pointer or external_call
pass  error cases each of the 3 functions that fail in the original has a recorded failing case
pass  size       336 lines of Mojo for 184 lines of TypeScript/JavaScript (1.8x)
FAIL  build      the dispatcher's IR has a float constant clang cannot read: `double +nan`
            fix: fix the compile error above, then `mojo-anything build <work>/ms-wasm/mojo/index-mojo`
pass  coverage   the recorded cases ran 215 of the original's 227 lines (95%); never ran: src/index.ts: 105, 123-125, 129-131, 141-145 (add inputs that reach them, e.g. `record --from-tests`)
Gate failed.
[exit 1]
# built files (bytes)
```
