# Ruby's `shellwords` on Mojo (`ffi`, Fiddle over the JSON dispatcher)

- Date: 2026-11-22T21:12:22Z
- Machine: AMD Ryzen 9 3900X, 12 cores / 24 threads, WSL2 Ubuntu 24.04 (6.18.33.2-microsoft-standard-WSL2)
- Mojo: Mojo 1.2.0 (2016d0cd)
- mojo-anything: 4031c71 (mojo-anything 0.1.0), `target/release/mojo-anything`
- Original: ruby 3.3.14 lib/shellwords.rb
- Load average (1, 5, 15 min) during the run: 6.37, 12.06, 14.80; 5.41, 11.47, 14.55. The machine is shared with other sessions' builds and benchmarks: this run checks correctness and sizes only, and times nothing.

The unit in `demo/real-world/ruby-shellwords-mojo`, copied next to Ruby 3.3's `shellwords.rb` (fingerprint matched). The second `diff` replays `cases.rust-era.jsonl`. This run is of the port as folded in 4031c71 (210 code lines; an earlier run at 1bc29c5 had 367 and failed `size`), with the same cases. The built library is 287,800 bytes, where the 367-line port's was 257,416.

`<work>` is the scratch folder the run used, `<repo>` this repository.

## Output

```text
date: 2026-11-22T21:12:22Z
machine: AMD Ryzen 9 3900X, 12 cores / 24 threads, WSL2 Ubuntu 24.04 (6.18.33.2-microsoft-standard-WSL2)
mojo: Mojo 1.2.0 (2016d0cd)
mojo-anything: 4031c71 (mojo-anything 0.1.0)
uptime:  22:12:22 up 2 days,  1:02,  3 users,  load average: 6.37, 12.06, 14.80
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
uptime:  22:12:46 up 2 days,  1:02,  3 users,  load average: 5.41, 11.47, 14.55
$ <repo>/target/release/mojo-anything gate <work>/shellwords/mojo/shellwords-mojo
pass  mojo format port.mojo is formatted
pass  mojo test  no test_*.mojo files
pass  ported     every function in port.mojo is ported
pass  unsafe     no unexplained abort, pointer or external_call
pass  error cases each of the 1 functions that fail in the original has a recorded failing case
pass  size       210 lines of Mojo for 54 lines of Ruby (3.9x)
pass  build      built <work>/shellwords/mojo/shellwords-mojo/.mojo-anything/build/libshellwords_mojo.so
pass  api        exports shellsplit, shellescape, shelljoin
pass  behavior   1626/1626 recorded cases match
Gate passed.
[exit 0]
# built files (bytes)
287800 .mojo-anything/build/libshellwords_mojo.so
```
