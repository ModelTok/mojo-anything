#!/usr/bin/env bash
# For every Mojo unit: copies it next to the tree that ../ffmpeg-rs/scripts/prepare.sh
# assembles, records ffmpeg's behaviour on the inputs from ../ffmpeg-rs/scripts/inputs.py (and
# mojo-anything's generated edge cases), builds the Mojo library, replays every case and runs
# gate. Run prepare.sh first, with the same WORK. Pass unit folder names to verify only those.
set -euo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
REPO=$(cd "$HERE/../../.." && pwd)
SCRIPTS=$REPO/demo/real-world/ffmpeg-rs/scripts
WORK=${WORK:-$REPO/demo/real-world/ffmpeg-rs/work}
TREE=$WORK/tree
MA=${MA:-$REPO/target/release/mojo-anything}
[ -x "$MA" ] || cargo build --release --manifest-path "$REPO/Cargo.toml"
export CFLAGS="-I$TREE -DHAVE_AV_CONFIG_H"

units=("$@")
[ ${#units[@]} -gt 0 ] || units=(rational-mojo)
for unit_dir in "${units[@]}"; do
  unit=${unit_dir%-mojo}
  dir=$TREE/libavutil/mojo/$unit_dir
  rm -rf "$dir"
  mkdir -p "$dir"
  (cd "$HERE/$unit_dir" && tar cf - --exclude .pixi --exclude .mojo-anything .) | (cd "$dir" && tar xf -)
  python3 - "$dir/mojo-anything.json" "$TREE/libavutil" <<'PY'
import json, sys
path, root = sys.argv[1], sys.argv[2]
m = json.load(open(path))
m["root"] = root
json.dump(m, open(path, "w"), indent=2)
PY
  python3 "$SCRIPTS/inputs.py" "$unit" "$dir/inputs.jsonl"
  echo "== $unit_dir"
  "$MA" record "$dir" --inputs "$dir/inputs.jsonl" | grep Recorded | sed 's/ in .*//'
  "$MA" build "$dir" > /dev/null
  "$MA" diff "$dir" | sed -n 1p
  "$MA" gate "$dir" | tail -1
done
