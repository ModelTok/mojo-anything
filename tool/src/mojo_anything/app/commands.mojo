# `mojo-anything app record` and `app replay` (main.rs `run_app`): the
# settings first (record.mojo, replay.mojo), then a CLI's cases, a server's
# (server.mojo) or a library's units (library.mojo), and the outcome printed
# as the Rust tool prints it. Anything
# this port cannot answer exactly runs the Phase 1 binary.

from std.python import Python, PythonObject

from mojo_anything.app.cases import DECLINE
from mojo_anything.app.py import py_helpers
from mojo_anything.app.library import library_helpers
from mojo_anything.app.library import replay as replay_library
from mojo_anything.app.py_server import server_helpers
from mojo_anything.app.record import (
    outcome_json as record_json,
    record,
    record_setup,
    say_record,
)
from mojo_anything.app.replay import (
    Options,
    Outcome,
    outcome_json as replay_json,
    replay,
    replay_setup,
    say_replay,
)
from mojo_anything.app.server import record as record_server
from mojo_anything.app.server import replay as replay_server
from mojo_anything.cli_parse import Parsed
from mojo_anything.fallback import fallback


def _helpers() raises -> PythonObject:
    var h = py_helpers()
    server_helpers(h)
    library_helpers(h)
    return h


def run_app_record(p: Parsed, argv: List[String]) raises -> Int:
    """`mojo-anything app record`."""
    var h = _helpers()
    try:
        var s = record_setup(h, p)
        var outcome = record_server(h, p, s) if s.config.http else record(
            h, p, s
        )
        if p.flag("json"):
            print(record_json(outcome))
        else:
            print(say_record(outcome), end="")
        return 0
    except e:
        if String(e) == DECLINE:
            return fallback(argv)
        raise e


def run_app_replay(p: Parsed, argv: List[String]) raises -> Int:
    """`mojo-anything app replay`: the Rust tool's output, exit 1 on any
    mismatch."""
    var builtins = Python.import_module("builtins")
    var timeout: Optional[Int] = None
    var t = p.value("timeout")
    if t:
        var v = builtins.int(PythonObject(t.value()))
        if Bool(py=v > PythonObject(Int(Int64.MAX))):
            return fallback(argv)
        timeout = Int(py=v)
    var port: Optional[Int] = None
    var given_port = p.value("port")
    if given_port:
        port = Int(py=builtins.int(PythonObject(given_port.value())))
    var repo = String(".")
    var given = p.value("REPO")
    if given:
        repo = given.value()
    var opts = Options(repo, p.value("build"), timeout, p.value("case"))
    var h = _helpers()
    try:
        var s = replay_setup(h, opts)
        var outcome: Outcome
        if s.is_library():
            outcome = replay_library(h, s.repo, s.library, opts.only)
        elif s.config.http:
            outcome = replay_server(h, s, port, opts.only)
        else:
            outcome = replay(h, opts, s)
        if p.flag("json"):
            print(replay_json(h, outcome))
        else:
            print(say_replay(h, outcome), end="")
        return 1 if len(outcome.failures) > 0 else 0
    except e:
        if String(e) == DECLINE:
            return fallback(argv)
        raise e
