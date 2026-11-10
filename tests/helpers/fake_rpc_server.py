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


def main():
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
                "capabilities": {"textDocumentSync": 1, "hoverProvider": True, "foldingRangeProvider": False},
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
            text = doc["text"] if method.endswith("didOpen") else params["contentChanges"][0]["text"]
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
