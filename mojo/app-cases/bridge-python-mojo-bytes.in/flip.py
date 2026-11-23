"""A Python unit whose function takes and returns bytes, with no type hints (as most of the
standard library is written)."""


def invert(data, keep_ascii=False):
    """Each byte as 255 minus itself; with keep_ascii, bytes below 128 stay as they are."""
    return bytes(c if keep_ascii and c < 128 else 255 - c for c in data)
