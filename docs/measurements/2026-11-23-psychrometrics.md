# EnergyPlus psychrometrics on Mojo (`c-abi`, C++)

- Date: 2026-11-23T00:21:09Z
- Machine: AMD Ryzen 9 3900X, 12 cores / 24 threads, WSL2 Ubuntu 24.04 (6.18.33.2-microsoft-standard-WSL2)
- Mojo: Mojo 1.2.0 (2016d0cd)
- mojo-anything: 517398b with the C++ work (c15f440) merged in, before the merge commit (mojo-anything 0.1.0), `target/release/mojo-anything`
- Original: demo/real-world/psychrometrics-mojo/facade/src/psychrometrics.cpp (three routines of EnergyPlus version 27.1.0, commit `7ab256b`), c++ (Ubuntu 13.3.0-6ubuntu2~24.04.1) 13.3.0
- Load average (1, 5, 15 min) during the run: 2.12, 1.90, 2.91; 2.26, 2.00, 2.89. This run checks correctness and sizes only, and times nothing.

The unit in `demo/real-world/psychrometrics-mojo`, copied without its `.pixi/` and
`.mojo-anything/` folders. The demo keeps no recording, so the facade was recorded first on
`scripts/inputs.py`'s 9,000 inputs plus the generated cases, as the demo's `scripts/verify.sh`
does (without `EP`, so the facade was not compared with an EnergyPlus checkout here). The
recording compiles the facade with `-ffp-contract=off` and the port builds with
`--fp-mode contract=off`; the built library has no `vfmadd` instruction.

`<work>` is the scratch folder the run used, `<repo>` this repository.

## Output

```text
date: 2026-11-23T00:21:09Z
machine: AMD Ryzen 9 3900X 12-Core Processor, 24 threads, WSL2 Ubuntu 24.04 (6.18.33.2-microsoft-standard-WSL2)
mojo: Mojo 1.2.0 (2016d0cd)
mojo-anything: 517398b + the merge in progress (mojo-anything 0.1.0)
uptime:  01:21:10 up 2 days,  4:10,  1 user,  load average: 2.12, 1.90, 2.91
original: demo/real-world/psychrometrics-mojo/facade/src/psychrometrics.cpp, c++ (Ubuntu 13.3.0-6ubuntu2~24.04.1) 13.3.0
inputs: 9000 lines from scripts/inputs.py
$ <repo>/target/release/mojo-anything record <work>/psy/psychrometrics-mojo --inputs <work>/psy/psychrometrics-mojo/inputs.jsonl
Recorded 9658 cases (0 threw) in <work>/psy/psychrometrics-mojo/cases.jsonl
  EnergyPlus::Psychrometrics::PsyHFnTdbW: 3216
  EnergyPlus::Psychrometrics::PsyRhoAirFnPbTdbW: 3226
  EnergyPlus::Psychrometrics::PsyTdbFnHW: 3216
[exit 0]
$ <repo>/target/release/mojo-anything build <work>/psy/psychrometrics-mojo
Built <work>/psy/psychrometrics-mojo/.mojo-anything/build/libpsychrometrics_mojo.so
[exit 0]
$ <repo>/target/release/mojo-anything diff <work>/psy/psychrometrics-mojo
9658/9658 cases match
[exit 0]
uptime:  01:22:05 up 2 days,  4:11,  1 user,  load average: 2.26, 2.00, 2.89
$ <repo>/target/release/mojo-anything gate <work>/psy/psychrometrics-mojo
pass  mojo format port.mojo is formatted
pass  mojo test  no test_*.mojo files
pass  ported     every function in port.mojo is ported
pass  unsafe     no unexplained abort, pointer or external_call
pass  pointers   port.mojo uses no pointers
pass  error cases the original fails on purpose nowhere
pass  size       10 lines of Mojo for 27 lines of C++ (0.4x)
pass  build      built <work>/psy/psychrometrics-mojo/.mojo-anything/build/libpsychrometrics_mojo.so
pass  exports    <work>/psy/psychrometrics-mojo/.mojo-anything/build/libpsychrometrics_mojo.so exports cpp__EnergyPlus__Psychrometrics__PsyRhoAirFnPbTdbW, cpp__EnergyPlus__Psychrometrics__PsyHFnTdbW, cpp__EnergyPlus__Psychrometrics__PsyTdbFnHW
pass  cpp api    cpp/wrapper.cpp defines the original's symbols: EnergyPlus::Psychrometrics::PsyRhoAirFnPbTdbW(double, double, double), EnergyPlus::Psychrometrics::PsyHFnTdbW(double, double), EnergyPlus::Psychrometrics::PsyTdbFnHW(double, double)
pass  api        exports EnergyPlus::Psychrometrics::PsyRhoAirFnPbTdbW, EnergyPlus::Psychrometrics::PsyHFnTdbW, EnergyPlus::Psychrometrics::PsyTdbFnHW
pass  behavior   9658/9658 recorded cases match
Gate passed.
[exit 0]
# multiply-adds in the built library
0
# built files (bytes)
15160 .mojo-anything/build/libpsychrometrics_mojo.so
```
