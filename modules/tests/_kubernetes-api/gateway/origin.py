"""Disposable application backend; the actual rendered Envoy owns ingress policy."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import time
from urllib.parse import urlsplit


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        path = urlsplit(self.path).path
        if path == "/slow":
            time.sleep(17)
        payload = (json.dumps({"headers": dict(self.headers), "path": self.path}).encode()
                   if path == "/headers" else b"origin\n")
        self.send_response(200)
        self.send_header("Content-Type", "application/json" if path == "/headers" else "text/plain")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, *_):
        pass


ThreadingHTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
