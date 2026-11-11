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
    .../bp        stops at the first breakpoint it was given (thread 7), then exits
    .../steps     stops on line 2 of $FAKE_DAP_SOURCE in main(); next goes one line on;
                  step in on line 3 enters a library function without a source, on
                  line 4 the function helper() at line 10; step out returns; a breakpoint
                  of a later line is where `continue` stops, else it exits
    .../vars      stops in work() (line 5 of $FAKE_DAP_SOURCE, called from main() on
                  line 9) with variables shaped like Mojo 1.2's debugger shows them;
                  writeMemory changes them
    .../forever   (also) `pause` stops it inside a C function without a source, called
                  from line 7 of $FAKE_DAP_SOURCE
Breakpoints: lines from 1000 on cannot be placed; line 99 is placed on line 100; the
first breakpoint is reported again by a "breakpoint" event (changed, verified) once the
program runs; the log messages of the breakpoints are written to the console when the program starts.
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
next_id = 0
SOURCE = os.environ.get("FAKE_DAP_SOURCE", "/src/stop.mojo")
frames = []         # innermost first: (name, path, line)
memory = {"0xFF00": 4, "0xFF08": 1}
ip = 0xAAAA0F20     # the instruction the "vars" program is at
pc_moves = 0


def raw(n, width=8):
    return n.to_bytes(width, "little", signed=True).hex() + ("  " if width == 8 else " ") + (str(n) if width == 8 else ("True" if n else "False"))


def variables(handle):
    IDX = "__mlir_type.`!kgen.scalar<index>`"
    if handle == 1:
        return [
            {"name": "n", "type": IDX, "value": raw(memory["0xFF00"]), "variablesReference": 4, "memoryReference": "0xFF00", "evaluateName": "n"},
            {"name": "flag", "type": "__mlir_type.`!kgen.scalar<bool>`", "value": raw(memory["0xFF08"], 1), "variablesReference": 5, "memoryReference": "0xFF08", "evaluateName": "flag"},
            {"name": "p", "type": "Point", "value": "Point", "variablesReference": 8, "evaluateName": "p"},
            {"name": "items", "type": "List", "value": "(size 2)[0, 1]", "variablesReference": 9, "memoryReference": "0xFF10", "evaluateName": "items"},
        ]
    if handle == 4:
        return [{"name": "[0]", "type": "__mlir_type.si64", "value": str(memory["0xFF00"]), "variablesReference": 0}]
    if handle == 8:
        return [{"name": "x", "type": IDX, "value": raw(4), "variablesReference": 14, "evaluateName": "p.x"},
                {"name": "y", "type": "__mlir_type.`!kgen.scalar<f64>`", "value": "0000000000000440  2.5", "variablesReference": 15, "evaluateName": "p.y"}]
    if handle == 9:
        return [{"name": "[%d]" % k, "type": IDX, "value": raw(k), "variablesReference": 20 + k, "evaluateName": "(*( (!kgen.scalar<index> *)0x50353fe0400%d))" % (8 * k)} for k in range(2)]
    if handle == 3:
        return [{"name": "General Purpose Registers", "value": "", "variablesReference": 60}, {"name": "Floating Point Registers", "value": "", "variablesReference": 61}]
    if handle == 60:
        regs = [{"name": "x0", "value": "0x0000ffffffffde5c", "type": "unsigned long"}, {"name": "x1", "value": "0x0000aaaaaaaaa350 vars`static_string_b65d", "type": "unsigned long"},
                {"name": "sp", "value": "0x0000ffffffffe060", "type": "unsigned long"}, {"name": "pc", "value": "0x%016x" % ip, "type": "unsigned long"},
                {"name": "cpsr", "value": "0x80001000", "type": "unsigned int"}, {"name": "w0", "value": "0xffffde5c", "type": "unsigned int"}]
        return [dict(r, variablesReference=0) for r in regs]
    if handle == 50:
        return [{"name": "r", "type": IDX, "value": raw(7), "variablesReference": 51, "memoryReference": "0xFF20", "evaluateName": "r"}]
    return []


def stop(reason, description):
    event("stopped", {"reason": reason, "description": description, "threadId": 7, "allThreadsStopped": True})


def resumed():
    event("continued", {"threadId": 7, "allThreadsContinued": True})
breakpoints = []    # (path, line, id) as last set, file by file
logs = []
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
        path = m["arguments"]["source"]["path"]
        breakpoints = [b for b in breakpoints if b[0] != path]
        logs = []
        out_bps = []
        for b in m["arguments"].get("breakpoints", []):
            next_id += 1
            line = b["line"]
            if line >= 1000:
                out_bps.append({"id": next_id, "verified": False, "message": "no code"})
                continue
            if line == 99:
                line = 100
            breakpoints.append((path, line, next_id))
            if "logMessage" in b:
                logs.append(b["logMessage"])
            out_bps.append({"id": next_id, "verified": True, "line": line, "source": {"path": path}})
        respond(m, {"breakpoints": out_bps})
    elif cmd == "setFunctionBreakpoints":
        out_bps = []
        for b in m["arguments"].get("breakpoints", []):
            next_id += 1
            out_bps.append({"id": next_id, "verified": b["name"] != "nosuch", "line": 3 if b["name"] != "nosuch" else 0})
        respond(m, {"breakpoints": out_bps})
    elif cmd == "setExceptionBreakpoints":
        respond(m, {})
    elif cmd == "configurationDone":
        respond(m)
        respond(launch)
        event("capabilities", {"capabilities": {"supportsRestartRequest": True}})
        if program == "bp":
            event("process", {"name": program, "systemProcessId": 0})
            for text in logs:      # as the real adapter does: on the console, once the program runs
                event("output", {"category": "console", "output": text + "\n"})
            if breakpoints:
                event("breakpoint", {"reason": "changed", "breakpoint": {"id": breakpoints[0][2], "verified": True, "line": breakpoints[0][1]}})
                stop_at = breakpoints[0]
                event("stopped", {"reason": "breakpoint", "description": "breakpoint %d.1" % stop_at[2], "threadId": 7, "hitBreakpointIds": [stop_at[2]]})
            else:
                event("exited", {"exitCode": 0})
                event("terminated")
        elif program == "vars":
            event("process", {"name": program, "systemProcessId": 0})
            frames = [("vars::work(...)", SOURCE, 5), ("vars::main()", SOURCE, 9), ("std::builtin::_startup::__mojo_main_prototype(...)", "Mojo/stdlib/std/builtin/_startup.mojo", 133)]
            stop("breakpoint", "breakpoint 1.1")
        elif program == "steps":
            event("process", {"name": program, "systemProcessId": 0})
            frames = [("steps::main()", SOURCE, 2)]
            stop("breakpoint", "breakpoint 1.1")
        elif program == "forever":
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
    elif cmd == "stackTrace" and frames:
        respond(m, {"stackFrames": [{"id": 100 + k, "name": f[0], "line": f[2], "column": 1, "source": ({"path": f[1]} if f[1] else {"name": f[0], "sourceReference": 9}), "instructionPointerReference": "0x%012X" % (ip if k == 0 else 0xAAAA1000 + k)} for k, f in enumerate(frames)], "totalFrames": len(frames)})
    elif cmd == "scopes":
        fid = m["arguments"]["frameId"]
        respond(m, {"scopes": [{"name": "Locals", "presentationHint": "locals", "variablesReference": 1 if fid == 100 else 50}, {"name": "Registers", "presentationHint": "registers", "variablesReference": 3, "expensive": True}]})
    elif cmd == "disassemble":
        a = m["arguments"]
        base = int(a["memoryReference"], 16) + 4 * a.get("instructionOffset", 0)
        listing = []
        for k in range(a["instructionCount"]):
            addr = base + 4 * k
            ins = {"address": "0x%012X" % addr, "instruction": ("nop" if addr == ip else "add     x%d, x%d, #%d" % (k % 8, k % 8, k)) + "        ", "instructionBytes": "1f 20 03 d5"}
            if addr in (ip - 8, ip):
                ins["line"] = 4 if addr < ip else 5
                ins["location"] = {"name": "vars.mojo", "path": SOURCE}
            listing.append(ins)
        respond(m, {"instructions": listing})
    elif cmd == "readMemory":
        a = m["arguments"]
        start = int(a["memoryReference"], 16) + a.get("offset", 0)
        import base64
        if start < 0x1000:
            respond(m, {"address": a["memoryReference"], "unreadableBytes": a["count"]})
        else:
            data = bytes((start + i) & 255 for i in range(a["count"] - 16))
            respond(m, {"address": "0x%X" % start, "data": base64.b64encode(data).decode(), "unreadableBytes": 16})
    elif cmd == "evaluate":
        a = m["arguments"]
        e = a["expression"]
        IDX = "__mlir_type.`!kgen.scalar<index>`"
        known = {"n": (raw(memory["0xFF00"]), IDX), "p.x": (raw(4), IDX), "p": ("Point", "Point")}
        if a.get("frameId") == 101:
            known = {"r": (raw(7), IDX)}
        if e.startswith("`"):
            if e == "`frame variable":
                respond(m, {"result": "(%s) n = %d\n(Point) p = (x = 4, y = 2.5)\n" % (IDX, memory["0xFF00"]), "variablesReference": 0})
            else:
                respond(m, {"error": {"id": 3, "format": "error: '%s' is not a valid command." % e[1:].split()[0]}}, success=False, message="failed")
        elif e in known:
            value, typ = known[e]
            if a.get("context") == "repl":
                value = "(%s)  = %s" % (typ, value.split("  ")[-1])
            answer = {"result": value, "type": typ, "variablesReference": 0}
            if e == "n":
                answer["memoryReference"] = "0xFF00"      # as the real one: locals have an address
            respond(m, answer)
        else:
            respond(m, {"error": {"id": 3, "format": "error: invalid value object"}}, success=False, message="failed")
    elif cmd == "variables":
        respond(m, {"variables": variables(m["arguments"]["variablesReference"])})
    elif cmd == "writeMemory":
        import base64
        data = base64.b64decode(m["arguments"]["data"])
        addr = m["arguments"]["memoryReference"]
        if addr in memory:
            memory[addr] = int.from_bytes(data, "little", signed=True)
            respond(m, {"bytesWritten": len(data)})
        else:
            respond(m, {"error": {"id": 2, "format": "memory write failed for " + addr}}, success=False, message="failed")
    elif cmd in ("next", "stepIn", "stepOut") and m["arguments"].get("granularity") == "instruction":
        respond(m)
        resumed()
        ip += 4
        name, path, line = frames[0]
        frames[0] = (name, "", 146)          # inside a line: a disassembly, no file
        stop("step", "instruction step")
    elif cmd in ("next", "stepIn", "stepOut"):
        respond(m)
        resumed()
        name, path, line = frames[0]
        if program == "forever" and cmd == "stepOut" and len(frames) > 1:
            frames.pop(0)
        elif cmd == "next":
            frames[0] = (name, path, line + 1)
        elif cmd == "stepIn" and line == 3 and len(frames) == 1:
            frames.insert(0, ("std::io::print(...)", "Mojo/stdlib/std/io/io.mojo", 120))
        elif cmd == "stepIn" and line == 4 and len(frames) == 1:
            frames.insert(0, ("steps::helper()", SOURCE, 10))
        elif cmd == "stepOut" and len(frames) > 1:
            frames.pop(0)
        else:
            frames[0] = (name, path, line + 1)
        stop("step", "step " + cmd)
    elif cmd == "pause":
        respond(m)
        frames = [("__clock_nanosleep", "sysdeps/unix/sysv/linux/clock_nanosleep.c", 78), ("forever::main()", SOURCE, 7)]
        stop("exception", "signal SIGSTOP")
    elif cmd == "continue" and program == "steps":
        respond(m, {"allThreadsContinued": True})
        resumed()
        later = [b for b in breakpoints if b[0] == SOURCE and b[1] > frames[-1][2]]
        if later:
            frames = [("steps::main()", SOURCE, min(b[1] for b in later))]
            stop("breakpoint", "breakpoint")
        else:
            event("exited", {"exitCode": 0})
            event("terminated")
    elif cmd == "stackTrace":
        if program == "bp" and breakpoints:
            respond(m, {"stackFrames": [{"id": 1, "name": "bp::main()", "line": breakpoints[0][1], "column": 1, "source": {"path": breakpoints[0][0]}}], "totalFrames": 1})
        else:
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
