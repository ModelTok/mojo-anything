from std.os import abort

from std.python import Python, PythonObject
from std.python.bindings import PythonModuleBuilder


@export
def PyInit__native() abi("C") -> PythonObject:
    try:
        var module = PythonModuleBuilder("_native")
        module.def_function[add]("add")
        module.def_function[fail]("fail")
        module.def_function[pair]("pair")
        return module.finalize()
    except e:
        abort(String("failed to create Python module: ", e))


def add(a: PythonObject, b: PythonObject) raises -> PythonObject:
    var x = Float64(py=a)
    var y = Float64(py=b)
    return PythonObject(x + y)


def fail(msg: PythonObject) raises -> PythonObject:
    raise Error(String("ValueError: ", String(py=msg)))


def pair(a: PythonObject) raises -> PythonObject:
    var n = Int(py=a)
    return Python.tuple(PythonObject(n), PythonObject(String("x")))
