#!/usr/bin/env python3
"""A tiny JSON-RPC server over stdio for testing the IDE's transport (tests/test_rpc.mojo)."""
import json
import sys
import time

out = sys.stdout.buffer
inp = sys.stdin.buffer


def frame(obj):
    body = json.dumps(obj).encode()
    return b"Content-Length: %d\r\n\r\n" % len(body) + body


def send(obj):
    out.write(frame(obj))
    out.flush()


def read_message():
    length = None
    while True:
        line = inp.readline()
        if not line:
            return None
        line = line.strip()
        if not line:
            break
        name, _, value = line.partition(b":")
        if name.lower() == b"content-length":
            length = int(value)
    if length is None:
        return None
    return json.loads(inp.read(length))


DOCS = {}          # uri -> current text, as this server understands it
SAVED = []


def utf16_index(line, units):
    """Index into a Python string for a column counted in UTF-16 code units."""
    n = 0
    for i, ch in enumerate(line):
        if n >= units:
            return i
        n += 2 if ord(ch) > 0xFFFF else 1
    return len(line)


def offset_of(text, line, character):
    start = 0
    for _ in range(line):
        nl = text.find("\n", start)
        if nl < 0:
            return len(text)
        start = nl + 1
    end = text.find("\n", start)
    if end < 0:
        end = len(text)
    return start + utf16_index(text[start:end], character)


def apply_changes(text, changes):
    for ch in changes:
        if "range" not in ch:
            text = ch["text"]
            continue
        a = offset_of(text, ch["range"]["start"]["line"], ch["range"]["start"]["character"])
        b = offset_of(text, ch["range"]["end"]["line"], ch["range"]["end"]["character"])
        text = text[:a] + ch["text"] + text[b:]
    return text


def main():
    # FAKE_START_LOG=path: note every launch (tests count restarts with it)
    import os
    log = os.environ.get("FAKE_START_LOG")
    if log:
        with open(log, "a") as f:
            f.write(" ".join(sys.argv[1:]) + "\n")
    while True:
        msg = read_message()
        if msg is None:
            return 0                      # stdin closed
        method = msg.get("method")
        mid = msg.get("id")
        params = msg.get("params")
        if method == "exit":
            return 0
        # ---- a minimal language server
        if method == "initialize":
            send({"jsonrpc": "2.0", "id": mid, "result": {
                # FAKE_SYNC=2: incremental sync with save notifications
                "capabilities": {"textDocumentSync": ({"openClose": True, "change": 2, "save": True}
                                                      if os.environ.get("FAKE_SYNC") == "2" else 1),
                                 "hoverProvider": True, "foldingRangeProvider": False,
                                 "completionProvider": {"triggerCharacters": [".", "("], "resolveProvider": True},
                                 "renameProvider": {"prepareProvider": True}},
                "serverInfo": {"name": "fake-lsp"}}})
            continue
        if method == "initialized":
            send({"jsonrpc": "2.0", "id": 900, "method": "client/registerCapability", "params": {"registrations": []}})
            send({"jsonrpc": "2.0", "id": 901, "method": "workspace/configuration", "params": {"items": [{}, {}]}})
            send({"jsonrpc": "2.0", "id": 902, "method": "window/unknownThing", "params": {}})
            continue
        if method is None and mid in (900, 901, 902):
            main.replies = getattr(main, "replies", {})
            main.replies[str(mid)] = {"result": msg.get("result", "absent"), "error": msg.get("error")}
            continue
        if method == "client_replies":
            send({"jsonrpc": "2.0", "id": mid, "result": getattr(main, "replies", {})})
            continue
        if method in ("textDocument/didOpen", "textDocument/didChange"):
            doc = params["textDocument"]
            if method.endswith("didOpen"):
                text = doc["text"]
            else:
                text = apply_changes(DOCS.get(doc["uri"], ""), params["contentChanges"])
                main.ranged = getattr(main, "ranged", 0) + sum(1 for c in params["contentChanges"] if "range" in c)
                main.whole = getattr(main, "whole", 0) + sum(1 for c in params["contentChanges"] if "range" not in c)
            DOCS[doc["uri"]] = text
            diags = []
            for n, line in enumerate(text.split("\n")):
                for word, sev in (("BUG", 1), ("WARN", 2)):
                    at = line.find(word)
                    if at >= 0:
                        ch = len(line[:at].encode("utf-16-le")) // 2
                        diags.append({"range": {"start": {"line": n, "character": ch},
                                                "end": {"line": n, "character": ch + len(word)}},
                                      "severity": sev, "message": "found %s\nsecond line of detail" % word})
            send({"jsonrpc": "2.0", "method": "window/logMessage", "params": {"type": 3, "message": "checked v%s" % doc.get("version")}})
            send({"jsonrpc": "2.0", "method": "textDocument/publishDiagnostics",
                  "params": {"uri": doc["uri"], "version": doc.get("version"), "diagnostics": diags}})
            continue
        if method == "textDocument/didClose":
            main.closed = getattr(main, "closed", []) + [params["textDocument"]["uri"]]
            DOCS.pop(params["textDocument"]["uri"], None)
            continue
        if method == "textDocument/didSave":
            SAVED.append(params["textDocument"]["uri"])
            continue
        if method == "doc_state":        # what this server holds, for the tests
            send({"jsonrpc": "2.0", "id": mid, "result": {
                "docs": DOCS, "saved": SAVED, "ranged": getattr(main, "ranged", 0), "whole": getattr(main, "whole", 0)}})
            continue
        if method == "closed_docs":
            send({"jsonrpc": "2.0", "id": mid, "result": getattr(main, "closed", [])})
            continue
        if method == "shutdown":
            send({"jsonrpc": "2.0", "id": mid, "result": None})
            continue
        if method == "echo":
            send({"jsonrpc": "2.0", "id": mid, "result": params})
        elif method == "add":
            send({"jsonrpc": "2.0", "id": mid, "result": params["a"] + params["b"]})
        elif method == "fail":
            send({"jsonrpc": "2.0", "id": mid, "error": {"code": -32000, "message": "boom"}})
        elif method == "notify_then_reply":
            send({"jsonrpc": "2.0", "method": "log", "params": {"text": "working"}})
            send({"jsonrpc": "2.0", "id": mid, "result": "done"})
        elif method == "split":
            data = frame({"jsonrpc": "2.0", "id": mid, "result": "in pieces"})
            for i in range(0, len(data), 7):
                out.write(data[i:i + 7])
                out.flush()
                time.sleep(0.01)
        elif method == "burst":
            data = b"".join(frame({"jsonrpc": "2.0", "method": "tick", "params": {"n": n}}) for n in range(3))
            data += frame({"jsonrpc": "2.0", "id": mid, "result": "after burst"})
            out.write(data)
            out.flush()
        elif method == "big":
            send({"jsonrpc": "2.0", "id": mid, "result": "x" * params["n"]})
        elif method == "count_bytes":
            send({"jsonrpc": "2.0", "id": mid, "result": len(params["data"])})
        elif method == "ask":
            send({"jsonrpc": "2.0", "id": "srv-1", "method": "client/confirm", "params": {"question": "ok?"}})
            answer = read_message()
            send({"jsonrpc": "2.0", "id": mid, "result": {"client_said": answer.get("result"), "client_error": answer.get("error")}})
        elif method == "garbage":
            out.write(b"some stray log line\n")
            send({"jsonrpc": "2.0", "id": mid, "result": "still fine"})
        elif method == "stderr":
            sys.stderr.write("warning from the server\n")
            sys.stderr.flush()
            send({"jsonrpc": "2.0", "id": mid, "result": "wrote stderr"})
        elif method == "never":
            pass                          # no reply: the client must time out
        elif method == "die":
            return 3
        elif method == "seen":            # notification: remember it
            main.seen = getattr(main, "seen", 0) + 1
        elif method == "how_many_seen":
            send({"jsonrpc": "2.0", "id": mid, "result": getattr(main, "seen", 0)})
        elif mid is not None:
            send({"jsonrpc": "2.0", "id": mid, "error": {"code": -32601, "message": "method not found: %s" % method}})


if __name__ == "__main__":
    sys.exit(main())
