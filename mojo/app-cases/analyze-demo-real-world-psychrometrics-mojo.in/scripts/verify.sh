#!/usr/bin/env bash
# Checks the facade's statements against EnergyPlus's Psychrometrics.hh (when EP points at an
# EnergyPlus checkout), then records the facade on scripts/inputs.py's inputs and mojo-anything's
# generated cases, builds the Mojo port, replays every case and runs gate. Needs a C++ compiler,
# Python 3, pixi and cargo.
set -euo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
REPO=$(cd "$HERE/../../.." && pwd)
UNIT=$HERE/psychrometrics-mojo
MA=${MA:-$REPO/target/release/mojo-anything}
[ -x "$MA" ] || cargo build --release --manifest-path "$REPO/Cargo.toml"

if [ -n "${EP:-}" ]; then
  header=$EP/src/EnergyPlus/Psychrometrics.hh
  grep -E '^\s*(return|Real64 const W)' "$HERE/facade/src/psychrometrics.cpp" | while IFS= read -r line; do
    grep -qF -- "$(echo "$line" | sed 's/^ *//')" "$header" || { echo "not in $header: $line"; exit 1; }
  done
  echo "== the facade's statements are EnergyPlus's"
fi

python3 "$HERE/scripts/inputs.py" "$UNIT/inputs.jsonl"
echo "== psychrometrics-mojo"
"$MA" record "$UNIT" --inputs "$UNIT/inputs.jsonl" | grep Recorded | sed 's/ in .*//'
"$MA" build "$UNIT" > /dev/null
"$MA" diff "$UNIT" | sed -n 1p
"$MA" gate "$UNIT" | tail -1
