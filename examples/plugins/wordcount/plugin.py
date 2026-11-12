#!/usr/bin/env python3
"""An example TurboMojo plugin (docs/PLUGINS.md): counts the words of the file in
front - in a status item, kept up to date when a file is opened or saved, and as a
notification from the command "Count words" (Ctrl-Alt-W) -, inserts today's date
with "Insert today's date", and shows "Most used words" in a table panel (Enter on a
row says how often; the panel follows saves while it is open).

TurboMojo talks to it with JSON-RPC 2.0, one message per line on stdin and stdout.
"""
import collections
import datetime
import json
import re
import sys

next_id = 1000


def send(msg):
    sys.stdout.write(json.dumps(msg) + "\n")
    sys.stdout.flush()


waiting = []                            # messages that came while we waited for an answer


def read_line():
    line = sys.stdin.readline()
    if not line:
        sys.exit(0)                     # TurboMojo has gone
    return json.loads(line)


def read():
    """The next message for the main loop (those kept while waiting come first)."""
    return waiting.pop(0) if waiting else read_line()


def ask(method, params):
    """A request to TurboMojo; waits for its answer. What else comes meanwhile is kept
    for the main loop, in order."""
    global next_id
    next_id += 1
    my = next_id
    send({"jsonrpc": "2.0", "id": my, "method": method, "params": params})
    while True:
        m = read_line()
        if m.get("id") == my and "method" not in m:
            return m.get("result")
        waiting.append(m)


def tell(method, params):
    send({"jsonrpc": "2.0", "method": method, "params": params})


def count():
    ed = ask("editor/get", {}) or {}
    text = ed.get("text", "")
    return len(text.split()), len(text.splitlines()), ed.get("path", "")


panel_open = False
last_counts = {}


def show_words():
    """Fill the panel with the twenty words used most."""
    global last_counts
    ed = ask("editor/get", {}) or {}
    counts = collections.Counter(w.lower() for w in re.findall(r"[A-Za-z_][A-Za-z_0-9]*", ed.get("text", "")))
    last_counts = counts
    rows = [{"cells": [w, str(n)], "style": "ok" if n >= 3 else "", "data": w} for w, n in counts.most_common(20)]
    tell("panel/set", {"id": "words", "rows": rows})


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
                {"id": "words", "title": "Most ~u~sed words", "hint": "A table of the words used most in the file in front"},
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
        elif which == "words":
            tell("panel/open", {"id": "words", "title": "Most used words", "kind": "table", "columns": ["Word", "Times"]})
            panel_open = True
            show_words()
        send({"jsonrpc": "2.0", "id": m["id"], "result": None})
    elif method == "event":
        show_status()
        if panel_open and m["params"].get("name") == "save":
            show_words()
    elif method == "panel/select":
        w = m["params"].get("data", "")
        tell("ui/message", {"text": "\"%s\" is used %d times" % (w, last_counts.get(w, 0))})
    elif method == "panel/closed":
        panel_open = False
    elif method == "shutdown":
        sys.exit(0)
    elif "id" in m and method:
        send({"jsonrpc": "2.0", "id": m["id"], "error": {"code": -32601, "message": "unknown " + method}})
