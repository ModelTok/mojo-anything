# The Mojo port of `src/textkit/`.
#
# Replace each `raise Error("not ported: ...")` with the port of the source function.
# Raise `Error("ValueError: message")` (any builtin exception name) where the source
# raises: the caller gets that exception. After changing a signature, run
# `mojo-anything refresh`; `mojo-anything diff` checks behaviour against the recording.

from std.python import Python, PythonObject

from py_num import PyNum


# Port of `slugify` (`src/textkit/words.py:10`).
# `sep` defaults to `"-"` in the source.
# `max_length` defaults to `None` in the source.
def slugify(text: String, sep: String, max_length: Optional[PyNum]) raises -> String:
    raise Error("not ported: slugify")


# Port of `word_counts` (`src/textkit/words.py:21`).
# `min_length` defaults to `1` in the source.
def word_counts(text: String, min_length: PyNum) raises -> PythonObject:
    raise Error("not ported: word_counts")


# Port of `chunk` (`src/textkit/words.py:31`).
def chunk(items: List[PyNum], size: PyNum) raises -> List[List[PyNum]]:
    raise Error("not ported: chunk")


# Port of `page_count` (`src/textkit/words.py:38`).
def page_count(total: PyNum, per_page: PyNum) raises -> PyNum:
    raise Error("not ported: page_count")


# Port of `mean` (`src/textkit/words.py:43`).
def mean(values: List[PyNum]) raises -> PyNum:
    raise Error("not ported: mean")


# Port of `clipped` (`src/textkit/words.py:55`).
# `limits` defaults to `None` in the source.
def clipped(text: String, limits: Optional[PythonObject]) raises -> String:
    raise Error("not ported: clipped")


# Class `Stack` (`src/textkit/stack.py:4`) is not bridged to Mojo yet; it stays in the source.
