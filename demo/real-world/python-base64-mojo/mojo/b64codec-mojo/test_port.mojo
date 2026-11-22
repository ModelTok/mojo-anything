# Checks of the port against RFC 4648's test vectors and binascii's own
# behaviour in non-strict mode (CPython 3.12).

from std.testing import assert_equal, assert_raises, assert_true

from port import decode, encode


def _bytes(text: String) -> List[UInt8]:
    var out = List[UInt8]()
    for b in text.as_bytes():
        out.append(b)
    return out^


def _text(data: List[UInt8]) -> String:
    var out = String()
    for b in data:
        out += chr(Int(b))
    return out


def _decoded(text: String) raises -> String:
    var out = List[UInt8]()
    decode(_bytes(text), out)
    return _text(out)


def test_rfc_4648_vectors() raises:
    assert_equal(_text(encode(_bytes(""))), "")
    assert_equal(_text(encode(_bytes("f"))), "Zg==\n")
    assert_equal(_text(encode(_bytes("fo"))), "Zm8=\n")
    assert_equal(_text(encode(_bytes("foo"))), "Zm9v\n")
    assert_equal(_text(encode(_bytes("foob"))), "Zm9vYg==\n")
    assert_equal(_text(encode(_bytes("fooba"))), "Zm9vYmE=\n")
    assert_equal(_text(encode(_bytes("foobar"))), "Zm9vYmFy\n")


def test_lines_of_57_bytes() raises:
    var text = String()
    for _ in range(58):
        text += "a"
    var lines = _text(encode(_bytes(text))).split("\n")
    assert_equal(len(lines), 3)
    assert_equal(lines[0].byte_length(), 76)
    assert_equal(String(lines[1]), "YQ==")


def test_decode_round_trip() raises:
    assert_equal(_decoded("Zm9vYmFy\n"), "foobar")
    assert_equal(_decoded("Zm9vYg==\nZm8=\n"), "foobfo")


def test_non_strict_decoding() raises:
    assert_equal(_decoded("Zm9v YmFy!\n"), "foobar")
    assert_equal(_decoded("YQ==YWJj\n"), "a")
    assert_equal(_decoded("====\n"), "")


def test_errors() raises:
    with assert_raises(contains="Incorrect padding"):
        _ = _decoded("YQ=\n")
    with assert_raises(contains="cannot be 1 more than a multiple of 4"):
        _ = _decoded("YWJjZ\n")
    var out = List[UInt8]()
    try:
        decode(_bytes("YWJj\nYQ\n"), out)
    except:
        pass
    assert_true(_text(out) == "abc")


def main() raises:
    test_rfc_4648_vectors()
    test_lines_of_57_bytes()
    test_decode_round_trip()
    test_non_strict_decoding()
    test_errors()
