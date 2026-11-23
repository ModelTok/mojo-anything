# The Mojo port of `src/pipeline.ts`.
#
# Replace each `raise Error("not ported: ...")` with the port of the source function.
# Raise `Error("ValueError: message")` (any builtin exception name) where the source
# raises: the caller gets that exception. After changing a signature, run
# `mojo-anything refresh`; `mojo-anything diff` checks behaviour against the recording.

from json import JsonValue


# Port of `normalize` (`src/pipeline.ts:7`).
def normalize(entries: List[JsonValue], prefix: Optional[String]) raises -> List[JsonValue]:
    raise Error("not ported: normalize")


# Port of `countWords` (`src/pipeline.ts:14`).
def count_words(text: String) raises -> Float64:
    raise Error("not ported: countWords")


# Port of `upper` (`src/pipeline.ts:19`).
def upper(text: String) raises -> String:
    raise Error("not ported: upper")
