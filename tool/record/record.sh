#!/usr/bin/env bash
# Record the Phase 1 binary on tool/record/inputs.jsonl into mojo/app-cases/.
#
# The inputs are recorded in chunks so a run that is interrupted resumes at the first chunk not
# yet done (tool/record/chunks/<n>.done). `app record` saves the line-order noise of its own run
# only, so each chunk's outcome is kept and the `unordered` table of mojo-anything.json is the
# union of every chunk's, merged at the end.
#
# Usage: tool/record/record.sh [--fresh]   (--fresh starts over)
set -euo pipefail
repo=$(git rev-parse --show-toplevel)
cd "$repo"
bin=tool/fallback/mojo-anything
work=tool/record/chunks
size=${CHUNK:-40}
[ -x "$bin" ] || { echo "no $bin: run scripts/build-fallback.sh" >&2; exit 1; }
if [ "${1:-}" = "--fresh" ]; then rm -rf "$work" mojo/app-cases; fi
mkdir -p "$work"
[ -f "$work/inputs-000.jsonl" ] || split -d -a 3 -l "$size" --additional-suffix=.jsonl tool/record/inputs.jsonl "$work/inputs-"

for chunk in "$work"/inputs-*.jsonl; do
  n=$(basename "$chunk" .jsonl)
  [ -f "$work/$n.done" ] && continue
  [ -n "${ONLY:-}" ] && [ "$n" != "$ONLY" ] && continue
  echo "recording $n ($(wc -l < "$chunk") cases)"
  "$bin" app record . --inputs "$chunk" --no-traps --timeout 120 --json \
    --normalize timestamps --normalize uuids \
    --normalize 'binary=/[^\s"'"'"'`]*/tool/(fallback|build)/mojo-anything' \
    --normalize 'pixi-path=/[^\s()]*/\.pixi/bin/pixi' \
    --normalize 'scratch=/tmp/mojo-anything-[A-Za-z0-9_.-]+' \
    --normalize 'pixi-version=pixi [0-9]+\.[0-9]+\.[0-9]+' \
    --normalize 'tool-version=Python [0-9][0-9.]*|\bv[0-9]+\.[0-9]+\.[0-9]+|cc \([^)\n]*\) [0-9][0-9.]*|go version go[0-9][0-9.]* [a-z0-9/]+|ruby [0-9][0-9.]* \([^)\n]*\) \[[^]\n]*\]|openjdk version \\?"[0-9][0-9.]*\\?" [0-9-]+|javac [0-9][0-9.]*|info: kotlinc-jvm [^ \n]+ \(JRE [^)\n]*\)' \
    -- tool/record/run-phase1 > "$work/$n.json"
  touch "$work/$n.done"
done

python3 - "$work" <<'EOF'
import glob, json, os, sys
work = sys.argv[1]
path = os.path.join("mojo", "app-cases", "mojo-anything.json")
config = json.load(open(path))
unordered = {}
for f in sorted(glob.glob(os.path.join(work, "inputs-*.json"))):
    for n in json.load(open(f)).get("noise", []):
        if n["kind"] == "order":
            unordered.setdefault(n["case"], []).append(n["field"])
if unordered:
    config["unordered"] = dict(sorted(unordered.items()))
else:
    config.pop("unordered", None)
open(path, "w").write(json.dumps(config, indent=2, ensure_ascii=False) + "\n")
print(f"merged unordered fields of {len(unordered)} cases")
EOF
ls mojo/app-cases/*.toml | wc -l
