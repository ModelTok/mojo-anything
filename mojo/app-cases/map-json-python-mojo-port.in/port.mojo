# The Mojo port of `src/mathkit/` the loop tests use in place of the generated stubs.

from py_num import PyNum


# Port of `scale`.
def scale(x: PyNum, factor: PyNum) raises -> PyNum:
    return x * factor


# Port of `safe_div`.
def safe_div(a: PyNum, b: PyNum) raises -> PyNum:
    if b == PyNum(0):
        raise Error("ValueError: cannot divide by zero")
    return a / b


# Port of `exclaim`.
def exclaim(text: String) raises -> String:
    return text + "!"


# Port of `count_items`.
def count_items(items: List[String]) raises -> PyNum:
    return PyNum(len(items))
