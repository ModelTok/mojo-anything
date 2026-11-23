"""A small HTTP server for tool/tests/test_app_http.mojo: JSON, text, binary and
chunked answers, merged and skipped headers, a request echo, a clock (noise)
and a webhook to the effects sink. BUG=1 changes an error message and a
status; NOHOOK=1 leaves the webhook out."""

import os
import sys
import time
import urllib.request
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import unquote, urlsplit

TEXT = "text/plain; charset=utf-8"
BUG = os.environ.get("BUG") == "1"


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def send(self, status, ctype, data, extra=()):
        if isinstance(data, str):
            data = data.encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        for k, v in extra:
            self.send_header(k, v)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(data)

    def chunked(self):
        self.send_response(200)
        self.send_header("Content-Type", TEXT)
        self.send_header("Transfer-Encoding", "chunked")
        self.end_headers()
        for part in (b"one ", b"two ", b"three\n"):
            self.wfile.write(b"%x;ext=1\r\n%s\r\n" % (len(part), part))
        self.wfile.write(b"0\r\nX-Trailer: t\r\n\r\n")

    def route(self, body):
        url = urlsplit(self.path)
        path = url.path
        parts = path.split("/")[1:]
        if path == "/hello":
            return self.send(200, "application/json", '{"message":"hello"}')
        if path == "/upper" and self.command == "POST":
            return self.send(200, TEXT, body.decode("utf-8", "replace").upper())
        if len(parts) == 3 and parts[0] == "div":
            try:
                a, b = int(unquote(parts[1])), int(unquote(parts[2]))
            except ValueError:
                return self.send(400, TEXT, "error: not a number\n")
            if b == 0:
                text = "error: cannot divide by zero\n" if BUG else "error: division by zero\n"
                return self.send(400, TEXT, text)
            return self.send(200, TEXT, f"{a} / {b} = {a // b} remainder {a % b}\n")
        if path == "/now":
            return self.send(200, TEXT, f"now: {time.time_ns()}\n")
        if path == "/echo":
            keep = ("cookie", "referer", "user-agent", "content-type", "accept")
            seen = sorted(
                (k.lower(), v)
                for k, v in self.headers.items()
                if k.lower().startswith("x-") or k.lower() in keep
            )
            head = "%s %s\n" % (self.command, self.path)
            head += "".join("%s: %s\n" % kv for kv in seen) + "\n"
            return self.send(200, TEXT, head.encode("utf-8") + body)
        if path == "/search":
            return self.send(200, TEXT, "query: %s\n" % url.query)
        if path == "/bin":
            return self.send(200, "application/octet-stream", bytes([0xFF, 0, 1, 2]))
        if path == "/chunked":
            return self.chunked()
        if path == "/headers":
            extra = [("Set-Cookie", "a=1"), ("Set-Cookie", "b=2"), ("ETag", '"x"')]
            return self.send(201 if BUG else 200, TEXT, "h\n", extra)
        if path == "/hook":
            sink = os.environ.get("MOJO_ANYTHING_HTTP_SINK")
            if sink and os.environ.get("NOHOOK") != "1":
                req = urllib.request.Request(
                    sink + "/hook",
                    data=b'{"n":1}',
                    headers={"Content-Type": "application/json"},
                )
                urllib.request.urlopen(req, timeout=5).read()
            return self.send(200, TEXT, "hooked\n")
        self.send(404, TEXT, "not found\n")

    def body(self):
        n = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(n) if n else b""

    def do_GET(self):
        self.route(self.body())

    def do_HEAD(self):
        self.route(b"")

    def do_POST(self):
        self.route(self.body())

    def do_PUT(self):
        self.route(self.body())

    def do_DELETE(self):
        self.route(self.body())


port = os.environ.get("PORT", "8080")
for arg in sys.argv[1:]:
    if arg.startswith("--port="):
        port = arg[len("--port="):]
HTTPServer(("127.0.0.1", int(port)), Handler).serve_forever()
