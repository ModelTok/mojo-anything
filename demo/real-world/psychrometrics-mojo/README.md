# psychrometrics-mojo

Three psychrometric routines of EnergyPlus version 27.1.0 (development, commit `7ab256b`,
`src/EnergyPlus/Psychrometrics.hh`) ported to Mojo with mojo-anything's C++ support: the
density of moist air (`PsyRhoAirFnPbTdbW`), its enthalpy (`PsyHFnTdbW`) and the dry-bulb
temperature from enthalpy (`PsyTdbFnHW`). Every recorded call is matched bit for bit, and the
unit passes `mojo-anything gate`.

## License

EnergyPlus is under its own BSD-style licence, kept in [`LICENSE`](LICENSE) (EnergyPlus's
`LICENSE.txt`). The facade's statements are copied from EnergyPlus and the Mojo ports them, so
both carry that notice and those conditions, including clause (4) on the EnergyPlus name.

## What is here

- `facade/src/psychrometrics.{hpp,cpp}`: a free-function facade. In EnergyPlus the three
  routines are `constexpr` or `inline` in a header, so no object file defines them and
  mojo-anything refuses them (a shim in another file would have nothing to call). The facade
  defines them as plain functions in `EnergyPlus::Psychrometrics` with the statements copied
  unchanged; `Real64` and `Constant::Kelvin` are EnergyPlus's definitions, and the unqualified
  `max` is `std::max`, which for two doubles is what ObjexxFCL's `max` computes
  (`a < b ? b : a`). The rest of the header, which takes `EnergyPlusData &state`, is not here.
- `psychrometrics-mojo/`: the unit `bridge` made from the facade (`kind: c-abi`,
  `language: cpp`): `port.mojo` (the port), `exports.mojo` (the C symbols
  `cpp__EnergyPlus__Psychrometrics__<name>`), `cpp/shim.cpp` (those symbols over the facade, for
  recording) and `cpp/wrapper.cpp` (the facade's functions with their original signatures over
  the Mojo library, for C++ callers). Its manifest's `root` is `../facade`.

| Function | Cases | Match |
| --- | ---: | ---: |
| `PsyRhoAirFnPbTdbW` | 3,226 | 3,226 |
| `PsyHFnTdbW` | 3,216 | 3,216 |
| `PsyTdbFnHW` | 3,216 | 3,216 |
| Total | 9,658 | 9,658 |

Recorded and replayed on 2026-11-22 on Linux x86-64 only (Ubuntu 24.04 in WSL, g++ 13.3 at `-O1`,
Mojo 1.2.0 with `--fp-mode contract=off`); recorded again with `-ffp-contract=off`, the cases are
byte for byte the same. Not run on other platforms or compilers. The
inputs are `scripts/inputs.py`'s 9,000 seeded calls over the ranges EnergyPlus sees (pressure
40 to 120 kPa, dry-bulb -60 to 70 C, humidity ratio 0 to 0.05, enthalpy -100 to 300 kJ/kg), the
1e-5 floor of the humidity ratio approached from both sides, and edge values (-0, absolute
zero, 1e300), plus mojo-anything's 658 generated cases and traps (subnormals, the largest
double, infinities).

## Found along the way

The first port, the statements written as they are in C++, matched 8,267 of 9,658 cases. The
1,391 misses were in all three functions (663 `PsyHFnTdbW`, 688 `PsyTdbFnHW`, 40
`PsyRhoAirFnPbTdbW`); 1,087 were one unit in the last place, and where a sum cancels (an
enthalpy near `2.50094e6 * W`) up to 730 units. `mojo build` fused `a * b + c` (as in
`1.00484e3 * TDB + w * (...)`) into one multiply-add with one rounding by default, where g++
13.3 at `-O1` for x86-64 rounds the product and the sum separately. mojo-anything now builds C
ABI units with `--fp-mode contract=off` and records the original with `-ffp-contract=off`, and
the port, the C++ statements as they are, matches every case with no multiply-add in its
library.
`max(dw, 1.0e-5)` is ported as `a < b ? b : a` rather than Mojo's `max`, so a NaN humidity ratio
stays NaN as it does in C++.

## Speed

`bench` runs (it times both libraries through the driver, each call crossing ctypes), but no
numbers are published yet: the machine these runs were made on was shared with other heavy
jobs. Numbers are pending a quiet machine.

## Reproduce

Needs a C++ compiler, Python 3, pixi, cargo and git; run on Linux x86-64 only. From the repository
root:

```sh
git clone --depth 1 https://github.com/NREL/EnergyPlus.git /tmp/EnergyPlus   # for the facade check
EP=/tmp/EnergyPlus demo/real-world/psychrometrics-mojo/scripts/verify.sh
```

`verify.sh` checks each copied statement against `Psychrometrics.hh` when `EP` is set, then
records the facade, builds the Mojo library, replays every case and runs `gate`.
