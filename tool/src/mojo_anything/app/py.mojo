# The parts of `app record` and `app replay` that run through CPython (Mojo's
# Python interop): starting a case's program with its stdin, environment and
# working directory (`subprocess`, one thread per case as the Rust tool's
# `par_map`), walking and snapshotting the case's files, reading the trycmd
# files (`tomllib`), the JSON settings (`json`, refusing what serde_json reads
# otherwise) and the normalizers (`re`, refusing patterns whose meaning in
# Rust's `regex` could differ). Every decision about what the files mean and
# every text the tool writes stays in Mojo (`cases.mojo`, `diff.mojo`,
# `replay.mojo`).

from std.python import Python, PythonObject

comptime _SOURCE = """
import concurrent.futures, itertools, json, os, re, shutil, signal, subprocess
import threading, tomllib, unicodedata

FALLBACK_ENV = "MOJO_ANYTHING_FALLBACK_LOG"
_next = itertools.count()
_lock = threading.Lock()


def os_error(e):
    if e.errno is None:
        return str(e)
    return "%s (os error %d)" % (e.strerror, e.errno)


def tmp_root():
    t = os.environ.get("TMPDIR")
    return "/tmp" if t is None else t


def temp_dir(tag):
    with _lock:
        n = next(_next)
    d = os.path.join(tmp_root(), "mojo-anything-app-%s-%d-%d" % (tag, os.getpid(), n))
    shutil.rmtree(d, ignore_errors=True)
    os.makedirs(d, exist_ok=True)
    return d


def canonical(path):
    try:
        return ("ok", os.path.realpath(path, strict=True))
    except OSError as e:
        return ("err", os_error(e))


def is_file(path):
    return os.path.isfile(path)


def is_dir(path):
    return os.path.isdir(path)


def exists(path):
    return os.path.exists(path)


def path_key(rel):
    return rel.split("/")


def walk_files(root):
    # Regular files only (a symlink is neither), sorted as Rust sorts paths:
    # component by component.
    out = []
    stack = [root]
    while stack:
        d = stack.pop()
        try:
            it = os.scandir(d)
        except OSError:
            continue
        with it:
            for e in it:
                try:
                    if e.is_dir(follow_symlinks=False):
                        stack.append(e.path)
                    elif e.is_file(follow_symlinks=False):
                        out.append(e.path[len(root) + 1:])
                except OSError:
                    pass
    out.sort(key=path_key)
    return out


def read_files(base):
    files = {}
    for rel in walk_files(base):
        try:
            with open(os.path.join(base, rel), "rb") as f:
                files[rel] = f.read()
        except OSError:
            files[rel] = b""
    return files


def file_names(files):
    return list(files.keys())


def toml_files(dir):
    # (kind, names or error): the `.toml` files directly in `dir`, sorted.
    try:
        names = os.listdir(dir)
    except OSError as e:
        return ("err", os_error(e))
    out = []
    for n in names:
        stem, dot, ext = n.rpartition(".")
        if dot == "" or stem == "" or ext != "toml":
            continue
        if os.path.isfile(os.path.join(dir, n)):
            out.append(n)
    out.sort(key=lambda n: n.encode("utf-8", "surrogateescape"))
    return ("ok", out)


def read_bytes(path):
    try:
        with open(path, "rb") as f:
            return ("ok", f.read())
    except OSError as e:
        return ("err", os_error(e))


def read_text(path):
    # ("ok", text), ("err", message) or ("odd", "") for bytes that are not UTF-8.
    r = read_bytes(path)
    if r[0] != "ok":
        return r
    try:
        return ("ok", r[1].decode("utf-8"))
    except UnicodeDecodeError:
        return ("odd", "")


def write_bytes(path, data):
    try:
        with open(path, "wb") as f:
            f.write(data)
        return ""
    except OSError as e:
        return os_error(e)


def utf8(s):
    return s.encode("utf-8")


def text_of(b):
    # (True, text) for UTF-8 bytes, (False, "") otherwise.
    try:
        return (True, b.decode("utf-8"))
    except UnicodeDecodeError:
        return (False, "")


def same_bytes(a, b):
    return a == b


def length(x):
    return len(x)


def lossy_lines(b):
    text = b.decode("utf-8", "replace")
    out = []
    for line in text.split("\\n"):
        if line.endswith("\\r"):
            line = line[:-1]
        if line != "":
            out.append(line)
    return out


# --- TOML (the trycmd files) ------------------------------------------------


def load_toml(text):
    try:
        return ("ok", tomllib.loads(text))
    except Exception:
        return ("odd", None)


def _is_int(v):
    return isinstance(v, int) and not isinstance(v, bool)


def _get(d, key):
    if isinstance(d, dict):
        return d.get(key)
    return None


def spec_args(doc):
    # ("list", words), ("str", line), ("none", []) or ("odd", ...) for an array
    # holding anything but strings (toml_edit would print its TOML form).
    v = _get(doc, "args")
    if v is None:
        return ("none", [])
    if isinstance(v, list):
        if all(isinstance(x, str) for x in v):
            return ("list", v)
        return ("odd", [])
    if isinstance(v, str):
        return ("str", v)
    return ("odd", [])


def spec_str(doc, key):
    v = _get(doc, key)
    return (True, v) if isinstance(v, str) else (False, "")


def spec_bool(doc, key, default):
    v = _get(doc, key)
    return v if isinstance(v, bool) else default


def spec_env(doc):
    # (inherit, [(key, value)], [removed]); a non-string value is "" as in Rust.
    env = _get(doc, "env")
    if env is None:
        return (True, [], [])
    inherit = spec_bool(env, "inherit", True)
    add = []
    a = _get(env, "add")
    if isinstance(a, dict):
        for k, v in a.items():
            add.append((k, v if isinstance(v, str) else ""))
    remove = []
    r = _get(env, "remove")
    if isinstance(r, list):
        remove = [x for x in r if isinstance(x, str)]
    return (inherit, add, remove)


def spec_fs(doc):
    # (has_base, base, [removed paths])
    fs = _get(doc, "fs")
    base = _get(fs, "base")
    remove = []
    r = _get(fs, "remove")
    if isinstance(r, list):
        remove = [x for x in r if isinstance(x, str)]
    return (isinstance(base, str), base if isinstance(base, str) else "", remove)


def spec_status(doc):
    # ("code", n), ("success"|"failed"|"interrupted"|"skipped", 0) or ("unknown", 0)
    if not isinstance(doc, dict) or "status" not in doc:
        return ("code", 0)
    s = doc["status"]
    if isinstance(s, str) and s in ("success", "failed", "interrupted", "skipped"):
        return (s, 0)
    code = _get(s, "code")
    if _is_int(code):
        if -2147483648 <= code <= 2147483647:
            return ("code", code)
        return ("code", 2147483647)
    return ("unknown", 0)


# --- JSON (mojo-anything.json) ----------------------------------------------


class _Odd(Exception):
    pass


def _pairs(items):
    seen = {}
    for k, v in items:
        if k in seen:
            raise _Odd()
        seen[k] = v
    return seen


def _const(name):
    raise _Odd()


def _plain(v):
    # What serde_json reads the same: no lone surrogates, finite numbers.
    if isinstance(v, str):
        try:
            v.encode("utf-8")
        except UnicodeEncodeError:
            raise _Odd()
    elif isinstance(v, float):
        if v != v or v in (float("inf"), float("-inf")):
            raise _Odd()
    elif isinstance(v, list):
        for x in v:
            _plain(x)
    elif isinstance(v, dict):
        for k, x in v.items():
            _plain(k)
            _plain(x)


def _strs(v):
    return isinstance(v, list) and all(isinstance(x, str) for x in v)


def _str_map(v):
    return isinstance(v, dict) and all(isinstance(x, str) for x in v.values())


def load_config(text):
    # ("ok", config dict) or ("odd", None) for anything serde could read
    # otherwise or refuse (its error text is not reproduced).
    try:
        c = json.loads(text, object_pairs_hook=_pairs, parse_constant=_const)
        _plain(c)
    except Exception:
        return ("odd", None)
    if not isinstance(c, dict):
        return ("odd", None)
    if not isinstance(c.get("schema"), str) or not isinstance(c.get("name"), str):
        return ("odd", None)
    if not _strs(c.get("run")):
        return ("odd", None)
    for key, check in (("normalize", _strs), ("normalizers", _str_map), ("fresh", _strs),
                       ("float_files", _str_map)):
        if key in c and not check(c[key]):
            return ("odd", None)
    if "timeout_secs" in c:
        t = c["timeout_secs"]
        if not _is_int(t) or t < 0 or t >= 1 << 64:
            return ("odd", None)
    if "float_tolerance" in c and c["float_tolerance"] is not None:
        t = c["float_tolerance"]
        if isinstance(t, bool) or not isinstance(t, (int, float)):
            return ("odd", None)
    if "unordered" in c:
        u = c["unordered"]
        if not isinstance(u, dict) or not all(_strs(x) for x in u.values()):
            return ("odd", None)
    return ("ok", c)


def config_strs(c, key):
    return list(c.get(key) or [])


def config_map(c, key):
    # sorted by key, as a BTreeMap
    m = c.get(key) or {}
    return [(k, m[k]) for k in sorted(m, key=lambda k: k.encode("utf-8"))]


def config_unordered(c):
    m = c.get("unordered") or {}
    return [(k, list(m[k])) for k in sorted(m, key=lambda k: k.encode("utf-8"))]


def config_timeout(c):
    return c.get("timeout_secs", 30)


def config_present(c, key):
    return c.get(key) is not None


def config_tolerance(c):
    t = c.get("float_tolerance")
    if t is None:
        return (False, 0.0)
    return (True, float(t))


# --- normalizers ------------------------------------------------------------

_ODD_SYNTAX = re.compile(
    r"\\$|\\(\\?(?!:)|\\[\\[|\\[:|&&|--|~~|\\\\[pPzZAxuUQEkgG0-9]"
)
_COUNTED = re.compile(r"\\{(\\d+)(,(\\d*))?\\}")


def _braces_plain(p):
    i = 0
    while i < len(p):
        c = p[i]
        if c == "\\\\":
            i += 2
            continue
        if c == "{":
            m = _COUNTED.match(p, i)
            if m is None:
                return False
            i = m.end()
            continue
        if c == "}":
            return False
        i += 1
    return True


def compile_normalizer(pattern):
    # (True, compiled) when Python's `re` matches what Rust's `regex` matches
    # for this pattern; (False, None) otherwise: anchors and flags, classes and
    # escapes the two read differently, counted repetitions Rust refuses, and
    # anything that can match the empty string (the two replace empty matches
    # next to a match differently).
    if _ODD_SYNTAX.search(pattern) or not _braces_plain(pattern):
        return (False, None)
    try:
        compiled = re.compile(pattern)
        parser = getattr(re, "_parser", None)
        if parser is None:
            return (False, None)
        if parser.parse(pattern).getwidth()[0] == 0:
            return (False, None)
    except Exception:
        return (False, None)
    return (True, compiled)


def apply_normalizers(patterns, text):
    for p in patterns:
        text = p.sub("[..]", text)
    return text


def new_list():
    return []


def push(xs, x):
    xs.append(x)


# --- quoting ------------------------------------------------------------------

_LETTERS = ("Lu", "Ll", "Lt", "Lm", "Lo")
_NUMBERS = ("Nd", "Nl", "No")


def alnum_kind(c):
    # 1: alphanumeric for Rust's char::is_alphanumeric, 0: not, -1: Python's
    # Unicode tables cannot say for sure (Other_Alphabetic marks, symbols,
    # unassigned code points).
    cat = unicodedata.category(c)
    if c.isalnum():
        return 1 if cat in _LETTERS or cat in _NUMBERS else -1
    if cat in ("Mn", "Mc", "Me", "So", "Cn") or cat in _NUMBERS:
        return -1
    return 0


def word_kind(w):
    # 1: printed as it is by shell_quote, 0: quoted, -1: unsure
    if w == "":
        return 0
    plain = True
    for c in w:
        if c.isascii():
            if not (c.isalnum() or c in "-_./=:,+@%"):
                plain = False
            continue
        k = alnum_kind(c)
        if k < 0:
            return -1
        if k == 0:
            plain = False
    return 1 if plain else 0


def stable_paths(text):
    tmp = tmp_root().rstrip("/\\\\")
    if len(tmp) > 1:
        text = text.replace(tmp, "$TMPDIR")
    return re.sub(r"mojo-anything-app-(\\w+)-\\d+-\\d+", r"mojo-anything-app-\\1", text)


def percent(cases, total):
    return "%.1f" % (cases / max(total, 1) * 100.0)


def rate(cases, total):
    return cases / max(total, 1)


# --- running a case -------------------------------------------------------------


def resolve_word(repo, word):
    if word.startswith("-"):
        return word
    path = os.path.join(repo, word)
    looks = "/" in word or "\\\\" in word or os.path.isfile(path)
    if looks and os.path.exists(path):
        try:
            return os.path.realpath(path, strict=True)
        except OSError:
            return path
    return word


def _stamp(path):
    try:
        st = os.stat(path)
    except OSError:
        return None
    return (st.st_size, st.st_mtime_ns)


def _redact(data, forms):
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError:
        return data
    for f in forms:
        text = text.replace(f, "[CWD]")
    return text.encode("utf-8")


def run_in(job):
    (command, repo, args, stdin, env_add, env_remove, timeout, files_in, removes) = job
    sandbox = temp_dir("run")
    try:
        return _run_in(sandbox, command, repo, args, stdin, env_add, env_remove,
                       timeout, files_in, removes)
    finally:
        shutil.rmtree(sandbox, ignore_errors=True)


def _run_in(sandbox, command, repo, args, stdin, env_add, env_remove, timeout, files_in, removes):
    work = os.path.join(sandbox, "cwd")
    os.makedirs(work, exist_ok=True)
    for rel in removes:
        target = os.path.join(work, rel)
        if os.path.isdir(target):
            shutil.rmtree(target)
        elif os.path.exists(target):
            os.remove(target)
    for rel, data in files_in.items():
        target = os.path.join(work, rel)
        os.makedirs(os.path.dirname(target), exist_ok=True)
        with open(target, "wb") as f:
            f.write(data)
    before = {}
    for rel in walk_files(work):
        s = _stamp(os.path.join(work, rel))
        if s is not None:
            before[rel] = s
    log = os.path.join(sandbox, "fallback.log")
    argv = [resolve_word(repo, command[0])]
    argv += [resolve_word(repo, w) for w in command[1:]]
    argv += list(args)
    env = dict(os.environ)
    for k in env_remove:
        env.pop(k, None)
    for k, v in env_add:
        env[k] = v
    env[FALLBACK_ENV] = log
    try:
        child = subprocess.Popen(argv, cwd=work, env=env, stdin=subprocess.PIPE,
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                 process_group=0)
    except OSError as e:
        return {"error": "running `%s`: %s" % (" ".join(command), os_error(e))}
    status = None
    try:
        out, err = child.communicate(input=stdin, timeout=timeout)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(child.pid, signal.SIGKILL)
        except OSError:
            pass
        child.kill()
        out, err = child.communicate()
        status = ("timeout", 0)
    if status is None:
        rc = child.returncode
        status = ("killed", 0) if rc < 0 else ("code", rc)
    forms = [work]
    try:
        forms.insert(0, os.path.realpath(work, strict=True))
    except OSError:
        pass
    files = {}
    present = set()
    for rel in walk_files(work):
        present.add(rel)
        path = os.path.join(work, rel)
        stamp = before.get(rel)
        if stamp is not None and stamp == _stamp(path):
            continue
        try:
            with open(path, "rb") as f:
                data = f.read()
        except OSError:
            data = b""
        files[rel] = _redact(data, forms)
    removed = sorted((r for r in before if r not in present), key=path_key)
    try:
        fallback = os.stat(log).st_size > 0
        reported = True
    except OSError:
        fallback = False
        reported = False
    return {
        "error": "",
        "stdout": _redact(out, forms),
        "stderr": _redact(err, forms),
        "status": status,
        "files": files,
        "removed": removed,
        "reported": reported,
        "fallback": fallback,
    }



def new_job(command, repo, args, stdin, env_add, env_remove, timeout, files, removes):
    job = (tuple(command), repo, tuple(args), stdin, tuple(env_add),
           tuple(env_remove), float(timeout), files, removes)
    return job


def workers():
    try:
        n = len(os.sched_getaffinity(0))
    except (AttributeError, OSError):
        n = os.cpu_count() or 4
    return max(1, min(8, n))


def run_all(jobs):
    # Every case at once on up to 8 threads (the Rust tool's par_map), in order.
    with concurrent.futures.ThreadPoolExecutor(max_workers=workers()) as pool:
        futures = [pool.submit(run_in, j) for j in jobs]
        out = []
        for f in futures:
            try:
                out.append(f.result())
            except Exception as e:
                out.append({"error": "", "odd": str(e)})
        return out


def result_kind(r):
    if "odd" in r:
        return "odd"
    if r["error"]:
        return "error"
    return "ok"


def get(d, key):
    return d[key]


def has(d, key):
    return key in d
"""


def py_helpers() raises -> PythonObject:
    """The helper functions above, in a fresh scope."""
    var scope = Python.dict()
    _ = Python.import_module("builtins").exec(_SOURCE, scope)
    return scope


def py_len(x: PythonObject) raises -> Int:
    return Int(py=Python.import_module("builtins").len(x))


def py_strings(x: PythonObject) raises -> List[String]:
    """A Python list of str as a Mojo list."""
    var out = List[String]()
    for i in range(py_len(x)):
        out.append(String(py=x[i]))
    return out^


def py_list(items: List[String]) raises -> PythonObject:
    var out = Python.list()
    for s in items:
        out.append(PythonObject(s))
    return out
