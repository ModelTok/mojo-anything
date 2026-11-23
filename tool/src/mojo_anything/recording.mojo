# What a recording was made from, and the differences from it a port is allowed
# to keep (port of src/recording.rs): the original's fingerprint in
# `recorded-from.json`, the diff history behind `diff`'s trend, and the
# entries of `known-diffs.jsonl`. File names and JSON shapes are the Rust
# tool's.

from emberjson import Object, Value
from std.os import makedirs
from std.os.path import exists, isdir, isfile

from mojo_anything.json import parse_json
from mojo_anything.json_text import json_equal, write_compact, write_string
from mojo_anything.walk import walk

comptime RECORDED_FROM = "recorded-from.json"
comptime KNOWN_DIFFS = "known-diffs.jsonl"
comptime HISTORY = ".mojo-anything/diff-history.jsonl"
comptime STALL_AFTER = 3


def _fnv(mut hash: UInt64, bytes: Span[UInt8, _]):
    for b in bytes:
        hash ^= UInt64(b)
        hash *= 0x0000_0100_0000_01B3


def _hex16(x: UInt64) -> String:
    var digits = "0123456789abcdef".as_bytes()
    var out = String("")
    for i in range(16):
        var shift = UInt64(60 - 4 * i)
        out += String(chr(Int(digits[Int((x >> shift) & 15)])))
    return out


def _path_less(a: String, b: String) -> Bool:
    """Rust's `PathBuf` order: folder by folder."""
    var x = a.split("/")
    var y = b.split("/")
    for i in range(min(len(x), len(y))):
        if x[i] != y[i]:
            return String(x[i]) < String(y[i])
    return len(x) < len(y)


def _keep_source(path: String) -> Bool:
    var name = String(path[byte = path.rfind("/") + 1 :])
    return not (
        name == "node_modules"
        or name == "target"
        or name == ".git"
        or name == "__pycache__"
    )


def fingerprint(root: String, unit: String) -> Optional[Tuple[String, Int]]:
    """FNV-1a over the unit's files (relative path and contents, in path
    order): `(hash, files)`, or None when the unit is not there."""
    var path = root + "/" + unit
    var files = List[String]()
    if isfile(path):
        files.append(path)
    elif isdir(path):
        files = walk(path, _keep_source)
    else:
        return None
    for i in range(1, len(files)):
        var j = i
        while j > 0 and _path_less(files[j], files[j - 1]):
            files.swap_elements(j, j - 1)
            j -= 1
    var hash: UInt64 = 0xCBF2_9CE4_8422_2325
    var zero: List[UInt8] = [0]
    for f in files:
        var relative = f
        if f.startswith(root + "/"):
            relative = String(f[byte = root.byte_length() + 1 :])
        _fnv(hash, relative.as_bytes())
        _fnv(hash, zero)
        try:
            var bytes = open(f, "r").read_bytes()
            _fnv(hash, bytes)
        except:
            return None
        _fnv(hash, zero)
    return (_hex16(hash), len(files))


def save_fingerprint(crate_dir: String, root: String, unit: String) raises:
    """Saves the fingerprint of the original next to `cases.jsonl`."""
    var got = fingerprint(root, unit)
    if not got:
        return
    ref fp = got.value()
    var text = String('{\n  "unit": ') + write_string(unit)
    text += ',\n  "files": ' + String(fp[1])
    text += ',\n  "fingerprint": ' + write_string(fp[0]) + "\n}\n"
    var f = open(crate_dir + "/" + RECORDED_FROM, "w")
    f.write(text)
    f.close()


def _get(v: Value, key: String) -> Optional[Value]:
    if not v.is_object():
        return None
    ref o = v.object()
    if key not in o:
        return None
    try:
        return o[key].copy()
    except:
        return None


def _read(path: String) -> Optional[String]:
    if not isfile(path):
        return None
    try:
        return open(path, "r").read()
    except:
        return None


def stale(crate_dir: String, root: String, unit: String) -> Optional[String]:
    """Why the recording no longer describes the original: the unit's files
    changed since `record`. None when they did not, or when there is nothing
    to compare."""
    var text = _read(crate_dir + "/" + RECORDED_FROM)
    if not text:
        return None
    try:
        var saved = parse_json(text.value())
        var fp = _get(saved, "fingerprint")
        if not fp or not fp.value().is_string():
            return None
        var now = fingerprint(root, unit)
        if not now:
            return None
        if fp.value().string() == now.value()[0]:
            return None
    except:
        return None
    return String(
        unit,
        " changed since it was recorded: re-run `mojo-anything record ",
        crate_dir,
        "` so the port is checked against what the original does now",
    )


@fieldwise_init
struct Trend(Copyable, Movable):
    """Cases matching after each change to the port, oldest first (the last
    ten); `stalled` when the last `STALL_AFTER` changes gained nothing while
    cases still fail."""

    var passed: List[Int]
    var total: Int
    var stalled: Bool


def trend(passed: List[Int], total: Int) -> Trend:
    var n = len(passed)
    var stalled = False
    if n > STALL_AFTER and passed[n - 1] < total:
        var best = 0
        for i in range(n - STALL_AFTER):
            best = max(best, passed[i])
        stalled = True
        for i in range(n - STALL_AFTER, n):
            if passed[i] > best:
                stalled = False
    return Trend(passed=passed.copy(), total=total, stalled=stalled)


def _u64(v: Optional[Value]) -> Optional[Int]:
    if not v:
        return None
    ref x = v.value()
    if x.is_uint():
        return Int(x.uint())
    if x.is_int() and x.int() >= 0:
        return Int(x.int())
    return None


def track(crate_dir: String, passed: Int, total: Int) -> Optional[Trend]:
    """Records this diff when the port (`port.mojo`, or a Rust-era crate's
    `src/port.rs`) changed since the last one, and returns the trend."""
    var port: List[UInt8]
    try:
        if isfile(crate_dir + "/port.mojo"):
            port = open(crate_dir + "/port.mojo", "r").read_bytes()
        elif isfile(crate_dir + "/src/port.rs"):
            port = open(crate_dir + "/src/port.rs", "r").read_bytes()
        else:
            return None
    except:
        return None
    var hash: UInt64 = 0xCBF2_9CE4_8422_2325
    _fnv(hash, port)
    var port_hash = _hex16(hash)
    var path = crate_dir + "/" + HISTORY
    var ports = List[String]()
    var counts = List[Int]()
    var old = _read(path)
    if old:
        for raw in old.value().split("\n"):
            try:
                var r = parse_json(String(raw))
                var t = _u64(_get(r, "total"))
                if not t or t.value() != total:
                    continue
                var p = _get(r, "port")
                var c = _u64(_get(r, "passed"))
                ports.append(write_compact(p.value()) if p else String("null"))
                counts.append(c.value() if c else -1)
            except:
                continue
    var quoted = write_string(port_hash)
    if len(ports) > 0 and ports[len(ports) - 1] == quoted:
        counts[len(counts) - 1] = passed
    else:
        ports.append(quoted)
        counts.append(passed)
    var keep = max(len(ports) - 10, 0)
    var text = String("")
    var kept = List[Int]()
    for i in range(keep, len(ports)):
        text += String(
            '{"port":',
            ports[i],
            ',"passed":',
            counts[i],
            ',"total":',
            total,
            "}\n",
        )
        if counts[i] >= 0:
            kept.append(counts[i])
    try:
        makedirs(crate_dir + "/.mojo-anything", exist_ok=True)
        var f = open(path, "w")
        f.write(text)
        f.close()
    except:
        pass
    return trend(kept, total)


def last_diff(crate_dir: String) -> Optional[Tuple[Int, Int]]:
    var text = _read(crate_dir + "/" + HISTORY)
    if not text:
        return None
    var all = text.value()
    if all.endswith("\n"):
        var trimmed = String(all[byte = 0 : all.byte_length() - 1])
        all = trimmed^
    var at = all.rfind("\n")
    var line = String(all[byte = at + 1 :])
    try:
        var last = parse_json(line)
        var p = _u64(_get(last, "passed"))
        var t = _u64(_get(last, "total"))
        if p and t:
            return (p.value(), t.value())
    except:
        pass
    return None


def known_diffs(crate_dir: String) raises -> List[Value]:
    """The entries of `known-diffs.jsonl`: `{"fn", "args", "actual",
    "reason"}` per line. An entry without a reason is refused."""
    var path = crate_dir + "/" + KNOWN_DIFFS
    var out = List[Value]()
    var text = _read(path)
    if not text:
        return out^
    var n = 0
    for raw in text.value().split("\n"):
        n += 1
        var line = String(raw).strip()
        if line.byte_length() == 0 or line.startswith("//"):
            continue
        var entry: Value
        try:
            entry = parse_json(String(line))
        except e:
            raise Error(String(path, ":", n, ": not JSON: ", e))
        for key in ["fn", "args", "actual"]:
            if not _get(entry, key):
                raise Error(
                    String(path, ":", n, ": an entry needs `", key, "`")
                )
        var reason = _get(entry, "reason")
        if (
            not reason
            or not reason.value().is_string()
            or reason.value().string().strip().byte_length() == 0
        ):
            raise Error(
                String(
                    path,
                    ":",
                    n,
                    (
                        ": an entry needs a `reason`: why the port is meant to"
                        " differ here"
                    ),
                )
            )
        out.append(entry^)
    return out^


@fieldwise_init
struct DiffOutcome(Copyable, Movable):
    """The counts of a diff and its mismatches (`{"fn", "args", "expected",
    "actual"}`), as `harness::DiffOutcome` keeps them."""

    var total: Int
    var passed: Int
    var failed: Int
    var accepted: Int
    var mismatches: List[Value]
    var stale_known: List[Value]

    def __init__(out self, total: Int, passed: Int, failed: Int):
        self.total = total
        self.passed = passed
        self.failed = failed
        self.accepted = 0
        self.mismatches = List[Value]()
        self.stale_known = List[Value]()


def _same(a: Optional[Value], b: Optional[Value]) -> Bool:
    if not a or not b:
        return not a and not b
    return json_equal(a.value(), b.value())


def apply_known(var outcome: DiffOutcome, entries: List[Value]) -> DiffOutcome:
    """Counts the mismatches a known-diffs entry explains as passed, and lists
    the entries no mismatch matched. A mismatch is explained only when the
    port gives exactly the entry's `actual`."""
    if len(entries) == 0:
        return outcome^
    var used = List[Bool]()
    for _ in range(len(entries)):
        used.append(False)
    var left = List[Value]()
    for m in outcome.mismatches:
        var hit = -1
        for i in range(len(entries)):
            ref e = entries[i]
            if (
                _same(_get(e, "fn"), _get(m, "fn"))
                and _same(_get(e, "args"), _get(m, "args"))
                and _same(_get(e, "actual"), _get(m, "actual"))
            ):
                hit = i
                break
        if hit >= 0:
            used[hit] = True
        else:
            left.append(m.copy())
    var accepted = 0
    for u in used:
        if u:
            accepted += 1
    outcome.mismatches = left^
    outcome.accepted = accepted
    outcome.failed -= min(accepted, outcome.failed)
    outcome.passed += accepted
    for i in range(len(entries)):
        if used[i]:
            continue
        var o = Object()
        for key in ["fn", "args", "reason"]:
            var v = _get(entries[i], key)
            o[key] = v.value().copy() if v else Value(None)
        outcome.stale_known.append(Value(o^))
    return outcome^
