# The Mojo port of `src/colorsys_pkg/`: CPython 3.13's `Lib/colorsys.py` (PSF licence), function
# by function. `PyNum` keeps Python's int-or-float arithmetic, so an int passed in stays an int
# where Python keeps it one (`hsv_to_rgb(0, 0, 7)` is `(7, 7, 7)`).

from std.python import Python, PythonObject

from py_num import PyNum, py_int, py_max, py_min


def _n(x: Float64) -> PyNum:
    return PyNum(x)


def _triple(a: PyNum, b: PyNum, c: PyNum) raises -> PythonObject:
    return Python.tuple(a.to_python(), b.to_python(), c.to_python())


# Port of `rgb_to_yiq` (`src/colorsys_pkg/colorsys.py:40`).
def rgb_to_yiq(r: PyNum, g: PyNum, b: PyNum) raises -> PythonObject:
    var y = _n(0.30) * r + _n(0.59) * g + _n(0.11) * b
    var i = _n(0.74) * (r - y) - _n(0.27) * (b - y)
    var q = _n(0.48) * (r - y) + _n(0.41) * (b - y)
    return _triple(y, i, q)


# Port of `yiq_to_rgb` (`src/colorsys_pkg/colorsys.py:46`).
def yiq_to_rgb(y: PyNum, i: PyNum, q: PyNum) raises -> PythonObject:
    var r = y + _n(0.9468822170900693) * i + _n(0.6235565819861433) * q
    var g = y - _n(0.27478764629897834) * i - _n(0.6356910791873801) * q
    var b = y - _n(1.1085450346420322) * i + _n(1.7090069284064666) * q
    if r < _n(0.0):
        r = _n(0.0)
    if g < _n(0.0):
        g = _n(0.0)
    if b < _n(0.0):
        b = _n(0.0)
    if r > _n(1.0):
        r = _n(1.0)
    if g > _n(1.0):
        g = _n(1.0)
    if b > _n(1.0):
        b = _n(1.0)
    return _triple(r, g, b)


# Port of `rgb_to_hls` (`src/colorsys_pkg/colorsys.py:75`).
def rgb_to_hls(r: PyNum, g: PyNum, b: PyNum) raises -> PythonObject:
    var maxc = py_max(r, g, b)
    var minc = py_min(r, g, b)
    var sumc = maxc + minc
    var rangec = maxc - minc
    var l = sumc / _n(2.0)
    if minc == maxc:
        return _triple(_n(0.0), l, _n(0.0))
    var s: PyNum
    if l <= _n(0.5):
        s = rangec / sumc
    else:
        s = rangec / (_n(2.0) - maxc - minc)
    var rc = (maxc - r) / rangec
    var gc = (maxc - g) / rangec
    var bc = (maxc - b) / rangec
    var h: PyNum
    if r == maxc:
        h = bc - gc
    elif g == maxc:
        h = _n(2.0) + rc - bc
    else:
        h = _n(4.0) + gc - rc
    h = (h / _n(6.0)) % _n(1.0)
    return _triple(h, l, s)


# Port of `hls_to_rgb` (`src/colorsys_pkg/colorsys.py:99`).
def hls_to_rgb(h: PyNum, l: PyNum, s: PyNum) raises -> PythonObject:
    if s == _n(0.0):
        return _triple(l, l, l)
    var m2: PyNum
    if l <= _n(0.5):
        m2 = l * (_n(1.0) + s)
    else:
        m2 = l + s - (l * s)
    var m1 = _n(2.0) * l - m2
    var one_third = _n(1.0) / _n(3.0)
    return _triple(
        _v(m1, m2, h + one_third), _v(m1, m2, h), _v(m1, m2, h - one_third)
    )


def _v(m1: PyNum, m2: PyNum, hue_in: PyNum) raises -> PyNum:
    var one_sixth = _n(1.0) / _n(6.0)
    var two_third = _n(2.0) / _n(3.0)
    var hue = hue_in % _n(1.0)
    if hue < one_sixth:
        return m1 + (m2 - m1) * hue * _n(6.0)
    if hue < _n(0.5):
        return m2.copy()
    if hue < two_third:
        return m1 + (m2 - m1) * (two_third - hue) * _n(6.0)
    return m1.copy()


# Port of `rgb_to_hsv` (`src/colorsys_pkg/colorsys.py:125`).
def rgb_to_hsv(r: PyNum, g: PyNum, b: PyNum) raises -> PythonObject:
    var maxc = py_max(r, g, b)
    var minc = py_min(r, g, b)
    var rangec = maxc - minc
    var v = maxc.copy()
    if minc == maxc:
        return _triple(_n(0.0), _n(0.0), v)
    var s = rangec / maxc
    var rc = (maxc - r) / rangec
    var gc = (maxc - g) / rangec
    var bc = (maxc - b) / rangec
    var h: PyNum
    if r == maxc:
        h = bc - gc
    elif g == maxc:
        h = _n(2.0) + rc - bc
    else:
        h = _n(4.0) + gc - rc
    h = (h / _n(6.0)) % _n(1.0)
    return _triple(h, s, v)


# Port of `hsv_to_rgb` (`src/colorsys_pkg/colorsys.py:145`).
def hsv_to_rgb(h: PyNum, s: PyNum, v: PyNum) raises -> PythonObject:
    if s == _n(0.0):
        return _triple(v, v, v)
    var i = py_int(h * _n(6.0))
    var f = (h * _n(6.0)) - i
    var p = v * (_n(1.0) - s)
    var q = v * (_n(1.0) - s * f)
    var t = v * (_n(1.0) - s * (_n(1.0) - f))
    i = i % PyNum(6)
    if i == PyNum(0):
        return _triple(v, t, p)
    if i == PyNum(1):
        return _triple(q, v, p)
    if i == PyNum(2):
        return _triple(p, v, t)
    if i == PyNum(3):
        return _triple(p, q, v)
    if i == PyNum(4):
        return _triple(t, p, v)
    if i == PyNum(5):
        return _triple(v, p, q)
    # Cannot get here: `i % 6` is 0 to 5.
    return Python.none()
