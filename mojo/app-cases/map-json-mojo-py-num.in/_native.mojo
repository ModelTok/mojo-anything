from std.os import abort

from std.python import Python, PythonObject
from std.python.bindings import PythonModuleBuilder

from py_num import PyNum, py_int, py_max


@export
def PyInit__native() abi("C") -> PythonObject:
    try:
        var module = PythonModuleBuilder("_native")
        module.def_function[add]("add")
        module.def_function[mul]("mul")
        module.def_function[div]("div")
        module.def_function[mod]("mod")
        module.def_function[neg]("neg")
        module.def_function[to_int]("to_int")
        module.def_function[biggest]("biggest")
        return module.finalize()
    except e:
        abort(String("failed to create Python module: ", e))


def add(a: PythonObject, b: PythonObject) raises -> PythonObject:
    return (PyNum(py=a) + PyNum(py=b)).to_python()


def mul(a: PythonObject, b: PythonObject) raises -> PythonObject:
    return (PyNum(py=a) * PyNum(py=b)).to_python()


def div(a: PythonObject, b: PythonObject) raises -> PythonObject:
    return (PyNum(py=a) / PyNum(py=b)).to_python()


def mod(a: PythonObject, b: PythonObject) raises -> PythonObject:
    return (PyNum(py=a) % PyNum(py=b)).to_python()


def neg(a: PythonObject) raises -> PythonObject:
    return (-PyNum(py=a)).to_python()


def to_int(a: PythonObject) raises -> PythonObject:
    return py_int(PyNum(py=a)).to_python()


def biggest(a: PythonObject, b: PythonObject, c: PythonObject) raises -> PythonObject:
    return py_max(PyNum(py=a), PyNum(py=b), PyNum(py=c)).to_python()
