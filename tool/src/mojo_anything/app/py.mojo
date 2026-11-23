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
    # ("odd", "") for what Rust's canonicalize may resolve otherwise: an empty
    # path, a trailing slash after something that is not a folder.
    if path == "" or (path.endswith("/") and not os.path.isdir(path)):
        return ("odd", "")
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
    # Rust strips the root by components: `fixture/` and `fixture` give the same names.
    cut = len(root.rstrip("/")) + 1
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
                        out.append(e.path[cut:])
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


def names_plain(names):
    # Whether every name is UTF-8 (a name Python decoded with surrogates is
    # one Rust would print lossily, in its own way).
    for n in names:
        try:
            n.encode("utf-8")
        except UnicodeEncodeError:
            return False
    return True


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
    # str::lines: `\\r` goes only with the `\\n` after it.
    text = b.decode("utf-8", "replace")
    parts = text.split("\\n")
    out = []
    for i, line in enumerate(parts):
        if i + 1 < len(parts) and line.endswith("\\r"):
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


def _int(s):
    # serde_json reads `-0` as a float, which a u64 field refuses.
    if s == "-0":
        raise _Odd()
    return int(s)


def load_config(text):
    # ("ok", config dict) or ("odd", None) for anything serde could read
    # otherwise or refuse (its error text is not reproduced), and for a
    # server's or an effects recording, which this port does not replay.
    try:
        c = json.loads(text, object_pairs_hook=_pairs, parse_constant=_const,
                       parse_int=_int)
        _plain(c)
    except Exception:
        return ("odd", None)
    if not isinstance(c, dict):
        return ("odd", None)
    if c.get("http") is not None or c.get("effects") is not None:
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
        try:
            if float(t) in (float("inf"), float("-inf")):
                return ("odd", None)
        except OverflowError:
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

_COUNTED = re.compile(r"\\{(\\d+)(,(\\d*))?\\}")
_PLAIN_ESCAPES = "dDwWsSbBntrfva"
_CLASS_ESCAPES = "dDwWsSntrfva"
_KINDS = {"w": "word", "W": "word", "b": "word", "B": "word",
          "s": "space", "S": "space", "d": "digit", "D": "digit"}


def _screen(p):
    # The Unicode classes a pattern uses ({"word", "space", "digit"}), or None
    # when Rust's `regex` could read it otherwise than Python's `re` or refuse
    # it: `$`, flags and lookaround, `\\<`, `\\N{...}`, escaped letters and
    # digits beyond the shared ones, escaped non-ASCII, nested classes and set
    # operations, possessive quantifiers, counts Rust refuses or finds too big.
    kinds = set()
    i = 0
    n = len(p)
    quantified = False
    while i < n:
        c = p[i]
        if c == "\\\\":
            if i + 1 >= n:
                return None
            x = p[i + 1]
            if x.isascii() and x.isalnum():
                if x not in _PLAIN_ESCAPES:
                    return None
                if x in _KINDS:
                    kinds.add(_KINDS[x])
            elif not x.isascii() or x in "<>":
                return None
            i += 2
            quantified = False
            continue
        if c == "[":
            i += 1
            if i < n and p[i] == "^":
                i += 1
            if i < n and p[i] == "]":
                i += 1
            while True:
                if i >= n:
                    return None
                c = p[i]
                if c == "]":
                    break
                if c == "[" or p.startswith(("&&", "--", "~~"), i):
                    return None
                if c == "\\\\":
                    if i + 1 >= n:
                        return None
                    x = p[i + 1]
                    if x.isascii() and x.isalnum():
                        if x not in _CLASS_ESCAPES:
                            return None
                        if x in _KINDS:
                            kinds.add(_KINDS[x])
                    elif not x.isascii():
                        return None
                    i += 2
                    continue
                i += 1
            i += 1
            quantified = False
            continue
        if c == "$":
            return None
        if c == "(":
            if p.startswith("(?", i) and not p.startswith("(?:", i):
                return None
            i += 1
            quantified = False
            continue
        if c == "{":
            m = _COUNTED.match(p, i)
            if m is None:
                return None
            for g in (m.group(1), m.group(3)):
                if g and int(g) > 1000:
                    return None
            i = m.end()
            quantified = True
            continue
        if c == "}":
            return None
        if c in "*+?":
            if c == "+" and quantified:
                return None
            # `*?`, `+?` are lazy in both; a `?` after a quantifier ends it.
            quantified = not (c == "?" and quantified)
            i += 1
            continue
        quantified = False
        i += 1
    return kinds


def compile_normalizer(pattern):
    # (True, compiled, kinds) when Python's `re` matches what Rust's `regex`
    # matches for this pattern on ASCII text and on text whose characters
    # both classify alike (`text_safe`); (False, None, None) otherwise, and
    # for anything that can match the empty string (the two replace empty
    # matches next to a match differently).
    kinds = _screen(pattern)
    if kinds is None:
        return (False, None, None)
    try:
        compiled = re.compile(pattern)
        parser = getattr(re, "_parser", None)
        if parser is None:
            return (False, None, None)
        if parser.parse(pattern).getwidth()[0] == 0:
            return (False, None, None)
    except Exception:
        return (False, None, None)
    return (True, compiled, kinds)


_RUST_SPACE = set("\\t\\n\\x0b\\x0c\\r \\x85\\xa0\\u1680\\u2028\\u2029\\u202f\\u205f\\u3000") | set(
    chr(c) for c in range(0x2000, 0x200B))
_OTHER_ALPHABETIC_SYMBOLS = ((0x24B6, 0x24E9), (0x1F130, 0x1F149), (0x1F150, 0x1F169),
                             (0x1F170, 0x1F189))
_alike = {}


def _rust_word(c):
    cat = unicodedata.category(c)
    if cat == "Cn":
        return None
    if cat[0] in "LM" or cat in ("Nd", "Nl", "Pc") or c in "\\u200c\\u200d":
        return True
    o = ord(c)
    return any(lo <= o <= hi for lo, hi in _OTHER_ALPHABETIC_SYMBOLS)


def _classify_alike(c, kinds):
    key = (c, kinds)
    if key in _alike:
        return _alike[key]
    same = True
    if unicodedata.category(c) == "Cn":
        same = False
    if "word" in kinds and same:
        same = _rust_word(c) == (re.match(r"\\w", c) is not None)
    if "space" in kinds and same:
        same = (c in _RUST_SPACE) == (re.match(r"\\s", c) is not None)
    if "digit" in kinds and same:
        same = (unicodedata.category(c) == "Nd") == (re.match(r"\\d", c) is not None)
    _alike[key] = same
    return same


def merge_kinds(a, b):
    return frozenset(a) | frozenset(b)


def no_kinds():
    return frozenset()


def text_safe(kinds, text):
    # Whether every character a `\\w`, `\\b`, `\\s` or `\\d` of the patterns
    # could meet is classified by Python's `re` as Rust's `regex` does.
    if not kinds:
        return True
    for c in set(text):
        o = ord(c)
        if o < 0x1C or (0x20 <= o < 0x80):
            continue
        if not _classify_alike(c, kinds):
            return False
    return True


def blob_safe(kinds, b):
    try:
        return text_safe(kinds, b.decode("utf-8"))
    except UnicodeDecodeError:
        return True


def apply_normalizers(patterns, kinds, text):
    # (True, text) or (False, "") when Rust could normalise this text otherwise.
    if not text_safe(kinds, text):
        return (False, "")
    for p in patterns:
        text = p.sub("[..]", text)
    return (True, text)


def safe_word(w):
    # Rust's Command takes these; Python refuses a NUL.
    return "\\x00" not in w


def safe_env_key(k):
    return k != "" and "=" not in k and "\\x00" not in k


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


class _CopyError(Exception):
    pass


def _copy_tree(src, dst):
    # http.rs copy_tree: folders made, files copied with their permissions
    # (std::fs::copy); a failed copy names both paths.
    if os.path.isdir(src):
        os.makedirs(dst, exist_ok=True)
        for name in os.listdir(src):
            _copy_tree(os.path.join(src, name), os.path.join(dst, name))
    else:
        parent = os.path.dirname(dst)
        if parent:
            os.makedirs(parent, exist_ok=True)
        try:
            shutil.copyfile(src, dst)
            shutil.copymode(src, dst)
        except OSError as e:
            raise _CopyError("copying %s to %s: %s" % (src, dst, os_error(e)))


def copy_tree(src, dst):
    # "" or the error the Rust tool prints.
    try:
        _copy_tree(src, dst)
        return ""
    except _CopyError as e:
        return str(e)
    except OSError as e:
        return os_error(e)


def run_in(job):
    (command, repo, args, stdin, env_add, env_remove, timeout, files_in, removes, base) = job
    sandbox = temp_dir("run")
    try:
        return _run_in(sandbox, command, repo, args, stdin, env_add, env_remove,
                       timeout, files_in, removes, base)
    finally:
        shutil.rmtree(sandbox, ignore_errors=True)


def _run_in(sandbox, command, repo, args, stdin, env_add, env_remove, timeout, files_in, removes,
            base):
    work = os.path.join(sandbox, "cwd")
    os.makedirs(work, exist_ok=True)
    if base is not None:
        # Any failure is a Python exception here, which declines.
        _copy_tree(base, work)
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
                                 process_group=0, close_fds=False)
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
        if stamp is not None and rel not in files_in and base is not None:
            # Rewritten with the bytes the snapshot holds: not a written file.
            try:
                with open(os.path.join(base, rel), "rb") as f:
                    if f.read() == data:
                        continue
            except OSError:
                pass
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



def new_job(command, repo, args, stdin, env_add, env_remove, timeout, files, removes,
            base=None):
    job = (tuple(command), repo, tuple(args), stdin, tuple(env_add),
           tuple(env_remove), float(timeout), files, removes, base)
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
    if not names_plain(r["files"].keys()) or not names_plain(r["removed"]):
        return "odd"
    return "ok"


def get(d, key):
    return d[key]


def has(d, key):
    return key in d


# --- recording -------------------------------------------------------------------

_DOC_SKIP = ("node_modules", "target", "vendor", ".git")


def doc_links(repo):
    # Whether a symlink named like a doc (`.md`, `.markdown`, `.sh`) lies within
    # the four levels the example scan reads: the Rust walk reads the file it
    # points at, the Mojo walk skips links.
    stack = [(repo, 1)]
    while stack:
        d, depth = stack.pop()
        try:
            entries = list(os.scandir(d))
        except OSError:
            continue
        for e in entries:
            if e.name in _DOC_SKIP:
                continue
            try:
                if e.is_symlink():
                    stem, dot, ext = e.name.rpartition(".")
                    if dot and ext.lower() in ("md", "markdown", "sh"):
                        return True
                elif e.is_dir() and depth < 4:
                    stack.append((e.path, depth + 1))
            except OSError:
                pass
    return False


def sort_paths(paths):
    return sorted(paths, key=path_key)


def sorted_strs(items):
    return sorted(items, key=lambda s: s.encode("utf-8", "surrogateescape"))


def read_input_file(candidates):
    # The first candidate that is a file of at most 1 MiB, read; None otherwise.
    for p in candidates:
        try:
            ok = os.path.isfile(p) and os.stat(p).st_size <= 1 << 20
        except OSError:
            ok = False
        if ok:
            try:
                with open(p, "rb") as f:
                    return f.read()
            except OSError:
                return None
    return None


class _Unsure(Exception):
    pass


def _serde_reads_alike(v, depth):
    # What serde_json's `Value` refuses although Python's json reads it: lone
    # surrogates, numbers beyond f64, nesting past its recursion limit.
    if depth > 100:
        raise _Unsure()
    if isinstance(v, str):
        try:
            v.encode("utf-8")
        except UnicodeEncodeError:
            raise _Unsure()
    elif isinstance(v, bool) or v is None:
        pass
    elif isinstance(v, int):
        if abs(v) > 1.7976931348623157e308:
            raise _Unsure()
    elif isinstance(v, float):
        if v != v or v in (float("inf"), float("-inf")):
            raise _Unsure()
    elif isinstance(v, list):
        for x in v:
            _serde_reads_alike(x, depth + 1)
    elif isinstance(v, dict):
        for k, x in v.items():
            _serde_reads_alike(k, depth + 1)
            _serde_reads_alike(x, depth + 1)


def _json_value(text):
    # ("ok", value), ("none", None) when serde_json refuses it too, or
    # ("odd", None) when serde_json could read it otherwise.
    try:
        v = json.loads(text, parse_constant=_const)
    except Exception:
        return ("none", None)
    try:
        _serde_reads_alike(v, 0)
    except _Unsure:
        return ("odd", None)
    return ("ok", v)


def _read_utf8(path):
    try:
        with open(path, "rb") as f:
            return f.read().decode("utf-8")
    except (OSError, UnicodeDecodeError):
        return None


def package_names(repo):
    # The bin names of package.json, as app_names reads them.
    text = _read_utf8(os.path.join(repo, "package.json"))
    if text is None:
        return ("ok", [])
    kind, v = _json_value(text)
    if kind != "ok":
        return (kind if kind == "odd" else "ok", [])
    if not isinstance(v, dict):
        return ("ok", [])
    b = v.get("bin")
    if isinstance(b, str):
        n = v.get("name")
        return ("ok", [n if isinstance(n, str) else ""])
    if isinstance(b, dict):
        return ("ok", list(b.keys()))
    return ("ok", [])


def pyproject_names(repo):
    # The script names of pyproject.toml; "odd" when tomllib refuses a file
    # toml_edit might read.
    text = _read_utf8(os.path.join(repo, "pyproject.toml"))
    if text is None:
        return ("ok", [])
    try:
        doc = tomllib.loads(text)
    except Exception:
        return ("odd", [])
    out = []
    for path in (("project", "scripts"), ("tool", "poetry", "scripts")):
        t = doc
        for k in path:
            t = t.get(k) if isinstance(t, dict) else None
        if isinstance(t, dict):
            out.extend(t.keys())
    return ("ok", out)


def dir_entries(dir, dirs_only):
    # Names in `dir` whose type (not following links) is a folder when
    # `dirs_only`, anything else otherwise.
    try:
        entries = list(os.scandir(dir))
    except OSError:
        return []
    out = []
    for e in entries:
        try:
            if e.is_dir(follow_symlinks=False) == dirs_only:
                out.append(e.name)
        except OSError:
            pass
    return out


def json_container(data):
    # 1: an object or array for serde_json, 0: not, -1: unsure.
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError:
        return 0
    kind, v = _json_value(text)
    if kind == "odd":
        return -1
    return 1 if kind == "ok" and isinstance(v, (dict, list)) else 0


_INPUT_KEYS = ("name", "args", "stdin", "env", "files", "remove")


def _str_list(v):
    return isinstance(v, list) and all(isinstance(x, str) for x in v)


def _str_dict(v):
    return isinstance(v, dict) and all(isinstance(x, str) for x in v.values())


def _by_key(d):
    return [(k, d[k]) for k in sorted(d, key=lambda k: k.encode("utf-8"))]


def input_line(line):
    # One `--inputs` line as serde reads `Input` (deny_unknown_fields), or
    # None for anything it could read otherwise or refuse.
    try:
        v = json.loads(line, object_pairs_hook=_pairs, parse_constant=_const)
        _plain(v)
    except Exception:
        return None
    if not isinstance(v, dict) or any(k not in _INPUT_KEYS for k in v):
        return None
    name = v.get("name")
    stdin = v.get("stdin")
    args = v.get("args", [])
    env = v.get("env", {})
    files = v.get("files", {})
    remove = v.get("remove", [])
    if name is not None and not isinstance(name, str):
        return None
    if stdin is not None and not isinstance(stdin, str):
        return None
    if not (_str_list(args) and _str_dict(env) and _str_dict(files) and _str_list(remove)):
        return None
    return (name, args, stdin, _by_key(env), _by_key(files), remove)


def case_key(args, stdin, env_pairs, files, remove):
    return repr((tuple(args), stdin, tuple(tuple(p) for p in env_pairs),
                 tuple(files.items()), tuple(remove)))


def sorted_files(d):
    return {k: d[k] for k in sorted(d, key=path_key)}


def _run_pair(job):
    one = run_in(job)
    if one["error"]:
        return one
    two = run_in(job)
    if two["error"]:
        return two
    return {"error": "", "one": one, "two": two}


def run_pairs(jobs):
    # Each case twice, one run after the other, cases on up to 8 threads.
    with concurrent.futures.ThreadPoolExecutor(max_workers=workers()) as pool:
        futures = [pool.submit(_run_pair, j) for j in jobs]
        out = []
        for f in futures:
            try:
                out.append(f.result())
            except Exception as e:
                out.append({"error": "", "odd": str(e)})
        return out


def pair_kind(r):
    if "odd" in r:
        return "odd"
    if r["error"]:
        return "error"
    for k in ("one", "two"):
        x = r[k]
        if not names_plain(x["files"].keys()) or not names_plain(x["removed"]):
            return "odd"
    return "ok"


def written(run, case_files):
    return {p: b for p, b in run["files"].items() if case_files.get(p) != b}


def dict_get(d, key, default):
    return d.get(key, default)


def is_none(x):
    return x is None


def put(d, key, value):
    d[key] = value


def merge_tokens(line):
    # app.rs `tokens`: runs of alphanumerics, every other character alone;
    # None when Python cannot say what Rust's is_alphanumeric would.
    out = []
    start = None
    for i, c in enumerate(line):
        if c.isascii():
            alnum = c.isalnum()
        else:
            k = alnum_kind(c)
            if k < 0:
                return None
            alnum = k == 1
        if alnum:
            if start is None:
                start = i
        else:
            if start is not None:
                out.append(line[start:i])
                start = None
            out.append(c)
    if start is not None:
        out.append(line[start:])
    return out


def remove_file(path):
    try:
        os.remove(path)
    except OSError:
        pass


def remove_tree(path):
    # remove_dir_all: a link goes, not what it points at.
    if os.path.islink(path):
        remove_file(path)
    elif os.path.isdir(path):
        shutil.rmtree(path, ignore_errors=True)


def make_dirs(path):
    try:
        os.makedirs(path, exist_ok=True)
        return ""
    except OSError as e:
        return os_error(e)


def write_file(path, data):
    # std::fs::write after create_dir_all of the parent; "" or the error.
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "wb") as f:
            f.write(data)
        return ""
    except OSError as e:
        return os_error(e)
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
