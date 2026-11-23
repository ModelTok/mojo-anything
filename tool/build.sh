#!/usr/bin/env bash
# Build the Mojo tool into tool/build/mojo-anything, warnings as errors.
# Run through pixi: `pixi run build-tool`.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p tool/build
mojo build --Werror -I tool/src tool/src/main.mojo -o tool/build/mojo-anything.tmp
mv tool/build/mojo-anything.tmp tool/build/mojo-anything
echo "built tool/build/mojo-anything"
