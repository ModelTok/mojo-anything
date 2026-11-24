# `bridge` and `refresh` of TypeScript and JavaScript units in Mojo
# (src/bridge.rs `bridge`, `bridge_mojo_node`, `mojo_node_bindings` and
# `refresh`, src/codegen_mojo_node.rs, src/ts/exports.rs and
# src/ts/jsdoc.rs read through oxc_reader.mjs): the Mojo binary runs next to
# the Phase 1 binary on copies of the same repository, and the two must agree
# on stdout, stderr, the exit code and every file written, byte for byte,
# with no fallback logged; the cases the Mojo tool does not answer must log
# one.

from std.python import Python, PythonObject
from std.testing import assert_equal, assert_true

comptime FALLBACK = "tool/fallback/mojo-anything"
comptime MOJO = "tool/build/mojo-anything"


def _py() raises -> PythonObject:
    var scope = Python.dict()
    _ = Python.import_module("builtins").exec(
        """
import os, shutil, subprocess, tempfile

BASE = os.path.join(tempfile.gettempdir(), "mojo-anything-test-bridge-ts-%d" % os.getpid())

def fixture(side, name, source, files):
    d = os.path.join(BASE, side, name)
    shutil.rmtree(d, ignore_errors=True)
    if source:
        shutil.copytree(source, d, symlinks=True)
    else:
        os.makedirs(d)
    for rel, text in files:
        p = os.path.join(d, rel)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, "w", newline="") as f:
            f.write(text)
    return d

def gone():
    shutil.rmtree(BASE, ignore_errors=True)

def tree(d):
    out = []
    for base, dirs, files in os.walk(d):
        for sub in dirs:
            out.append((os.path.relpath(os.path.join(base, sub), d) + "/", b""))
        for f in files:
            p = os.path.join(base, f)
            with open(p, "rb") as fh:
                out.append((os.path.relpath(p, d), fh.read().replace(d.encode(), b"<D>")))
    out.sort()
    return repr(out)

def run(binary, args, cwd, log):
    env = dict(os.environ)
    env.pop("MOJO_ANYTHING_FALLBACK_LOG", None)
    if log:
        if os.path.exists(log):
            os.remove(log)
        env["MOJO_ANYTHING_FALLBACK_LOG"] = log
    p = subprocess.run([os.path.abspath(binary)] + list(args), cwd=cwd, env=env,
                       stdin=subprocess.DEVNULL, capture_output=True, timeout=600)
    out = p.stdout.decode("utf-8", "replace").replace(cwd, "<D>")
    err = p.stderr.decode("utf-8", "replace").replace(cwd, "<D>")
    return (p.returncode, out, err)

def edit(d, rel, old, new):
    p = os.path.join(d, rel)
    with open(p) as f:
        text = f.read()
    assert old in text, (p, old)
    with open(p, "w", newline="") as f:
        f.write(text.replace(old, new))

def log_text(path):
    try:
        with open(path) as f:
            return f.read()
    except OSError:
        return ""
""",
        scope,
    )
    return scope


def _files(spec: List[String]) raises -> PythonObject:
    var out = Python.list()
    for s in spec:
        var eq = s.find("=")
        out.append(
            Python.tuple(
                PythonObject(String(s[byte=0:eq])),
                PythonObject(String(s[byte = eq + 1 :])),
            )
        )
    return out


def _again(
    t: PythonObject, name: String, old: String, new: String, args: List[String]
) raises -> String:
    """Runs both binaries in the two copies; returns the Mojo run's fallback
    log."""
    var pargs = Python.list()
    var shown = String(" in " + name + ":")
    for a in args:
        pargs.append(PythonObject(a))
        shown += " " + a
    var o = t["run"](
        PythonObject(FALLBACK), pargs, PythonObject(old), PythonObject("")
    )
    var log = new + ".fallback.log"
    var n = t["run"](
        PythonObject(MOJO), pargs, PythonObject(new), PythonObject(log)
    )
    assert_equal(String(py=n[1]), String(py=o[1]), "stdout of" + shown)
    assert_equal(String(py=n[2]), String(py=o[2]), "stderr of" + shown)
    assert_equal(Int(py=n[0]), Int(py=o[0]), "exit code of" + shown)
    assert_equal(
        String(py=t["tree"](PythonObject(new))),
        String(py=t["tree"](PythonObject(old))),
        "files of" + shown,
    )
    return String(py=t["log_text"](PythonObject(log)))


def _copies(
    t: PythonObject, name: String, source: String, spec: List[String]
) raises -> Tuple[String, String]:
    var files = _files(spec)
    var src = PythonObject(source)
    var old = String(
        py=t["fixture"](PythonObject("old"), PythonObject(name), src, files)
    )
    var new = String(
        py=t["fixture"](PythonObject("new"), PythonObject(name), src, files)
    )
    return (old, new)


def _both(
    t: PythonObject,
    name: String,
    source: String,
    spec: List[String],
    args: List[String],
) raises -> String:
    var c = _copies(t, name, source, spec)
    return _again(t, name, c[0], c[1], args)


def _owned(
    t: PythonObject,
    name: String,
    source: String,
    spec: List[String],
    args: List[String],
) raises:
    assert_equal(_both(t, name, source, spec, args), "", "fell back in " + name)


def _args(a: String, b: String) -> List[String]:
    var out = List[String]()
    out.append("bridge")
    out.append(a)
    out.append(b)
    return out^


def _with(var args: List[String], a: String, b: String) -> List[String]:
    args.append(a)
    args.append(b)
    return args^


def test_ts_fixtures_are_bridged_in_mojo() raises:
    """Functions, async functions, aliases resolved through imports and
    tsconfig, workspace packages, classes left in TS, and units with no
    export."""
    var t = _py()
    var none = List[String]()
    _owned(t, "lib", "tests/fixtures/lib", none, _args(".", "ts/src/nums.ts"))
    _owned(
        t, "aliases", "tests/fixtures/aliases", none, _args(".", "src/greet.ts")
    )
    _owned(
        t, "async", "tests/fixtures/async", none, _args(".", "src/pipeline.ts")
    )
    _owned(
        t, "classes", "tests/fixtures/classes", none, _args(".", "src/stats.ts")
    )
    _owned(
        t,
        "mini",
        "tests/fixtures/mini",
        none,
        _args(".", "packages/a/src/fs.ts"),
    )
    _owned(
        t,
        "monorepo",
        "tests/fixtures/monorepo",
        none,
        _args(".", "packages/a/src/index.ts"),
    )
    _owned(
        t,
        "floats",
        "tests/fixtures/wasm-floats",
        none,
        _args(".", "src/floats.ts"),
    )
    _owned(t, "cli", "tests/fixtures/cli", none, _args(".", "ts/tcli.js"))
    _owned(t, "http", "tests/fixtures/http", none, _args(".", "ts/"))


comptime _KINDS = """import type { Shape } from "./types";
import { Mode } from "./types";

/** Doubles `x`. */
export function double(x: number): number {
  return x * 2;
}

export const join = (parts: string[], sep?: string): string => parts.join(sep ?? ",");

export async function later(text: string): Promise<string> {
  return text;
}

export function all(...xs: number[]): number {
  return xs.length;
}

export function maybe(x: string | null, y: number | undefined): string[] | null {
  return null;
}

export function pick(m: Mode, s: Shape): "a" | "b" {
  return "a";
}

export function bounded<T extends number>(x: T): T {
  return x;
}

export function open<T>(x: T): T {
  return x;
}

export function shaped<T extends { n: number }>(x: T): number {
  return x.n;
}

export function apply(f: (x: number) => number): number {
  return f(1);
}

export function rx(r: RegExp): string {
  return r.source;
}

export function* gen(): Generator<number> {
  yield 1;
}

export function check(x: unknown): boolean {
  return x instanceof Date;
}

export function iter(xs: Iterable<number>): IterableIterator<number> {
  return xs[Symbol.iterator]() as IterableIterator<number>;
}

export function cb(h: Handler): void {}

export function data(r: Record<string, number>, j: any): object {
  return r;
}

function hidden(): void {}
const local = (x: number): number => x;
export { local as renamed, hidden };

export class Box {
  private v = 0;
  get(): number {
    return this.v;
  }
}

export class Maker {
  constructor(f: (x: number) => void) {}
}

export class Checker {
  is(x: unknown): boolean {
    return x instanceof Box;
  }
}

export class Wide {
  public n = 1;
  static of(): Wide {
    return new Wide();
  }
}
"""

comptime _TYPES = """export type Mode = "fast" | "slow";
export type Size = number;
export interface Shape {
  w: Size;
  h: Size;
}
export interface Handler {
  run(x: number): void;
}
"""

comptime _JS = """/**
 * @param {string} a
 * @param {number} [n]
 * @returns {string}
 */
function repeat(a, n) {
  return a.repeat(n ?? 1);
}

function typed(a, b) {
  return a + b;
}

function plain(x) {
  return x;
}

module.exports = { repeat, typed, plain };
"""

comptime _DTS = """export declare function typed(a: number, b: number): number;
export declare function plain(x: string): string;
export declare function plain(x: number): number;
"""


def test_exports_cross_as_bridge_rs_reads_them() raises:
    """Types of every shape `RType` maps, aliases and constraints resolved,
    the exports that stay in TS and why, classes, JSDoc and declaration-file
    types of JavaScript, and the unit as a folder."""
    var t = _py()
    var spec: List[String] = [
        'package.json={"name": "kinds"}\n',
        "src/kinds.ts=" + _KINDS,
        "src/types.ts=" + _TYPES,
        "src/js/lib.js=" + _JS,
        "src/js/lib.d.ts=" + _DTS,
        "src/js/View.vue=<template><p/></template>\n",
        "src/js/esm.mjs=export function twice(x) { return x * 2; }\n",
    ]
    _owned(t, "kinds", "", spec, _args(".", "src/kinds.ts"))
    _owned(t, "jsdoc", "", spec, _args(".", "src/js/lib.js"))
    _owned(t, "folder", "", spec, _args(".", "src/js/"))
    _owned(
        t,
        "as-json",
        "",
        spec,
        _with(_args(".", "src/kinds.ts"), "--as-json", "T"),
    )
    _owned(
        t,
        "keep",
        "",
        spec,
        _with(
            _with(_args(".", "src/kinds.ts"), "--keep", "double"),
            "--keep",
            "Box:hand-written",
        ),
    )
    _owned(
        t,
        "named",
        "",
        spec,
        _with(
            _with(_args(".", "src/kinds.ts"), "--name", "kinds-port"),
            "--out",
            "ports/k",
        ),
    )
    _owned(
        t, "wasm", "", spec, _with(_args(".", "src/kinds.ts"), "--kind", "wasm")
    )
    _owned(
        t, "node", "", spec, _with(_args(".", "src/kinds.ts"), "--kind", "node")
    )


def test_bridge_errors_match_the_phase1_binary() raises:
    """Two exports of one name, a unit whose every export stays in TS, a
    crate folder already in use, and a unit the plan keeps."""
    var t = _py()
    var dup: List[String] = [
        "package.json={}\n",
        "src/a.ts=export function f(x: number): number { return x; }\n",
        "src/b.ts=export function f(x: string): string { return x; }\n",
    ]
    _owned(t, "dup", "", dup, _args(".", "src/"))
    var only: List[String] = [
        "package.json={}\n",
        "src/a.ts=export function f(g: () => void): void {}\n",
    ]
    _owned(t, "only", "", only, _args(".", "src/a.ts"))
    var taken = only.copy()
    taken.append(
        "src/b.ts=export function g(x: number): number { return x; }\n"
    )
    taken.append("mojo/b-mojo/x=x\n")
    _owned(t, "taken", "", taken, _args(".", "src/b.ts"))
    var ui: List[String] = [
        "package.json={}\n",
        "src/App.tsx=export function App(): number { return 1; }\n",
    ]
    _owned(t, "ui", "", ui, _args(".", "src/App.tsx"))
    var force = _args(".", "src/App.tsx")
    force.append("--force")
    _owned(t, "ui-force", "", ui, force)


def test_refresh_regenerates_ts_bindings() raises:
    """`refresh` of the vercel-ms port, of a Node unit whose port changed,
    and of a wasm unit."""
    var t = _py()
    var dot = List[String]()
    dot.append("refresh")
    dot.append(".")
    _owned(t, "ms", "demo/real-world/vercel-ms-mojo", List[String](), dot)
    for kind in ["node", "wasm"]:
        var name = String("refresh-", kind)
        var c = _copies(t, name, "tests/fixtures/lib", List[String]())
        var bridge = _with(_args(".", "ts/src/nums.ts"), "--kind", kind)
        assert_equal(
            _again(t, name, c[0], c[1], bridge), "", "fell back in " + name
        )
        for side in [c[0], c[1]]:
            _ = t["edit"](
                PythonObject(side),
                PythonObject("mojo/nums-mojo/port.mojo"),
                PythonObject("raises -> Float64:"),
                PythonObject("raises -> String:"),
            )
        var r = List[String]()
        r.append("refresh")
        r.append("mojo/nums-mojo")
        assert_equal(_again(t, name, c[0], c[1], r), "", "fell back in " + name)


def test_what_is_not_ported_goes_to_the_phase1_binary() raises:
    """`--batch` of a TS unit."""
    var t = _py()
    var log = _both(
        t,
        "batch",
        "tests/fixtures/lib",
        List[String](),
        _with(_args(".", "ts/src/nums.ts"), "--batch", "clamp:x"),
    )
    assert_true(log != "", "--batch did not fall back")


def main() raises:
    test_ts_fixtures_are_bridged_in_mojo()
    test_exports_cross_as_bridge_rs_reads_them()
    test_bridge_errors_match_the_phase1_binary()
    test_refresh_regenerates_ts_bindings()
    test_what_is_not_ported_goes_to_the_phase1_binary()
    _ = _py()["gone"]()
    print("test_bridge_ts: 5 passed")
