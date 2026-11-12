#!/usr/bin/env python3
"""A scripted ACP agent over stdio for testing the IDE's ACP client (tests/test_acp.mojo).

    fake_acp_agent.py <log file> [mode]

One JSON-RPC message per line in each direction. Every message received is appended to
the log file as one line (the JSON as received). Modes:
    ""          a normal agent (protocol version 1)
    "v2"        answers initialize with protocol version 2
    "noinit"    never answers initialize
    "nosession" session/new fails (and authMethods are advertised)
    "die"       exits right after initialize
The prompt's text chooses what a turn does:
    "hello"     two message chunks "Hel" "lo", a thought, then end_turn
    "tool"      a tool call (read, with a location), an update with text and a diff, completed
    "plan"      a plan with two entries
    "perm"      asks for permission (allow / reject options) and says what it was told
    "permrun"   asks for permission to run `git status --short` (execute; allow once,
                allow always, reject)
    "slow"      sends a chunk every 50 ms until session/cancel, then stops with "cancelled"
    "read"      asks the client for fs/read_text_file, says what came back
    "other"     an update kind this client does not know, then end_turn
    "fail"      the prompt request fails with an error
    "readfile P" / "readlines P" (line 2, limit 1)   asks the client for file P
    "write P TEXT"  asks the client to write TEXT (\\n for line feeds) to P
    "run CMD"       runs sh -c CMD in a client terminal (64-byte output limit), waits,
                    reads the output, releases it, and says it all
    "killrun"       starts "sleep 30", kills it, says how it ended
A prompt with blocks other than text (mentions) is answered with what they were.
Lines it writes to stdout that are not JSON: never (the protocol forbids it); with
"noise" in the prompt it writes a log line to stderr instead.
"""
import json
import select
import sys
import time

log_path = sys.argv[1]
mode = sys.argv[2] if len(sys.argv) > 2 else ""
out = sys.stdout
inp = sys.stdin
next_id = 1000
session = "sess_fake_1"
pending = []        # messages read while waiting for something else


def log(line):
    with open(log_path, "a") as f:
        f.write(line.rstrip("\n") + "\n")


def send(obj):
    out.write(json.dumps(obj) + "\n")
    out.flush()


def update(u):
    send({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": session, "update": u}})


def chunk(text, kind="agent_message_chunk"):
    update({"sessionUpdate": kind, "content": {"type": "text", "text": text}})


def read_msg(timeout=None):
    if pending:
        return pending.pop(0)
    if timeout is not None:
        r, _, _ = select.select([inp], [], [], timeout)
        if not r:
            return None
    line = inp.readline()
    if not line:
        sys.exit(0)
    line = line.strip()
    if not line:
        return read_msg(timeout)
    log(line)
    return json.loads(line)


def ask(method, params):
    """Send a request to the client and wait for its answer (other messages are kept)."""
    global next_id
    next_id += 1
    rid = next_id
    send({"jsonrpc": "2.0", "id": rid, "method": method, "params": params})
    held = []
    while True:
        m = read_msg()
        if m.get("id") == rid and "method" not in m:
            pending.extend(held)
            return m
        held.append(m)


def turn(rid, text):
    if text.startswith("Explain this"):
        # an "explain" request: say what it was given, answer with one real import and one made up
        chunk("pages given: %d; rules: %s; numbered: %s|" % (text.count("### Page: "), "[page:" in text, "\n3: " in text))
        chunk("Use this:\n\n```mojo\nfrom std.collections import List\nfrom std.collections import NoSuchThing\n```\n")
        return "end_turn"
    if "noise" in text:
        sys.stderr.write("fake agent: a log line on stderr\n")
        sys.stderr.flush()
    if text == "hello":
        chunk("Hel")
        chunk("lo")
        chunk("thinking about it", "agent_thought_chunk")
        return "end_turn"
    if text == "tool":
        update({"sessionUpdate": "tool_call", "toolCallId": "call_1", "title": "Reading a.mojo", "kind": "read",
                "status": "pending", "locations": [{"path": "/p/a.mojo", "line": 3}]})
        update({"sessionUpdate": "tool_call_update", "toolCallId": "call_1", "status": "in_progress"})
        update({"sessionUpdate": "tool_call_update", "toolCallId": "call_1", "status": "completed",
                "content": [{"type": "content", "content": {"type": "text", "text": "3 lines"}},
                            {"type": "diff", "path": "/p/a.mojo", "oldText": "a", "newText": "b"}]})
        return "end_turn"
    if text == "plan":
        update({"sessionUpdate": "plan", "entries": [
            {"content": "Read the file", "priority": "high", "status": "completed"},
            {"content": "Fix the bug", "priority": "medium", "status": "pending"}]})
        return "end_turn"
    if text == "permrun":
        r = ask("session/request_permission", {
            "sessionId": session,
            "toolCall": {"toolCallId": "call_3", "title": "`git status --short`", "kind": "execute"},
            "options": [{"optionId": "yes", "name": "Allow", "kind": "allow_once"},
                        {"optionId": "always", "name": "Always", "kind": "allow_always"},
                        {"optionId": "no", "name": "Reject", "kind": "reject_once"}]})
        o = r.get("result", {}).get("outcome", {})
        chunk("told: " + o.get("outcome", "?") + ((" " + o["optionId"]) if "optionId" in o else ""))
        return "end_turn"
    if text == "perm":
        update({"sessionUpdate": "tool_call", "toolCallId": "call_2", "title": "Write b.mojo", "kind": "edit", "status": "pending"})
        r = ask("session/request_permission", {
            "sessionId": session,
            "toolCall": {"toolCallId": "call_2", "title": "Write b.mojo", "kind": "edit"},
            "options": [{"optionId": "allow", "name": "Allow once", "kind": "allow_once"},
                        {"optionId": "reject", "name": "Reject", "kind": "reject_once"}]})
        o = r.get("result", {}).get("outcome", {})
        chunk("told: " + o.get("outcome", "?") + ((" " + o["optionId"]) if "optionId" in o else ""))
        return "end_turn"
    if text == "slow":
        n = 0
        held = []
        while True:
            m = read_msg(0.05)
            if m is not None:
                if m.get("method") == "session/cancel":
                    pending.extend(held)
                    return "cancelled"
                held.append(m)
                continue
            n += 1
            chunk("tick %d " % n)
    if text == "read":
        r = ask("fs/read_text_file", {"sessionId": session, "path": "/p/a.mojo"})
        if "error" in r:
            chunk("read refused: %d" % r["error"]["code"])
        else:
            chunk("read: " + r["result"]["content"])
        return "end_turn"
    word, _, rest = text.partition(" ")
    if word == "readfile":
        r = ask("fs/read_text_file", {"sessionId": session, "path": rest})
        chunk(("read error: " + r["error"]["message"]) if "error" in r else ("read: " + r["result"]["content"]))
        return "end_turn"
    if word == "readlines":
        r = ask("fs/read_text_file", {"sessionId": session, "path": rest, "line": 2, "limit": 1})
        chunk(("read error: " + r["error"]["message"]) if "error" in r else ("lines: " + r["result"]["content"]))
        return "end_turn"
    if word == "write":
        path, _, content = rest.partition(" ")
        r = ask("fs/write_text_file", {"sessionId": session, "path": path, "content": content.replace("\\n", "\n")})
        chunk(("write refused: " + r["error"]["message"]) if "error" in r else "write: ok")
        return "end_turn"
    if word == "run":
        r = ask("terminal/create", {"sessionId": session, "command": "sh", "args": ["-c", rest], "env": [{"name": "FAKE_AGENT_VAR", "value": "set"}], "outputByteLimit": 64})
        if "error" in r:
            chunk("run refused: " + r["error"]["message"])
            return "end_turn"
        tid = r["result"]["terminalId"]
        w = ask("terminal/wait_for_exit", {"sessionId": session, "terminalId": tid})
        o = ask("terminal/output", {"sessionId": session, "terminalId": tid})
        ask("terminal/release", {"sessionId": session, "terminalId": tid})
        gone = ask("terminal/output", {"sessionId": session, "terminalId": tid})
        res = o["result"]
        chunk("exit %s truncated %s: %s|released: %s" % (w["result"]["exitCode"], res["truncated"], res["output"], "error" in gone))
        return "end_turn"
    if word == "killrun":
        r = ask("terminal/create", {"sessionId": session, "command": "sleep 30"})
        if "error" in r:
            chunk("run refused: " + r["error"]["message"])
            return "end_turn"
        tid = r["result"]["terminalId"]
        o = ask("terminal/output", {"sessionId": session, "terminalId": tid})
        ask("terminal/kill", {"sessionId": session, "terminalId": tid})
        w = ask("terminal/wait_for_exit", {"sessionId": session, "terminalId": tid})
        ask("terminal/release", {"sessionId": session, "terminalId": tid})
        chunk("before kill: %s; signal %s" % ("exitStatus" in o["result"], w["result"]["signal"]))
        return "end_turn"
    if text == "other":
        update({"sessionUpdate": "available_commands_update", "availableCommands": []})
        return "end_turn"
    chunk("you said: " + text)
    return "end_turn"


while True:
    m = read_msg()
    method = m.get("method")
    rid = m.get("id")
    if method == "initialize":
        if mode == "noinit":
            continue
        version = 2 if mode == "v2" else 1
        auth = [{"id": "login", "name": "Log in"}] if mode == "nosession" else []
        send({"jsonrpc": "2.0", "id": rid, "result": {
            "protocolVersion": version,
            "agentCapabilities": {"loadSession": True, "promptCapabilities": {"image": False, "audio": False, "embeddedContext": True}},
            "agentInfo": {"name": "fake-agent", "title": "Fake Agent", "version": "0.1"},
            "authMethods": auth}})
        if mode == "die":
            sys.exit(0)
    elif method == "session/new":
        if mode == "nosession":
            send({"jsonrpc": "2.0", "id": rid, "error": {"code": -32000, "message": "Authentication required"}})
        else:
            send({"jsonrpc": "2.0", "id": rid, "result": {"sessionId": session, "modes": {
                "currentModeId": "auto",
                "availableModes": [{"id": "default", "name": "Manual", "description": "Always ask before making changes"},
                                   {"id": "auto", "name": "Auto", "description": "Decides by itself"},
                                   {"id": "plan", "name": "Plan", "description": "Plans first"}]}}})
    elif method == "session/set_mode":
        if m["params"].get("modeId") not in ("default", "auto", "plan"):
            send({"jsonrpc": "2.0", "id": rid, "error": {"code": -32602, "message": "no such mode"}})
        else:
            send({"jsonrpc": "2.0", "id": rid, "result": {}})
    elif method == "session/prompt":
        blocks = m["params"]["prompt"]
        text = " ".join(b.get("text", "") for b in blocks if b.get("type") == "text")
        if text == "fail":
            send({"jsonrpc": "2.0", "id": rid, "error": {"code": -32603, "message": "the model is unavailable"}})
            continue
        extra = [b for b in blocks if b.get("type") != "text"]
        if extra:
            for b in extra:
                if b["type"] == "resource":
                    r = b["resource"]
                    chunk("got resource %s (%s): %s|" % (r["uri"], r.get("mimeType", ""), r.get("text", "")))
                else:
                    chunk("got %s %s|" % (b["type"], b.get("uri", "")))
            send({"jsonrpc": "2.0", "id": rid, "result": {"stopReason": "end_turn"}})
            continue
        reason = turn(rid, text)
        send({"jsonrpc": "2.0", "id": rid, "result": {"stopReason": reason}})
    elif method == "session/cancel":
        pass                                    # (no turn running)
    elif rid is not None and method is not None:
        send({"jsonrpc": "2.0", "id": rid, "error": {"code": -32601, "message": "unknown " + method}})
