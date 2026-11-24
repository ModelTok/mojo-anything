# vercel/ms on Mojo through the Node-API addon (`mojo-node`)

- Date: 2026-11-22T19:45:20Z
- Machine: AMD Ryzen 9 3900X, 12 cores / 24 threads, WSL2 Ubuntu 24.04 (6.18.33.2-microsoft-standard-WSL2)
- Mojo: Mojo 1.2.0 (2016d0cd)
- mojo-anything: 1bc29c5 (mojo-anything 0.1.0), `target/release/mojo-anything`
- Original: vercel/ms at commit 4ff48ce (src/index.ts), Node v24.22.3
- Load average (1, 5, 15 min) during the run: 14.88, 17.60, 20.80; 27.31, 20.17, 21.50. The machine was busy (other sessions' builds and benchmarks): this run checks correctness and sizes only, and times nothing.

The unit in `demo/real-world/vercel-ms-mojo`, copied into a checkout of vercel/ms at commit `4ff48ce` (`git archive`), on Node 24. The second `diff` replays `cases.rust-era.jsonl`, the recording rust-anything's napi-rs port passed (`record --from-tests -- jest`). `recorded-from.json` gives the recording's coverage of `src/index.ts`: 215 of 227 lines.

`<work>` is the scratch folder the run used, `<repo>` this repository.

## Output

```text
date: 2026-11-22T19:45:20Z
machine: AMD Ryzen 9 3900X, 12 cores / 24 threads, WSL2 Ubuntu 24.04 (6.18.33.2-microsoft-standard-WSL2)
mojo: Mojo 1.2.0 (2016d0cd)
mojo-anything: 1bc29c5 (mojo-anything 0.1.0)
uptime:  20:45:20 up 1 day, 23:34,  3 users,  load average: 14.88, 17.60, 20.80
original: vercel/ms at commit 4ff48ce (src/index.ts), Node v24.22.3
$ <repo>/target/release/mojo-anything build <work>/ms/mojo/index-mojo
Built <work>/ms/mojo/index-mojo/index_mojo.node
[exit 0]
$ <repo>/target/release/mojo-anything diff <work>/ms/mojo/index-mojo
1128/1128 cases match
[exit 0]
# the same diff on cases.rust-era.jsonl (the recording the Rust port passed)
$ <repo>/target/release/mojo-anything diff <work>/ms/mojo/index-mojo
975/975 cases match
[exit 0]
uptime:  20:46:05 up 1 day, 23:35,  3 users,  load average: 27.31, 20.17, 21.50
$ <repo>/target/release/mojo-anything gate <work>/ms/mojo/index-mojo
pass  mojo format port.mojo is formatted
pass  mojo test  no test_*.mojo files
pass  ported     every function in port.mojo is ported
pass  unsafe     no unexplained abort, pointer or external_call
pass  error cases each of the 3 functions that fail in the original has a recorded failing case
pass  size       336 lines of Mojo for 184 lines of TypeScript/JavaScript (1.8x)
pass  build      built <work>/ms/mojo/index-mojo/index_mojo.node
pass  coverage   the recorded cases ran 215 of the original's 227 lines (95%); never ran: src/index.ts: 105, 123-125, 129-131, 141-145 (add inputs that reach them, e.g. `record --from-tests`)
pass  api        exports ms, parse, parseStrict, format
pass  behavior   1128/1128 recorded cases match
Gate passed.
[exit 0]
# built files (bytes)
294784 .mojo-anything/build/libindex_mojo.so
16584 index_mojo.node
294784 libindex_mojo.so
```
