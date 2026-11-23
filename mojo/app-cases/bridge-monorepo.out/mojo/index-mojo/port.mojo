# The Mojo port of `packages/a/src/index.ts`.
#
# Replace each `raise Error("not ported: ...")` with the port of the source function.
# Raise `Error("ValueError: message")` (any builtin exception name) where the source
# raises: the caller gets that exception. After changing a signature, run
# `mojo-anything refresh`; `mojo-anything diff` checks behaviour against the recording.


# Port of `slug` (`packages/a/src/index.ts:1`).
def slug(text: String) raises -> String:
    raise Error("not ported: slug")
