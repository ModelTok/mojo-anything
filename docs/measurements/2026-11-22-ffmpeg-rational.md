# ffmpeg's `rational.c` on Mojo (`c-abi`)

- Date: 2026-11-22T19:47:00Z
- Machine: AMD Ryzen 9 3900X, 12 cores / 24 threads, WSL2 Ubuntu 24.04 (6.18.33.2-microsoft-standard-WSL2)
- Mojo: Mojo 1.2.0 (2016d0cd)
- mojo-anything: 1bc29c5 (mojo-anything 0.1.0), `target/release/mojo-anything`
- Original: ffmpeg n7.1 (b08d796) libavutil/rational.c, gcc (Ubuntu 13.3.0-6ubuntu2~24.04.1) 13.3.0
- Load average (1, 5, 15 min) during the run: 19.94, 19.40, 21.17; 10.52, 15.19, 16.98. The machine was busy (other sessions' builds and benchmarks): this run checks correctness and sizes only, and times nothing.

`demo/real-world/ffmpeg-mojo/scripts/verify.sh`, which copies the unit next to the tree `ffmpeg-rs/scripts/prepare.sh` assembled (ffmpeg n7.1, commit `b08d796`), records ffmpeg's behaviour on the inputs of `ffmpeg-rs/scripts/inputs.py` plus generated cases, builds, diffs and gates. The demo keeps no cases, so this run recorded them again.

`<work>` is the scratch folder the run used, `<repo>` this repository.

## Output

```text
date: 2026-11-22T19:47:00Z
machine: AMD Ryzen 9 3900X, 12 cores / 24 threads, WSL2 Ubuntu 24.04 (6.18.33.2-microsoft-standard-WSL2)
mojo: Mojo 1.2.0 (2016d0cd)
mojo-anything: 1bc29c5 (mojo-anything 0.1.0)
uptime:  20:47:00 up 1 day, 23:36,  3 users,  load average: 19.94, 19.40, 21.17
original: ffmpeg n7.1 (b08d796) libavutil/rational.c, gcc (Ubuntu 13.3.0-6ubuntu2~24.04.1) 13.3.0
# demo/real-world/ffmpeg-mojo/scripts/verify.sh on the tree ffmpeg-rs/scripts/prepare.sh assembled
$ bash <repo>/demo/real-world/ffmpeg-mojo/scripts/verify.sh
== rational-mojo
Recorded 46764 cases (234 threw)
46764/46764 cases match
Gate passed.
[exit 0]
uptime:  21:04:18 up 1 day, 23:53,  3 users,  load average: 10.52, 15.19, 16.98
# built files (bytes)
19568 build/librational_mojo.so
19680 build/librational_mojo_shadow.so
126888 original.so
```
