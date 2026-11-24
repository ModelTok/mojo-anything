# `record` of Go and Ruby units (port of src/harness.rs `record` for those
# languages, src/harness_go.rs `record` with `build_driver`, `module_of`,
# `import_path` and `local_module_version`, src/codegen_go.rs `driver` and
# `qualify`, and src/harness_ruby.rs `record` with `driver_command`, `files`
# and src/codegen_ruby.rs `targets` and `driver`).
#
# The inputs are generate_cases' (harness_py.mojo `_generate` and `_given`,
# with the language's regex needles and no int-for-float cases); a Go
# recording builds the driver over the original package with `go build` in
# `.mojo-anything/go-original` and runs it on `{fn, args}` cases, a Ruby one
# runs the Rust tool's own driver (CODEC_RB and DRIVER_RB, embedded) with each
# package's source root on `-I`, under the same watchdog as Python's.
#
# Declined before anything is written (the Phase 1 binary records): a class in
# the manifest, a named type in a parameter (Rust reads it with the TS type
# reader), `pinned.json` or a pin flag, a Go unit path that is not plain
# (absolute, `.`/`..` components, `//`), an export or type naming the driver's
# placeholders, no `go` or `ruby` on PATH, a Ruby workspace the Mojo
# discovery declines, and what record_python declines.

from std.python import Python, PythonObject

from mojo_anything.analyze import helpers as analyze_helpers
from mojo_anything.analyze import ruby_workspace
from mojo_anything.codegen_go import results
from mojo_anything.codegen_mojo import Manifest, join
from mojo_anything.codegen_ruby import receiver
from mojo_anything.embedded import (
    go_driver,
    go_helpers,
    ruby_codec,
    ruby_driver,
)
from mojo_anything.fallback import fallback
from mojo_anything.harness import Gen
from mojo_anything.harness_py import (
    _case_limit,
    _c_pointers,
    _generate,
    _given,
    _helpers,
    _len,
    _plain_count,
)
from mojo_anything.json_text import write_string
from mojo_anything.recording import save_fingerprint
from mojo_anything.shape import DECLINE
from mojo_anything.tree_lang import tree_helpers

comptime _PY = """
import json, os, re, shutil, subprocess

def which(name):
    return shutil.which(name) is not None

def _plain_unit(unit):
    u = unit.rstrip("/")
    if not u or u.startswith("/") or "//" in u:
        return None
    if any(p in (".", "..") for p in u.split("/")):
        return None
    return u

def go_module_of(root, unit, th):
    # harness_go.rs `module_of` and `import_path`: ("ok", module_dir,
    # go_mod_text, module, import_path), ("error", message), ("decline",).
    u = _plain_unit(unit)
    if u is None:
        return ("decline",)
    unit_dir = root + "/" + u
    if os.path.isfile(unit_dir):
        unit_dir = os.path.dirname(unit_dir)
    d = unit_dir
    while True:
        go_mod = os.path.join(d, "go.mod") if d != "/" else "/go.mod"
        if os.path.exists(go_mod):
            try:
                with open(go_mod, "rb") as f:
                    text = f.read().decode("utf-8")
            except (OSError, UnicodeError):
                return ("decline",)
            path = th["_mod_directive"](text, "module")
            if path is None:
                return ("error", "no `module` line in %s" % go_mod)
            module = path.strip('"')
            rel = unit_dir[len(d):].lstrip("/") if d != "/" else unit_dir.lstrip("/")
            return ("ok", d, text, module, module + "/" + rel if rel else module)
        if d == "/":
            return ("error", "no go.mod above %s" % unit_dir)
        d = os.path.dirname(d)

def _local_module_version(module):
    if module.startswith("gopkg.in/"):
        m = module
        while m.endswith("-unstable"):
            m = m[: -len("-unstable")]
        k = m.rfind(".v")
        major = m[k + 2 :] if k >= 0 else None
    else:
        k = module.rfind("/v")
        major = module[k + 2 :] if k >= 0 else None
    if major is not None and re.fullmatch(r"\\+?[0-9]+", major) and int(major) < 2**64:
        return "v%d.0.0" % int(major)
    return "v0.0.0"

def cleanup(crate_dir):
    # harness.rs `record`: the last run's timed-out list and coverage go first.
    work = crate_dir + "/.mojo-anything"
    try:
        os.remove(work + "/timed-out.json")
    except OSError:
        pass
    shutil.rmtree(work + "/coverage", ignore_errors=True)

def _exit_text(rc):
    # ExitStatus's Display for a subprocess return code.
    if rc >= 0:
        return "exit status: %d" % rc
    from signal import Signals
    try:
        name = Signals(-rc).name
    except ValueError:
        name = ""
    return "signal: %d (%s)" % (-rc, name)

def record_go(slim, crate_dir, module_info, driver_text, limit, hp):
    # harness_go.rs `record`: ("ok", [indices left out]) or ("error", message).
    Failed = hp["Failed"]
    try:
        _, module_dir, go_mod, module, _ = module_info
        canon = os.path.realpath(crate_dir)
        d = canon + "/.mojo-anything/go-original"
        hp["_create_dir_all"](d)
        ver = hp["tree"]["_mod_directive"](go_mod, "go") or "1.21"
        text = "module %s/mojo-anything-driver\\n\\ngo %s\\n\\nrequire %s %s\\n\\nreplace %s => %s\\n" % (
            module, ver, module, _local_module_version(module), module,
            json.dumps(module_dir, ensure_ascii=False))
        hp["_write"](d + "/go.mod", text)
        try:
            with open(os.path.join(module_dir, "go.sum"), "rb") as f:
                hp["_write"](d + "/go.sum", f.read().decode("utf-8"))
        except (OSError, UnicodeError):
            pass
        hp["_write"](d + "/main.go", driver_text)
        binary = d + "/driver"
        env = dict(os.environ)
        env["GOWORK"] = "off"
        env["GOFLAGS"] = "-mod=mod"
        what = "go build (driver over the original package)"
        try:
            p = subprocess.run(["go", "build", "-o", binary, "."], cwd=d, env=env,
                               stdin=subprocess.DEVNULL, capture_output=True)
        except OSError as e:
            raise Failed("running %s: %s" % (what, hp["_io"](e)))
        if p.returncode != 0:
            tail = hp["_lines"](p.stderr.decode("utf-8", "replace"))[-30:]
            raise Failed("%s failed (%s):\\n%s" % (what, _exit_text(p.returncode), "\\n".join(tail)))
        work = hp["join"](crate_dir, ".mojo-anything")
        out = hp["join"](crate_dir, "cases.jsonl")
        timed = hp["record_cases"](slim, slim, work, out, "Go driver (record)",
                                   lambda inputs, part: [binary, "record", inputs, part],
                                   dict(os.environ), limit)
        return ("ok", timed)
    except Failed as e:
        return ("error", str(e))

def _depth_ok(line):
    # serde_json's recursion limit: 127 levels of arrays and objects.
    depth = 0
    in_str = False
    esc = False
    for c in line:
        if in_str:
            if esc:
                esc = False
            elif c == "\\\\":
                esc = True
            elif c == '"':
                in_str = False
        elif c == '"':
            in_str = True
        elif c in "[{":
            depth += 1
            if depth > 127:
                return False
        elif c in "]}":
            depth -= 1
    return True

def _path_key(p):
    return [c for c in p.split("/") if c not in ("", ".")]

def ruby_files(root, rels):
    # harness_ruby.rs `files` of the original: sorted as paths, once each.
    paths = sorted((root + "/" + r for r in rels), key=_path_key)
    out = []
    for p in paths:
        if not out or _path_key(out[-1]) != _path_key(p):
            out.append(p)
    return out

def record_ruby(texts, fns, crate_dir, includes, files, targets_text, driver_text, limit, hp):
    # harness_ruby.rs `record`: ("ok", [indices left out]) or ("error", message).
    Failed = hp["Failed"]
    try:
        work = hp["join"](crate_dir, ".mojo-anything")
        pending = work + "/recording.jsonl"
        out = hp["join"](crate_dir, "cases.jsonl")
        script = work + "/driver.rb"
        targets = work + "/targets.json"
        head = ["ruby", "-E", "UTF-8:UTF-8"] + ["-I" + i for i in includes] + [script, "record", targets]

        def argv_of(inputs, part):
            # driver_command writes the driver and its targets each time a
            # part starts: a recording with no case writes neither.
            hp["_create_dir_all"](work)
            hp["_write"](script, driver_text)
            hp["_write"](targets, targets_text)
            return head + [inputs, part, "0"] + list(files)

        timed = hp["record_cases"](texts, texts, work, pending, "ruby driver (record)",
                                   argv_of, dict(os.environ), limit)
        try:
            with open(pending, "rb") as f:
                text = f.read().decode("utf-8")
        except OSError as e:
            raise Failed(hp["_io"](e))
        except UnicodeError:
            raise Failed("stream did not contain valid UTF-8")
        recorded = set()
        for line in hp["_lines"](text):
            if not _depth_ok(line):
                continue
            try:
                c = json.loads(line)
            except ValueError:
                continue
            if isinstance(c, dict) and isinstance(c.get("fn"), str):
                recorded.add(c["fn"])
        for name in sorted(set(fns)):
            if name not in recorded:
                raise Failed("cannot encode recorded result for %s: no case could be written as JSON "
                             "(a binary String result?); kept the previous cases.jsonl" % name)
        try:
            os.rename(pending, out)
        except OSError as e:
            raise Failed("publishing %s: %s" % (out, hp["_io"](e)))
        return ("ok", timed)
    except Failed as e:
        return ("error", str(e))
"""


def _ffi() raises -> PythonObject:
    var scope = Python.dict()
    _ = Python.import_module("builtins").exec(_PY, scope)
    return scope


def _qualify(t: String) -> String:
    """codegen_go.rs `qualify`: the package's named types as `pkg.Name`."""
    var out = String("")
    var bytes = t.as_bytes()
    var prev: UInt8 = 32
    var start = 0
    var n = len(bytes)
    for i in range(n + 1):
        if i < n and (
            (bytes[i] >= 48 and bytes[i] <= 57)
            or (bytes[i] >= 65 and bytes[i] <= 90)
            or (bytes[i] >= 97 and bytes[i] <= 122)
            or bytes[i] == 95
        ):
            continue
        if i > start:
            var first = bytes[start]
            if first >= 65 and first <= 90 and prev != 46:
                out += "pkg."
            out += String(t[byte=start:i])
        if i < n:
            out += String(t[byte = i : i + 1])
            prev = bytes[i]
        start = i + 1
    return out^


def go_driver_text(m: Manifest, import_path: String) -> String:
    """codegen_go.rs `driver`: a `main` package calling the package's
    functions by name."""
    var cases = String("")
    var prepares = String("")
    for f in m.exports:
        var r = results(f)
        cases += String('\tcase "', f.name, '":\n')
        var args = List[String]()
        for i in range(len(f.params)):
            var t = _qualify(f.params[i].native_type.or_else("any"))
            cases += String(
                "\t\tvar a",
                i,
                " ",
                t,
                "\n\t\tif mojoAnythingDecode(argAt(args, ",
                i,
                "), &a",
                i,
                ") != nil {\n\t\t\treturn invalid\n\t\t}\n",
            )
            args.append(String("a", i))
        prepares += String('\tcase "', f.name, '":\n')
        for i in range(len(f.params)):
            var t = _qualify(f.params[i].native_type.or_else("any"))
            prepares += String(
                "\t\tvar a",
                i,
                " ",
                t,
                "\n\t\tif mojoAnythingDecode(argAt(args, ",
                i,
                "), &a",
                i,
                ") != nil {\n\t\t\treturn nil\n\t\t}\n",
            )
        var joined = join(args, ", ")
        prepares += String(
            "\t\treturn func() { pkg.", f.name, "(", joined, ") }\n"
        )
        var lhs = List[String]()
        for i in range(len(r.types)):
            lhs.append(String("r", i))
        if r.fallible:
            lhs.append("err")
        var call = String("pkg.", f.name, "(", joined, ")")
        if len(lhs) == 0:
            cases += String("\t\t", call, "\n")
        else:
            cases += String("\t\t", join(lhs, ", "), " := ", call, "\n")
        if r.fallible:
            cases += (
                "\t\tif err != nil {\n\t\t\treturn"
                ' map[string]any{"error": err.Error()}\n\t\t}\n'
            )
        var ok = String("nil")
        if len(r.types) == 1:
            ok = "mojoAnythingEncode(r0)"
        elif len(r.types) > 1:
            var parts = List[String]()
            for i in range(len(r.types)):
                parts.append(String("mojoAnythingEncode(r", i, ")"))
            ok = String("[]any{", join(parts, ", "), "}")
        cases += String('\t\treturn map[string]any{"ok": ', ok, "}\n")
    return (
        go_driver()
        .replace("IMPORT_PATH", import_path)
        .replace("// CASES\n", cases)
        .replace("// PREPARES\n", prepares)
        .replace("// HELPERS\n", go_helpers())
    )


def _targets(m: Manifest) -> String:
    """codegen_ruby.rs `targets` as serde_json writes it: an export met
    twice keeps its first place and takes the last value."""
    var names = List[String]()
    var values = List[String]()
    for f in m.exports:
        var rn = receiver(f)
        var v = String("[", write_string(rn[0]), ",", write_string(rn[1]), "]")
        var k = -1
        for i in range(len(names)):
            if names[i] == f.name:
                k = i
        if k >= 0:
            values[k] = v
        else:
            names.append(f.name)
            values.append(v)
    var out = String("{")
    for i in range(len(names)):
        if i > 0:
            out += ","
        out += write_string(names[i]) + ":" + values[i]
    return out + "}"


def _placeholders(m: Manifest) -> Bool:
    """Whether an export or a type names one of DRIVER_GO's placeholders
    (Rust replaces them one after another in the growing text)."""
    for f in m.exports:
        var texts: List[String] = [f.name, f.native_return.or_else("")]
        for p in f.params:
            texts.append(p.native_type.or_else(""))
        for t in texts:
            for needle in [
                "IMPORT_PATH",
                "// CASES",
                "// PREPARES",
                "// HELPERS",
            ]:
                if t.find(needle) >= 0:
                    return True
    return False


def record_ffi(
    m: Manifest,
    crate_dir: String,
    count_text: String,
    inputs: Optional[String],
    pin_clock: Int,
    argv: List[String],
) raises -> Int:
    """`record` of a Go or Ruby unit."""
    var count = _plain_count(count_text)
    var limit = _case_limit()
    if count < 0 or limit < 0.0 or pin_clock != 0 or len(m.classes) > 0:
        return fallback(argv)
    for f in m.exports:
        if _c_pointers(f.params):
            return fallback(argv)
    var go = m.language == "go"
    if go and _placeholders(m):
        return fallback(argv)
    var h = _helpers()
    var x = _ffi()
    if Bool(py=h["lexists"](PythonObject(crate_dir + "/pinned.json"))):
        return fallback(argv)
    if inputs:
        var r = h["read_inputs"](PythonObject(inputs.value()))
        if String(py=r[0]) == "decline":
            return fallback(argv)
    if not Bool(py=x["which"](PythonObject("go" if go else "ruby"))):
        return fallback(argv)
    var th = tree_helpers()
    var module_info = Python.none()
    var includes = Python.list()
    if go:
        module_info = x["go_module_of"](
            PythonObject(m.root), PythonObject(m.unit), th
        )
        if String(py=module_info[0]) == "decline":
            return fallback(argv)
    else:
        var ws = ruby_workspace(m.root, analyze_helpers())
        if ws.declined or len(ws.packages) == 0:
            return fallback(argv)
        for p in ws.packages:
            includes.append(
                h["join"](PythonObject(m.root), PythonObject(p.src_root))
            )
    var g = Gen(h["make_loader"](th))
    var texts = List[String]()
    var fns = List[String]()
    var shown = List[String]()
    var regex_functions = List[String]()
    try:
        _generate(m, h, g, count, texts, fns, shown, regex_functions)
    except e:
        if String(e) == DECLINE:
            return fallback(argv)
        raise e^
    if inputs:
        _given(m, h, inputs.value(), texts, fns, shown)
    _ = x["cleanup"](PythonObject(crate_dir))
    var r: PythonObject
    if go:
        if String(py=module_info[0]) == "error":
            raise Error(String(py=module_info[1]))
        var slim = Python.list()
        for i in range(len(fns)):
            slim.append(
                PythonObject(
                    String(
                        '{"fn":',
                        write_string(fns[i]),
                        ',"args":',
                        shown[i],
                        "}",
                    )
                )
            )
        h["tree"] = th
        r = x["record_go"](
            slim,
            PythonObject(crate_dir),
            module_info,
            PythonObject(go_driver_text(m, String(py=module_info[4]))),
            PythonObject(limit),
            h,
        )
    else:
        var pt = Python.list()
        var pf = Python.list()
        for i in range(len(texts)):
            pt.append(PythonObject(texts[i]))
            pf.append(PythonObject(fns[i]))
        var rels = Python.list()
        for f in m.exports:
            rels.append(PythonObject(f.file))
        for j in m.js_only:
            rels.append(PythonObject(j.file))
        r = x["record_ruby"](
            pt,
            pf,
            PythonObject(crate_dir),
            includes,
            x["ruby_files"](PythonObject(m.root), rels),
            PythonObject(_targets(m)),
            PythonObject(ruby_codec() + "\n" + ruby_driver()),
            PythonObject(limit),
            h,
        )
    if String(py=r[0]) != "ok":
        raise Error(String(py=r[1]))
    var timed = r[1]
    save_fingerprint(crate_dir, m.root, m.unit)
    var out = String(
        py=h["join"](PythonObject(crate_dir), PythonObject("cases.jsonl"))
    )
    var s = h["summarize"](PythonObject(out))
    print(
        String(
            "Recorded ",
            Int(py=s[0]),
            " cases (",
            Int(py=s[1]),
            " threw) in ",
            out,
        )
    )
    var per = s[2]
    for i in range(_len(per)):
        print(String("  ", String(py=per[i][0]), ": ", Int(py=per[i][1])))
    if len(regex_functions) > 0:
        print(
            "Regex traps (non-ASCII \\w, \\b and case folding) added for: "
            + join(regex_functions, ", ")
        )
    var n = _len(timed)
    if n > 0:
        print(
            String(
                "Left out ",
                n,
                (
                    " input(s) the original ran too long on (over the per-case"
                    " limit, MOJO_ANYTHING_CASE_TIMEOUT seconds, 10 by"
                    " default). The original does this itself, so the port"
                    " need not match it there:"
                ),
            )
        )
        for i in range(n):
            var k = Int(py=timed[i])
            print(String("  ", fns[k], "(", shown[k], ")"))
    return 0
