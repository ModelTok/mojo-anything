# The unit tests of src/http.rs, on the Mojo port: curl lines to requests,
# responses read from bytes (informational answers, lengths, chunks, close),
# malformed chunks and lengths, and traps. test_app_http.mojo runs both tools
# on real servers.

from std.python import Python, PythonObject
from std.testing import assert_equal, assert_false, assert_true

from mojo_anything.app.py import py_helpers
from mojo_anything.app.py_server import server_helpers
from mojo_anything.app.server import Req, parse_curl, toml_value, traps


def _h() raises -> PythonObject:
    var h = py_helpers()
    server_helpers(h)
    return h


def _header(r: Req, k: String) -> String:
    var at = r.find(k)
    return r.values[at] if at >= 0 else "(none)"


def test_curl_lines_become_requests() raises:
    var h = _h()
    var r = (
        parse_curl(
            h,
            (
                "curl -sS -X POST -H 'Content-Type: text/plain' -d 'hello"
                " world' http://localhost:8080/upper?x=1"
            ),
            ".",
            ".",
        )
        .value()
        .copy()
    )
    assert_equal(r.method, "POST")
    assert_equal(r.path, "/upper?x=1")
    assert_true(r.has_body)
    assert_equal(r.body, "hello world")
    assert_equal(_header(r, "Content-Type"), "text/plain")
    var g = parse_curl(h, "curl 127.0.0.1:3000", ".", ".").value().copy()
    assert_equal(g.method + " " + g.path, "GET /")
    var form = (
        parse_curl(h, "curl -d a=1 http://[::1]:80/f", ".", ".").value().copy()
    )
    assert_equal(form.method, "POST")
    assert_equal(
        _header(form, "Content-Type"), "application/x-www-form-urlencoded"
    )
    assert_false(Bool(parse_curl(h, "curl https://example.com/x", ".", ".")))
    var query = (
        parse_curl(h, "curl 'http://localhost?x=y#section'", ".", ".")
        .value()
        .copy()
    )
    assert_equal(query.path, "/?x=y")
    var fragment = (
        parse_curl(h, "curl 'http://[::1]:8080/path#section'", ".", ".")
        .value()
        .copy()
    )
    assert_equal(fragment.path, "/path")
    assert_false(Bool(parse_curl(h, "curl ftp://localhost/file", ".", ".")))
    assert_false(
        Bool(parse_curl(h, "curl --unknown x http://localhost/", ".", "."))
    )
    assert_false(Bool(parse_curl(h, "curl http://localhost/ | jq .", ".", ".")))


def _response(
    h: PythonObject, raw: String, head_only: Bool = False, fail: Bool = False
) raises -> PythonObject:
    return h["parse_response"](
        h["utf8"](PythonObject(raw)),
        PythonObject(head_only),
        PythonObject(fail),
    )


def test_informational_responses_do_not_replace_the_final_response() raises:
    var h = _h()
    var r = _response(
        h,
        (
            "HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 103 Early Hints\r\nLink:"
            " </app.js>\r\n\r\nHTTP/1.1 201 Created\r\nContent-Length:"
            " 2\r\n\r\nok"
        ),
    )
    assert_equal(String(py=r[0]), "ok")
    assert_equal(Int(py=r[1]), 201)
    assert_equal(String(py=r[3].decode()), "ok")
    assert_equal(String(py=r[2]), "[('content-length', '2')]")
    var switching = _response(h, "HTTP/1.1 101 Switching Protocols\r\n\r\n")
    assert_equal(Int(py=switching[1]), 101)


def test_responses_parse_with_length_chunks_or_close() raises:
    var h = _h()
    var fixed = _response(
        h,
        (
            "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length:"
            " 5\r\n\r\nhelloEXTRA"
        ),
    )
    assert_equal(String(py=fixed[3].decode()), "hello")
    var chunked = _response(
        h,
        (
            "HTTP/1.1 404 Not Found\r\nTransfer-Encoding:"
            " chunked\r\n\r\n4\r\nnot \r\n5;x=y\r\nfound\r\n0\r\n\r\n"
        ),
    )
    assert_equal(Int(py=chunked[1]), 404)
    assert_equal(String(py=chunked[3].decode()), "not found")
    var close = _response(h, "HTTP/1.0 500 Oops\r\n\r\nbye")
    assert_equal(String(py=close[3].decode()), "bye")


def test_malformed_chunks_and_lengths_are_errors() raises:
    var h = _h()
    var head = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n"
    var bad = _response(h, head + "1\r\naXX0\r\n\r\n")
    assert_equal(String(py=bad[1]), "bad chunk terminator")
    var max = _response(h, head + "ffffffffffffffff\r\n")
    assert_equal(String(py=max[1]), "chunk size is too large")
    var huge = _response(h, head + "1ffffffffffffffff\r\n")
    assert_equal(
        String(py=huge[1]),
        (
            "bad chunk size `1ffffffffffffffff`: number too large to fit in"
            " target type"
        ),
    )
    var word = _response(h, head + "zz\r\n")
    assert_equal(
        String(py=word[1]), "bad chunk size `zz`: invalid digit found in string"
    )
    var truncated = _response(h, head + "1\r\na\r\n0\r\n")
    assert_equal(
        String(py=truncated[1]),
        "the connection closed in the middle of the response",
    )
    var trailers = _response(
        h, head + "1\r\na\r\n0\r\nX-Trailer: present\r\n\r\n"
    )
    assert_equal(String(py=trailers[3].decode()), "a")
    var lengths = "HTTP/1.1 200 OK\r\n"
    var invalid = _response(
        h, lengths + "Content-Length: invalid\r\n\r\nabc trailing"
    )
    assert_equal(String(py=invalid[1]), "invalid Content-Length")
    var conflict = _response(
        h,
        lengths + "Content-Length: 3\r\nContent-Length: 4\r\n\r\nabc trailing",
    )
    assert_equal(String(py=conflict[1]), "conflicting Content-Length headers")
    var matching = _response(
        h,
        lengths + "Content-Length: 3\r\nContent-Length: 03\r\n\r\nabc trailing",
    )
    assert_equal(String(py=matching[3].decode()), "abc")
    var short = _response(h, "HTTP/1.1 200 OK\r\n\r")
    assert_equal(
        String(py=short[1]), "the connection closed before a full response"
    )
    var status = _response(h, "HTTP/1.1 abc\r\n\r\n")
    assert_equal(String(py=status[1]), "not an HTTP response: `HTTP/1.1 abc`")


def test_an_interrupted_close_delimited_body_is_an_error() raises:
    var h = _h()
    var r = _response(h, "HTTP/1.0 200 OK\r\n\r\npartial", fail=True)
    assert_equal(
        String(py=r[1]),
        (
            "reading close-delimited HTTP body: Resource temporarily"
            " unavailable (os error 11)"
        ),
    )


def test_traps_change_path_segments_queries_and_bodies() raises:
    var h = _h()
    var base = Req("POST", "/div/7/2?name=bob")
    base.has_body = True
    base.body = '{"a":1}'
    var bases = List[Req]()
    bases.append(base^)
    var t = traps(h, bases)
    var paths = List[String]()
    var json_body = False
    for r in t:
        paths.append(r.path)
        if r.has_body and r.body.startswith('{"zebra"'):
            json_body = True
    assert_true("/div/-7/2?name=bob" in paths)
    assert_true("/div/7/0?name=bob" in paths)
    assert_true("/div/7/2?name=%F0%9F%91%8D%F0%9F%8F%BD%20thumbs" in paths)
    for p in paths:
        assert_true(p.startswith("/div/") or p == "/mojo-anything-missing")
    assert_true(json_body)
    assert_equal(
        String(py=h["percent_decode"](PythonObject("a%20b%zz%+F"))),
        "a b%zz" + chr(15),
    )


def test_strings_take_toml_edits_quotes() raises:
    assert_equal(toml_value("plain"), '"plain"')
    assert_equal(toml_value('a "q"'), "'a \"q\"'")
    assert_equal(toml_value("it's \\ ok"), "'''it's \\ ok'''")
    assert_equal(toml_value("x\ny"), '"""\nx\ny"""')
    assert_equal(toml_value("a\tb" + chr(1)), '"a\\tb\\u0001"')


def main() raises:
    test_curl_lines_become_requests()
    test_informational_responses_do_not_replace_the_final_response()
    test_responses_parse_with_length_chunks_or_close()
    test_malformed_chunks_and_lengths_are_errors()
    test_an_interrupted_close_delimited_body_is_an_error()
    test_traps_change_path_segments_queries_and_bodies()
    test_strings_take_toml_edits_quotes()
    print("test_app_server: 7 passed")
