"""Small functions the Mojo loop tests port: floats, ints, strings, lists and a raised error."""


def scale(x: float, factor: float = 2.0) -> float:
    return x * factor


def safe_div(a: float, b: float) -> float:
    if b == 0:
        raise ValueError("cannot divide by zero")
    return a / b


def exclaim(text: str) -> str:
    return text + "!"


def count_items(items: list[str]) -> int:
    return len(items)
