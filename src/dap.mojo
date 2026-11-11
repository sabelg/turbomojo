"""Debug Adapter Protocol client.

DAP frames its messages like the language server protocol (Content-Length headers, a JSON
body), so the framing and the child process come from the JSON-RPC layer; the messages
themselves are shaped differently: every message has a `seq`, requests name a `command`,
responses carry `request_seq` and `success`, events name an `event`.

`DapConn` is the transport. `DebugSession` is one program being debugged: it walks through
initialize → launch → (initialized) → configuration → configurationDone, follows the
adapter's events, and keeps what the IDE shows - the program's output, where it stopped,
how it ended.

Verified against mojo-lldb-dap (LLDB 24) of Mojo 1.2: the `launch` response arrives only
after `configurationDone`; the `initialized` event comes after `launch` was sent; locals
are empty unless Mojo's LLDB plugin (lib/libMojoLLDB.so) is loaded before initialization.
"""
from std.collections import List
from std.ffi import external_call
from json import Json, JsonWriter, json_parse_bytes, json_quote, J_OBJ, J_STR, J_BOOL
from rpc import Framer, frame
from proc import Proc
from util import dirname, path_exists, shell_quote, bytes_to_str

comptime DAP_INVALID = 0
comptime DAP_RESPONSE = 1    # the answer to one of our requests
comptime DAP_EVENT = 2       # the adapter tells us something
comptime DAP_REQUEST = 3     # the adapter asks us something ("reverse request")

# what a session is doing
comptime DS_OFF = 0          # no session
comptime DS_INIT = 1         # initialize sent
comptime DS_LAUNCH = 2       # launch sent; the adapter is being configured
comptime DS_RUNNING = 3      # the program runs
comptime DS_STOPPED = 4      # the program is stopped (breakpoint, step, signal, ...)

# what happened, as told to the IDE by DebugSession.pump
comptime DE_OUTPUT = 1       # the program or the debugger wrote something
comptime DE_RUNNING = 2      # the program runs (again)
comptime DE_STOPPED = 3      # it stopped; the place is not known yet
comptime DE_LOCATED = 4      # the place it stopped at is known (stop_file, stop_line)
comptime DE_EXITED = 5       # the program ended (exit_code)
comptime DE_ENDED = 6        # the session is over: the adapter said so, or went away
comptime DE_FAILED = 7       # the session could not be set up (error says why)
comptime DE_BREAKPOINTS = 8  # the debugger said where breakpoints are (reports, changed_*)


struct DapMessage(Copyable, Movable):
    var kind: Int
    var name: String        # the command (requests, responses) or the event
    var request_seq: Int    # responses: the seq of our request (-1 otherwise)
    var seq: Int            # the sender's own number
    var success: Bool       # responses
    var message: String     # responses that failed: the reason
    var doc: Json

    def __init__(out self):
        self.kind = DAP_INVALID
        self.name = ""
        self.request_seq = -1
        self.seq = -1
        self.success = False
        self.message = ""
        self.doc = Json()

    def body(self) -> Int:
        """Node index of "body" (-1 if absent)."""
        return self.doc.get(0, "body")

    def arguments(self) -> Int:
        return self.doc.get(0, "arguments")


struct DapConn(Copyable, Movable):
    var proc: Proc
    var framer: Framer
    var seq: Int
    var pending_seqs: List[Int]
    var pending_cmds: List[String]
    var invalid: Int            # bodies that were not DAP messages

    def __init__(out self):
        self.proc = Proc()
        self.framer = Framer()
        self.seq = 0
        self.pending_seqs = List[Int]()
        self.pending_cmds = List[String]()
        self.invalid = 0

    def start(mut self, cmd: String, stderr_path: String = "/dev/null") -> Bool:
        self.framer = Framer()
        self.seq = 0
        self.pending_seqs.clear()
        self.pending_cmds.clear()
        return self.proc.start(cmd, stderr_path)

    def fd(self) -> Int:
        return self.proc.out_fd

    def alive(self) -> Bool:
        return self.proc.alive()

    def ended(self) -> Bool:
        return self.proc.running and self.proc.eof

    def wants_write(self) -> Bool:
        return self.proc.wants_write()

    def stop(mut self) -> Int:
        return self.proc.stop()

    def request_body(mut self, command: String, args_json: String) -> String:
        """The next request as JSON text; it is remembered as waiting for its answer."""
        self.seq += 1
        var w = JsonWriter()
        w.begin_obj()
        w.kv_int("seq", self.seq)
        w.kv_str("type", "request")
        w.kv_str("command", command)
        if args_json.byte_length() > 0:
            w.key("arguments")
            w.raw(args_json)
        w.end_obj()
        self.pending_seqs.append(self.seq)
        self.pending_cmds.append(command)
        return w.text()

    def request(mut self, command: String, args_json: String = "") -> Int:
        """Send a request; returns its seq. `args_json` is JSON text ('' for none)."""
        var body = self.request_body(command, args_json)
        self.proc.write(frame(body))
        return self.seq

    def respond(mut self, request_seq: Int, command: String, success: Bool, message: String = ""):
        """Answer a request of the adapter."""
        self.seq += 1
        var w = JsonWriter()
        w.begin_obj()
        w.kv_int("seq", self.seq)
        w.kv_str("type", "response")
        w.kv_int("request_seq", request_seq)
        w.kv_bool("success", success)
        w.kv_str("command", command)
        if message.byte_length() > 0:
            w.kv_str("message", message)
        w.end_obj()
        self.proc.write(frame(w.text()))

    def is_pending(self, seq: Int) -> Bool:
        return seq in self.pending_seqs

    def classify(mut self, body: List[UInt8]) -> DapMessage:
        var m = DapMessage()
        m.doc = json_parse_bytes(body)
        if not m.doc.ok or m.doc.kind(0) != J_OBJ:
            self.invalid += 1
            return m^
        var what = m.doc.str(m.doc.get(0, "type"), "")
        m.seq = m.doc.int(m.doc.get(0, "seq"), -1)
        if what == "event":
            m.name = m.doc.str(m.doc.get(0, "event"), "")
            if m.name.byte_length() == 0:
                self.invalid += 1
                return m^
            m.kind = DAP_EVENT
        elif what == "response":
            m.kind = DAP_RESPONSE
            m.request_seq = m.doc.int(m.doc.get(0, "request_seq"), -1)
            m.success = m.doc.bool(m.doc.get(0, "success"), False)
            m.name = m.doc.str(m.doc.get(0, "command"), "")
            m.message = m.doc.str(m.doc.get(0, "message"), "")
            # the adapter's longer explanation, when it gives one
            var longer = m.doc.str(m.doc.path(0, "body/error/format"), "")
            if longer.byte_length() > 0:
                m.message = longer
            for k in range(len(self.pending_seqs)):
                if self.pending_seqs[k] == m.request_seq:
                    if m.name.byte_length() == 0:
                        m.name = self.pending_cmds[k]
                    _ = self.pending_seqs.pop(k)
                    _ = self.pending_cmds.pop(k)
                    break
        elif what == "request":
            m.name = m.doc.str(m.doc.get(0, "command"), "")
            if m.name.byte_length() == 0 or m.seq < 0:
                self.invalid += 1
                return m^
            m.kind = DAP_REQUEST
        else:
            self.invalid += 1
        return m^

    def feed(mut self, data: List[UInt8]) -> List[DapMessage]:
        """Parse received bytes into messages (usable without a child process)."""
        var out = List[DapMessage]()
        self.framer.feed(data)
        var body = List[UInt8]()
        while self.framer.next(body):
            var m = self.classify(body)
            if m.kind != DAP_INVALID:
                out.append(m^)
        return out^

    def poll(mut self) -> List[DapMessage]:
        self.proc.flush()
        _ = self.proc.read_available()
        return self.feed(self.proc.take())


def adapter_command(adapter_path: String) -> String:
    """The command line that starts Mojo's debug adapter, given where it is installed
    (<prefix>/bin/mojo-lldb-dap). The adapter is a script that needs CONDA_PREFIX to
    find its debugger; and without Mojo's LLDB plugin the debugger stops at the right
    lines but shows no variables - so the plugin is loaded before anything else, when
    it is there. '' if there is no adapter."""
    if adapter_path.byte_length() == 0:
        return ""
    var prefix = dirname(dirname(adapter_path))
    var cmd = "env CONDA_PREFIX=" + shell_quote(prefix) + " " + shell_quote(adapter_path)
    var plugin = prefix + "/lib/libMojoLLDB.so"
    if path_exists(plugin):
        cmd += " --pre-init-command " + shell_quote("plugin load " + plugin)
    return cmd


def initialize_arguments() -> String:
    var w = JsonWriter()
    w.begin_obj()
    w.kv_str("clientID", "turbomojo")
    w.kv_str("clientName", "TurboMojo")
    w.kv_str("adapterID", "mojo-lldb-dap")
    w.kv_str("pathFormat", "path")
    w.kv_bool("linesStartAt1", True)
    w.kv_bool("columnsStartAt1", True)
    w.kv_bool("supportsVariableType", True)
    w.kv_bool("supportsRunInTerminalRequest", False)
    w.kv_bool("supportsProgressReporting", False)
    w.end_obj()
    return w.text()


def launch_arguments(program: String, cwd: String, args: List[String]) -> String:
    var w = JsonWriter()
    w.begin_obj()
    w.kv_str("program", program)
    w.kv_str("cwd", cwd)
    w.key("args")
    w.begin_arr()
    for a in args:
        w.str(a)
    w.end_arr()
    w.kv_bool("stopOnEntry", False)
    w.end_obj()
    return w.text()


def split_arguments(line: String) -> List[String]:
    """Program arguments as a shell would split them, for the common cases: blanks
    separate, single and double quotes group, a backslash takes the next character as
    it is. (No variables, no globbing: the debugger starts the program without a
    shell.)"""
    var out = List[String]()
    var cur = List[UInt8]()
    var started = False        # an argument was started (it may be empty: "")
    var quote = UInt8(0)
    var bs = line.as_bytes()
    var k = 0
    while k < len(bs):
        var c = bs[k]
        if quote != 0:
            if c == quote:
                quote = 0
            elif c == 92 and quote == 34 and k + 1 < len(bs):
                k += 1
                cur.append(bs[k])
            else:
                cur.append(c)
        elif c == 39 or c == 34:
            quote = c
            started = True
        elif c == 92 and k + 1 < len(bs):
            k += 1
            cur.append(bs[k])
            started = True
        elif c == 32 or c == 9:
            if started or len(cur) > 0:
                out.append(bytes_to_str(cur))
                cur.clear()
                started = False
        else:
            cur.append(c)
        k += 1
    if started or len(cur) > 0:
        out.append(bytes_to_str(cur))
    return out^


struct BpReport(Copyable, Movable):
    """The debugger's answer for the breakpoints of one file ('' = function
    breakpoints), in the order they were sent."""
    var tag: String
    var verified: List[Bool]
    var lines: List[Int]
    var ids: List[Int]

    def __init__(out self, tag: String):
        self.tag = tag
        self.verified = List[Bool]()
        self.lines = List[Int]()
        self.ids = List[Int]()


struct DebugSession(Copyable, Movable):
    var conn: DapConn
    var state: Int
    var program: String
    var cwd: String
    var args: List[String]
    var caps: List[String]          # the capabilities the adapter said it has
    var config_cmds: List[String]   # requests to send when the adapter is ready for its
    var config_args: List[String]   #   configuration (breakpoints), before configurationDone
    var config_tags: List[String]   # the file each of them is about ('' = functions)
    var bp_seqs: List[Int]          # breakpoint requests that wait for their answer
    var bp_tags: List[String]
    var reports: List[BpReport]     # answers the IDE has not taken yet
    var changed_ids: List[Int]      # single breakpoints the debugger changed later
    var changed_ok: List[Bool]
    var changed_lines: List[Int]
    var launched: Bool              # the program's process exists
    var output: List[UInt8]         # what the program wrote (stdout and stderr)
    var console: List[String]       # what the debugger itself said
    var pid: Int                    # the program's process (0: not known)
    var exited: Bool
    var exit_code: Int
    var stop_reason: String         # "breakpoint", "step", "exception", "signal", ...
    var stop_text: String           # the adapter's description of the stop
    var stop_thread: Int
    var stop_file: String
    var stop_line: Int
    var stop_func: String
    var error: String
    var trace_seq: Int              # the stackTrace request whose answer locates the stop

    def __init__(out self):
        self.conn = DapConn()
        self.state = DS_OFF
        self.program = ""
        self.cwd = ""
        self.args = List[String]()
        self.caps = List[String]()
        self.config_cmds = List[String]()
        self.config_args = List[String]()
        self.config_tags = List[String]()
        self.bp_seqs = List[Int]()
        self.bp_tags = List[String]()
        self.reports = List[BpReport]()
        self.changed_ids = List[Int]()
        self.changed_ok = List[Bool]()
        self.changed_lines = List[Int]()
        self.launched = False
        self.output = List[UInt8]()
        self.console = List[String]()
        self.pid = 0
        self.exited = False
        self.exit_code = 0
        self.stop_reason = ""
        self.stop_text = ""
        self.stop_thread = 0
        self.stop_file = ""
        self.stop_line = 0
        self.stop_func = ""
        self.error = ""
        self.trace_seq = -1

    def active(self) -> Bool:
        return self.state != DS_OFF

    def fd(self) -> Int:
        return self.conn.fd() if self.state != DS_OFF else -1

    def supports(self, capability: String) -> Bool:
        return capability in self.caps

    def reset(mut self):
        self.caps.clear()
        self.output.clear()
        self.console.clear()
        self.pid = 0
        self.exited = False
        self.exit_code = 0
        self.error = ""
        self.bp_seqs.clear()
        self.bp_tags.clear()
        self.reports.clear()
        self.changed_ids.clear()
        self.changed_ok.clear()
        self.changed_lines.clear()
        self.launched = False
        self.clear_stop()

    def clear_stop(mut self):
        self.stop_reason = ""
        self.stop_text = ""
        self.stop_file = ""
        self.stop_line = 0
        self.stop_func = ""
        self.trace_seq = -1

    def begin(mut self, adapter_cmd: String, program: String, cwd: String, args: List[String], stderr_path: String = "/dev/null") -> Bool:
        """Start the adapter and the conversation that launches `program`."""
        if self.state != DS_OFF:
            return False
        self.reset()
        self.program = program
        self.cwd = cwd
        self.args = args.copy()
        if adapter_cmd.byte_length() == 0 or not self.conn.start(adapter_cmd, stderr_path):
            self.error = "The debug adapter could not be started"
            return False
        self.state = DS_INIT
        _ = self.conn.request("initialize", initialize_arguments())
        return True

    def can_send(self) -> Bool:
        """The adapter takes breakpoint changes now (the program runs or is stopped)."""
        return self.state == DS_RUNNING or self.state == DS_STOPPED

    def set_config(mut self, tag: String, command: String, args_json: String):
        """One more request for the configuration phase of the next session."""
        self.config_tags.append(tag)
        self.config_cmds.append(command)
        self.config_args.append(args_json)

    def clear_config(mut self):
        self.config_tags.clear()
        self.config_cmds.clear()
        self.config_args.clear()

    def send_breakpoints(mut self, tag: String, command: String, args_json: String):
        """Send the breakpoints of one file (or the function breakpoints); the answer
        comes back as a report with this tag."""
        self.bp_seqs.append(self.conn.request(command, args_json))
        self.bp_tags.append(tag)

    def add_text(mut self, text: String):
        for b in text.as_bytes():
            self.output.append(b)

    def handle(mut self, m: DapMessage) -> Int:
        """Take one message of the adapter; returns what it means for the IDE (a DE_
        value, 0 for nothing)."""
        if m.kind == DAP_REQUEST:
            # runInTerminal and the like: this client offers none of them
            self.conn.respond(m.seq, m.name, False, "not supported")
            return 0
        if m.kind == DAP_RESPONSE:
            return self.handle_response(m)
        if m.kind != DAP_EVENT:
            return 0
        var b = m.body()
        if m.name == "initialized":
            # the adapter is ready to be configured: breakpoints first, then go
            for k in range(len(self.config_cmds)):
                var tag = self.config_tags[k] if k < len(self.config_tags) else String("")
                var command = self.config_cmds[k]
                var args = self.config_args[k]
                self.send_breakpoints(tag, command, args)
            _ = self.conn.request("setExceptionBreakpoints", "{\"filters\":[]}")
            if self.supports("supportsConfigurationDoneRequest"):
                _ = self.conn.request("configurationDone")
            elif self.state == DS_LAUNCH:
                self.state = DS_RUNNING
                return DE_RUNNING
            return 0
        if m.name == "output":
            var cat = m.doc.str(m.doc.get(b, "category"), "console")
            var text = m.doc.str(m.doc.get(b, "output"), "")
            if cat == "stdout" or cat == "stderr":
                self.add_text(text)
                return DE_OUTPUT
            if cat == "console" or cat == "important":
                self.console.append(text)
                # once the program runs, the debugger's console carries the messages
                # of log points; its note that the process ended is told another way
                if self.launched and not (text.startswith("Process ") and text.find(" exited with status") > 0):
                    self.add_text(text)
                    return DE_OUTPUT
            return 0
        if m.name == "process":
            self.pid = m.doc.int(m.doc.get(b, "systemProcessId"), 0)
            self.launched = True
            return 0
        if m.name == "capabilities":
            self.take_capabilities(m.doc, m.doc.get(b, "capabilities"))
            return 0
        if m.name == "breakpoint":
            var bp = m.doc.get(b, "breakpoint")
            var id = m.doc.int(m.doc.get(bp, "id"), -1)
            if id < 0:
                return 0
            self.changed_ids.append(id)
            self.changed_ok.append(m.doc.bool(m.doc.get(bp, "verified"), False))
            self.changed_lines.append(m.doc.int(m.doc.get(bp, "line"), 0))
            return DE_BREAKPOINTS
        if m.name == "stopped":
            self.state = DS_STOPPED
            self.clear_stop()
            self.stop_reason = m.doc.str(m.doc.get(b, "reason"), "")
            self.stop_text = m.doc.str(m.doc.get(b, "description"), "")
            if self.stop_text.byte_length() == 0:
                self.stop_text = m.doc.str(m.doc.get(b, "text"), self.stop_reason)
            self.stop_thread = m.doc.int(m.doc.get(b, "threadId"), self.stop_thread)
            self.trace_seq = self.conn.request("stackTrace", "{\"threadId\":" + String(self.stop_thread) + ",\"startFrame\":0,\"levels\":1}")
            return DE_STOPPED
        if m.name == "continued":
            if self.state == DS_STOPPED:
                self.state = DS_RUNNING
                self.clear_stop()
                return DE_RUNNING
            return 0
        if m.name == "exited":
            self.exited = True
            self.exit_code = m.doc.int(m.doc.get(b, "exitCode"), 0)
            return DE_EXITED
        if m.name == "terminated":
            return DE_ENDED
        return 0

    def take_capabilities(mut self, doc: Json, node: Int):
        if node < 0:
            return
        for c in doc.children(node):
            if doc.kind(c) == J_BOOL:
                var name = doc.key_of(c)
                if doc.bool(c) and name not in self.caps:
                    self.caps.append(name)

    def handle_response(mut self, m: DapMessage) -> Int:
        for k in range(len(self.bp_seqs)):
            if self.bp_seqs[k] == m.request_seq:
                var report = BpReport(self.bp_tags[k])
                _ = self.bp_seqs.pop(k)
                _ = self.bp_tags.pop(k)
                if not m.success:
                    return 0
                for n in m.doc.children(m.doc.get(m.body(), "breakpoints")):
                    report.verified.append(m.doc.bool(m.doc.get(n, "verified"), False))
                    report.lines.append(m.doc.int(m.doc.get(n, "line"), 0))
                    report.ids.append(m.doc.int(m.doc.get(n, "id"), -1))
                self.reports.append(report^)
                return DE_BREAKPOINTS
        if m.name == "initialize":
            if not m.success:
                self.error = "The debug adapter refused to start: " + m.message
                return DE_FAILED
            self.take_capabilities(m.doc, m.body())
            if self.state == DS_INIT:
                self.state = DS_LAUNCH
                _ = self.conn.request("launch", launch_arguments(self.program, self.cwd, self.args))
            return 0
        if m.name == "launch":
            if not m.success:
                self.error = "The program could not be started: " + m.message
                return DE_FAILED
            return 0
        if m.name == "configurationDone":
            if self.state == DS_LAUNCH:
                self.state = DS_RUNNING
                return DE_RUNNING
            return 0
        if m.name == "stackTrace" and m.request_seq == self.trace_seq:
            self.trace_seq = -1
            if not m.success or self.state != DS_STOPPED:
                return 0
            var frame0 = m.doc.at(m.doc.get(m.body(), "stackFrames"), 0)
            if frame0 < 0:
                return 0
            self.stop_func = m.doc.str(m.doc.get(frame0, "name"), "")
            self.stop_file = m.doc.str(m.doc.path(frame0, "source/path"), "")
            self.stop_line = m.doc.int(m.doc.get(frame0, "line"), 0)
            return DE_LOCATED
        return 0

    def pump(mut self) -> List[Int]:
        """Read what the adapter sent and return what happened, in order. An adapter
        that went away ends the session."""
        var out = List[Int]()
        if self.state == DS_OFF:
            return out^
        var msgs = self.conn.poll()
        for k in range(len(msgs)):
            var e = self.handle(msgs[k])
            if e != 0:
                out.append(e)
        if self.conn.ended() and DE_ENDED not in out and DE_FAILED not in out:
            if self.state == DS_INIT or self.state == DS_LAUNCH:
                self.error = "The debug adapter ended before the program was started"
                out.append(DE_FAILED)
            else:
                out.append(DE_ENDED)
        return out^

    def resume(mut self) -> Bool:
        if self.state != DS_STOPPED:
            return False
        _ = self.conn.request("continue", "{\"threadId\":" + String(self.stop_thread) + "}")
        return True

    def finish(mut self):
        """End the session whatever its state: ask the adapter to end the program,
        give it half a second, stop the adapter, and make sure the program is gone -
        a debugger that was killed must not leave it running."""
        if self.state == DS_OFF:
            return
        if self.conn.alive() and not self.conn.ended():
            var asked = self.conn.request("disconnect", "{\"terminateDebuggee\":true}")
            for _ in range(50):
                var msgs = self.conn.poll()
                for k in range(len(msgs)):
                    # late news still counts: the output and the exit code
                    if msgs[k].kind == DAP_EVENT and (msgs[k].name == "output" or msgs[k].name == "exited" or msgs[k].name == "process"):
                        _ = self.handle(msgs[k])
                if not self.conn.is_pending(asked) or self.conn.ended():
                    break
                _ = external_call["usleep", Int32](UInt32(10000))
        _ = self.conn.stop()
        if self.pid > 0 and not self.exited:
            if Int(external_call["kill", Int32](Int32(self.pid), Int32(0))) == 0:
                _ = external_call["kill", Int32](Int32(self.pid), Int32(9))
        self.state = DS_OFF
        self.clear_stop()
