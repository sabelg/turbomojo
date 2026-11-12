#!/usr/bin/env python3
"""An example TurboMojo plugin (docs/PLUGINS.md): counts the words of the file in
front - in a status item, kept up to date when a file is opened or saved, and as a
notification from the command "Count words" (Ctrl-Alt-W) - and inserts today's date
with "Insert today's date".

TurboMojo talks to it with JSON-RPC 2.0, one message per line on stdin and stdout.
"""
import datetime
import json
import sys

next_id = 1000


def send(msg):
    sys.stdout.write(json.dumps(msg) + "\n")
    sys.stdout.flush()


def read():
    line = sys.stdin.readline()
    if not line:
        sys.exit(0)                     # TurboMojo has gone
    return json.loads(line)


def ask(method, params):
    """A request to TurboMojo; waits for its answer (and handles nothing else meanwhile)."""
    global next_id
    next_id += 1
    my = next_id
    send({"jsonrpc": "2.0", "id": my, "method": method, "params": params})
    while True:
        m = read()
        if m.get("id") == my and "method" not in m:
            return m.get("result")


def tell(method, params):
    send({"jsonrpc": "2.0", "method": method, "params": params})


def count():
    ed = ask("editor/get", {}) or {}
    text = ed.get("text", "")
    return len(text.split()), len(text.splitlines()), ed.get("path", "")


def show_status():
    words, _, path = count()
    tell("status/set", {"text": ("%d words" % words) if path else ""})


while True:
    m = read()
    method = m.get("method")
    if method == "initialize":
        send({"jsonrpc": "2.0", "id": m["id"], "result": {
            "commands": [
                {"id": "count", "title": "Count ~w~ords", "hint": "Count the words and lines of the file in front", "key": "Ctrl-Alt-W"},
                {"id": "date", "title": "Insert today's ~d~ate", "hint": "Insert the date at the cursor"},
            ],
            "events": ["open", "save"],
        }})
    elif method == "command":
        which = m["params"]["id"]
        if which == "count":
            words, lines, path = count()
            tell("ui/notify", {"level": "info", "title": "Word count", "text": "%d words, %d lines in %s" % (words, lines, path.split("/")[-1] or "this window")})
        elif which == "date":
            ask("editor/insert", {"text": datetime.date.today().isoformat()})
        send({"jsonrpc": "2.0", "id": m["id"], "result": None})
    elif method == "event":
        show_status()
    elif method == "shutdown":
        sys.exit(0)
    elif "id" in m and method:
        send({"jsonrpc": "2.0", "id": m["id"], "error": {"code": -32601, "message": "unknown " + method}})
