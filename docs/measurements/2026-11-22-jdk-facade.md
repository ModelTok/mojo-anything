# The JDK facade on Mojo (`mojo-jvm`)

- Date: 2026-11-22T19:44:12Z
- Machine: AMD Ryzen 9 3900X, 12 cores / 24 threads, WSL2 Ubuntu 24.04 (6.18.33.2-microsoft-standard-WSL2)
- Mojo: Mojo 1.2.0 (2016d0cd)
- mojo-anything: 1bc29c5 (mojo-anything 0.1.0), `target/release/mojo-anything`
- Original: demo/real-world/java-jdk-mojo/original/Jdk.java on openjdk version "25.0.5.1" 2026-11-17
- Load average (1, 5, 15 min) during the run: 15.08, 18.62, 21.37; 13.39, 17.83, 21.02. The machine was busy (other sessions' builds and benchmarks): this run checks correctness and sizes only, and times nothing.

The unit in `demo/real-world/java-jdk-mojo`, copied next to its `original/Jdk.java` in a Maven layout (fingerprint matched), on OpenJDK 25. The second `diff` replays `cases.rust-era.jsonl`, the JDK 21 recording the Rust port passed.

`<work>` is the scratch folder the run used, `<repo>` this repository.

## Output

```text
date: 2026-11-22T19:44:12Z
machine: AMD Ryzen 9 3900X, 12 cores / 24 threads, WSL2 Ubuntu 24.04 (6.18.33.2-microsoft-standard-WSL2)
mojo: Mojo 1.2.0 (2016d0cd)
mojo-anything: 1bc29c5 (mojo-anything 0.1.0)
uptime:  20:44:12 up 1 day, 23:33,  3 users,  load average: 15.08, 18.62, 21.37
original: demo/real-world/java-jdk-mojo/original/Jdk.java on openjdk version "25.0.5.1" 2026-11-17
$ <repo>/target/release/mojo-anything build <work>/jdk/mojo/jdk-mojo
Built <work>/jdk/mojo/jdk-mojo/.mojo-anything/build/libjdk_mojo.so
[exit 0]
$ <repo>/target/release/mojo-anything diff <work>/jdk/mojo/jdk-mojo
4782/4782 cases match
[exit 0]
# the same diff on cases.rust-era.jsonl (the recording the Rust port passed)
$ <repo>/target/release/mojo-anything diff <work>/jdk/mojo/jdk-mojo
4492/4492 cases match
[exit 0]
uptime:  20:44:38 up 1 day, 23:34,  3 users,  load average: 13.39, 17.83, 21.02
$ <repo>/target/release/mojo-anything gate <work>/jdk/mojo/jdk-mojo
pass  mojo format port.mojo is formatted
pass  mojo test  no test_*.mojo files
pass  ported     every function in port.mojo is ported
pass  unsafe     no unexplained abort, pointer or external_call
pass  error cases the original fails on purpose nowhere
pass  size       173 lines of Mojo for 41 lines of Java (4.2x)
pass  build      built <work>/jdk/mojo/jdk-mojo/.mojo-anything/build/libjdk_mojo.so
pass  java api   the wrappers keep every public member of the original classes: Jdk.addExact, Jdk.base64, Jdk.floorMod, Jdk.formatDouble, Jdk.parseRadix, Jdk.reverseBits, Jdk.toBinary, Jdk.toHex, Jdk.toRadix, Jdk.upper, Jdk.urlEncode
pass  api        exports toRadix, parseRadix, toBinary, toHex, reverseBits, floorMod, addExact, formatDouble, urlEncode, base64, upper
pass  behavior   4782/4782 recorded cases match
Gate passed.
[exit 0]
# built files (bytes)
277112 .mojo-anything/build/libjdk_mojo.so
```
