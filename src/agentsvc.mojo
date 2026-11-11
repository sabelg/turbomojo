"""What the editor does for a coding agent (ACP): its terminals (`terminal/*`: a command on
a pty, its output kept for the agent) and the files it proposes to write
(`fs/write_text_file`: a proposal the user accepts or rejects in the diff view).
"""
from std.collections import List
from pty import Pty, exit_code
from util import bytes_to_str, str_bytes

comptime TERM_DEFAULT_LIMIT = 1024 * 1024


def clean_output(data: List[UInt8]) -> List[UInt8]:
    """Terminal output as text: escape sequences (CSI, OSC, other ESC pairs) taken out,
    CR LF made LF, other CRs dropped."""
    var out = List[UInt8]()
    var n = len(data)
    var i = 0
    while i < n:
        var b = data[i]
        if b == 27 and i + 1 < n:
            var c = data[i + 1]
            if c == 91:                         # CSI: up to a final byte @..~
                i += 2
                while i < n and not (data[i] >= 64 and data[i] <= 126):
                    i += 1
                i += 1
                continue
            if c == 93:                         # OSC: up to BEL or ESC \
                i += 2
                while i < n and data[i] != 7 and not (data[i] == 27 and i + 1 < n and data[i + 1] == 92):
                    i += 1
                i += 1 if (i < n and data[i] == 7) else 2
                continue
            i += 2
            continue
        if b == 13:
            i += 1
            continue
        out.append(b)
        i += 1
    return out^


def keep_last(mut data: List[UInt8], limit: Int) -> Bool:
    """Drop bytes from the front so that at most `limit` are left, at a character
    boundary. True if something was dropped."""
    if limit <= 0 or len(data) <= limit:
        return False
    var start = len(data) - limit
    while start < len(data) and (data[start] & 0xC0) == 0x80:
        start += 1                              # not in the middle of a UTF-8 character
    var rest = List[UInt8]()
    for k in range(start, len(data)):
        rest.append(data[k])
    data = rest^
    return True


def tail_lines(text: String, n: Int) -> String:
    var lines = text.split("\n")
    var count = len(lines)
    if count > 0 and String(lines[count - 1]).byte_length() == 0:
        count -= 1
    var out = String("")
    for k in range(max(0, count - n), count):
        out += ("\n" if out.byte_length() > 0 else "") + String(lines[k])
    return out^


struct AgentTerm(Copyable, Movable):
    var id: String
    var title: String           # the command as shown
    var pty: Pty
    var output: List[UInt8]     # cleaned, at most `limit` bytes (the newest)
    var limit: Int
    var truncated: Bool
    var done: Bool
    var code: Int               # exit code (when done; -1 if it was a signal)
    var signal: Int             # the signal that ended it (0: none)
    var waiters: List[String]   # terminal/wait_for_exit requests not answered yet

    def __init__(out self, id: String, title: String, limit: Int):
        self.id = id
        self.title = title
        self.pty = Pty()
        self.output = List[UInt8]()
        self.limit = limit if limit > 0 else TERM_DEFAULT_LIMIT
        self.truncated = False
        self.done = False
        self.code = -1
        self.signal = 0
        self.waiters = List[String]()

    def pump(mut self) -> Bool:
        """Take what the command printed; notice its end. True if anything changed."""
        if self.done:
            return False
        var changed = False
        if self.pty.read_available() > 0:
            for b in clean_output(self.pty.take()):
                self.output.append(b)
            if keep_last(self.output, self.limit):
                self.truncated = True
            changed = True
        if self.pty.poll_exit():
            # whatever came last
            _ = self.pty.read_available()
            for b in clean_output(self.pty.take()):
                self.output.append(b)
            if keep_last(self.output, self.limit):
                self.truncated = True
            self.done = True
            var st = self.pty.status
            if st & 127 == 0:
                self.code = (st >> 8) & 255
            else:
                self.signal = st & 127
            changed = True
        return changed

    def kill(mut self):
        if not self.done:
            _ = self.pty.stop()
            self.done = True
            var st = self.pty.status
            if st >= 0 and st & 127 == 0:
                self.code = (st >> 8) & 255
            else:
                self.signal = st & 127 if st >= 0 and st & 127 != 0 else 9

    def exit_json(self) -> String:
        """{"exitCode": .., "signal": ..} (as ACP has it: a signal by name)."""
        var sig = String("null")
        if self.signal != 0:
            sig = "\"" + signal_name(self.signal) + "\""
        return "{\"exitCode\":" + (String(self.code) if self.signal == 0 else String("null")) + ",\"signal\":" + sig + "}"


def signal_name(n: Int) -> String:
    if n == 1:
        return "SIGHUP"
    if n == 2:
        return "SIGINT"
    if n == 9:
        return "SIGKILL"
    if n == 15:
        return "SIGTERM"
    if n == 11:
        return "SIGSEGV"
    if n == 6:
        return "SIGABRT"
    return "SIG" + String(n)


struct Proposal(Copyable, Movable):
    """A file the agent wants written: the request to answer, the file, and its text
    before and after."""
    var request: String
    var path: String
    var old: String
    var new: String
    var exists: Bool

    def __init__(out self, request: String, path: String, old: String, new: String, exists: Bool):
        self.request = request
        self.path = path
        self.old = old
        self.new = new
        self.exists = exists


@fieldwise_init
struct RunAsk(Copyable, Movable):
    """A command the agent wants to run, waiting for the user's yes."""
    var request: String
    var argv: List[String]
    var cwd: String
    var env: List[String]
    var limit: Int
    var title: String
