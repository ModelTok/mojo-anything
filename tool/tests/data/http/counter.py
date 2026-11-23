"""A server that keeps a count in the file named by its first argument: POST
adds one, every request answers the count. tool/tests/test_app_http.mojo
records it with `--fresh` so the count starts again at every start."""

import os
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

FILE = sys.argv[1]


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def answer(self):
        with open(FILE) as f:
            data = f.read().encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        self.answer()

    def do_POST(self):
        with open(FILE) as f:
            n = int(f.read())
        with open(FILE, "w") as f:
            f.write(str(n + 1))
        self.answer()


HTTPServer(("127.0.0.1", int(os.environ["PORT"])), Handler).serve_forever()
