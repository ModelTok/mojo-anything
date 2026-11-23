# Checks for json.mojo (EmberJson plus mojo-anything's markers), run with
# `mojo run test_json.mojo` next to json.mojo and floats.txt (Mojo 1.2 has no `mojo test`).
# Prints one `pass <name>` per check, then `ok`.

from std.memory import bitcast
from std.pathlib import Path
from std.utils.numerics import inf, isinf, isnan, nan

from emberjson import Array, Value
from json import JsonValue, as_float, json_float, parse_json, write_json


def check(cond: Bool, what: String) raises:
    if not cond:
        raise Error("failed: " + what)


def bits(x: Float64) -> UInt64:
    return bitcast[DType.uint64](x)


def refused(text: String, says: String, refuse_big_ints: Bool = False) raises:
    try:
        _ = parse_json(text, refuse_big_ints)
    except e:
        var msg = String(e)
        check(msg.find(says) >= 0, text + " raised: " + msg)
        return
    raise Error("failed: accepted " + text)


def json_float_corpus() raises:
    var n = 0
    for line in Path("floats.txt").read_text().splitlines():
        var s = String(line)
        if s == "" or s.startswith("#"):
            continue
        n += 1
        var x = atof(s)
        # Every float survives a write and a read bit for bit, from text and from the float.
        var again = as_float(parse_json(write_json(parse_json(s))))
        check(bits(again) == bits(x), s + " came back as " + String(again))
        var from_float = as_float(parse_json(write_json(json_float(x))))
        check(bits(from_float) == bits(x), s + " from the float came back as " + String(from_float))
    check(n > 400, "corpus has " + String(n) + " lines")


def json_200_deep() raises:
    var arr = String()
    var obj = String()
    for _ in range(200):
        arr += "["
        obj += '{"k":'
    arr += "1"
    obj += "null"
    for _ in range(200):
        arr += "]"
        obj += "}"
    check(write_json(parse_json(arr)) == arr, "200-deep array")
    check(write_json(parse_json(obj)) == obj, "200-deep object")
    var deep = String()
    for _ in range(1100):
        deep += "["
    for _ in range(1100):
        deep += "]"
    refused(deep, "depth")


def json_key_order() raises:
    check(write_json(parse_json('{"b":1,"a":2}')) == '{"b":1,"a":2}', "key order")
    check(write_json(parse_json(' { "b" : 1 , "a" : [ 2 , 3 ] } ')) == '{"b":1,"a":[2,3]}', "spaces")


def json_big_ints_exact() raises:
    check(parse_json("18446744073709551615").uint() == UInt64.MAX, "u64 max")
    check(write_json(parse_json("18446744073709551615")) == "18446744073709551615", "u64 max text")
    check(parse_json("-9223372036854775808").int() == Int64.MIN, "i64 min")
    check(parse_json("9007199254740993").int() == 9007199254740993, "2^53 + 1 stays exact")
    # V8 and Go write large floats as bare digits: by default they read as that float.
    var big = parse_json("123456789012345680000")
    check(big.is_float() and big.float() == 1.2345678901234568e20, "a float in bare digits")
    # Ruby's bignums are refused, not turned into floats.
    refused("18446744073709551616", "beyond 64 bits", True)
    refused("[1, -9223372036854775809]", "beyond 64 bits", True)
    refused('{"n": -123456789012345678901234567890}', "beyond 64 bits", True)
    check(parse_json("18446744073709551615", True).uint() == UInt64.MAX, "u64 max is not refused")
    # Digits inside strings and in floats are not integers.
    check(parse_json('"123456789012345678901234567890"', True).is_string(), "digits in a string")
    check(parse_json("123456789012345678901234567890.5", True).is_float(), "a long float")


def json_markers() raises:
    var z = as_float(parse_json('{"$num":"-0"}'))
    check(z == 0.0 and (bits(z) >> 63) == 1, "-0 keeps its sign")
    check(isnan(as_float(parse_json('{"$num":"NaN"}'))), "NaN")
    var p = as_float(parse_json('{"$num":"Infinity"}'))
    var m = as_float(parse_json('{"$num":"-Infinity"}'))
    check(isinf(p) and p > 0 and isinf(m) and m < 0, "infinities")
    check(write_json(json_float(-0.0)) == '{"$num":"-0"}', "-0 writes a marker")
    check(write_json(json_float(nan[DType.float64]())) == '{"$num":"NaN"}', "NaN marker")
    check(write_json(json_float(-inf[DType.float64]())) == '{"$num":"-Infinity"}', "-inf marker")
    # A NaN built with Value(...) deep inside is still written as a marker, not as null.
    var a = Array()
    a.append(Value(1.5))
    a.append(Value(inf[DType.float64]()))
    var nested = write_json(Value(a^))
    check(nested == '[1.5,{"$num":"Infinity"}]', "nested inf: " + nested)
    var u = '{"$undefined":true}'
    check(write_json(parse_json(u)) == u, "$undefined stays an object")


def json_strings() raises:
    var s = r'"a\u0000b\"c\\d\n\t\u001f"'
    check(write_json(parse_json(s)) == s, "escapes: " + write_json(parse_json(s)))
    check(parse_json(r'"😀"').string() == "😀", "surrogate pair escapes decode")
    check(parse_json(r'"hé"').string() == "hé", "decodes")
    refused(r'"\ud800"', "unicode")


def json_rejects() raises:
    for bad in ["[1,]", '{"a"}', "01", "[1] x", "", '"abc', "tru", "[1 2]"]:
        var raised = False
        try:
            _ = parse_json(String(bad))
        except:
            raised = True
        check(raised, "accepted " + String(bad))


def main() raises:
    json_float_corpus()
    print("pass json_float_corpus")
    json_200_deep()
    print("pass json_200_deep")
    json_key_order()
    print("pass json_key_order")
    json_big_ints_exact()
    print("pass json_big_ints_exact")
    json_markers()
    print("pass json_markers")
    json_strings()
    print("pass json_strings")
    json_rejects()
    print("pass json_rejects")
    print("ok")
