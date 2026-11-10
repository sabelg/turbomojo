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
        if method is None and "id" in msg and str(mid).startswith("srv"):
            # the client's answer to one of our own requests
            main.client_answers = getattr(main, "client_answers", []) + [msg.get("result")]
            continue
        # ---- a minimal language server
        if method == "initialize":
            send({"jsonrpc": "2.0", "id": mid, "result": {
                # FAKE_SYNC=2: incremental sync with save notifications
                "capabilities": {"textDocumentSync": ({"openClose": True, "change": 2, "save": True}
                                                      if os.environ.get("FAKE_SYNC") == "2" else 1),
                                 "hoverProvider": True, "foldingRangeProvider": False, "definitionProvider": True, "codeActionProvider": {"resolveProvider": True},
                                 "executeCommandProvider": {"commands": ["fake.organise"]}, "referencesProvider": True,
                                 "signatureHelpProvider": {"triggerCharacters": ["(", ","]},
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
                                      "severity": sev, "code": "E%d" % sev, "message": "found %s\nsecond line of detail" % word})
            send({"jsonrpc": "2.0", "method": "window/logMessage", "params": {"type": 3, "message": "checked v%s" % doc.get("version")}})
            send({"jsonrpc": "2.0", "method": "textDocument/publishDiagnostics",
                  "params": {"uri": doc["uri"], "version": doc.get("version"), "diagnostics": diags}})
            continue
        if method == "textDocument/didClose":
            main.closed = getattr(main, "closed", []) + [params["textDocument"]["uri"]]
            DOCS.pop(params["textDocument"]["uri"], None)
            continue
        if method == "textDocument/completion":
            # what a small language server might offer; "." asks for members
            main.asked = getattr(main, "asked", []) + [{
                "line": params["position"]["line"], "character": params["position"]["character"],
                "kind": params.get("context", {}).get("triggerKind"), "char": params.get("context", {}).get("triggerCharacter")}]
            text = DOCS.get(params["textDocument"]["uri"], "")
            if "SLOWCOMPLETE" in text:
                time.sleep(0.4)
            if "BUSYSERVER" in text and len(main.asked) < 3:
                # like a real server that is still analysing the last edit
                send({"jsonrpc": "2.0", "id": mid, "error": {"code": -32801, "message": "outdated request"}})
                continue
            if "BROKENCOMPLETE" in text:
                send({"jsonrpc": "2.0", "id": mid, "error": {"code": -32603, "message": "internal error in completion"}})
                continue
            if params.get("context", {}).get("triggerCharacter") == ".":
                items = [{"label": "append", "kind": 2, "detail": "def append(self, value: T)", "sortText": "1", "data": 1},
                         {"label": "clear", "kind": 2, "detail": "def clear(self)", "sortText": "2", "data": 2},
                         {"label": "capacity", "kind": 5, "detail": "Int", "sortText": "0",
                          "documentation": "How many items fit before the list grows."}]
                send({"jsonrpc": "2.0", "id": mid, "result": items})
            elif "NOCOMPLETE" in text:
                send({"jsonrpc": "2.0", "id": mid, "result": None})
            else:
                items = [{"label": "print_line", "kind": 3, "detail": "def print_line(s: String)", "sortText": "b",
                          "documentation": {"kind": "markdown", "value": "Prints **s** and a line break.\n\n```mojo\nprint_line(\"hi\")\n```\nReturns nothing."}},
                         {"label": "prefix_len", "kind": 6, "detail": "Int", "sortText": "a"},
                         {"label": "Path", "kind": 22, "insertText": "Path()", "sortText": "c"},
                         {"label": "pass", "kind": 14, "sortText": "d"},
                         {"label": "Zebra", "kind": 7, "filterText": "prZ", "textEdit": {"newText": "zebra.Zebra"}, "sortText": "e"}]
                send({"jsonrpc": "2.0", "id": mid, "result": {"isIncomplete": False, "items": items}})
            continue
        if method == "textDocument/hover":
            text = DOCS.get(params["textDocument"]["uri"], "")
            main.hovers = getattr(main, "hovers", 0) + 1
            lines = text.split("\n")
            ln = params["position"]["line"]
            line = lines[ln] if ln < len(lines) else ""
            at = utf16_index(line, params["position"]["character"])
            a = at
            while a > 0 and (line[a - 1].isalnum() or line[a - 1] == "_"):
                a -= 1
            b = at
            while b < len(line) and (line[b].isalnum() or line[b] == "_"):
                b += 1
            word = line[a:b]
            if "HOVERBUSY" in text and main.hovers < 3:
                send({"jsonrpc": "2.0", "id": mid, "error": {"code": -32801, "message": "outdated request"}})
            elif not word:
                send({"jsonrpc": "2.0", "id": mid, "result": None})
            elif word == "old":
                # the older MarkedString forms, as an array
                send({"jsonrpc": "2.0", "id": mid, "result": {"contents": [
                    {"language": "mojo", "value": "def old(x: Int) -> Int"}, "Plain *words* after the code."]}})
            elif word == "long":
                body = "\n".join("- line %d of a long description" % i for i in range(40))
                send({"jsonrpc": "2.0", "id": mid, "result": {"contents": {"kind": "markdown", "value": "# long\n" + body}}})
            else:
                send({"jsonrpc": "2.0", "id": mid, "result": {"contents": {"kind": "markdown", "value":
                    "### function `%s`\n\n---\nDoes **important** things with [care](https://example.org).\n\n```mojo\ndef %s(n: Int) -> String\n```" % (word, word)},
                    "range": {"start": {"line": ln, "character": a}, "end": {"line": ln, "character": b}}}})
            continue
        if method == "textDocument/definition":
            uri = params["textDocument"]["uri"]
            text = DOCS.get(uri, "")
            main.defs = getattr(main, "defs", 0) + 1
            lines = text.split("\n")
            ln = params["position"]["line"]
            line = lines[ln] if ln < len(lines) else ""
            at = utf16_index(line, params["position"]["character"])
            a = at
            while a > 0 and (line[a - 1].isalnum() or line[a - 1] == "_"):
                a -= 1
            b = at
            while b < len(line) and (line[b].isalnum() or line[b] == "_"):
                b += 1
            word = line[a:b]
            places = []
            for k, l in enumerate(lines):
                idx = l.find("def " + word + "(")
                if word and idx >= 0:
                    col = len(l[:idx + 4].encode("utf-16-le")) // 2
                    places.append({"uri": uri, "range": {"start": {"line": k, "character": col},
                                                           "end": {"line": k, "character": col + len(word)}}})
            folder = uri.rsplit("/", 1)[0]
            if "DEFBUSY" in text and main.defs < 3:
                send({"jsonrpc": "2.0", "id": mid, "error": {"code": -32801, "message": "outdated request"}})
            elif word == "ext":
                # a LocationLink into another file: the name is at 2:4, the whole definition starts at 1:0
                send({"jsonrpc": "2.0", "id": mid, "result": [{
                    "targetUri": folder + "/other.mojo",
                    "targetRange": {"start": {"line": 1, "character": 0}, "end": {"line": 4, "character": 0}},
                    "targetSelectionRange": {"start": {"line": 2, "character": 4}, "end": {"line": 2, "character": 7}}}]})
            elif word == "gone":
                send({"jsonrpc": "2.0", "id": mid, "result": {"uri": folder + "/no_such_file.mojo",
                     "range": {"start": {"line": 0, "character": 0}, "end": {"line": 0, "character": 1}}}})
            elif word == "web":
                send({"jsonrpc": "2.0", "id": mid, "result": [{"uri": "https://example.org/x.mojo",
                     "range": {"start": {"line": 0, "character": 0}, "end": {"line": 0, "character": 1}}}]})
            elif not places:
                send({"jsonrpc": "2.0", "id": mid, "result": None})
            elif len(places) == 1:
                send({"jsonrpc": "2.0", "id": mid, "result": places[0]})      # a single Location, not a list
            else:
                send({"jsonrpc": "2.0", "id": mid, "result": places})
            continue
        if method == "textDocument/references":
            import re
            uri = params["textDocument"]["uri"]
            text = DOCS.get(uri, "")
            main.refs = getattr(main, "refs", 0) + 1
            main.ref_contexts = getattr(main, "ref_contexts", []) + [params.get("context")]
            lines = text.split("\n")
            ln = params["position"]["line"]
            line = lines[ln] if ln < len(lines) else ""
            at = utf16_index(line, params["position"]["character"])
            a = at
            while a > 0 and (line[a - 1].isalnum() or line[a - 1] == "_"):
                a -= 1
            b = at
            while b < len(line) and (line[b].isalnum() or line[b] == "_"):
                b += 1
            word = line[a:b]
            sources = [(uri, text)]
            if word == "shared":
                # also used in a file the editor has not opened
                other = uri.rsplit("/", 1)[0] + "/other.mojo"
                with open(other[len("file://"):], encoding="utf-8") as fh:
                    sources.append((other, fh.read()))
            places = []
            for u, t in sources:
                for k, l in enumerate(t.split("\n")):
                    for mm in re.finditer(r"\b%s\b" % re.escape(word), l) if word else []:
                        col = len(l[:mm.start()].encode("utf-16-le")) // 2
                        places.append({"uri": u, "range": {"start": {"line": k, "character": col},
                                                             "end": {"line": k, "character": col + len(word)}}})
            places.reverse()                 # servers promise no order
            if "REFBUSY" in text and main.refs < 3:
                send({"jsonrpc": "2.0", "id": mid, "error": {"code": -32801, "message": "outdated request"}})
            elif word == "nowhere" or not word:
                send({"jsonrpc": "2.0", "id": mid, "result": None if not word else []})
            else:
                send({"jsonrpc": "2.0", "id": mid, "result": places})
            continue
        if method in ("textDocument/prepareRename", "textDocument/rename"):
            import re
            uri = params["textDocument"]["uri"]
            text = DOCS.get(uri, "")
            lines = text.split("\n")
            ln = params["position"]["line"]
            line = lines[ln] if ln < len(lines) else ""
            at = utf16_index(line, params["position"]["character"])
            a = at
            while a > 0 and (line[a - 1].isalnum() or line[a - 1] == "_"):
                a -= 1
            b = at
            while b < len(line) and (line[b].isalnum() or line[b] == "_"):
                b += 1
            word = line[a:b]
            u16 = lambda s: len(s.encode("utf-16-le")) // 2
            rng = {"start": {"line": ln, "character": u16(line[:a])}, "end": {"line": ln, "character": u16(line[:b])}}
            if method == "textDocument/prepareRename":
                if not word or word == "fixed":
                    send({"jsonrpc": "2.0", "id": mid, "result": None})
                elif word == "bad":
                    send({"jsonrpc": "2.0", "id": mid, "error": {"code": -32602, "message": "cannot rename this"}})
                elif word == "plain":
                    send({"jsonrpc": "2.0", "id": mid, "result": {"defaultBehavior": True}})
                elif word == "ph":
                    send({"jsonrpc": "2.0", "id": mid, "result": {"range": rng, "placeholder": "placeholder_name"}})
                else:
                    send({"jsonrpc": "2.0", "id": mid, "result": rng})
                continue
            new = params["newName"]
            main.renames = getattr(main, "renames", []) + [new]
            sources = [(uri, text)]
            if word == "shared":
                other = uri.rsplit("/", 1)[0] + "/other.mojo"
                if other in DOCS:
                    sources.append((other, DOCS[other]))
                else:
                    with open(other[len("file://"):], encoding="utf-8") as fh:
                        sources.append((other, fh.read()))
            changes = {}
            for u, t in sources:
                for k, l in enumerate(t.split("\n")):
                    for mm in re.finditer(r"\b%s\b" % re.escape(word), l):
                        changes.setdefault(u, []).append({"range": {
                            "start": {"line": k, "character": u16(l[:mm.start()])},
                            "end": {"line": k, "character": u16(l[:mm.end()])}}, "newText": new})
            if "RENBUSY" in text and len(main.renames) < 3:
                send({"jsonrpc": "2.0", "id": mid, "error": {"code": -32801, "message": "outdated request"}})
            elif "RENSLOW" in text:
                main.held = {"jsonrpc": "2.0", "id": mid, "result": {"changes": changes}}     # answered on "release"
            elif new == "1bad":
                send({"jsonrpc": "2.0", "id": mid, "error": {"code": -32602, "message": "invalid name"}})
            elif word == "nothing":
                send({"jsonrpc": "2.0", "id": mid, "result": {"changes": {}}})
            elif word == "mover":
                send({"jsonrpc": "2.0", "id": mid, "result": {"documentChanges": [
                    {"textDocument": {"uri": uri, "version": 1}, "edits": changes[uri]},
                    {"kind": "rename", "oldUri": uri, "newUri": uri + ".new"}]}})
            elif word == "clash":
                send({"jsonrpc": "2.0", "id": mid, "result": {"changes": {uri: [
                    {"range": {"start": {"line": ln, "character": 0}, "end": {"line": ln, "character": 4}}, "newText": "x"},
                    {"range": {"start": {"line": ln, "character": 2}, "end": {"line": ln, "character": 5}}, "newText": "y"}]}}})
            elif word == "far":
                send({"jsonrpc": "2.0", "id": mid, "result": {"changes": {uri: [
                    {"range": {"start": {"line": 999, "character": 0}, "end": {"line": 999, "character": 1}}, "newText": "x"}]}}})
            elif "DOCCHANGES" in text:
                send({"jsonrpc": "2.0", "id": mid, "result": {"documentChanges": [
                    {"textDocument": {"uri": u, "version": None}, "edits": list(reversed(e))} for u, e in changes.items()]}})
            else:
                send({"jsonrpc": "2.0", "id": mid, "result": {"changes": changes}})
            continue
        if method == "release":             # send the answer that was held back
            send(main.held)
            continue
        if method == "textDocument/codeAction":
            uri = params["textDocument"]["uri"]
            text = DOCS.get(uri, "")
            lines = text.split("\n")
            ln = params["range"]["start"]["line"]
            line = lines[ln] if ln < len(lines) else ""
            main.actions_asked = getattr(main, "actions_asked", []) + [
                {"range": params["range"], "codes": [d.get("code") for d in params["context"]["diagnostics"]]}]
            u16 = lambda s: len(s.encode("utf-16-le")) // 2

            def swap(old, new, in_uri=uri, in_line=None, row=None):
                l = line if in_line is None else in_line
                r = ln if row is None else row
                at = l.find(old)
                return {"range": {"start": {"line": r, "character": u16(l[:at])},
                                  "end": {"line": r, "character": u16(l[:at + len(old)])}}, "newText": new}

            organise = {"title": "Organise imports", "command": "fake.organise", "arguments": [uri]}
            out_actions = []
            if "typo" in line:
                out_actions = [
                    {"title": "Extract to a function", "kind": "refactor.extract", "disabled": {"reason": "nothing is selected"}},
                    organise,
                    {"title": "Add a comment", "kind": "quickfix",
                     "edit": {"changes": {uri: [{"range": {"start": {"line": ln, "character": 0}, "end": {"line": ln, "character": 0}}, "newText": "# note\n"}]}}},
                    {"title": "Change 'typo' to 'type'", "kind": "quickfix", "isPreferred": True,
                     "edit": {"changes": {uri: [swap("typo", "type")]}}},
                    {"kind": "quickfix"},                       # no title: not shown
                ]
            elif "lazy" in line:
                out_actions = [{"title": "Make it eager", "kind": "quickfix", "data": {"line": ln}}]
            elif "both" in line:
                out_actions = [{"title": "Finish and organise", "kind": "source",
                                "edit": {"documentChanges": [{"textDocument": {"uri": uri, "version": 1}, "edits": [swap("both", "done")]}]},
                                "command": organise}]
            elif "wide" in line:
                other = uri.rsplit("/", 1)[0] + "/other.mojo"
                with open(other[len("file://"):], encoding="utf-8") as fh:
                    first = fh.read().split("\n")[0]
                out_actions = [{"title": "Rename wide everywhere", "kind": "refactor",
                                "edit": {"changes": {uri: [swap("wide", "broad")], other: [swap("wide", "broad", other, first, 0)]}}}]
            elif "empty" in line:
                out_actions = [{"title": "Does nothing", "kind": "quickfix", "edit": {"changes": {}}}]
            if "ACTBUSY" in text and len(main.actions_asked) < 3:
                send({"jsonrpc": "2.0", "id": mid, "error": {"code": -32801, "message": "outdated request"}})
            else:
                send({"jsonrpc": "2.0", "id": mid, "result": out_actions if "nullanswer" not in line else None})
            continue
        if method == "codeAction/resolve":
            item = dict(params)
            uri = next(iter(DOCS))
            ln = params["data"]["line"]
            l = DOCS[uri].split("\n")[ln]
            at = l.find("lazy")
            item["edit"] = {"changes": {uri: [{"range": {"start": {"line": ln, "character": at}, "end": {"line": ln, "character": at + 4}}, "newText": "eager"}]}}
            main.resolved_actions = getattr(main, "resolved_actions", 0) + 1
            send({"jsonrpc": "2.0", "id": mid, "result": item})
            continue
        if method == "workspace/executeCommand":
            main.executed = getattr(main, "executed", []) + [params]
            uri = params["arguments"][0]
            send({"jsonrpc": "2.0", "id": "srv%d" % len(main.executed), "method": "workspace/applyEdit", "params": {
                "label": "Organise imports",
                "edit": {"changes": {uri: [{"range": {"start": {"line": 0, "character": 0}, "end": {"line": 0, "character": 0}}, "newText": "# organised\n"}]}}}})
            send({"jsonrpc": "2.0", "id": mid, "result": None})
            continue
        if method == "textDocument/signatureHelp":
            text = DOCS.get(params["textDocument"]["uri"], "")
            main.sigs = getattr(main, "sigs", 0) + 1
            main.sig_contexts = getattr(main, "sig_contexts", []) + [params.get("context")]
            lines = text.split("\n")
            ln = params["position"]["line"]
            line = lines[ln] if ln < len(lines) else ""
            at = utf16_index(line, params["position"]["character"])
            # the innermost call still open before the cursor, and the commas typed in it
            depth = 0
            commas = 0
            open_at = -1
            k = at - 1
            while k >= 0:
                ch = line[k]
                if ch == ")":
                    depth += 1
                elif ch == "(":
                    if depth == 0:
                        open_at = k
                        break
                    depth -= 1
                elif ch == "," and depth == 0:
                    commas += 1
                k -= 1
            a = open_at
            while a > 0 and (line[a - 1].isalnum() or line[a - 1] == "_"):
                a -= 1
            name = line[a:open_at] if open_at >= 0 else ""
            if "SIGBUSY" in text and main.sigs < 3:
                send({"jsonrpc": "2.0", "id": mid, "error": {"code": -32801, "message": "outdated request"}})
            elif not name:
                send({"jsonrpc": "2.0", "id": mid, "result": None})
            elif name == "offsets":
                # labels as [start, end) in UTF-16 units; the text starts with a non-BMP char
                label = "\U0001F600 offsets(first: Int, second: Int)"
                send({"jsonrpc": "2.0", "id": mid, "result": {"signatures": [{"label": label, "parameters": [
                    {"label": [11, 21]}, {"label": [23, 34], "documentation": {"kind": "markdown", "value": "The **second** one."}}]}],
                    "activeSignature": 0, "activeParameter": commas}})
            elif name == "over":
                send({"jsonrpc": "2.0", "id": mid, "result": {"signatures": [
                    {"label": "over(a: Int)", "parameters": [{"label": "a: Int"}]},
                    {"label": "over(a: Int, a2: Int)", "documentation": "The two-argument form.",
                     "parameters": [{"label": "a: Int"}, {"label": "a2: Int"}], "activeParameter": commas}],
                    "activeSignature": 1 if commas > 0 else 0, "activeParameter": 0}})
            elif name == "wide":
                params_ = ["argument_number_%d: SomeLongTypeName" % i for i in range(8)]
                send({"jsonrpc": "2.0", "id": mid, "result": {"signatures": [
                    {"label": "wide(" + ", ".join(params_) + ") -> Nothing", "parameters": [{"label": q} for q in params_]}],
                    "activeParameter": commas}})
            else:
                send({"jsonrpc": "2.0", "id": mid, "result": {"signatures": [
                    {"label": "%s(n: Int, name: String) -> Bool" % name,
                     "parameters": [{"label": "n: Int"}, {"label": "name: String"}]}],
                    "activeSignature": 0, "activeParameter": commas}})
            continue
        if method == "completionItem/resolve":
            item = dict(params)
            item["documentation"] = "Details for %s, fetched on request." % params.get("label")
            main.resolved = getattr(main, "resolved", []) + [params.get("label")]
            send({"jsonrpc": "2.0", "id": mid, "result": item})
            continue
        if method == "textDocument/didSave":
            SAVED.append(params["textDocument"]["uri"])
            continue
        if method == "doc_state":        # what this server holds, for the tests
            send({"jsonrpc": "2.0", "id": mid, "result": {
                "docs": DOCS, "saved": SAVED, "asked": getattr(main, "asked", []), "sig_contexts": getattr(main, "sig_contexts", []), "ref_contexts": getattr(main, "ref_contexts", []), "renames": getattr(main, "renames", []), "actions_asked": getattr(main, "actions_asked", []),
                "executed": getattr(main, "executed", []), "client_answers": getattr(main, "client_answers", []),
                "resolved_actions": getattr(main, "resolved_actions", 0), "resolved": getattr(main, "resolved", []), "ranged": getattr(main, "ranged", 0), "whole": getattr(main, "whole", 0)}})
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
