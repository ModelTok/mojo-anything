# `mojo-anything app record` (port of `record` in src/app.rs and its caller
# in src/main.rs). This slice answers the checks `record` makes before it runs
# anything (the folder, the command, the float files, the normalizers) with
# the Rust tool's errors; every recording that gets past them, and every
# option this port does not read yet (servers, effects, a database), goes to
# the Phase 1 binary before anything runs or is written.

from std.python import Python, PythonObject

from mojo_anything.app.cases import DECLINE, Config, decline, load_config
from mojo_anything.app.diff import Normalizers
from mojo_anything.app.py import py_helpers
from mojo_anything.cli_parse import Parsed
from mojo_anything.fallback import fallback


def _split_once(s: String, sep: String) -> Optional[Tuple[String, String]]:
    var at = s.find(sep)
    if at < 0:
        return None
    return (
        String(s[byte=0:at]),
        String(s[byte = at + sep.byte_length() :]),
    )


def _rsplit_once(s: String, sep: String) -> Optional[Tuple[String, String]]:
    var at = s.rfind(sep)
    if at < 0:
        return None
    return (
        String(s[byte=0:at]),
        String(s[byte = at + sep.byte_length() :]),
    )


def _float_width(format: String) raises:
    if format != "f32le" and format != "f64le":
        raise Error("float file format `" + format + "`: use f32le or f64le")


def check_record(h: PythonObject, p: Parsed) raises:
    """The Rust tool's `record` up to its first run: raises its error, or
    `DECLINE` once the arguments are good (the recording itself is the Phase 1
    binary's)."""
    for name in ["effects", "effect-env", "db-reset", "db-dump"]:
        if len(p.all(String(name))) > 0:
            raise decline()
    var given = p.value("REPO")
    var repo_arg = given.value() if given else String(".")
    var canon = h["canonical"](PythonObject(repo_arg))
    if String(py=canon[0]) == "odd":
        raise decline()
    if String(py=canon[0]) != "ok":
        raise Error("no folder " + repo_arg + ": " + String(py=canon[1]))
    var repo = String(py=canon[1])
    var existing = load_config(h, repo)
    var config = existing.value().copy() if existing else Config()
    if len(p.rest) == 0 and not existing:
        raise Error(
            "give the command that runs the original after `--`, e.g."
            " `mojo-anything app record . -- python3 cli.py`"
        )
    for n in p.all("normalize"):
        var pair = _split_once(n, "=")
        if pair:
            # A BTreeMap: one pattern per name, kept in name order.
            var name = pair.value()[0]
            var found = False
            for i in range(len(config.normalizer_names)):
                if config.normalizer_names[i] == name:
                    config.normalizer_patterns[i] = pair.value()[1]
                    found = True
            if not found:
                var at = 0
                while (
                    at < len(config.normalizer_names)
                    and config.normalizer_names[at] < name
                ):
                    at += 1
                config.normalizer_names.insert(at, name)
                config.normalizer_patterns.insert(at, pair.value()[1])
        elif not (n in config.normalize):
            config.normalize.append(n)
    if (
        p.flag("http")
        or p.value("port")
        or p.value("pace")
        or len(p.all("arg")) > 0
        or config.http
    ):
        raise decline()
    var tol = p.value("float-tolerance")
    if tol:
        var t = Float64(
            py=Python.import_module("builtins").float(PythonObject(tol.value()))
        )
        if not (t >= 0.0 and t < 1.0):
            raise decline()
        if t > 0.0:
            config.float_tolerance = t
        else:
            config.float_tolerance = None
    var files = p.all("float-file")
    for spec in files:
        var pair = _rsplit_once(spec, "=")
        if not pair:
            raise Error(
                "--float-file `" + spec + "`: use PATH=f32le or PATH=f64le"
            )
        _float_width(pair.value()[1])
    if len(files) > 0:
        config.float_files = False
    # The rest of the checks are Normalizers::new's.
    _ = Normalizers(h, config)
    raise decline()


def run_app_record(p: Parsed, argv: List[String]) raises -> Int:
    var h = py_helpers()
    try:
        check_record(h, p)
    except e:
        if String(e) == DECLINE:
            return fallback(argv)
        raise e
    return fallback(argv)
