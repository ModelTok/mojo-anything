# `analyze` and `map` of TypeScript and JavaScript workspaces in Mojo
# (src/ts/discover.rs, src/ts/scan.rs, src/ts/exports.rs, src/ts/jsdoc.rs,
# src/ts/tsconfig.rs and bridge::check_bridgeable, read from oxc's AST by
# oxc_reader.mjs on the project's Node): the Mojo binary runs next to the
# Phase 1 binary on copies of the same project, and the two must agree byte
# for byte with no fallback logged; what the reader cannot vouch for goes to
# the Phase 1 binary.

from std.python import Python, PythonObject
from std.testing import assert_equal


comptime FALLBACK = "tool/fallback/mojo-anything"
comptime MOJO = "tool/build/mojo-anything"


def _py() raises -> PythonObject:
    var scope = Python.dict()
    _ = Python.import_module("builtins").exec(
        """
import os, shutil, subprocess, tempfile

def fixture(side, name, files):
    base = os.path.join(tempfile.gettempdir(), "mojo-anything-test-analyze-ts-%d" % os.getpid(), side)
    d = os.path.join(base, name)
    shutil.rmtree(d, ignore_errors=True)
    os.makedirs(d)
    for rel, text in files:
        p = os.path.join(d, rel)
        if rel.endswith("/"):
            os.makedirs(p, exist_ok=True)
            continue
        os.makedirs(os.path.dirname(p), exist_ok=True)
        if text.startswith("b64:"):
            import base64
            with open(p, "wb") as f:
                f.write(base64.b64decode(text[4:]))
            continue
        with open(p, "w", newline="") as f:
            f.write(text)
    return d

def gone():
    shutil.rmtree(os.path.join(tempfile.gettempdir(), "mojo-anything-test-analyze-ts-%d" % os.getpid()),
                  ignore_errors=True)

def tree(d):
    out = []
    for base, dirs, files in os.walk(d):
        for f in files:
            p = os.path.join(base, f)
            if f.endswith(".fallback.log"):
                continue
            with open(p, "rb") as fh:
                out.append((os.path.relpath(p, d), fh.read()))
    out.sort()
    return repr(out)

def run(binary, args, cwd, log, path=None):
    env = dict(os.environ)
    env.pop("MOJO_ANYTHING_FALLBACK_LOG", None)
    if path is not None:
        env = {"PATH": path, "HOME": os.environ.get("HOME", "/")}
    if log:
        if os.path.exists(log):
            os.remove(log)
        env["MOJO_ANYTHING_FALLBACK_LOG"] = log
    p = subprocess.run([os.path.abspath(binary)] + list(args), cwd=cwd, env=env,
                       stdin=subprocess.DEVNULL, capture_output=True, timeout=600)
    out = p.stdout.decode("utf-8", "replace").replace(cwd, "<D>")
    err = p.stderr.decode("utf-8", "replace").replace(cwd, "<D>")
    import re
    err = re.sub(r"thread 'main' \\(\\d+\\)", "thread 'main'", err)
    return (p.returncode, out, err)

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
    """Pairs of (path, text) from `path=text` strings; `dir/` makes a folder."""
    var out = Python.list()
    for s in spec:
        var eq = s.find("=")
        if eq < 0:
            out.append(Python.tuple(PythonObject(s), PythonObject("")))
        else:
            out.append(
                Python.tuple(
                    PythonObject(String(s[byte=0:eq])),
                    PythonObject(String(s[byte = eq + 1 :])),
                )
            )
    return out


def _both(
    t: PythonObject,
    name: String,
    spec: List[String],
    args: List[String],
    path: String = "",
) raises -> String:
    """Runs both binaries on fresh copies of the project; returns the Mojo
    run's fallback log. A `path` runs the Mojo binary with only that PATH."""
    var files = _files(spec)
    var old = String(
        py=t["fixture"](PythonObject("old"), PythonObject(name), files)
    )
    var new = String(
        py=t["fixture"](PythonObject("new"), PythonObject(name), files)
    )
    var pargs = Python.list()
    var shown = String(" in " + name + ":")
    for a in args:
        pargs.append(PythonObject(a))
        shown += " " + a
    var o = t["run"](
        PythonObject(FALLBACK), pargs, PythonObject(old), PythonObject("")
    )
    var log = new + ".fallback.log"
    var p = PythonObject(None)
    if path != "":
        p = PythonObject(path)
    var n = t["run"](
        PythonObject(MOJO), pargs, PythonObject(new), PythonObject(log), p
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


def _both_ways(
    t: PythonObject, name: String, spec: List[String], args: List[String]
) raises:
    """Markdown and `--json`, both owned by Mojo."""
    assert_equal(_both(t, name, spec, args), "", "fell back in " + name)
    var j = args.copy()
    j.append("--json")
    assert_equal(_both(t, name, spec, j), "", "fell back in " + name)


comptime _TEXT = """import { readFileSync } from "node:fs";
import type { Options } from "./types";
import { shout } from "@util/shout";
import { other } from "~/other";
import chalk from "chalk";
import missing from "not-a-dependency";
export { tally } from "./tally";
export * from "./types";

/** Slug of `text`, at most `max` characters. */
export function slugify(text: string, max: number): string {
  let out = "";
  for (const c of text) {
    if (/[a-z0-9]/.test(c)) {
      out += c;
    }
  }
  return out.slice(0, max);
}

export function words(text: string): string[] {
  return text.split(/(?<=\\s)/u);
}

export const count = (xs: number[]): number => xs.length;

export async function load(path: string): Promise<string> {
  const data = await Promise.resolve(readFileSync(path, "utf8"));
  return JSON.parse(data);
}

export function* chunks(xs: number[], n: number): Generator<number[]> {
  for (let i = 0; i < xs.length; i += n) {
    yield xs.slice(i, i + n);
  }
}

export function any(x: any): Options {
  return x as Options;
}

export function call(f: (x: number) => number): number {
  return f(1);
}

export function risky(s: string, o: object): number {
  const m = new Map<string, number>();
  const keys = Object.keys(o);
  for (const k in o) {
    m.set(k, 1);
  }
  try {
    eval("1");
  } catch (e) {
    throw new Error("x");
  }
  const r = new RegExp(s, "d");
  s.codePointAt(0);
  s.matchAll(/a/g);
  r.lastIndex = 0;
  const t = Date.now() + Math.random();
  const n = parseInt(s) | 0;
  const w = (1.5).toFixed(1);
  Object.freeze(o);
  const p = new Proxy({}, {});
  if ("a" in o) {
    return keys.length;
  }
  let i = 0;
  while (i < 3) { i++; }
  do { i--; } while (i > 0);
  return n + t + shout(other) + chalk.length + missing;
}

export class Counter extends Base {
  private n = 0;
  constructor(start: number) {
    super();
    this.n = start;
  }
  next(): number {
    return ++this.n;
  }
  static of(n: number): Counter {
    return new Counter(n);
  }
}

class Base {}

export default function main(): void {}
"""

comptime _TYPES = """export interface Options {
  max: number;
  name?: string;
}

export type Mode = "a" | "b";

export function mode(m: Mode): Mode {
  return m;
}
"""

comptime _TALLY = """import { slugify } from "./text";

export function tally(xs: string[]): Record<string, number> {
  const out: Record<string, number> = {};
  for (const x of xs) {
    out[slugify(x, 10)] = (out[slugify(x, 10)] ?? 0) + 1;
  }
  return out;
}
"""

comptime _JSDOC = """// @ts-check
const path = require("path");

/**
 * Joins two parts.
 * @param {string} a
 * @param {string} b
 * @returns {string}
 */
function join(a, b) {
  return path.join(a, b);
}

/**
 * @param {number[]} xs
 * @returns {number}
 */
function sum(xs) {
  let s = 0;
  for (const x of xs) s += x;
  return s;
}

function untyped(x) {
  return x;
}

module.exports = { join, sum, untyped };
"""

comptime _TSCONFIG_BASE = """{
  // Shared options.
  "compilerOptions": {
    "baseUrl": ".",
    "paths": {
      "@util/*": ["src/util/*"],
      "~/*": ["src/*"],
    },
  },
}
"""


def test_ts_plans_match_the_phase1_binary() raises:
    """Packages, units, waves, cycles, risks, exports, bridgeability, tests,
    aliases and dependencies of TypeScript and JavaScript workspaces, in
    Markdown and JSON."""
    var t = _py()
    var dot: List[String] = ["analyze", "."]
    _both_ways(
        t,
        "lib",
        [
            (
                'package.json={"name": "textkit", "dependencies": {"chalk":'
                ' "5"}, "devDependencies": {"vitest": "1"}}\n'
            ),
            "tsconfig.base.json=" + _TSCONFIG_BASE,
            'tsconfig.json={"extends": "./tsconfig.base.json"}\n',
            "src/text.ts=" + _TEXT,
            "src/types.ts=" + _TYPES,
            "src/tally.ts=" + _TALLY,
            (
                "src/util/shout.ts=export function shout(s: string): string {"
                " return s.toUpperCase(); }\n"
            ),
            (
                'src/other.ts=import { tally } from "./tally";\nexport const'
                " other = 1;\n"
            ),
            "src/join.js=" + _JSDOC,
            "src/esm.mjs=export function twice(x) { return x * 2; }\n",
            (
                "test/text.test.ts=import { slugify } from"
                ' "../src/text";\nimport { it } from "vitest";\nit("slugs", ()'
                ' => slugify("a", 1));\n'
            ),
            'src/tally.spec.ts=import { tally } from "./tally";\ntally([]);\n',
            "dist/out.js=export const x = 1;\n",
            "node_modules/chalk/index.js=export default 1;\n",
            "src/types.d.ts=export declare function d(x: number): number;\n",
        ],
        dot,
    )
    _both_ways(
        t,
        "monorepo",
        [
            (
                'package.json={"name": "root", "private": true, "workspaces":'
                ' ["packages/*"]}\n'
            ),
            'packages/a/package.json={"name": "@m/a"}\n',
            (
                "packages/a/src/index.ts=export function a(x: number): number"
                " { return x + 1; }\n"
            ),
            (
                'packages/b/package.json={"name": "@m/b", "dependencies":'
                ' {"@m/a": "*"}}\n'
            ),
            (
                'packages/b/src/index.ts=import { a } from "@m/a";\nexport'
                " function b(x: number): number { return a(x) * 2; }\n"
            ),
            (
                'packages/b/test/b.test.ts=import { b } from "../src/index";\n'
                "b(1);\n"
            ),
            (
                'packages/c/package.json={"dependencies": {"@m/b": "*",'
                ' "react": "18"}}\n'
            ),
            (
                'packages/c/src/app.tsx=import { b } from "@m/b";\nexport'
                " function App() { return <div>{b(1)}</div>; }\n"
            ),
        ],
        dot,
    )
    _both_ways(
        t,
        "platforms",
        [
            'package.json={"name": "web"}\n',
            (
                "src/dom.ts=export function title(): string { return"
                " document.title + window.name; }\n"
            ),
            (
                'src/node.ts=import { join } from "path";\nexport function'
                " here(): string { return join(__dirname, process.cwd()); }\n"
            ),
            (
                "src/pure.ts=export function add(a: number, b: number): number"
                " { return a + b; }\n"
            ),
            (
                'src/ext.ts=import * as vscode from "vscode";\nexport function'
                ' show(): void { vscode.window.showInformationMessage("x");'
                " }\n"
            ),
            (
                'src/uses.ts=import { here } from "./node";\nexport function'
                " twice(): string { return here() + here(); }\n"
            ),
            "src/View.vue=<template><p/></template>\n",
            "src/Card.svelte=<script>export let x = 1;</script>\n<p>{x}</p>\n",
            "src/Page.jsx=export const Page = () => <p/>;\n",
            (
                "src/buf.ts=export function b(): number { return"
                ' Buffer.from("x").length + localStorage.length; }\n'
            ),
        ],
        dot,
    )
    _both_ways(
        t,
        "parse-errors",
        [
            'package.json={"name": "bad"}\n',
            "src/bad.ts=export function f(x: number { return x; }\n",
            "src/good.ts=export function g(x: number): number { return x; }\n",
        ],
        dot,
    )
    var many = List[String]()
    many.append('package.json={"name": "many"}\n')
    for i in range(12):
        var body = String(
            "export function f", i, "(s: string): string {\n  let t = s;\n"
        )
        for _ in range(i * 3):
            body += "  t = t.slice(1) + t.toLowerCase();\n"
        body += "  return t;\n}\n"
        many.append(String("src/m", i, "/index.ts=") + body)
    _both_ways(t, "many", many, dot)
    _both_ways(
        t,
        "lang-flag",
        [
            "go.mod=module x\n",
            "a.ts=export function f(x: number): number { return x; }\n",
        ],
        ["analyze", ".", "--lang", "ts"],
    )
    _both_ways(
        t,
        "unreadable",
        [
            "package.json={}\n",
            "bad.ts=b64:ZXhwb3J0IGNvbnN0IHggPSAi/yI7Cg==",
            "good.ts=export function f(x: number): number { return x; }\n",
        ],
        dot,
    )


def test_out_writes_a_ts_plan() raises:
    var t = _py()
    assert_equal(
        _both(
            t,
            "out",
            [
                "package.json={}\n",
                "a.ts=export function f(x: number): number { return x; }\n",
            ],
            ["analyze", ".", "-o", "plan.md"],
        ),
        "",
        "fell back in out",
    )


def test_ts_maps_match_the_phase1_binary() raises:
    """`map` reads the same plan."""
    var t = _py()
    var spec: List[String] = [
        'package.json={"name": "m"}\n',
        (
            'src/a.ts=import { b } from "./b";\nexport function a(x: number):'
            " number { return b(x); }\n"
        ),
        "src/b.ts=export function b(x: number): number { return x; }\n",
        "src/c.ts=export function c(): string { return document.title; }\n",
    ]
    _both_ways(t, "map", spec, ["map", "."])


def test_what_the_reader_cannot_vouch_for_goes_to_the_phase1_binary() raises:
    """Decorators, a tsconfig the JSON5 screen rejects and a package.json
    serde_json would not read the same way."""
    var t = _py()
    var cases = List[Tuple[String, String]]()
    cases.append(
        (
            "decorator",
            "package.json={}\n|a.ts=@sealed\nexport class A { m(): void {} }\n",
        )
    )
    cases.append(
        (
            "tsconfig",
            (
                'package.json={}\n|tsconfig.json={"compilerOptions": {"paths":'
                ' {"@\u00e9/*": ["src/*"]}}}\n|a.ts=import { y } from'
                ' "lib/b";\nexport const x = y;\n|b.ts=export const y = 1;\n'
            ),
        )
    )
    cases.append(("bad-json", "package.json={\n|a.ts=export const x = 1;\n"))
    for c in cases:
        var spec = List[String]()
        for part in c[1].split("|"):
            spec.append(String(part))
        var log = _both(t, c[0], spec, ["analyze", "."])
        assert_equal(log, "analyze .\n", "fallback of " + c[0])


def test_an_older_node_leaves_it_to_the_phase1_binary() raises:
    """With only the system's PATH, whose Node (18 on Ubuntu 24.04) is older
    than oxc-parser supports, the reader does not run, and the command goes
    to the Phase 1 binary, which answers it."""
    var t = _py()
    var log = _both(
        t,
        "no-node",
        [
            "package.json={}\n",
            "a.ts=export function f(x: number): number { return x; }\n",
        ],
        ["analyze", "."],
        "/usr/bin:/bin",
    )
    assert_equal(log, "analyze .\n", "fallback with an older node")


def test_review_findings_match_the_phase1_binary() raises:
    """Review of 8a5790e..f7e2382: names in a dotted namespace and an
    import type's qualifier are not references, an interface's heritage is
    a type name, and a bare import of a root package with no `src` finds
    no types (Rust looks for it at the filesystem root)."""
    var t = _py()
    var dot: List[String] = ["analyze", "."]
    _both_ways(
        t,
        "names",
        [
            'package.json={"name": "proj"}\n',
            (
                "src/a.ts=export namespace process.tools { export const v = 1"
                " }\nexport function add(a: number, b: number): number {"
                " return a + b; }\n"
            ),
            (
                'src/b.ts=export function f(x: import("./c").window.Opts):'
                " number { return 1; }\n"
            ),
            "src/c.ts=export namespace window { export interface Opts {} }\n",
            "src/d.ts=export interface M extends ns.lastIndex {}\n",
        ],
        dot,
    )
    _both_ways(
        t,
        "root-import",
        [
            'package.json={"name": "proj"}\n',
            "index.ts=export interface Hooks { run: () => void }\n",
            (
                'lib/use.ts=import type { Hooks } from "proj";\nexport function'
                " count(h: Hooks): number { return 1; }\n"
            ),
        ],
        dot,
    )


def main() raises:
    test_review_findings_match_the_phase1_binary()
    test_ts_plans_match_the_phase1_binary()
    test_out_writes_a_ts_plan()
    test_ts_maps_match_the_phase1_binary()
    test_what_the_reader_cannot_vouch_for_goes_to_the_phase1_binary()
    test_an_older_node_leaves_it_to_the_phase1_binary()
    _ = _py()["gone"]()
    print("test_analyze_ts: 6 passed")
