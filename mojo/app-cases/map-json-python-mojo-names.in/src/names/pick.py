"""Names that are keywords in Mojo or Rust, a parameter named like the port module, and
names the Mojo port cannot take (`*args`, a class), for `tests/mojo_py_review.rs`."""


def pick(type: str, out: str, port: str) -> str:
    return type + out + port


def match(case: str) -> str:
    return case + "!"


def lengths(items: list[str]) -> list[int]:
    return [len(i) for i in items]


def spin(n: int) -> int:
    return n


def total(*xs):
    return sum(xs)


class Box:
    def __init__(self, v):
        self.v = v
