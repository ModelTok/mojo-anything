# A program with effects outside its own output (tests/effects.rs's, with
# more shapes): HTTP requests to a webhook (HOOK) and through the proxy the
# sink sets, a chunked and a binary body, an https tunnel, mail with a login
# and a dot-stuffed line, and a line appended to the database file DB.
# BUG=1 sends other mail; NOMAIL=1 sends none.
import http.client
import os
import smtplib
import sys
import urllib.parse
import urllib.request


def say(*parts):
    print(*parts, flush=True)


hook = os.environ.get("HOOK")
if hook:
    req = urllib.request.Request(hook + "/new?x=1", data=b'{"a":1}', method="POST",
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=10) as r:
        say("hook", r.status, r.read().decode())
    sink = urllib.parse.urlsplit(hook)
    c = http.client.HTTPConnection(sink.hostname, sink.port, timeout=10)
    c.request("PUT", "/chunked", body=iter([b"ab", b"cd\n"]), encode_chunked=True,
              headers={"Transfer-Encoding": "chunked", "Content-Type": "text/plain"})
    say("chunked", c.getresponse().status)
    c.close()
    c = http.client.HTTPConnection(sink.hostname, sink.port, timeout=10)
    c.request("POST", "/bin", body=b"\xff\x00\x01")
    say("binary", c.getresponse().status)
    c.close()
    c = http.client.HTTPConnection(sink.hostname, sink.port, timeout=10)
    c.set_tunnel("secure.example", 443)
    try:
        c.request("GET", "/")
    except OSError as e:
        say("tunnel refused")
    c.close()
if os.environ.get("HTTP_PROXY"):
    with urllib.request.urlopen("http://api.example/v1/items", timeout=10) as r:
        say("proxied", r.status)
if os.environ.get("SMTP_PORT") and not os.environ.get("NOMAIL"):
    try:
        s = smtplib.SMTP(os.environ["SMTP_HOST"], int(os.environ["SMTP_PORT"]),
                         local_hostname="localhost", timeout=10)
        s.login("user", "secret")
        body = "Subject: hi\r\n\r\nline one\r\n.starts with a dot\r\n"
        if os.environ.get("BUG"):
            body = "Subject: bye\r\n\r\nother\r\n"
        s.sendmail("a@x.test", ["b@y.test", "c@y.test"], body)
        s.quit()
        say("mailed")
    except OSError as e:
        say("no mail:", type(e).__name__)
db = os.environ.get("DB")
if db:
    with open(db, "a") as f:
        f.write("case %s\n" % " ".join(sys.argv[1:]))
say("done", " ".join(sys.argv[1:]))
