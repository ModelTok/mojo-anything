# The glibc facade on Mojo (`c-abi`)

- Date: 2026-11-22T21:12:51Z
- Machine: AMD Ryzen 9 3900X, 12 cores / 24 threads, WSL2 Ubuntu 24.04 (6.18.33.2-microsoft-standard-WSL2)
- Mojo: Mojo 1.2.0 (2016d0cd)
- mojo-anything: 4031c71 (mojo-anything 0.1.0), `target/release/mojo-anything`
- Original: demo/real-world/c-libc-mojo/original/facade.c, gcc (Ubuntu 13.3.0-6ubuntu2~24.04.1) 13.3.0, ldd (Ubuntu GLIBC 2.39-0ubuntu8.12) 2.39
- Load average (1, 5, 15 min) during the run: 5.14, 11.32, 14.48; 4.45, 10.76, 14.23. The machine is shared with other sessions' builds and benchmarks: this run checks correctness and sizes only, and times nothing.

The unit in `demo/real-world/c-libc-mojo`, copied next to its `original/facade.c` (fingerprint matched), glibc 2.39. This demo keeps no Rust-era recording, so only `cases.jsonl` is replayed. Since 4031c71 `size` does not compare a C unit that calls functions from outside the repository: an earlier run at 1bc29c5 failed `size` with the same 236 lines.

`<work>` is the scratch folder the run used, `<repo>` this repository.

## Output

```text
date: 2026-11-22T21:12:51Z
machine: AMD Ryzen 9 3900X, 12 cores / 24 threads, WSL2 Ubuntu 24.04 (6.18.33.2-microsoft-standard-WSL2)
mojo: Mojo 1.2.0 (2016d0cd)
mojo-anything: 4031c71 (mojo-anything 0.1.0)
uptime:  22:12:52 up 2 days,  1:02,  3 users,  load average: 5.14, 11.32, 14.48
original: demo/real-world/c-libc-mojo/original/facade.c, gcc (Ubuntu 13.3.0-6ubuntu2~24.04.1) 13.3.0, ldd (Ubuntu GLIBC 2.39-0ubuntu8.12) 2.39
$ <repo>/target/release/mojo-anything build <work>/libc/mojo/facade-mojo
Built <work>/libc/mojo/facade-mojo/.mojo-anything/build/libfacade_mojo.so
[exit 0]
$ <repo>/target/release/mojo-anything diff <work>/libc/mojo/facade-mojo
2488/2488 cases match
[exit 0]
uptime:  22:13:11 up 2 days,  1:02,  3 users,  load average: 4.45, 10.76, 14.23
$ <repo>/target/release/mojo-anything gate <work>/libc/mojo/facade-mojo
pass  mojo format port.mojo is formatted
pass  mojo test  no test_*.mojo files
pass  ported     every function in port.mojo is ported
pass  unsafe     no unexplained abort, pointer or external_call
pass  pointers   port.mojo uses no pointers
pass  error cases the original fails on purpose nowhere
pass  size       236 lines of Mojo for 15 lines of C (15.7x); not compared: the C calls `atoi`, `isalpha`, `ispunct`, `isspace`, `strcmp`, `strspn`, `strtod`, `strtol`, `toupper` from outside the repository, which the port reimplements
pass  build      built <work>/libc/mojo/facade-mojo/.mojo-anything/build/libfacade_mojo.so
pass  exports    <work>/libc/mojo/facade-mojo/.mojo-anything/build/libfacade_mojo.so exports parse_long, parse_int, parse_double, span, compare, is_alpha, is_space, is_punct, to_upper
pass  api        exports parse_long, parse_int, parse_double, span, compare, is_alpha, is_space, is_punct, to_upper
pass  behavior   2488/2488 recorded cases match
Gate passed.
[exit 0]
# built files (bytes)
73168 .mojo-anything/build/libfacade_mojo.so
73296 .mojo-anything/build/libfacade_mojo_shadow.so
```
