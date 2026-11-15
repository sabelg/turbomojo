"""A client of the Agent Client Protocol (ACP, protocol version 1): a coding agent runs as
a child process and speaks JSON-RPC 2.0 over its stdin/stdout, one message per line
(https://agentclientprotocol.com/protocol/transports).

The client sends `initialize` and, once the agent has answered, `session/new` for the
project folder; then `session/prompt` per turn and `session/cancel` to stop one. What
the agent says arrives as `session/update` notifications, turned here into `AcpEvent`s
for the app: message and thought chunks, tool calls and their updates, plans. Requests
from the agent: `session/request_permission` becomes an event the app answers with
`answer_permission`; file system and terminal requests are refused until the editor
offers them (the capabilities say so: fs and terminal false), as is anything unknown.

Nothing blocks: the event loop polls `fd()` and calls `pump()`.
"""
from std.collections import List
from json import Json, JsonWriter, json_quote, J_ARR, J_OBJ, J_STR, J_NUM
from rpc import RpcConn, RpcMessage, RPC_RESPONSE, RPC_ERROR, RPC_REQUEST, RPC_NOTIFICATION

comptime ACP_PROTOCOL_VERSION = 1

comptime AS_STOPPED = 0
comptime AS_STARTING = 1        # initialize sent
comptime AS_OPENING = 2         # session/new sent
comptime AS_READY = 3           # a session is open; prompts can be sent
comptime AS_FAILED = 4          # it could not be started (see `problem`)

comptime AE_MESSAGE = 1         # text of the agent's answer (a chunk of it)
comptime AE_THOUGHT = 2         # the agent's thinking (a chunk)
comptime AE_USER = 3            # the user's message echoed back (when a session is loaded)
comptime AE_TOOL = 4            # a tool call starts (id, title, kind, status)
comptime AE_TOOL_UPDATE = 5     # a tool call changes (id, status; text and diffs when given)
comptime AE_PLAN = 6            # the agent's plan (entries)
comptime AE_PERMISSION = 7      # the agent asks to be allowed something: answer it
comptime AE_TURN_END = 8        # the prompt's turn is over (stop reason)
comptime AE_READY = 9           # the session is open
comptime AE_FAILED = 10         # the agent could not be started, or ended (text: why)
comptime AE_OTHER = 11          # an update this client does not show (its kind in `kind_name`)
comptime AE_MODE = 13           # the session's mode changed (status: the mode; text: a problem)
comptime AE_MODEL = 14          # the session's model changed (status: model id; text: a problem)
comptime AE_THINKING = 15       # the session's thinking level changed (status: level; text: a problem)
comptime AE_SERVICE = 12        # the agent asks the editor (fs/*, terminal/*): method in
                                # kind_name, request id in request, params (JSON) in text

comptime INIT_TIMEOUT_NS = 30 * 1000 * 1000 * 1000


struct AcpEvent(Copyable, Movable):
    var kind: Int
    var text: String            # message / thought text, a tool call's text, or why
    var id: String              # tool call id
    var title: String           # tool call title
    var tool_kind: String       # read, edit, execute, ...
    var status: String          # pending, in_progress, completed, failed
    var stop_reason: String     # end_turn, max_tokens, max_turn_requests, refusal, cancelled
    var kind_name: String       # the sessionUpdate as sent
    var entries: List[String]   # plan entries ("[status] content")
    var option_ids: List[String]    # permission options
    var option_names: List[String]
    var option_kinds: List[String]  # allow_once, allow_always, reject_once, reject_always
    var request: String         # the permission request's id, as JSON
    var diffs: List[String]     # paths of diffs a tool call carries
    var locations: List[String] # "path:line" a tool call works on

    def __init__(out self, kind: Int):
        self.kind = kind
        self.text = ""
        self.id = ""
        self.title = ""
        self.tool_kind = ""
        self.status = ""
        self.stop_reason = ""
        self.kind_name = ""
        self.entries = List[String]()
        self.option_ids = List[String]()
        self.option_names = List[String]()
        self.option_kinds = List[String]()
        self.request = ""
        self.diffs = List[String]()
        self.locations = List[String]()


def content_text(doc: Json, node: Int) -> String:
    """The text of a ContentBlock ({"type": "text", "text": ...}); other kinds say what
    they are."""
    if node < 0 or doc.kind(node) != J_OBJ:
        return ""
    var t = doc.str(doc.get(node, "type"))
    if t == "text":
        return doc.str(doc.get(node, "text"))
    if t == "resource_link":
        return "[" + doc.str(doc.get(node, "uri")) + "]"
    if t == "resource":
        return "[" + doc.str(doc.path(node, "resource/uri")) + "]"
    return "[" + t + "]"


def update_event(doc: Json, u: Int) -> AcpEvent:
    """An event for the `update` of a session/update notification."""
    var su = doc.str(doc.get(u, "sessionUpdate"))
    var e = AcpEvent(AE_OTHER)
    e.kind_name = su
    if su == "agent_message_chunk" or su == "agent_thought_chunk" or su == "user_message_chunk":
        e.kind = AE_MESSAGE if su == "agent_message_chunk" else (AE_THOUGHT if su == "agent_thought_chunk" else AE_USER)
        e.text = content_text(doc, doc.get(u, "content"))
        return e^
    if su == "tool_call" or su == "tool_call_update":
        e.kind = AE_TOOL if su == "tool_call" else AE_TOOL_UPDATE
        e.id = doc.str(doc.get(u, "toolCallId"))
        e.title = doc.str(doc.get(u, "title"))
        e.tool_kind = doc.str(doc.get(u, "kind"))
        e.status = doc.str(doc.get(u, "status"))
        if su == "tool_call" and e.status.byte_length() == 0:
            e.status = "pending"
        var c = doc.get(u, "content")
        if c >= 0 and doc.kind(c) == J_ARR:
            for item in doc.children(c):
                var t = doc.str(doc.get(item, "type"))
                if t == "content":
                    var s = content_text(doc, doc.get(item, "content"))
                    e.text += ("\n" if e.text.byte_length() > 0 else "") + s
                elif t == "diff":
                    e.diffs.append(doc.str(doc.get(item, "path")))
                elif t == "terminal":
                    e.text += ("\n" if e.text.byte_length() > 0 else "") + "[terminal " + doc.str(doc.get(item, "terminalId")) + "]"
        var locs = doc.get(u, "locations")
        if locs >= 0 and doc.kind(locs) == J_ARR:
            for l in doc.children(locs):
                var line = doc.get(l, "line")
                e.locations.append(doc.str(doc.get(l, "path")) + ((":" + String(doc.int(line))) if line >= 0 and doc.kind(line) == J_NUM else String("")))
        return e^
    if su == "plan":
        e.kind = AE_PLAN
        var ents = doc.get(u, "entries")
        if ents >= 0 and doc.kind(ents) == J_ARR:
            for en in doc.children(ents):
                e.entries.append("[" + doc.str(doc.get(en, "status")) + "] " + doc.str(doc.get(en, "content")))
        return e^
    return e^


struct AcpClient(Movable):
    var conn: RpcConn
    var state: Int
    var problem: String         # why it failed
    var cwd: String
    var agent_name: String      # agentInfo title or name
    var version: Int            # the protocol version agreed
    var load_session: Bool      # what the agent can do
    var images: Bool
    var embedded_context: Bool
    var auth_methods: List[String]
    var session_id: String
    var init_id: Int
    var new_id: Int
    var prompt_id: Int          # the turn running (-1: none)
    var prompt_ns: Int          # when it began
    var started_ns: Int
    var permissions: List[String]   # requests for permission not answered yet (their ids)
    var events: List[AcpEvent]
    var refused: List[String]   # methods the agent asked for that were refused (for tests and the log)
    var services: Bool          # offer the editor's file system and terminals (the app answers)
    var mode: String            # the session's mode (agents that have modes: ask, auto, plan...)
    var mode_ids: List[String]
    var mode_names: List[String]
    var mode_texts: List[String]
    var mode_id: Int            # a session/set_mode request waiting for its answer
    var mode_wanted: String
    var current_model: String   # models.currentModelId
    var model_ids: List[String]
    var model_names: List[String]
    var model_req_id: Int       # a session/set_model request waiting for its answer
    var model_wanted: String
    var thinking: String        # thought_level configOption currentValue
    var thinking_ids: List[String]
    var thinking_names: List[String]
    var cfg_req_id: Int         # a session/set_config_option request waiting for its answer
    var thinking_wanted: String
    var resume_session_id: String   # sessionId to try loading via session/load
    var load_id: Int
    var resumed: Bool
    var mcp_servers_json: String    # JSON array passed as mcpServers in session/new & load

    def __init__(out self):
        self.conn = RpcConn()
        self.conn.lines = True
        self.state = AS_STOPPED
        self.problem = ""
        self.cwd = ""
        self.agent_name = ""
        self.version = 0
        self.load_session = False
        self.images = False
        self.embedded_context = False
        self.auth_methods = List[String]()
        self.session_id = ""
        self.init_id = -1
        self.new_id = -1
        self.prompt_id = -1
        self.prompt_ns = 0
        self.started_ns = 0
        self.permissions = List[String]()
        self.events = List[AcpEvent]()
        self.refused = List[String]()
        self.services = False
        self.mode = ""
        self.mode_ids = List[String]()
        self.mode_names = List[String]()
        self.mode_texts = List[String]()
        self.mode_id = -1
        self.mode_wanted = ""
        self.current_model = ""
        self.model_ids = List[String]()
        self.model_names = List[String]()
        self.model_req_id = -1
        self.model_wanted = ""
        self.thinking = ""
        self.thinking_ids = List[String]()
        self.thinking_names = List[String]()
        self.cfg_req_id = -1
        self.thinking_wanted = ""
        self.resume_session_id = ""
        self.load_id = -1
        self.resumed = False
        self.mcp_servers_json = "[]"

    def fd(self) -> Int:
        return self.conn.fd() if self.conn.proc.running else -1

    def active(self) -> Bool:
        return self.state != AS_STOPPED and self.state != AS_FAILED

    def busy(self) -> Bool:
        """A turn is running."""
        return self.prompt_id >= 0

    def start(mut self, cmd: String, cwd: String, stderr_path: String, now: Int) -> Bool:
        """Start the agent (`cmd` through the shell, in `cwd`) and introduce ourselves."""
        if self.conn.proc.running:
            _ = self.conn.stop()
        self.conn = RpcConn()
        self.conn.lines = True
        self.problem = ""
        self.session_id = ""
        self.init_id = -1
        self.new_id = -1
        self.load_id = -1
        self.resumed = False
        self.prompt_id = -1
        self.mode_id = -1
        self.model_req_id = -1
        self.cfg_req_id = -1
        self.current_model = ""
        self.model_ids.clear()
        self.model_names.clear()
        self.thinking = ""
        self.thinking_ids.clear()
        self.thinking_names.clear()
        self.permissions.clear()
        self.events.clear()
        self.refused.clear()
        self.cwd = cwd
        # (Proc.start execs the command: the change of folder goes through a shell)
        if not self.conn.start("sh -c " + shell_word("cd " + shell_word(cwd) + " && exec " + cmd), stderr_path):
            self.fail("the agent could not be started: " + cmd)
            return False
        var w = JsonWriter()
        w.begin_obj()
        w.kv_int("protocolVersion", ACP_PROTOCOL_VERSION)
        w.key("clientCapabilities")
        w.begin_obj()
        w.key("fs")
        w.begin_obj()
        w.kv_bool("readTextFile", self.services)
        w.kv_bool("writeTextFile", self.services)
        w.end_obj()
        w.kv_bool("terminal", self.services)
        w.end_obj()
        w.key("clientInfo")
        w.begin_obj()
        w.kv_str("name", "turbomojo")
        w.kv_str("title", "TurboMojo")
        w.kv_str("version", "1.7")
        w.end_obj()
        w.end_obj()
        self.init_id = self.conn.request("initialize", w.text(), now)
        self.state = AS_STARTING
        self.started_ns = now
        return True

    def fail(mut self, why: String):
        self.state = AS_FAILED
        self.problem = why
        self.prompt_id = -1
        var e = AcpEvent(AE_FAILED)
        e.text = why
        self.events.append(e^)

    def stop(mut self):
        """End the agent (a turn running is cancelled first)."""
        if self.busy():
            self.cancel()
            self.conn.proc.flush()
        if self.conn.proc.running:
            _ = self.conn.stop()
        self.state = AS_STOPPED
        self.session_id = ""
        self.prompt_id = -1
        self.permissions.clear()

    def prompt(mut self, text: String, now: Int) -> Bool:
        """Start a turn with the user's text. False if no session is open or a turn
        is running."""
        var w = JsonWriter()
        w.begin_obj()
        w.kv_str("type", "text")
        w.kv_str("text", text)
        w.end_obj()
        return self.prompt_blocks("[" + w.text() + "]", now)

    def prompt_blocks(mut self, blocks_json: String, now: Int) -> Bool:
        """Start a turn with these content blocks (a JSON array: text, resource_link,
        resource)."""
        if self.state != AS_READY or self.busy():
            return False
        self.prompt_id = self.conn.request("session/prompt", "{\"sessionId\":" + json_quote(self.session_id) + ",\"prompt\":" + blocks_json + "}", now)
        self.prompt_ns = now
        return True

    def cancel(mut self):
        """Ask the agent to stop the turn; it answers the prompt with "cancelled".
        Permission requests not yet answered are answered "cancelled", as the protocol
        requires."""
        if not self.busy():
            return
        for rid in self.permissions:
            self.conn.respond(rid, "{\"outcome\":{\"outcome\":\"cancelled\"}}")
        self.permissions.clear()
        self.conn.notify("session/cancel", "{\"sessionId\":" + json_quote(self.session_id) + "}")

    def answer_permission(mut self, request: String, option_id: String) -> Bool:
        """Answer a permission request with one of its options ('' = cancelled)."""
        var k = -1
        for i in range(len(self.permissions)):
            if self.permissions[i] == request:
                k = i
        if k < 0:
            return False
        _ = self.permissions.pop(k)
        if option_id.byte_length() == 0:
            self.conn.respond(request, "{\"outcome\":{\"outcome\":\"cancelled\"}}")
        else:
            self.conn.respond(request, "{\"outcome\":{\"outcome\":\"selected\",\"optionId\":" + json_quote(option_id) + "}}")
        return True

    def set_mode(mut self, id: String, now: Int) -> Bool:
        """Ask the agent to work in one of the modes it offers."""
        if self.state != AS_READY or id not in self.mode_ids:
            return False
        self.mode_wanted = id
        self.mode_id = self.conn.request("session/set_mode", "{\"sessionId\":" + json_quote(self.session_id) + ",\"modeId\":" + json_quote(id) + "}", now)
        return True

    def asking_mode(self) -> String:
        """The mode in which the agent asks before it changes anything ('' if it has no
        such mode): "default" (Claude's "Manual: Always ask before making changes"), else
        one whose name or description says it asks."""
        if "default" in self.mode_ids:
            return "default"
        for k in range(len(self.mode_ids)):
            var t = self.mode_names[k].lower() + " " + self.mode_texts[k].lower()
            if t.find("ask") >= 0 or t.find("approv") >= 0 or t.find("manual") >= 0:
                return self.mode_ids[k]
        return ""

    def mode_name(self, id: String) -> String:
        for k in range(len(self.mode_ids)):
            if self.mode_ids[k] == id:
                return self.mode_names[k] if self.mode_names[k].byte_length() > 0 else id
        return id

    def set_model(mut self, id: String, now: Int) -> Bool:
        """Ask the agent to switch to one of the models it offers."""
        if self.state != AS_READY or id not in self.model_ids:
            return False
        self.model_wanted = id
        self.model_req_id = self.conn.request("session/set_model", "{\"sessionId\":" + json_quote(self.session_id) + ",\"modelId\":" + json_quote(id) + "}", now)
        return True

    def model_name(self, id: String) -> String:
        for k in range(len(self.model_ids)):
            if self.model_ids[k] == id:
                return self.model_names[k] if self.model_names[k].byte_length() > 0 else id
        return id

    def set_thinking(mut self, val: String, now: Int) -> Bool:
        """Ask the agent to set its `thought_level` config option."""
        if self.state != AS_READY or val not in self.thinking_ids:
            return False
        self.thinking_wanted = val
        self.cfg_req_id = self.conn.request("session/set_config_option", "{\"sessionId\":" + json_quote(self.session_id) + ",\"configId\":\"thought_level\",\"value\":" + json_quote(val) + "}", now)
        return True

    def thinking_name(self, id: String) -> String:
        for k in range(len(self.thinking_ids)):
            if self.thinking_ids[k] == id:
                return self.thinking_names[k] if self.thinking_names[k].byte_length() > 0 else id
        return id

    def parse_config_options(mut self, doc: Json, opts: Int):
        if opts < 0 or doc.kind(opts) != J_ARR:
            return
        for opt in doc.children(opts):
            var cid = doc.str(doc.get(opt, "id"))
            if cid == "thought_level":
                self.thinking = doc.str(doc.get(opt, "currentValue"))
                self.thinking_ids.clear()
                self.thinking_names.clear()
                var arr = doc.get(opt, "options")
                if arr >= 0 and doc.kind(arr) == J_ARR:
                    for o in doc.children(arr):
                        self.thinking_ids.append(doc.str(doc.get(o, "value")))
                        self.thinking_names.append(doc.str(doc.get(o, "name")))
            elif cid == "model":
                var cv = doc.str(doc.get(opt, "currentValue"))
                if cv.byte_length() > 0:
                    self.current_model = cv
            elif cid == "mode":
                var mv = doc.str(doc.get(opt, "currentValue"))
                if mv.byte_length() > 0:
                    self.mode = mv

    def parse_session_meta(mut self, doc: Json, r: Int):
        var modes = doc.get(r, "modes")
        self.mode = doc.str(doc.get(modes, "currentModeId"))
        self.mode_ids.clear()
        self.mode_names.clear()
        self.mode_texts.clear()
        var am = doc.get(modes, "availableModes")
        if am >= 0 and doc.kind(am) == J_ARR:
            for md in doc.children(am):
                self.mode_ids.append(doc.str(doc.get(md, "id")))
                self.mode_names.append(doc.str(doc.get(md, "name")))
                self.mode_texts.append(doc.str(doc.get(md, "description")))
        var models = doc.get(r, "models")
        if models >= 0 and doc.kind(models) == J_OBJ:
            self.current_model = doc.str(doc.get(models, "currentModelId"))
            self.model_ids.clear()
            self.model_names.clear()
            var av = doc.get(models, "availableModels")
            if av >= 0 and doc.kind(av) == J_ARR:
                for ml in doc.children(av):
                    self.model_ids.append(doc.str(doc.get(ml, "modelId")))
                    self.model_names.append(doc.str(doc.get(ml, "name")))
        self.parse_config_options(doc, doc.get(r, "configOptions"))

    def answer(mut self, request: String, result_json: String):
        """Answer a request of the agent (a service the editor gave)."""
        self.conn.respond(request, result_json)

    def answer_error(mut self, request: String, code: Int, message: String):
        self.conn.respond_error(request, code, message)

    def take_events(mut self) -> List[AcpEvent]:
        var out = self.events.copy()
        self.events.clear()
        return out^

    # ------------------------------------------------------------ receiving
    def pump(mut self, now: Int):
        """Send what is queued, read what came, turn it into events."""
        if not self.conn.proc.running:
            return
        for m in self.conn.poll():
            self.handle(m)
        if self.state == AS_STARTING and now - self.started_ns > INIT_TIMEOUT_NS:
            _ = self.conn.stop()
            self.fail("the agent did not answer `initialize` within 30 s")
            return
        if self.conn.ended():
            _ = self.conn.stop()
            if self.state != AS_FAILED:
                self.fail("the agent ended" + (" before it was ready" if self.state != AS_READY else String("")))

    def handle(mut self, m: RpcMessage):
        if m.kind == RPC_RESPONSE or m.kind == RPC_ERROR:
            self.handle_response(m)
        elif m.kind == RPC_NOTIFICATION:
            if m.method == "session/update":
                var p = m.params()
                if m.doc.str(m.doc.get(p, "sessionId")) != self.session_id:
                    return
                var u = m.doc.get(p, "update")
                if u >= 0:
                    var ev = update_event(m.doc, u)
                    if ev.kind_name == "current_mode_update":
                        self.mode = m.doc.str(m.doc.get(u, "currentModeId"))
                        ev.kind = AE_MODE
                        ev.status = self.mode
                    elif ev.kind_name == "config_option_update":
                        self.parse_config_options(m.doc, m.doc.get(u, "configOptions"))
                    self.events.append(ev^)
        elif m.kind == RPC_REQUEST:
            if m.method == "session/request_permission":
                var p = m.params()
                var e = AcpEvent(AE_PERMISSION)
                e.request = m.id_json
                var tc = m.doc.get(p, "toolCall")
                e.id = m.doc.str(m.doc.get(tc, "toolCallId"))
                e.title = m.doc.str(m.doc.get(tc, "title"))
                e.tool_kind = m.doc.str(m.doc.get(tc, "kind"))
                var opts = m.doc.get(p, "options")
                if opts >= 0 and m.doc.kind(opts) == J_ARR:
                    for o in m.doc.children(opts):
                        e.option_ids.append(m.doc.str(m.doc.get(o, "optionId")))
                        e.option_names.append(m.doc.str(m.doc.get(o, "name")))
                        e.option_kinds.append(m.doc.str(m.doc.get(o, "kind")))
                if not self.busy():
                    # not during a turn: nothing to allow
                    self.conn.respond(m.id_json, "{\"outcome\":{\"outcome\":\"cancelled\"}}")
                    return
                self.permissions.append(m.id_json)
                self.events.append(e^)
            elif self.services and (m.method.startswith("fs/") or m.method.startswith("terminal/")):
                var e = AcpEvent(AE_SERVICE)
                e.kind_name = m.method
                e.request = m.id_json
                var p = m.params()
                e.text = m.doc.dump(p) if p >= 0 else String("{}")
                self.events.append(e^)
            else:
                # fs/*, terminal/* when not offered, and anything unknown
                self.refused.append(m.method)
                self.conn.respond_error(m.id_json, -32601, "TurboMojo does not offer " + m.method)

    def handle_response(mut self, m: RpcMessage):
        if m.id == self.init_id:
            self.init_id = -1
            if m.kind == RPC_ERROR:
                _ = self.conn.stop()
                self.fail("initialize failed: " + m.error_message())
                return
            var r = m.result()
            self.version = m.doc.int(m.doc.get(r, "protocolVersion"), 0)
            if self.version != ACP_PROTOCOL_VERSION:
                _ = self.conn.stop()
                self.fail("the agent speaks ACP version " + String(self.version) + "; TurboMojo speaks version " + String(ACP_PROTOCOL_VERSION))
                return
            var info = m.doc.get(r, "agentInfo")
            self.agent_name = m.doc.str(m.doc.get(info, "title"))
            if self.agent_name.byte_length() == 0:
                self.agent_name = m.doc.str(m.doc.get(info, "name"))
            var caps = m.doc.get(r, "agentCapabilities")
            self.load_session = m.doc.bool(m.doc.get(caps, "loadSession"))
            self.images = m.doc.bool(m.doc.path(caps, "promptCapabilities/image"))
            self.embedded_context = m.doc.bool(m.doc.path(caps, "promptCapabilities/embeddedContext"))
            self.auth_methods.clear()
            var am = m.doc.get(r, "authMethods")
            if am >= 0 and m.doc.kind(am) == J_ARR:
                for a in m.doc.children(am):
                    self.auth_methods.append(m.doc.str(m.doc.get(a, "id")))
            if self.load_session and self.resume_session_id.byte_length() > 0:
                self.session_id = self.resume_session_id
                self.load_id = self.conn.request("session/load", "{\"sessionId\":" + json_quote(self.resume_session_id) + ",\"cwd\":" + json_quote(self.cwd) + ",\"mcpServers\":" + self.mcp_servers_json + "}", self.started_ns)
            else:
                self.new_id = self.conn.request("session/new", "{\"cwd\":" + json_quote(self.cwd) + ",\"mcpServers\":" + self.mcp_servers_json + "}", self.started_ns)
            self.state = AS_OPENING
            return
        if m.id == self.load_id:
            self.load_id = -1
            if m.kind == RPC_ERROR:
                self.session_id = ""
                self.resume_session_id = ""
                self.events.clear()
                self.new_id = self.conn.request("session/new", "{\"cwd\":" + json_quote(self.cwd) + ",\"mcpServers\":" + self.mcp_servers_json + "}", self.started_ns)
                return
            var sid = m.doc.str(m.doc.get(m.result(), "sessionId"))
            if sid.byte_length() > 0:
                self.session_id = sid
            self.resumed = True
            self.parse_session_meta(m.doc, m.result())
            self.state = AS_READY
            self.events.append(AcpEvent(AE_READY))
            return
        if m.id == self.new_id:
            self.new_id = -1
            if m.kind == RPC_ERROR:
                _ = self.conn.stop()
                var why = m.error_message()
                if len(self.auth_methods) > 0:
                    why += " (the agent wants you to sign in first: run it once in a terminal)"
                self.fail("no session: " + why)
                return
            self.session_id = m.doc.str(m.doc.get(m.result(), "sessionId"))
            if self.session_id.byte_length() == 0:
                _ = self.conn.stop()
                self.fail("no session: the agent gave no session id")
                return
            self.resumed = False
            self.parse_session_meta(m.doc, m.result())
            self.state = AS_READY
            self.events.append(AcpEvent(AE_READY))
            return
        if m.id == self.mode_id:
            self.mode_id = -1
            var e = AcpEvent(AE_MODE)
            if m.kind == RPC_ERROR:
                e.text = "the agent did not change its mode: " + m.error_message()
            else:
                self.mode = self.mode_wanted
            e.status = self.mode
            self.events.append(e^)
            return
        if m.id == self.model_req_id:
            self.model_req_id = -1
            var e = AcpEvent(AE_MODEL)
            if m.kind == RPC_ERROR:
                e.text = "the agent did not change its model: " + m.error_message()
            else:
                self.current_model = self.model_wanted
            e.status = self.current_model
            self.events.append(e^)
            return
        if m.id == self.cfg_req_id:
            self.cfg_req_id = -1
            var e = AcpEvent(AE_THINKING)
            if m.kind == RPC_ERROR:
                e.text = "the agent did not change its thinking level: " + m.error_message()
            else:
                self.thinking = self.thinking_wanted
                self.parse_config_options(m.doc, m.doc.get(m.result(), "configOptions"))
            e.status = self.thinking
            self.events.append(e^)
            return
        if m.id == self.prompt_id:
            self.prompt_id = -1
            self.permissions.clear()
            var e = AcpEvent(AE_TURN_END)
            if m.kind == RPC_ERROR:
                e.stop_reason = "error"
                e.text = m.error_message()
            else:
                e.stop_reason = m.doc.str(m.doc.get(m.result(), "stopReason"), "end_turn")
            self.events.append(e^)


def shell_word(s: String) -> String:
    return "'" + s.replace("'", "'\\''") + "'"
