#!/usr/bin/env bash
# The Mojo tool's gate: format, a build with warnings as errors, and every test.
# Mojo 1.2 has neither `mojo format --check` nor `mojo test` (docs/mojo-notes.md): the
# sources are formatted in a copy and compared, and each tool/tests/test_*.mojo runs with
# `mojo run`. Run through pixi: `pixi run check-tool`.
set -euo pipefail
cd "$(dirname "$0")/.."
copy=$(mktemp -d)
trap 'rm -rf "$copy"' EXIT
cp src/mojo/json.mojo tool/src/mojo_anything/json.mojo
python tool/skill_files.py
python tool/embedded.py
cp -r tool/src tool/tests "$copy/"
mojo format -q "$copy/src" "$copy/tests" > /dev/null
if ! diff -ru -x json.mojo -x skill_files.mojo -x embedded.mojo tool/src "$copy/src" || ! diff -ru tool/tests "$copy/tests"; then
  echo "mojo format would change the files above: run \`pixi run mojo format tool\`" >&2
  exit 1
fi
echo "format: clean"
bash tool/build.sh
failed=0
for t in tool/tests/test_*.mojo; do
  if ! mojo run -I tool/src "$t"; then
    echo "FAILED: $t" >&2
    failed=1
  fi
done
exit $failed
