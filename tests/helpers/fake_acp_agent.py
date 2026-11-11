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
    "slow"      sends a chunk every 50 ms until session/cancel, then stops with "cancelled"
    "read"      asks the client for fs/read_text_file, says what came back
    "other"     an update kind this client does not know, then end_turn
    "fail"      the prompt request fails with an error
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
            send({"jsonrpc": "2.0", "id": rid, "result": {"sessionId": session}})
    elif method == "session/prompt":
        blocks = m["params"]["prompt"]
        text = " ".join(b.get("text", "") for b in blocks if b.get("type") == "text")
        if text == "fail":
            send({"jsonrpc": "2.0", "id": rid, "error": {"code": -32603, "message": "the model is unavailable"}})
            continue
        reason = turn(rid, text)
        send({"jsonrpc": "2.0", "id": rid, "result": {"stopReason": reason}})
    elif method == "session/cancel":
        pass                                    # (no turn running)
    elif rid is not None and method is not None:
        send({"jsonrpc": "2.0", "id": rid, "error": {"code": -32601, "message": "unknown " + method}})
