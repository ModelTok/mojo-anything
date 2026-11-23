# The parts of a server's `app record` and `app replay` that run through
# CPython, as the effects sinks do (port of `Server`, `send`, `read_response`
# and `run_all` in src/http.rs): the server starts with `subprocess` on its
# port, waits until it listens, and each request goes over a socket of its
# own (`Connection: close`, TCP_NODELAY, the case's time limit as SO_RCVTIMEO
# and SO_SNDTIMEO, as Rust's `set_read_timeout`). The answer is read as
# http.rs reads it, and every error text is Rust's: an OS error as
# `<strerror> (os error N)`, http.rs's own words, and `ParseIntError`'s.
# Anything Rust would word or decide otherwise (a timed-out connect, a head
# that is not UTF-8, a server killed by a signal) raises `_HttpOdd`, which
# declines. Settling, the case files and the comparison stay in Mojo
# (`server.mojo`).

from std.python import Python, PythonObject

comptime _SOURCE = """
import struct as _struct

_READY = 60.0
_STOP_WAIT = 5.0


class _HttpOdd(Exception):
    pass


class _HttpErr(Exception):
    # An error the Rust tool prints as this text.
    pass


def _io_text(e):
    if not isinstance(e, OSError) or e.errno is None or not e.strerror:
        raise _HttpOdd()
    return "%s (os error %d)" % (e.strerror, e.errno)


def _rs_trim(s):
    return s.strip(_RUST_WS)


def _parse_uint(s, radix, bits):
    # (value, None) or (None, ParseIntError's text), digit by digit as
    # from_str_radix reads them: the first problem from the left wins.
    if s == "":
        return (None, "cannot parse integer from empty string")
    if s[0] in "+-" and len(s) == 1:
        return (None, "invalid digit found in string")
    if s[0] == "+":
        s = s[1:]
    digits = "0123456789abcdef"[:radix]
    n = 0
    for c in s:
        d = digits.find(c.lower()) if c.isascii() else -1
        if d < 0:
            return (None, "invalid digit found in string")
        n = n * radix + d
        if n >= 1 << bits:
            return (None, "number too large to fit in target type")
    return (n, None)


def str_lines_count(text):
    if text == "":
        return 0
    n = text.count("\\n")
    return n if text.endswith("\\n") else n + 1


def _str_lines(text):
    parts = text.split("\\n")
    if parts and parts[-1] == "":
        parts.pop()
    return [p[:-1] if p.endswith("\\r") else p for p in parts]


def free_port():
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    try:
        s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]
    finally:
        s.close()


class _Stream:
    def __init__(self, s):
        self.s = s

    def read(self, n):
        try:
            return self.s.recv(n)
        except OSError as e:
            raise _HttpErr(_io_text(e))


class _Bytes:
    # A response held in memory (the unit tests).
    def __init__(self, data, fail=False):
        self.data = data
        self.fail = fail

    def read(self, n):
        if not self.data and self.fail:
            raise _HttpErr("Resource temporarily unavailable (os error 11)")
        out, self.data = self.data[:n], self.data[n:]
        return out


def _fill(st, buf, need):
    while len(buf) < need:
        chunk = st.read(8192)
        if not chunk:
            raise _HttpErr("the connection closed in the middle of the response")
        buf += chunk


def _chunk_line_end(st, buf):
    while True:
        i = buf.find(b"\\r\\n")
        if i >= 0:
            return i
        _fill(st, buf, len(buf) + 1)


def _lossy(b):
    # from_utf8_lossy, where it cannot differ from Python's replacement.
    try:
        return b.decode("utf-8")
    except UnicodeDecodeError:
        raise _HttpOdd()


def _read_chunked(st, buf):
    body = bytearray()
    while True:
        end = _chunk_line_end(st, buf)
        size_text = _lossy(bytes(buf[:end]))
        size, err = _parse_uint(_rs_trim(size_text.split(";")[0]), 16, 64)
        if err is not None:
            raise _HttpErr("bad chunk size `%s`: %s" % (size_text, err))
        del buf[:end + 2]
        if size == 0:
            while True:
                end = _chunk_line_end(st, buf)
                if end == 0:
                    return bytes(body)
                del buf[:end + 2]
        stop = size + 2
        if stop >= 1 << 64:
            raise _HttpErr("chunk size is too large")
        _fill(st, buf, stop)
        if bytes(buf[size:stop]) != b"\\r\\n":
            raise _HttpErr("bad chunk terminator")
        body += buf[:size]
        del buf[:stop]


def _content_length(value):
    v = _rs_trim(value)
    if v == "" or not all(c in "0123456789" for c in v):
        raise _HttpErr("invalid Content-Length")
    n, err = _parse_uint(v, 10, 64)
    if err is not None:
        raise _HttpErr("invalid Content-Length: %s" % err)
    return n


def _read_response(st, head_only):
    buf = bytearray()
    while True:
        while True:
            i = buf.find(b"\\r\\n\\r\\n")
            if i >= 0:
                break
            chunk = st.read(8192)
            if not chunk:
                raise _HttpErr("the connection closed before a full response")
            buf += chunk
        head = _lossy(bytes(buf[:i]))
        status_line = head.split("\\r\\n")[0]
        words = _rs_split(status_line)
        status = None
        if len(words) > 1:
            status, err = _parse_uint(words[1], 10, 16)
        if status is None:
            raise _HttpErr("not an HTTP response: `%s`" % status_line)
        rest = bytearray(buf[i + 4:])
        if status == 101 or not (100 <= status < 200):
            break
        buf = rest
    headers = {}
    for line in head.split("\\r\\n")[1:]:
        if ":" in line:
            k, v = line.split(":", 1)
            k = _rs_trim(k).translate(_ASCII_LOWER)
            v = _rs_trim(v)
            headers[k] = headers[k] + ", " + v if k in headers else v
    te = headers.get("transfer-encoding")
    chunked = te is not None and "chunked" in te.translate(_ASCII_LOWER)
    if head_only or status in (204, 304) or 100 <= status < 200:
        body = b""
    elif chunked:
        body = _read_chunked(st, rest)
    elif "content-length" in headers:
        parts = headers["content-length"].split(",")
        n = _content_length(parts[0])
        for other in parts[1:]:
            if _content_length(other) != n:
                raise _HttpErr("conflicting Content-Length headers")
        _fill(st, rest, n)
        body = bytes(rest[:n])
    else:
        while True:
            try:
                chunk = st.read(8192)
            except _HttpErr as e:
                raise _HttpErr("reading close-delimited HTTP body: %s" % e)
            if not chunk:
                break
            rest += chunk
        body = bytes(rest)
    pairs = sorted(headers.items(), key=lambda kv: kv[0].encode("utf-8"))
    return (status, pairs, body)


def parse_response(data, head_only, fail):
    # A response from bytes: ("ok", status, header pairs, body), ("err",
    # text) or ("odd", ...): the unit tests' port of http.rs's.
    try:
        r = _read_response(_Bytes(data, fail), head_only)
        return ("ok", r[0], r[1], r[2])
    except _HttpErr as e:
        return ("err", str(e), [], b"")
    except _HttpOdd:
        return ("odd", "", [], b"")


def _timeouts(s, secs):
    tv = _struct.pack("ll", int(secs), 0)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_RCVTIMEO, tv)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_SNDTIMEO, tv)


def _http_send(port, req, timeout):
    method, path, headers, body = req
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    try:
        try:
            s.settimeout(timeout)
            s.connect(("127.0.0.1", port))
            s.settimeout(None)
            s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            _timeouts(s, timeout)
        except OSError as e:
            raise _HttpErr(_io_text(e))
        head = "%s %s HTTP/1.1\\r\\nHost: 127.0.0.1:%d\\r\\nConnection: close\\r\\n" % (
            method, path, port)
        for k, v in headers:
            if k.translate(_ASCII_LOWER) not in ("host", "connection", "content-length"):
                head += "%s: %s\\r\\n" % (k, v)
        data = (body or "").encode("utf-8")
        if body is not None or method in ("POST", "PUT", "PATCH"):
            head += "Content-Length: %d\\r\\n" % len(data)
        head += "\\r\\n"
        try:
            s.sendall(head.encode("utf-8"))
            if data:
                s.sendall(data)
        except OSError as e:
            raise _HttpErr(_io_text(e))
        r = _read_response(_Stream(s), method == "HEAD")
        return ("ok", r[0], r[1], r[2])
    except _HttpErr as e:
        return ("err", str(e), [], b"")
    finally:
        s.close()


def _log_lines(path):
    # read_to_string(..).ok().map(|t| t.lines().count())
    try:
        with open(path, "rb") as f:
            return str_lines_count(f.read().decode("utf-8"))
    except (OSError, UnicodeDecodeError):
        return None


class _Server:
    pass


def _stop(srv):
    child = srv.child
    if child.poll() is None:
        try:
            os.kill(child.pid, signal.SIGTERM)
        except OSError:
            pass
        deadline = time.monotonic() + _STOP_WAIT
        while time.monotonic() < deadline:
            if child.poll() is not None:
                break
            time.sleep(0.02)
    try:
        child.kill()
    except OSError:
        pass
    child.wait()
    shutil.rmtree(srv.dir, ignore_errors=True)
    if srv.sinks is not None:
        srv.sinks.stop()


def _start(command, args, files, effects, repo, port):
    # ("ok", server) or ("error", the Rust tool's text); _HttpOdd otherwise.
    d = temp_dir("server")
    ps = str(port)
    words = [resolve_word(repo, w.replace("{port}", ps)) for w in command]
    if not words:
        return ("error", "empty command")
    log = os.path.join(d, "fallback.log")
    if files is not None:
        cwd = os.path.join(d, "cwd")
        err = copy_tree(files, cwd)
        if err is None:
            raise _HttpOdd()
        if err:
            return ("error", err)
    else:
        cwd = repo
    sinks = None
    if effects is not None:
        sinks = _Sinks(effects)
        try:
            err = sinks.reset(cwd)
        except _SinkOdd:
            sinks.stop()
            raise _HttpOdd()
        if err:
            sinks.stop()
            return ("error", err)
    env = dict(os.environ)
    if sinks is not None:
        for k, v in sinks.env():
            env[k] = v
    env["PORT"] = ps
    env[FALLBACK_ENV] = log
    argv = words + [a.replace("{port}", ps) for a in args]
    try:
        out = open(os.path.join(d, "stdout"), "wb")
        err = open(os.path.join(d, "stderr"), "wb")
    except OSError as e:
        if sinks is not None:
            sinks.stop()
        return ("error", os_error(e))
    try:
        child = subprocess.Popen(argv, cwd=cwd, env=env, stdin=subprocess.DEVNULL,
                                 stdout=out, stderr=err, close_fds=False)
    except OSError as e:
        if sinks is not None:
            sinks.stop()
        return ("error", "starting `%s`: %s" % (" ".join(command), os_error(e)))
    finally:
        out.close()
        err.close()
    deadline = time.monotonic() + _READY
    while True:
        try:
            c = socket.create_connection(("127.0.0.1", port), timeout=0.2)
            c.close()
            break
        except OSError:
            pass
        rc = child.poll()
        failure = None
        if rc is not None:
            if rc < 0:
                # ExitStatus names the signal; not reproduced.
                if sinks is not None:
                    sinks.stop()
                shutil.rmtree(d, ignore_errors=True)
                raise _HttpOdd()
            failure = "exited (exit status: %d) before listening" % rc
        elif time.monotonic() > deadline:
            failure = "did not listen within 60s"
        if failure is not None:
            try:
                child.kill()
            except OSError:
                pass
            child.wait()
            try:
                with open(os.path.join(d, "stderr"), "rb") as f:
                    text = f.read().decode("utf-8")
            except (OSError, UnicodeDecodeError):
                text = ""
            tail = _str_lines(text)[-15:]
            shutil.rmtree(d, ignore_errors=True)
            if sinks is not None:
                sinks.stop()
            return ("error", "`%s` %s on port %d%s" % (
                " ".join(command), failure, port, ":\\n" + "\\n".join(tail) if tail else ""))
        time.sleep(0.05)
    srv = _Server()
    srv.child, srv.port, srv.dir, srv.cwd, srv.log, srv.sinks = child, port, d, cwd, log, sinks
    return ("ok", srv)


def _run_all(command, args, files, pace_ms, effects, repo, port, reqs, timeout):
    r = _start(command, args, files, effects, repo, port)
    if r[0] != "ok":
        return r
    srv = r[1]
    out = []
    try:
        for req in reqs:
            before = _log_lines(srv.log) or 0
            served = _log_lines(srv.log + ".served") or 0
            resp = _http_send(srv.port, req, timeout)
            if pace_ms is not None:
                time.sleep(pace_ms / 1000.0)
            after = _log_lines(srv.log)
            fell = None if after is None else after > before
            if fell is not None and resp[0] == "ok" and (_log_lines(srv.log + ".served") or 0) <= served:
                resp = ("err", "the front door did not answer: another process answered on port %d"
                        % srv.port, [], b"")
            fx = srv.sinks.take(srv.cwd) if srv.sinks is not None else None
            out.append({"resp": resp, "fallback": fell, "effects": fx})
    finally:
        _stop(srv)
    return ("ok", out)


def run_server(command, args, files, pace_ms, effects, repo, port, reqs, timeout):
    # ("ok", answers), ("error", text) or ("odd", "").
    try:
        signal.signal(signal.SIGPIPE, signal.SIG_IGN)
    except (ValueError, OSError, AttributeError):
        pass
    try:
        return _run_all(command, args, files, pace_ms, effects, repo, port, reqs, timeout)
    except (_HttpOdd, _SinkOdd):
        return ("odd", "")
    except Exception as e:
        return ("odd", str(e))


def curl_file(candidates):
    # The first candidate that is a file, read as UTF-8; None otherwise.
    for p in candidates:
        if os.path.isfile(p):
            try:
                with open(p, "rb") as f:
                    return f.read().decode("utf-8")
            except (OSError, UnicodeDecodeError):
                return None
    return None


def percent_decode(text):
    b = text.encode("utf-8")
    out = bytearray()
    i = 0
    hexd = "0123456789abcdefABCDEF"
    while i < len(b):
        if b[i] == 0x25 and i + 3 <= len(b):
            x, y = chr(b[i + 1]), chr(b[i + 2])
            v = None
            if x == "+" and y in hexd:
                v = int(y, 16)
            elif x in hexd and y in hexd:
                v = int(x + y, 16)
            if v is not None:
                out.append(v)
                i += 3
                continue
        out.append(b[i])
        i += 1
    return bytes(out).decode("utf-8", "replace")


def http_input_line(line):
    # One `--inputs` line as serde reads `HttpInput` (unknown keys ignored,
    # as `flatten` does), or None for anything it could read otherwise or
    # refuse: (name, method, path, header pairs, has_body, body).
    try:
        v = json.loads(line, object_pairs_hook=_pairs, parse_constant=_const)
        _plain(v)
    except Exception:
        return None
    if not isinstance(v, dict):
        return None
    name = v.get("name")
    method = v.get("method", "GET")
    path = v.get("path")
    headers = v.get("headers", {})
    body = v.get("body")
    if name is not None and not isinstance(name, str):
        return None
    if not isinstance(method, str) or not isinstance(path, str):
        return None
    if not _str_dict(headers):
        return None
    if body is not None and not isinstance(body, str):
        return None
    return (name, method, path, _by_key(headers), body is not None, body or "")


def _strings_of(t):
    # strings(): a table's values as strings ("" for anything else), sorted.
    if not isinstance(t, dict):
        return []
    return [(k, t[k] if isinstance(t[k], str) else "")
            for k in sorted(t, key=lambda k: k.encode("utf-8"))]


def http_spec(doc):
    # What load_spec reads from a case's TOML.
    req = doc.get("request")
    resp = doc.get("response")
    method = _get(req, "method")
    path = _get(req, "path")
    body = _get(req, "body")
    status = _get(resp, "status")
    if not _is_int(status) or not 0 <= status <= 65535:
        status = None
    binary = _get(resp, "binary")
    return {
        "has_request": "request" in doc,
        "has_response": "response" in doc,
        "method": method if isinstance(method, str) else "GET",
        "path": path if isinstance(path, str) else None,
        "headers": _strings_of(_get(req, "headers")),
        "body": body if isinstance(body, str) else None,
        "status": status,
        "resp_headers": _strings_of(_get(resp, "headers")),
        "binary": binary if isinstance(binary, bool) else False,
    }
"""


def server_helpers(h: PythonObject) raises:
    """Adds the helpers above to py.mojo's scope `h` (they use its sinks,
    `resolve_word`, `copy_tree` and `temp_dir`)."""
    _ = Python.import_module("builtins").exec(_SOURCE, h)
