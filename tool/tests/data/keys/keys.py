# A program printing JSON whose key order changes from run to run, for the
# `key-order` normalizer: `keys.py LINES DOC` prints one JSON object on stdout
# and writes LINES (JSON and other lines mixed) and DOC (a text that starts
# like JSON but is not). The order alternates with a counter kept in the file
# KEYS_COUNTER names, so two recordings of the same case see the same orders.
# V=1 gives other values; ODD=<name> prints one line serde_json may read
# otherwise than Python's json.
import os
import random
import sys

counter = os.environ.get("KEYS_COUNTER")
n = 0
if counter:
    try:
        with open(counter) as f:
            n = int(f.read() or "0")
    except OSError:
        n = 0
    with open(counter, "w") as f:
        f.write(str(n + 1))
rnd = random.Random(0)

A = [
    ("a", "1.0"),
    ("b", "-0"),
    ("c", "1e20"),
    ("d", "18446744073709551616"),
    ("e", "-9223372036854775809"),
    ("f", '"caf\\u00e9 \\u0001\\t\\ud83d\\ude00 \\/ é ¬ \\u007f"'),
    ("g", '{"z": [], "y": {}, "x": [1, {"q": 2, "p": [true, false]}]}'),
    ("h", "0.000001"),
    ("i", "1.5e-7"),
    ("j", "123456789.125"),
    ("k", "true"),
    ("l", "null"),
    ("Z", "-9223372036854775808"),
    ("é", "18446744073709551615"),
    ("m", "1E+2"),
    ("n", "0.1"),
    ("o", "1e16"),
    ("p", "12345678901234567"),
    ("q", "1e-5"),
    ("r", "5e-324"),
    ("s", "1.7976931348623157e308"),
    ("t", "-0.0"),
    ("u", "0e10"),
    ("w", "[" * 60 + "1" + "]" * 60),
]
B = [
    ("a", "2.0"),
    ("b", "0"),
    ("c", "1e21"),
    ("d", "18446744073709551617"),
    ("e", "-1"),
    ("f", '"\\u2028 \\" \\\\ \\b\\f\\n\\r"'),
    ("g", '{"z": [{}], "y": {"b": [], "a": {}}, "x": []}'),
    ("h", "0.0000001"),
    ("i", "-1.5e7"),
    ("j", "123456789.25"),
    ("k", "false"),
    ("l", '""'),
    ("Z", "9223372036854775807"),
    ("é", "-0.5"),
    ("m", "1E-2"),
    ("n", "0.3"),
    ("o", "1e15"),
    ("p", "123456789012345678"),
    ("q", "1e-4"),
    ("r", "2.2250738585072014e-308"),
    ("s", "-1.7976931348623157e308"),
    ("t", "4.35"),
    ("u", "100"),
    ("w", "[" * 61 + "]" * 61),
]
ODD = {
    "surrogate": '{"a": "\\ud800"}',
    "huge": '{"a": 1e400}',
    "huge-int": '{"a": ' + "9" * 400 + "}",
    "tiny": '{"a": 1e-400}',
    # Inside the object below: 127 and 128 levels in all.
    "deep-127": "[" * 126 + "]" * 126,
    "deep-128": "[" * 127 + "]" * 127,
}


def obj(pairs):
    pairs = list(pairs)
    rnd.shuffle(pairs)
    if n % 2:
        pairs.reverse()
    return "{" + ", ".join('"%s": %s' % (k, v) for k, v in pairs) + "}"


values = B if os.environ.get("V") == "1" else A
odd = os.environ.get("ODD")
if odd:
    # Two keys, so the two runs of a recording differ in order and the
    # normalizer reads the line.
    print(obj([("b", "1"), ("c", ODD[odd])]))
    sys.exit(0)
print("\n  " + obj(values).replace(", ", ",\n  ") + " \n")
small = obj(values[:3] + [("y", '{"b": 1, "a": 2}')])
lines = [
    "plain text",
    "  " + small + "  ",
    "[3, 1, 2]",
    "[..] not json",
    "{bad",
    '{"a":1}{"b":2}',
    "[NaN]",
    '{"dup": 1, "dup": 2, "a": 0}',
    "[" * 200 + "]" * 200,
    "\t[1.0, -0, 1e2]\r",
    "",
    "{}",
    "[]",
    " " + small,
]
with open(sys.argv[1], "w") as f:
    f.write("\n".join(lines) + "\n")
with open(sys.argv[2], "w") as f:
    f.write("[\n" + small + "\n,\n")
