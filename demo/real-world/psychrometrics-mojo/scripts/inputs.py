"""Inputs for the psychrometrics unit: seeded values over the ranges EnergyPlus sees (pressure
40-120 kPa, dry-bulb -60 to 70 C, humidity ratio 0 to 0.05, enthalpy -100 to 300 kJ/kg), the
1e-5 floor of the humidity ratio from both sides, and edge values. Writes JSONL to argv[1]."""

import json
import random
import sys

NS = "EnergyPlus::Psychrometrics::"
rng = random.Random(20261122)
FLOOR = 1.0e-5
W_EDGES = [0.0, -0.0, FLOOR, FLOOR * (1 - 2**-52), FLOOR * (1 + 2**-52), -0.01, 0.0001, 0.05, 1.0]
T_EDGES = [-273.15, -60.0, -0.0, 0.0, 20.0, 70.0, 1e-300, -1e300]


def w():
    return rng.choice(W_EDGES) if rng.random() < 0.1 else rng.uniform(0.0, 0.05)


def t():
    return rng.choice(T_EDGES) if rng.random() < 0.05 else rng.uniform(-60.0, 70.0)


def enc(x):
    if x == 0 and str(x).startswith("-"):
        return {"$num": "-0"}
    return x


cases = []
for _ in range(3000):
    cases.append((NS + "PsyRhoAirFnPbTdbW", [rng.uniform(40000.0, 120000.0), t(), w()]))
    cases.append((NS + "PsyHFnTdbW", [t(), w()]))
    cases.append((NS + "PsyTdbFnHW", [rng.uniform(-1.0e5, 3.0e5), w()]))
with open(sys.argv[1], "w", encoding="utf-8") as out:
    for name, args in cases:
        out.write(json.dumps({"fn": name, "args": [enc(a) for a in args]}) + "\n")
