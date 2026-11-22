# Ruby's `shellwords` on Mojo (`ffi`, Fiddle over the JSON dispatcher)

- Date: 2026-11-22T19:43:43Z
- Machine: AMD Ryzen 9 3900X, 12 cores / 24 threads, WSL2 Ubuntu 24.04 (6.18.33.2-microsoft-standard-WSL2)
- Mojo: Mojo 1.2.0 (2016d0cd)
- mojo-anything: 1bc29c5 (mojo-anything 0.1.0), `target/release/mojo-anything`
- Original: ruby 3.3.14 lib/shellwords.rb
- Load average (1, 5, 15 min) during the run: 17.54, 19.32, 21.67; 15.08, 18.62, 21.37. The machine was busy (other sessions' builds and benchmarks): this run checks correctness and sizes only, and times nothing.

The unit in `demo/real-world/ruby-shellwords-mojo`, copied next to Ruby 3.3's `shellwords.rb` (fingerprint matched). The second `diff` replays `cases.rust-era.jsonl`.

`<work>` is the scratch folder the run used, `<repo>` this repository.

## Output

```text
date: 2026-11-22T19:43:43Z
machine: AMD Ryzen 9 3900X, 12 cores / 24 threads, WSL2 Ubuntu 24.04 (6.18.33.2-microsoft-standard-WSL2)
mojo: Mojo 1.2.0 (2016d0cd)
mojo-anything: 1bc29c5 (mojo-anything 0.1.0)
uptime:  20:43:43 up 1 day, 23:33,  3 users,  load average: 17.54, 19.32, 21.67
original: ruby 3.3.14 lib/shellwords.rb
$ <repo>/target/release/mojo-anything build <work>/shellwords/mojo/shellwords-mojo
Built <work>/shellwords/mojo/shellwords-mojo/.mojo-anything/build/libshellwords_mojo.so
[exit 0]
$ <repo>/target/release/mojo-anything diff <work>/shellwords/mojo/shellwords-mojo
1626/1626 cases match
[exit 0]
# the same diff on cases.rust-era.jsonl (the recording the Rust port passed)
$ <repo>/target/release/mojo-anything diff <work>/shellwords/mojo/shellwords-mojo
1617/1617 cases match
[exit 0]
uptime:  20:44:08 up 1 day, 23:33,  3 users,  load average: 15.08, 18.62, 21.37
$ <repo>/target/release/mojo-anything gate <work>/shellwords/mojo/shellwords-mojo
pass  mojo format port.mojo is formatted
pass  mojo test  no test_*.mojo files
pass  ported     every function in port.mojo is ported
pass  unsafe     no unexplained abort, pointer or external_call
pass  error cases each of the 1 functions that fail in the original has a recorded failing case
FAIL  size       367 lines of Mojo for 54 lines of Ruby (6.8x); over 3x usually means code a crate already provides, or a case handled one by one: use the crates `analyze` lists and fold repeated code
            fix: use the crates `mojo-anything analyze` lists and fold repeated code
pass  build      built <work>/shellwords/mojo/shellwords-mojo/.mojo-anything/build/libshellwords_mojo.so
pass  api        exports shellsplit, shellescape, shelljoin
pass  behavior   1626/1626 recorded cases match
Gate failed.
[exit 1]
# built files (bytes)
257416 .mojo-anything/build/libshellwords_mojo.so
```
