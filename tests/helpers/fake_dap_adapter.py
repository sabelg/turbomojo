#!/usr/bin/env python3
"""A scripted debug adapter over stdio for testing the IDE's DAP client (tests/test_dap.mojo).

    fake_dap_adapter.py <log file> [mode]

Every request received is appended to the log file as one line "command arguments-json".
The program named in `launch` chooses what the "debuggee" does:
    .../exit3     writes two lines, exits with status 3
    .../stop      stops at /src/stop.mojo:12 in main() (thread 7); `continue` lets it
                  write a line and exit with status 0
    .../forever   runs until the session is ended; a real child process stands in for
                  the debuggee and its pid is reported
    .../nostart   the launch fails
Modes: "die" - the adapter exits right after `initialize`; "deaf" - `disconnect` is
ignored (the client must stop adapter and debuggee by itself); "ask" - the adapter sends a
runInTerminal request before it launches.
"""
import json
import os
import subprocess
import sys

log_path = sys.argv[1]
mode = sys.argv[2] if len(sys.argv) > 2 else ""
out = sys.stdout.buffer
inp = sys.stdin.buffer
seq = 0
child = None


def send(obj):
    global seq
    seq += 1
    obj["seq"] = seq
    body = json.dumps(obj).encode()
    out.write(b"Content-Length: %d\r\n\r\n" % len(body) + body)
    out.flush()


def event(name, body=None):
    m = {"type": "event", "event": name}
    if body is not None:
        m["body"] = body
    send(m)


def respond(req, body=None, success=True, message=None):
    m = {"type": "response", "request_seq": req["seq"], "command": req["command"], "success": success}
    if body is not None:
        m["body"] = body
    if message is not None:
        m["message"] = message
    send(m)


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


def note(text):
    with open(log_path, "a") as f:
        f.write(text + "\n")


launch = None
program = ""
while True:
    m = read_message()
    if m is None:
        break
    if m.get("type") == "response":
        note("response " + m.get("command", "") + " " + json.dumps({"success": m.get("success"), "message": m.get("message", "")}, sort_keys=True))
        continue
    cmd = m.get("command", "")
    note(cmd + " " + json.dumps(m.get("arguments", {}), sort_keys=True))
    if cmd == "initialize":
        respond(m, {"supportsConfigurationDoneRequest": True, "supportsConditionalBreakpoints": True, "supportsStepBack": False})
        if mode == "die":
            sys.exit(0)
    elif cmd == "launch":
        launch = m
        program = os.path.basename(m["arguments"]["program"])
        if program == "nostart":
            respond(m, {"error": {"id": 1, "format": "no such file: nostart"}}, success=False, message="launch failed")
            continue
        if mode == "ask":
            send({"type": "request", "command": "runInTerminal", "arguments": {"args": ["x"]}})
        event("output", {"category": "console", "output": "Welcome to fake debugging\n"})
        event("initialized")
    elif cmd == "setBreakpoints":
        lines = [b["line"] for b in m["arguments"].get("breakpoints", [])]
        respond(m, {"breakpoints": [{"verified": True, "line": l} for l in lines]})
    elif cmd == "setExceptionBreakpoints":
        respond(m, {})
    elif cmd == "configurationDone":
        respond(m)
        respond(launch)
        event("capabilities", {"capabilities": {"supportsRestartRequest": True}})
        if program == "forever":
            child = subprocess.Popen(["sleep", "300"], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            event("process", {"name": program, "systemProcessId": child.pid})
            event("output", {"category": "stdout", "output": "started\r\n"})
        elif program == "stop":
            event("process", {"name": program, "systemProcessId": 0})
            event("output", {"category": "stdout", "output": "before the stop\n"})
            event("stopped", {"reason": "breakpoint", "description": "breakpoint 1.1", "threadId": 7, "allThreadsStopped": True})
        else:
            event("output", {"category": "stdout", "output": "args: " + " | ".join(m_arg for m_arg in launch["arguments"].get("args", [])) + "\n"})
            event("output", {"category": "stderr", "output": "a line on stderr\n"})
            event("output", {"category": "telemetry", "output": "not for people"})
            event("exited", {"exitCode": 3})
            event("terminated")
    elif cmd == "stackTrace":
        respond(m, {"stackFrames": [{"id": 1, "name": "stop::main()", "line": 12, "column": 5, "source": {"name": "stop.mojo", "path": os.environ.get("FAKE_DAP_SOURCE", "/src/stop.mojo")}}], "totalFrames": 3})
    elif cmd == "continue":
        respond(m, {"allThreadsContinued": True})
        event("continued", {"threadId": 7, "allThreadsContinued": True})
        event("output", {"category": "stdout", "output": "after the stop\n"})
        event("exited", {"exitCode": 0})
        event("terminated")
    elif cmd == "disconnect":
        if mode == "deaf":
            continue
        if child is not None:
            child.kill()
            child.wait()
        respond(m)
        break
    else:
        respond(m, success=False, message="unknown command " + cmd)
