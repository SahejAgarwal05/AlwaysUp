#!/usr/bin/env python3
"""A tiny fake Docker Engine API on a Unix socket, for AlwaysUp's self-test.

Usage: fake_docker.py /path/to/docker.sock
Implements: GET /containers/json, POST /containers/<id>/{pause,unpause,stop}
Test controls: POST /_test/recreate/<name>, POST /_test/kill/<name>
"""
import json, os, socketserver, sys, uuid
from http.server import BaseHTTPRequestHandler

containers = [
    {"Id": "a1" + "0" * 62, "Names": ["/agent-box"], "Image": "python:3.12", "State": "running", "Status": "Up 5 minutes"},
    {"Id": "b2" + "0" * 62, "Names": ["/postgres"], "Image": "postgres:16", "State": "running", "Status": "Up 2 hours"},
]

def find(key):
    for c in containers:
        if c["Id"] == key or c["Names"][0] == "/" + key:
            return c
    return None

class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def address_string(self): return "unix"

    def reply(self, code, body=b""):
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path.startswith("/containers/json"):
            return self.reply(200, json.dumps([c for c in containers if c["State"] != "exited"]).encode())
        self.reply(404)

    def do_POST(self):
        parts = self.path.split("?")[0].strip("/").split("/")
        if parts[0] == "_test":
            c = find(parts[2])
            if not c: return self.reply(404)
            if parts[1] == "recreate": c["Id"] = uuid.uuid4().hex + uuid.uuid4().hex
            if parts[1] == "kill": c["State"] = "exited"
            return self.reply(204)
        if len(parts) == 3 and parts[0] == "containers":
            c = find(parts[1])
            if not c: return self.reply(404)
            c["State"] = {"pause": "paused", "unpause": "running", "stop": "exited"}.get(parts[2], c["State"])
            return self.reply(204)
        self.reply(404)

class S(socketserver.ThreadingMixIn, socketserver.UnixStreamServer):
    daemon_threads = True

path = sys.argv[1]
if os.path.exists(path): os.remove(path)
S(path, H).serve_forever()
