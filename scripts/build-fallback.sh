#!/usr/bin/env bash
# Build the Phase 1 binary (tag v0.1.0) into tool/fallback/mojo-anything.
#
# Phase 2 records this binary and falls back to it, so it is built from the tag, in a worktree
# outside this checkout, with its own CARGO_TARGET_DIR: a shared target folder would let another
# build of the crate replace it (docs/pitfalls.md). Run it again only to re-record.
set -euo pipefail

tag=${MOJO_ANYTHING_FALLBACK_TAG:-v0.1.0}
repo=$(git rev-parse --show-toplevel)
work=${MOJO_ANYTHING_FALLBACK_WORK:-$HOME/.cache/mojo-anything/fallback-$tag}
out="$repo/tool/fallback"

commit=$(git -C "$repo" rev-parse --verify "$tag^{commit}")
if [ -d "$work/src" ]; then
  git -C "$work" checkout --quiet --detach "$commit"
else
  mkdir -p "$(dirname "$work")"
  git -C "$repo" worktree add --detach "$work" "$commit"
fi

(cd "$work" && CARGO_TARGET_DIR="$work/target" cargo build --release --locked)

mkdir -p "$out"
cp "$work/target/release/mojo-anything" "$out/mojo-anything.tmp"
mv "$out/mojo-anything.tmp" "$out/mojo-anything"
printf '%s %s\n' "$tag" "$commit" > "$out/VERSION"
echo "built $tag ($commit) into $out/mojo-anything"
