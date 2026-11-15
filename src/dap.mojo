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
from json import Json, JsonWriter, json_parse, json_parse_bytes, json_quote, J_OBJ, J_ARR, J_STR, J_BOOL
from rpc import Framer, frame
from proc import Proc
from util import dirname, path_exists, shell_quote, bytes_to_str
from breakpoints import DataBreakpoint, BV_UNKNOWN, BV_OK, BV_NOT
from dbgview import FrameRow
from cpuview import Instr, InstructionBreakpoint

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
comptime DE_ANSWER = 9       # an answer to a request the IDE made through ask() (in answers)

comptime TRACE_LEVELS = 20   # frames asked for to find the innermost one with a source
comptime AUTO_OUTS = 6       # at most this many automatic steps out after a step in


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


def launch_arguments(program: String, cwd: String, args: List[String], env: List[String] = List[String]()) -> String:
    var w = JsonWriter()
    w.begin_obj()
    w.kv_str("program", program)
    w.kv_str("cwd", cwd)
    w.key("args")
    w.begin_arr()
    for a in args:
        w.str(a)
    w.end_arr()
    if len(env) > 0:
        w.key("env")
        w.begin_arr()
        for e in env:
            w.str(e)
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
    var env: List[String]
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
    var stop_top: String            # the innermost function, which may have no source
    var stop_depth: Int             # how many frames out the shown place is (0: the innermost)
    var stop_frame: Int             # the adapter's id of the frame shown
    var step_kind: String           # the step under way ("next", "stepIn", "stepOut"; '' none)
    var auto_outs: Int              # steps out made because a step in left the sources
    var pausing: Bool               # a pause was asked for (it is reported as a signal)
    var frames: List[FrameRow]      # the call stack of the stop (innermost first)
    var frame_ips: List[String]     # each frame's instruction address
    var stop_ip: String             # the instruction the program is stopped at
    var asked: List[Int]            # requests made through ask() that wait for their answer
    var answers: List[DapMessage]   # their answers, for the IDE to take
    var attached_live: Bool
    var post_mortem: Bool
    var core_file: String
    var attach_target_pid: Int
    var data_info_seq: Int
    var data_info_name: String
    var data_info_addr: String
    var data_bp_seq: Int
    var ibp_seq: Int

    def __init__(out self):
        self.conn = DapConn()
        self.state = DS_OFF
        self.program = ""
        self.cwd = ""
        self.args = List[String]()
        self.env = List[String]()
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
        self.stop_top = ""
        self.stop_depth = 0
        self.stop_frame = -1
        self.step_kind = ""
        self.auto_outs = 0
        self.pausing = False
        self.frames = List[FrameRow]()
        self.frame_ips = List[String]()
        self.stop_ip = ""
        self.asked = List[Int]()
        self.answers = List[DapMessage]()
        self.attached_live = False
        self.post_mortem = False
        self.core_file = ""
        self.attach_target_pid = 0
        self.data_info_seq = -1
        self.data_info_name = ""
        self.data_info_addr = ""
        self.data_bp_seq = -1
        self.ibp_seq = -1

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
        self.asked.clear()
        self.answers.clear()
        self.attached_live = False
        self.post_mortem = False
        self.core_file = ""
        self.attach_target_pid = 0
        self.data_info_seq = -1
        self.data_info_name = ""
        self.data_info_addr = ""
        self.data_bp_seq = -1
        self.ibp_seq = -1
        self.clear_stop()

    def clear_stop(mut self):
        self.stop_reason = ""
        self.stop_text = ""
        self.stop_file = ""
        self.stop_line = 0
        self.stop_func = ""
        self.stop_top = ""
        self.stop_depth = 0
        self.stop_frame = -1
        self.frames.clear()
        self.frame_ips.clear()
        self.stop_ip = ""
        self.trace_seq = -1

    def begin(mut self, adapter_cmd: String, program: String, cwd: String, args: List[String], stderr_path: String = "/dev/null", env: List[String] = List[String]()) -> Bool:
        """Start the adapter and the conversation that launches `program`."""
        if self.state != DS_OFF:
            return False
        self.reset()
        self.program = program
        self.cwd = cwd
        self.args = args.copy()
        self.env = env.copy()
        if adapter_cmd.byte_length() == 0 or not self.conn.start(adapter_cmd, stderr_path):
            self.error = "The debug adapter could not be started"
            return False
        self.state = DS_INIT
        _ = self.conn.request("initialize", initialize_arguments())
        return True

    def attach_pid(mut self, adapter_cmd: String, pid: Int, stderr_path: String = "/dev/null") -> Bool:
        """Start the adapter and attach to a running process `pid`."""
        if self.state != DS_OFF or pid <= 0:
            return False
        self.reset()
        self.attached_live = True
        self.post_mortem = False
        self.attach_target_pid = pid
        self.pid = pid
        if adapter_cmd.byte_length() == 0 or not self.conn.start(adapter_cmd, stderr_path):
            self.attached_live = False
            self.attach_target_pid = 0
            self.pid = 0
            self.error = "The debug adapter could not be started"
            return False
        self.state = DS_INIT
        _ = self.conn.request("initialize", initialize_arguments())
        return True

    def attach_core(mut self, adapter_cmd: String, program: String, core_file: String, stderr_path: String = "/dev/null") -> Bool:
        """Start the adapter and open a post-mortem `core_file` for `program`."""
        if self.state != DS_OFF:
            return False
        self.reset()
        self.post_mortem = True
        self.attached_live = False
        self.program = program
        self.core_file = core_file
        if adapter_cmd.byte_length() == 0 or not self.conn.start(adapter_cmd, stderr_path):
            self.post_mortem = False
            self.error = "The debug adapter could not be started"
            return False
        self.state = DS_INIT
        _ = self.conn.request("initialize", initialize_arguments())
        return True

    def data_breakpoint_info(mut self, name: String, variables_reference: Int) -> Int:
        var jw = JsonWriter()
        jw.begin_obj()
        jw.kv_str("name", name)
        jw.kv_int("variablesReference", variables_reference)
        jw.end_obj()
        return self.ask("dataBreakpointInfo", jw.text())

    def set_data_breakpoints(mut self, bps: List[DataBreakpoint]) -> Int:
        var jw = JsonWriter()
        jw.begin_obj()
        jw.key("breakpoints")
        jw.begin_arr()
        for i in range(len(bps)):
            jw.begin_obj()
            jw.kv_str("dataId", bps[i].data_id)
            jw.kv_str("accessType", bps[i].access_type)
            if bps[i].condition.byte_length() > 0:
                jw.kv_str("condition", bps[i].condition)
            if bps[i].hit_count.byte_length() > 0:
                jw.kv_str("hitCondition", bps[i].hit_count)
            jw.end_obj()
        jw.end_arr()
        jw.end_obj()
        return self.ask("setDataBreakpoints", jw.text())

    def set_instruction_breakpoints(mut self, ibps: List[InstructionBreakpoint]) -> Int:
        var jw = JsonWriter()
        jw.begin_obj()
        jw.key("breakpoints")
        jw.begin_arr()
        for i in range(len(ibps)):
            jw.begin_obj()
            jw.kv_str("instructionReference", ibps[i].address)
            jw.end_obj()
        jw.end_arr()
        jw.end_obj()
        return self.ask("setInstructionBreakpoints", jw.text())

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
            if self.pausing:
                # LLDB stops the program with SIGSTOP and says so ("signal SIGSTOP")
                self.pausing = False
                self.stop_reason = "pause"
                self.stop_text = "paused"
            self.trace_seq = self.conn.request("stackTrace", "{\"threadId\":" + String(self.stop_thread) + ",\"startFrame\":0,\"levels\":" + String(TRACE_LEVELS) + "}")
            return DE_STOPPED
        if m.name == "continued":
            if self.step_kind.byte_length() > 0:
                return 0                # a step under way: it is about to stop again
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

    def ask(mut self, command: String, args_json: String) -> Int:
        """A request whose answer the IDE handles itself (it comes back in answers)."""
        var seq = self.conn.request(command, args_json)
        self.asked.append(seq)
        return seq

    def handle_response(mut self, m: DapMessage) -> Int:
        for k in range(len(self.asked)):
            if self.asked[k] == m.request_seq:
                _ = self.asked.pop(k)
                self.answers.append(m.copy())
                return DE_ANSWER
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
                if self.post_mortem:
                    _ = self.conn.request("attach", "{\"program\":" + json_quote(self.program) + ",\"coreFile\":" + json_quote(self.core_file) + "}")
                elif self.attached_live:
                    _ = self.conn.request("attach", "{\"pid\":" + String(self.attach_target_pid) + "}")
                else:
                    _ = self.conn.request("launch", launch_arguments(self.program, self.cwd, self.args, self.env))
            return 0
        if m.name == "launch":
            if not m.success:
                self.error = "The program could not be started: " + m.message
                return DE_FAILED
            return 0
        if m.name == "attach":
            if not m.success:
                self.error = "Could not attach: " + m.message
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
            var frames = m.doc.children(m.doc.get(m.body(), "stackFrames"))
            if len(frames) == 0:
                return 0
            self.stop_top = m.doc.str(m.doc.get(frames[0], "name"), "")
            # the place shown is the innermost frame whose source file is there: a stop
            # inside the C library or the standard library (paths like
            # "Mojo/stdlib/std/time/time.mojo" are relative to where it was built) shows
            # the line of the program that called it
            var pick = -1
            for k in range(len(frames)):
                var p = m.doc.str(m.doc.path(frames[k], "source/path"), "")
                if p.startswith("/") and path_exists(p) and m.doc.int(m.doc.get(frames[k], "line"), 0) > 0:
                    pick = k
                    break
            if self.step_kind == "instr" and pick != 0:
                # an instruction step stays where it is, source or not (inside a line
                # the adapter names a disassembly instead of the file)
                pick = -1
            if pick > 0 and (self.step_kind == "stepIn" or self.step_kind == "toSource") and self.auto_outs < AUTO_OUTS:
                # a step in that left the sources (into the standard library): out again,
                # so that F7 stays in the program's own code
                self.auto_outs += 1
                self.state = DS_RUNNING
                _ = self.conn.request("stepOut", "{\"threadId\":" + String(self.stop_thread) + "}")
                return 0
            self.step_kind = ""
            self.auto_outs = 0
            self.frames.clear()
            for k in range(len(frames)):
                var p = m.doc.str(m.doc.path(frames[k], "source/path"), "")
                if not (p.startswith("/") and path_exists(p)):
                    p = ""
                self.frames.append(FrameRow(m.doc.int(m.doc.get(frames[k], "id"), -1), m.doc.str(m.doc.get(frames[k], "name"), ""), p, m.doc.int(m.doc.get(frames[k], "line"), 0)))
                self.frame_ips.append(m.doc.str(m.doc.get(frames[k], "instructionPointerReference"), ""))
            self.stop_ip = self.frame_ips[0] if len(self.frame_ips) > 0 else String("")
            var f = frames[pick] if pick >= 0 else frames[0]
            self.step_kind = ""
            self.stop_depth = max(0, pick)
            self.stop_frame = m.doc.int(m.doc.get(f, "id"), -1)
            self.stop_func = m.doc.str(m.doc.get(f, "name"), "")
            self.stop_file = m.doc.str(m.doc.path(f, "source/path"), "") if pick >= 0 else String("")
            self.stop_line = m.doc.int(m.doc.get(f, "line"), 0) if pick >= 0 else 0
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
        if self.post_mortem or self.state != DS_STOPPED:
            return False
        self.step_kind = ""
        _ = self.conn.request("continue", "{\"threadId\":" + String(self.stop_thread) + "}")
        return True

    def step(mut self, kind: String, instruction: Bool = False) -> Bool:
        """One step of the stopped thread: "next" (over), "stepIn" or "stepOut" - a
        line, or with `instruction` one machine instruction. The program counts as
        running until the adapter says where it stopped."""
        if self.post_mortem or self.state != DS_STOPPED:
            return False
        var what = kind
        if instruction:
            self.step_kind = "instr"
            self.auto_outs = 0
            self.state = DS_RUNNING
            self.clear_stop()
            _ = self.conn.request(kind, "{\"threadId\":" + String(self.stop_thread) + ",\"granularity\":\"instruction\"}")
            return True
        if self.stop_depth > 0 and kind != "stepOut":
            # stopped inside code without a source (a pause in the C library): a step
            # there means "back to the program's own line" - out until a source is there
            what = "stepOut"
            self.step_kind = "toSource"
        else:
            self.step_kind = kind
        self.auto_outs = 0
        self.state = DS_RUNNING
        self.clear_stop()
        _ = self.conn.request(what, "{\"threadId\":" + String(self.stop_thread) + ",\"granularity\":\"line\"}")
        return True

    def pause(mut self) -> Bool:
        """Stop the running program where it is (the adapter reports it as a stop)."""
        if self.post_mortem or self.state != DS_RUNNING:
            return False
        # the main thread's id is the process id (Linux); before the first stop that is
        # the only thread known
        var thread = self.stop_thread if self.stop_thread > 0 else self.pid
        if thread <= 0:
            return False
        self.step_kind = ""
        self.pausing = True
        _ = self.conn.request("pause", "{\"threadId\":" + String(thread) + "}")
        return True

    def finish(mut self):
        """End the session whatever its state: ask the adapter to end the program (or
        detach cleanly when attached to a live PID), give it half a second, stop the
        adapter, and make sure a launched program is gone."""
        if self.state == DS_OFF:
            return
        var was_attached_live = self.attached_live
        var was_post_mortem = self.post_mortem
        if self.conn.alive() and not self.conn.ended():
            var disc_args = "{\"terminateDebuggee\":false,\"restart\":false}" if was_attached_live else "{\"terminateDebuggee\":true}"
            var asked = self.conn.request("disconnect", disc_args)
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
        if not was_attached_live and not was_post_mortem and self.pid > 0 and not self.exited:
            if Int(external_call["kill", Int32](Int32(self.pid), Int32(0))) == 0:
                _ = external_call["kill", Int32](Int32(self.pid), Int32(9))
        self.attached_live = False
        self.post_mortem = False
        self.core_file = ""
        self.attach_target_pid = 0
        self.state = DS_OFF
        self.clear_stop()


# ===========================================================================
# Feature #14 DAP Helpers: Data Breakpoints / Hardware Watchpoints
# ===========================================================================

struct DataBreakpointInfoResult(Copyable, Movable):
    var data_id: String
    var access_types: List[String]
    var ok: Bool

    def __init__(out self, data_id: String, var access_types: List[String], ok: Bool):
        self.data_id = data_id
        self.access_types = access_types^
        self.ok = ok


def build_data_breakpoint_info_request(name: String, variables_reference: Int) -> String:
    """Format DAP dataBreakpointInfo request."""
    var jw = JsonWriter()
    jw.begin_obj()
    jw.kv_str("command", "dataBreakpointInfo")
    jw.key("arguments")
    jw.begin_obj()
    jw.kv_str("name", name)
    jw.kv_int("variablesReference", variables_reference)
    jw.end_obj()
    jw.end_obj()
    return jw.text()


def parse_data_breakpoint_info_response(resp_json: String) -> DataBreakpointInfoResult:
    """Parse DAP dataBreakpointInfo response, extracting dataId and accessTypes."""
    var doc = json_parse(resp_json)
    var empty_types = List[String]()
    if not doc.ok or len(doc.kinds) == 0:
        return DataBreakpointInfoResult("", empty_types^, False)

    var succ_idx = doc.get(0, "success")
    var ok = doc.bool(succ_idx, False) if succ_idx >= 0 else False
    if not ok:
        return DataBreakpointInfoResult("", empty_types^, False)

    var body_idx = doc.get(0, "body")
    if body_idx < 0:
        return DataBreakpointInfoResult("", empty_types^, False)

    var data_id_idx = doc.get(body_idx, "dataId")
    if data_id_idx < 0 or doc.is_null(data_id_idx):
        return DataBreakpointInfoResult("", empty_types^, False)
    var data_id = doc.str(data_id_idx, "")
    if data_id.byte_length() == 0:
        return DataBreakpointInfoResult("", empty_types^, False)

    var types = List[String]()
    var types_idx = doc.get(body_idx, "accessTypes")
    if types_idx >= 0 and doc.kinds[types_idx] == J_ARR:
        for ch in doc.children(types_idx):
            types.append(doc.str(ch, ""))

    return DataBreakpointInfoResult(data_id, types^, True)


def build_set_data_breakpoints_request(bps: List[DataBreakpoint]) -> String:
    """Format DAP setDataBreakpoints request."""
    var jw = JsonWriter()
    jw.begin_obj()
    jw.kv_str("command", "setDataBreakpoints")
    jw.key("arguments")
    jw.begin_obj()
    jw.key("breakpoints")
    jw.begin_arr()
    for i in range(len(bps)):
        jw.begin_obj()
        jw.kv_str("dataId", bps[i].data_id)
        jw.kv_str("accessType", bps[i].access_type)
        if bps[i].condition.byte_length() > 0:
            jw.kv_str("condition", bps[i].condition)
        if bps[i].hit_count.byte_length() > 0:
            jw.kv_str("hitCondition", bps[i].hit_count)
        jw.end_obj()
    jw.end_arr()
    jw.end_obj()
    jw.end_obj()
    return jw.text()


def apply_set_data_breakpoints_response(resp_json: String, mut bps: List[DataBreakpoint]):
    """Update DataBreakpoint list with verified status and IDs from adapter."""
    var doc = json_parse(resp_json)
    if not doc.ok:
        return
    var body_idx = doc.get(0, "body")
    if body_idx < 0:
        return
    var arr_idx = doc.get(body_idx, "breakpoints")
    if arr_idx < 0 or doc.kinds[arr_idx] != J_ARR:
        return
    var children = doc.children(arr_idx)
    var n = min(len(bps), len(children))
    for i in range(n):
        var c = children[i]
        var id_idx = doc.get(c, "id")
        var ver_idx = doc.get(c, "verified")
        var is_ver = doc.bool(ver_idx, False) if ver_idx >= 0 else False
        bps[i].id = doc.int(id_idx, -1) if id_idx >= 0 else -1
        bps[i].verified = BV_OK if is_ver else BV_NOT


struct WatchpointSession(Copyable, Movable):
    var state: Int
    var stop_reason: String
    var hit_breakpoint_id: Int
    var last_toast: String
    var active_bps: List[DataBreakpoint]

    def __init__(out self):
        self.state = DS_RUNNING
        self.stop_reason = ""
        self.hit_breakpoint_id = -1
        self.last_toast = ""
        self.active_bps = List[DataBreakpoint]()

    def on_stopped(mut self, reason: String, description: String, hit_id: Int):
        self.state = DS_STOPPED
        self.stop_reason = reason
        self.hit_breakpoint_id = hit_id

    def forget_debugger(mut self):
        for i in range(len(self.active_bps)):
            self.active_bps[i].verified = BV_UNKNOWN
            self.active_bps[i].id = -1


# ===========================================================================
# Feature #15 DAP Helpers: Post-Mortem Core Dumps & Live PID Attach
# ===========================================================================

struct CoreDumpEntry(Copyable, Movable):
    var timestamp: String
    var pid: Int
    var uid: Int
    var gid: Int
    var signal_name: String
    var exe: String
    var core_path: String

    def __init__(out self, timestamp: String, pid: Int, uid: Int, gid: Int, signal_name: String, exe: String, core_path: String):
        self.timestamp = timestamp
        self.pid = pid
        self.uid = uid
        self.gid = gid
        self.signal_name = signal_name
        self.exe = exe
        self.core_path = core_path


struct StackFrame(Copyable, Movable):
    var id: Int
    var name: String
    var line: Int
    var source_path: String

    def __init__(out self, id: Int, name: String, line: Int, source_path: String):
        self.id = id
        self.name = name
        self.line = line
        self.source_path = source_path


struct StepResult(Copyable, Movable):
    var ok: Bool
    var message: String

    def __init__(out self, ok: Bool, message: String):
        self.ok = ok
        self.message = message


struct CoreDumpSession(Copyable, Movable):
    var state: Int
    var is_post_mortem: Bool
    var pid: Int
    var program: String
    var core_file: String
    var stop_line: Int
    var stop_reason: String
    var stop_description: String
    var error_msg: String
    var frames: List[StackFrame]
    var filters: List[String]

    def __init__(out self):
        self.state = DS_OFF
        self.is_post_mortem = False
        self.pid = 0
        self.program = ""
        self.core_file = ""
        self.stop_line = 0
        self.stop_reason = ""
        self.stop_description = ""
        self.error_msg = ""
        self.frames = List[StackFrame]()
        self.filters = List[String]()

    def attach_core(mut self, program: String, core_file: String, success: Bool, err: String = ""):
        self.program = program
        self.core_file = core_file
        if not success:
            self.state = DS_OFF
            self.error_msg = err
            return
        self.is_post_mortem = True
        self.state = DS_STOPPED
        self.stop_reason = "signal"

    def attach_pid(mut self, pid: Int, success: Bool, err: String = ""):
        self.pid = pid
        if not success:
            self.state = DS_OFF
            self.error_msg = err
            return
        self.is_post_mortem = False
        self.state = DS_STOPPED
        self.stop_reason = "signal"

    def can_step(self) -> Bool:
        return not self.is_post_mortem and self.state == DS_STOPPED

    def can_resume(self) -> Bool:
        return not self.is_post_mortem and self.state == DS_STOPPED

    def resume(mut self) -> StepResult:
        if self.is_post_mortem:
            return StepResult(False, "Cannot step in a core dump")
        if self.state != DS_STOPPED:
            return StepResult(False, "Program is not stopped")
        self.state = DS_RUNNING
        return StepResult(True, "")

    def step(mut self, kind: String) -> StepResult:
        if self.is_post_mortem:
            return StepResult(False, "Cannot step in a core dump")
        if self.state != DS_STOPPED:
            return StepResult(False, "Program is not stopped")
        self.state = DS_RUNNING
        return StepResult(True, "")


def build_core_dump_attach_request(program: String, core_file: String) -> String:
    """Format DAP attach request for post-mortem core dump."""
    var jw = JsonWriter()
    jw.begin_obj()
    jw.kv_str("command", "attach")
    jw.key("arguments")
    jw.begin_obj()
    jw.kv_str("program", program)
    jw.kv_str("coreFile", core_file)
    jw.end_obj()
    jw.end_obj()
    return jw.text()


def build_live_pid_attach_request(pid: Int) -> String:
    """Format DAP attach request for live PID attach."""
    var jw = JsonWriter()
    jw.begin_obj()
    jw.kv_str("command", "attach")
    jw.key("arguments")
    jw.begin_obj()
    jw.kv_int("pid", pid)
    jw.end_obj()
    jw.end_obj()
    return jw.text()


def build_live_pid_detach_request() -> String:
    """Format DAP disconnect request with terminateDebuggee=false."""
    var jw = JsonWriter()
    jw.begin_obj()
    jw.kv_str("command", "disconnect")
    jw.key("arguments")
    jw.begin_obj()
    jw.kv_bool("terminateDebuggee", False)
    jw.kv_bool("restart", False)
    jw.end_obj()
    jw.end_obj()
    return jw.text()


def build_exception_filters_request(filters: List[String]) -> String:
    """Format DAP setExceptionBreakpoints request with signal and exception filters."""
    var jw = JsonWriter()
    jw.begin_obj()
    jw.kv_str("command", "setExceptionBreakpoints")
    jw.key("arguments")
    jw.begin_obj()
    jw.key("filters")
    jw.begin_arr()
    for i in range(len(filters)):
        jw.str(filters[i])
    jw.end_arr()
    jw.end_obj()
    jw.end_obj()
    return jw.text()


def parse_coredumpctl_line(line: String) -> CoreDumpEntry:
    """Parse one line of coredumpctl list --no-legend tabular output."""
    var parts = List[String]()
    for s in line.strip().split(" "):
        var p = String(s.strip())
        if p.byte_length() > 0:
            parts.append(p)

    var sig_idx = -1
    for i in range(len(parts)):
        if parts[i].startswith("SIG"):
            sig_idx = i
            break

    if sig_idx >= 4 and sig_idx + 2 < len(parts):
        var pid = 0
        var uid = 0
        var gid = 0
        try:
            pid = atol(parts[sig_idx - 3])
            uid = atol(parts[sig_idx - 2])
            gid = atol(parts[sig_idx - 1])
        except:
            pass

        var timestamp = ""
        for t in range(sig_idx - 3):
            if timestamp.byte_length() > 0:
                timestamp += " "
            timestamp += parts[t]

        var sig = parts[sig_idx]
        var exe = parts[sig_idx + 1]
        var core_path = parts[sig_idx + 2]
        return CoreDumpEntry(timestamp, pid, uid, gid, sig, exe, core_path)

    return CoreDumpEntry("", 0, 0, 0, "", "", "")


def extract_faulting_address_from_description(desc: String) -> String:
    """Extract address from e.g. 'signal SIGSEGV: address access violation (0x0)'."""
    var open_paren = desc.find("(")
    var close_paren = desc.find(")")
    if open_paren >= 0 and close_paren > open_paren:
        return String(desc[byte=open_paren + 1:close_paren])
    return ""


# ===========================================================================
# Feature #16 DAP Helpers: Disassembly & Instruction Breakpoints
# ===========================================================================

def build_disassemble_request(memory_ref: String, instruction_offset: Int = -24, instruction_count: Int = 96) -> String:
    """Format DAP disassemble request."""
    var jw = JsonWriter()
    jw.begin_obj()
    jw.kv_str("command", "disassemble")
    jw.key("arguments")
    jw.begin_obj()
    jw.kv_str("memoryReference", memory_ref)
    jw.kv_int("instructionOffset", instruction_offset)
    jw.kv_int("instructionCount", instruction_count)
    jw.kv_bool("resolveSymbols", True)
    jw.end_obj()
    jw.end_obj()
    return jw.text()


def parse_disassemble_response(resp_json: String) -> List[Instr]:
    """Parse DAP disassemble response into a list of Instr."""
    var out = List[Instr]()
    var doc = json_parse(resp_json)
    if not doc.ok:
        return out^
    var body = doc.get(0, "body")
    if body < 0:
        return out^
    var arr = doc.get(body, "instructions")
    if arr < 0 or doc.kinds[arr] != J_ARR:
        return out^
    for c in doc.children(arr):
        var addr = doc.str(doc.get(c, "address"), "")
        var text = doc.str(doc.get(c, "instruction"), "")
        var line = doc.int(doc.get(c, "line"), 0)
        var path = ""
        var loc = doc.get(c, "location")
        if loc >= 0:
            path = doc.str(doc.get(loc, "path"), "")
        out.append(Instr(addr, text, path, line))
    return out^


def build_set_instruction_breakpoints_request(ibps: List[InstructionBreakpoint]) -> String:
    """Format DAP setInstructionBreakpoints request."""
    var jw = JsonWriter()
    jw.begin_obj()
    jw.kv_str("command", "setInstructionBreakpoints")
    jw.key("arguments")
    jw.begin_obj()
    jw.key("breakpoints")
    jw.begin_arr()
    for i in range(len(ibps)):
        jw.begin_obj()
        jw.kv_str("instructionReference", ibps[i].address)
        jw.end_obj()
    jw.end_arr()
    jw.end_obj()
    jw.end_obj()
    return jw.text()
