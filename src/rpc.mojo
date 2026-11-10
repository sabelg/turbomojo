"""JSON-RPC 2.0 over a child process's pipes, with `Content-Length` framing.

This is the transport shared by the Language Server Protocol and (with a different message
shape) the Debug Adapter Protocol and the Agent Client Protocol.

`Framer` cuts a byte stream into message bodies. `RpcConn` owns the child process, sends
requests / notifications / responses, and turns incoming bodies into `RpcMessage`s, pairing
each response with the request it answers. Nothing here blocks: the event loop polls
`RpcConn.fd()` and calls `poll()`."""
from std.collections import List
from json import Json, JsonWriter, json_parse_bytes, json_quote, J_NUM, J_STR, J_OBJ, J_NULL
from proc import Proc
from util import str_bytes, bytes_to_str

comptime RPC_RESPONSE = 1       # a successful reply to one of our requests
comptime RPC_ERROR = 2          # an error reply to one of our requests
comptime RPC_REQUEST = 3        # the other side asks us something (needs a response)
comptime RPC_NOTIFICATION = 4   # the other side tells us something
comptime RPC_INVALID = 5        # not a JSON-RPC message

comptime MAX_MESSAGE_BYTES = 64 * 1024 * 1024


struct Framer(Copyable, Movable):
    var buf: List[UInt8]
    var pos: Int            # start of unconsumed data in buf
    var dropped: Int        # bytes thrown away because they were not a valid frame

    def __init__(out self):
        self.buf = List[UInt8]()
        self.pos = 0
        self.dropped = 0

    def feed(mut self, data: List[UInt8]):
        if self.pos > 0 and self.pos == len(self.buf):
            self.buf.clear()
            self.pos = 0
        elif self.pos > 65536:
            var rest = List[UInt8]()
            for k in range(self.pos, len(self.buf)):
                rest.append(self.buf[k])
            self.buf = rest^
            self.pos = 0
        for b in data:
            self.buf.append(b)

    def pending_bytes(self) -> Int:
        return len(self.buf) - self.pos

    def header_end(self) -> Int:
        """Index just past the first CR LF CR LF at or after pos, or -1."""
        var n = len(self.buf)
        var i = self.pos
        while i + 3 < n:
            if self.buf[i] == 13 and self.buf[i + 1] == 10 and self.buf[i + 2] == 13 and self.buf[i + 3] == 10:
                return i + 4
            i += 1
        return -1

    def content_length(self, start: Int, end: Int) -> Int:
        """Value of the Content-Length header in buf[start:end] (-1 if absent). The name
        is matched case-insensitively and anywhere in the block, so stray output printed
        before a frame does not break the stream."""
        var name = str_bytes("content-length:")
        var i = start
        while i + len(name) <= end:
            var hit = True
            for k in range(len(name)):
                var c = Int(self.buf[i + k])
                if c >= 65 and c <= 90:
                    c += 32
                if c != Int(name[k]):
                    hit = False
                    break
            if hit:
                var j = i + len(name)
                while j < end and (self.buf[j] == 32 or self.buf[j] == 9):
                    j += 1
                var v = 0
                var digits = 0
                while j < end and self.buf[j] >= 48 and self.buf[j] <= 57 and digits < 12:
                    v = v * 10 + Int(self.buf[j]) - 48
                    digits += 1
                    j += 1
                if digits > 0:
                    return v
            i += 1
        return -1

    def next(mut self, mut body: List[UInt8]) -> Bool:
        """Extract the next complete message body. False when more data is needed."""
        while True:
            var he = self.header_end()
            if he < 0:
                return False
            var n = self.content_length(self.pos, he)
            if n < 0 or n > MAX_MESSAGE_BYTES:
                # a header block without a usable length: skip it and look again
                self.dropped += he - self.pos
                self.pos = he
                continue
            if len(self.buf) - he < n:
                return False
            body.clear()
            for k in range(he, he + n):
                body.append(self.buf[k])
            self.pos = he + n
            return True


def frame(body: String) -> List[UInt8]:
    """A message body with its Content-Length header."""
    var out = str_bytes("Content-Length: " + String(body.byte_length()) + "\r\n\r\n")
    for b in body.as_bytes():
        out.append(b)
    return out^


struct RpcMessage(Copyable, Movable):
    var kind: Int
    var id: Int             # numeric id (responses to our requests; -1 otherwise)
    var id_json: String     # the id exactly as received, for answering a request
    var method: String      # request/notification method, or the method we had asked
    var doc: Json           # the whole message: see "result", "error", "params"

    def __init__(out self):
        self.kind = RPC_INVALID
        self.id = -1
        self.id_json = ""
        self.method = ""
        self.doc = Json()

    def result(self) -> Int:
        """Node index of "result" (-1 if absent)."""
        return self.doc.get(0, "result")

    def params(self) -> Int:
        return self.doc.get(0, "params")

    def error_code(self) -> Int:
        return self.doc.int(self.doc.path(0, "error/code"), 0)

    def error_message(self) -> String:
        return self.doc.str(self.doc.path(0, "error/message"), "")


struct RpcConn(Copyable, Movable):
    var proc: Proc
    var framer: Framer
    var next_id: Int
    var pending_ids: List[Int]
    var pending_methods: List[String]
    var pending_since: List[Int]     # caller-supplied timestamps (ns) for timeouts
    var invalid: Int                 # bodies that were not valid JSON-RPC

    def __init__(out self):
        self.proc = Proc()
        self.framer = Framer()
        self.next_id = 1
        self.pending_ids = List[Int]()
        self.pending_methods = List[String]()
        self.pending_since = List[Int]()
        self.invalid = 0

    # ------------------------------------------------------------ lifecycle
    def start(mut self, cmd: String, stderr_path: String = "/dev/null") -> Bool:
        self.framer = Framer()
        self.pending_ids.clear()
        self.pending_methods.clear()
        self.pending_since.clear()
        return self.proc.start(cmd, stderr_path)

    def fd(self) -> Int:
        return self.proc.out_fd

    def alive(self) -> Bool:
        return self.proc.alive()

    def ended(self) -> Bool:
        """The child has closed its output: no more messages will come."""
        return self.proc.running and self.proc.eof

    def wants_write(self) -> Bool:
        return self.proc.wants_write()

    def stop(mut self) -> Int:
        return self.proc.stop()

    # -------------------------------------------------------------- sending
    def send_body(mut self, body: String):
        self.proc.write(frame(body))

    def request(mut self, method: String, params_json: String, now: Int = 0) -> Int:
        """Send a request; returns its id. `params_json` is JSON text ('' for none)."""
        var id = self.next_id
        self.next_id += 1
        var w = JsonWriter()
        w.begin_obj()
        w.kv_str("jsonrpc", "2.0")
        w.kv_int("id", id)
        w.kv_str("method", method)
        if params_json.byte_length() > 0:
            w.key("params")
            w.raw(params_json)
        w.end_obj()
        self.pending_ids.append(id)
        self.pending_methods.append(method)
        self.pending_since.append(now)
        self.send_body(w.text())
        return id

    def notify(mut self, method: String, params_json: String):
        var w = JsonWriter()
        w.begin_obj()
        w.kv_str("jsonrpc", "2.0")
        w.kv_str("method", method)
        if params_json.byte_length() > 0:
            w.key("params")
            w.raw(params_json)
        w.end_obj()
        self.send_body(w.text())

    def respond(mut self, id_json: String, result_json: String):
        """Answer a request from the other side. `id_json` is RpcMessage.id_json."""
        self.send_body("{\"jsonrpc\":\"2.0\",\"id\":" + id_json + ",\"result\":" + (result_json if result_json.byte_length() > 0 else "null") + "}")

    def respond_error(mut self, id_json: String, code: Int, message: String):
        self.send_body("{\"jsonrpc\":\"2.0\",\"id\":" + id_json + ",\"error\":{\"code\":" + String(code) + ",\"message\":" + json_quote(message) + "}}")

    def cancel(mut self, id: Int) -> Bool:
        """Forget a pending request (its late reply will arrive with an empty method)."""
        for k in range(len(self.pending_ids)):
            if self.pending_ids[k] == id:
                _ = self.pending_ids.pop(k)
                _ = self.pending_methods.pop(k)
                _ = self.pending_since.pop(k)
                return True
        return False

    def is_pending(self, id: Int) -> Bool:
        return id in self.pending_ids

    def timed_out(mut self, now: Int, timeout_ns: Int) -> List[Int]:
        """Remove and return the ids of requests older than `timeout_ns`."""
        var out = List[Int]()
        var k = 0
        while k < len(self.pending_ids):
            if now - self.pending_since[k] >= timeout_ns:
                out.append(self.pending_ids[k])
                _ = self.pending_ids.pop(k)
                _ = self.pending_methods.pop(k)
                _ = self.pending_since.pop(k)
            else:
                k += 1
        return out^

    # ------------------------------------------------------------ receiving
    def classify(mut self, body: List[UInt8]) -> RpcMessage:
        var m = RpcMessage()
        m.doc = json_parse_bytes(body)
        if not m.doc.ok or m.doc.kind(0) != J_OBJ:
            self.invalid += 1
            return m^
        var idn = m.doc.get(0, "id")
        var has_id = idn >= 0 and not m.doc.is_null(idn)
        if has_id:
            m.id_json = m.doc.dump(idn)
            if m.doc.kind(idn) == J_NUM:
                m.id = m.doc.int(idn, -1)
        var mn = m.doc.get(0, "method")
        if mn >= 0 and m.doc.kind(mn) == J_STR:
            m.method = m.doc.str(mn)
            if has_id:
                m.kind = RPC_REQUEST
                m.id = -1       # ids of *their* requests are only echoed, never looked up
            else:
                m.kind = RPC_NOTIFICATION
            return m^
        if m.doc.has(0, "result") or m.doc.has(0, "error"):
            m.kind = RPC_ERROR if m.doc.has(0, "error") else RPC_RESPONSE
            for k in range(len(self.pending_ids)):
                if self.pending_ids[k] == m.id:
                    m.method = self.pending_methods[k]
                    _ = self.pending_ids.pop(k)
                    _ = self.pending_methods.pop(k)
                    _ = self.pending_since.pop(k)
                    break
            return m^
        self.invalid += 1
        return m^

    def feed(mut self, data: List[UInt8]) -> List[RpcMessage]:
        """Parse received bytes into messages (usable without a child process)."""
        var out = List[RpcMessage]()
        self.framer.feed(data)
        var body = List[UInt8]()
        while self.framer.next(body):
            var m = self.classify(body)
            if m.kind != RPC_INVALID:
                out.append(m^)
        return out^

    def poll(mut self) -> List[RpcMessage]:
        """Send queued output, read what has arrived and return the complete messages."""
        self.proc.flush()
        _ = self.proc.read_available()
        return self.feed(self.proc.take())
