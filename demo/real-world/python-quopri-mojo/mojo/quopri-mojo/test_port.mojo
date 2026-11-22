# Checks of the port against values binascii gives (CPython 3.12.3); the
# recorded cases in `cases.jsonl` are the full check, through `mojo-anything diff`.

from std.testing import assert_equal

from port import decodestring, encodestring


def _bytes(text: String) -> List[UInt8]:
    var out = List[UInt8]()
    for b in text.as_bytes():
        out.append(b)
    return out^


def _text(data: List[UInt8]) raises -> String:
    return String(from_utf8=Span(data))


def _enc(
    text: String, quotetabs: Bool = False, header: Bool = False
) raises -> String:
    return _text(encodestring(_bytes(text), quotetabs, header))


def _dec(text: String, header: Bool = False) raises -> String:
    return _text(decodestring(_bytes(text), header))


def test_encode() raises:
    assert_equal(_enc("hello world"), "hello world")
    assert_equal(_enc("a=b"), "a=3Db")
    assert_equal(_enc("café"), "caf=C3=A9")
    assert_equal(_enc("a \nb\t\n"), "a=20\nb=09\n")
    assert_equal(_enc("ends "), "ends=20")
    assert_equal(_enc("a b\tc", quotetabs=True), "a=20b=09c")
    assert_equal(_enc("a b_c", header=True), "a_b=5Fc")
    assert_equal(_enc(".\n"), "=2E\n")
    assert_equal(_enc("one\r\ntwo \r\n"), "one\r\ntwo=20\r\n")


def test_soft_breaks() raises:
    var x76 = String("x") * 76
    assert_equal(_enc(x76 + "\n"), x76 + "\n")
    var x75 = String("x") * 75
    assert_equal(_enc(x75 + "xx\n"), x75 + "=\nxx\n")


def test_decode() raises:
    assert_equal(_dec("=41=42"), "AB")
    assert_equal(_dec("caf=c3=a9"), "café")
    assert_equal(_dec("soft=\nbreak"), "softbreak")
    assert_equal(_dec("soft=\r\nbreak"), "softbreak")
    assert_equal(_dec("=ZZ =4"), "=ZZ =4")
    assert_equal(_dec("a==3D"), "a=3D")
    assert_equal(_dec("end="), "end")
    assert_equal(_dec("a_b", header=True), "a b")
    assert_equal(_dec("a_b"), "a_b")


def main() raises:
    test_encode()
    test_soft_breaks()
    test_decode()
