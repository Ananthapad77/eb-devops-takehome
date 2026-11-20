import json
import os
import socket
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

CONFIG_DIR = os.environ.get("CONFIG_DIR", "/etc/app-config")
PORT = int(os.environ.get("PORT", "8080"))


def setting(name, default=""):
    """Mounted ConfigMap file wins (it updates live when the ConfigMap is
    patched); otherwise fall back to the environment variable."""
    try:
        with open(os.path.join(CONFIG_DIR, name)) as f:
            return f.read().strip()
    except OSError:
        return os.environ.get(name, default)


class Handler(BaseHTTPRequestHandler):
    def _send(self, code, payload):
        body = json.dumps(payload).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        path = self.path.split("?", 1)[0]
        if path == "/":
            self._send(200, {
                "app": setting("APP_NAME"),
                "version": setting("VERSION"),
                "pod": socket.gethostname(),
            })
        elif path == "/healthz":
            self._send(200, {"status": "ok"})
        else:
            self._send(404, {"error": "not found"})

    def log_message(self, fmt, *args):
        print("%s - %s" % (self.address_string(), fmt % args), flush=True)


if __name__ == "__main__":
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
