# The Mojo port of `packages/a/src/fs.ts`.
#
# Replace each `raise Error("not ported: ...")` with the port of the source function.
# Raise `Error("ValueError: message")` (any builtin exception name) where the source
# raises: the caller gets that exception. After changing a signature, run
# `mojo-anything refresh`; `mojo-anything diff` checks behaviour against the recording.


# Port of `wordsIn` (`packages/a/src/fs.ts:4`).
def words_in(path: String) raises -> List[String]:
    raise Error("not ported: wordsIn")
