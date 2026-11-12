"""The agent panel's model: the conversation with a coding agent as entries (what you
said, what the agent answered as it streams in, its thinking, tool calls, plans, notes)
turned into Markdown for the panel; and the mentions in a prompt.

A mention is `@path` (a file) or `@path:12` / `@path:12-20` (lines of it), written at the
start of the prompt or after a blank. The app sends the file or the lines with the
prompt (see app_agent).
"""
from std.collections import List

comptime CE_USER = 1
comptime CE_AGENT = 2
comptime CE_THOUGHT = 3
comptime CE_TOOL = 4
comptime CE_PLAN = 5
comptime CE_NOTE = 6
comptime CE_TERM = 7         # a command the agent runs in a terminal: title, status, last lines


struct ChatEntry(Copyable, Movable):
    var kind: Int
    var text: String
    var id: String          # tool call id
    var title: String
    var status: String
    var detail: List[String]    # tool call: places, diffs, its text; plan: entries

    def __init__(out self, kind: Int, text: String):
        self.kind = kind
        self.text = text
        self.id = ""
        self.title = ""
        self.status = ""
        self.detail = List[String]()


def status_mark(status: String) -> String:
    if status == "completed":
        return "✓"
    if status == "failed":
        return "✗"
    if status == "in_progress":
        return "…"
    if status == "cancelled":
        return "-"
    return "·"


struct AgentChat(Copyable, Movable):
    var entries: List[ChatEntry]
    var version: Int        # changes with every change (the panel renders again)

    def __init__(out self):
        self.entries = List[ChatEntry]()
        self.version = 0

    def clear(mut self):
        self.entries.clear()
        self.version += 1

    def user(mut self, text: String):
        self.entries.append(ChatEntry(CE_USER, text))
        self.version += 1

    def note(mut self, text: String):
        self.entries.append(ChatEntry(CE_NOTE, text))
        self.version += 1

    def chunk(mut self, kind: Int, text: String):
        """A piece of the agent's answer or thinking: added to the entry being written
        if that is of the same kind, else a new entry."""
        var n = len(self.entries)
        if n > 0 and self.entries[n - 1].kind == kind:
            self.entries[n - 1].text += text
        else:
            self.entries.append(ChatEntry(kind, text))
        self.version += 1

    def tool(mut self, id: String, title: String, status: String, places: List[String]):
        var e = ChatEntry(CE_TOOL, "")
        e.id = id
        e.title = title if title.byte_length() > 0 else String("(a tool)")
        e.status = status
        for p in places:
            e.detail.append(p)
        self.entries.append(e^)
        self.version += 1

    def tool_update(mut self, id: String, title: String, status: String, text: String, diffs: List[String]):
        for k in range(len(self.entries) - 1, -1, -1):
            if self.entries[k].kind == CE_TOOL and self.entries[k].id == id:
                if status.byte_length() > 0:
                    self.entries[k].status = status
                if title.byte_length() > 0:
                    self.entries[k].title = title
                if text.byte_length() > 0:
                    self.entries[k].text = text
                for d in diffs:
                    if ("changes " + d) not in self.entries[k].detail:
                        self.entries[k].detail.append("changes " + d)
                self.version += 1
                return
        # an update of a call never announced: shown as a call
        self.tool(id, title, status, List[String]())
        self.tool_update(id, "", "", text, diffs)

    def term(mut self, id: String, title: String):
        var e = ChatEntry(CE_TERM, "")
        e.id = id
        e.title = title
        e.status = "running"
        self.entries.append(e^)
        self.version += 1

    def term_update(mut self, id: String, status: String, tail: String):
        for k in range(len(self.entries) - 1, -1, -1):
            if self.entries[k].kind == CE_TERM and self.entries[k].id == id:
                if status.byte_length() > 0:
                    self.entries[k].status = status
                self.entries[k].text = tail
                self.version += 1
                return

    def plan(mut self, entries: List[String]):
        """The agent's plan; a newer plan replaces the one shown last in this turn."""
        var n = len(self.entries)
        if n > 0 and self.entries[n - 1].kind == CE_PLAN:
            self.entries[n - 1].detail = entries.copy()
        else:
            var e = ChatEntry(CE_PLAN, "")
            e.detail = entries.copy()
            self.entries.append(e^)
        self.version += 1

    def turn_steps(self) -> Int:
        """Tool calls and commands since the user's last message: what the agent has
        done so far in this turn."""
        var n = 0
        var k = len(self.entries) - 1
        while k >= 0 and self.entries[k].kind != CE_USER:
            if self.entries[k].kind == CE_TOOL or self.entries[k].kind == CE_TERM:
                n += 1
            k -= 1
        return n

    def cancel_open_tools(mut self):
        """A turn ended: calls still pending or running did not finish."""
        for k in range(len(self.entries)):
            if self.entries[k].kind == CE_TOOL and (self.entries[k].status == "pending" or self.entries[k].status == "in_progress"):
                self.entries[k].status = "cancelled"
                self.version += 1

    def markdown(self, agent_name: String) -> String:
        var out = String("")
        var last = 0
        for e in self.entries:
            if out.byte_length() > 0:
                out += "\n\n"
            if e.kind == CE_USER:
                out += "**You**\n\n" + e.text
            elif e.kind == CE_AGENT:
                if last != CE_AGENT and last != CE_TOOL and last != CE_THOUGHT and last != CE_PLAN:
                    out += "**" + (agent_name if agent_name.byte_length() > 0 else String("Agent")) + "**\n\n"
                out += e.text
            elif e.kind == CE_THOUGHT:
                var q = String("")
                for l in e.text.split("\n"):
                    q += ("\n" if q.byte_length() > 0 else "") + "> " + String(l)
                out += "> *thinking*\n" + q
            elif e.kind == CE_TOOL:
                out += "- " + status_mark(e.status) + " " + e.title + " *(" + (e.status if e.status.byte_length() > 0 else String("pending")) + ")*"
                for d in e.detail:
                    out += "\n  - `" + d + "`"
                if e.text.byte_length() > 0:
                    # its first line of text (not a code fence)
                    var first = String("")
                    for l in e.text.split("\n"):
                        var t = String(String(l).strip())
                        if t.byte_length() > 0 and not t.startswith("```"):
                            first = t
                            break
                    if first.byte_length() > 0:
                        out += "\n  - " + first
            elif e.kind == CE_TERM:
                out += "- `$ " + e.title + "` *(" + e.status + ")*"
                if e.text.byte_length() > 0:
                    out += "\n\n```\n" + e.text + "\n```"
            elif e.kind == CE_PLAN:
                out += "**Plan**\n"
                for d in e.detail:
                    var mark = "·"
                    if d.startswith("[completed]"):
                        mark = "✓"
                    elif d.startswith("[in_progress]"):
                        mark = "…"
                    var close = d.find("] ")
                    out += "\n- " + mark + " " + (String(d[byte=close + 2:]) if close >= 0 else d)
            else:
                out += "*" + e.text + "*"
            last = e.kind
        return out^


@fieldwise_init
struct Mention(Copyable, Movable):
    var token: String       # as written, with the @
    var path: String        # as written (relative to the project, or absolute)
    var first: Int          # 1-based line range (0, 0: the whole file)
    var last: Int


def find_mentions(text: String) -> List[Mention]:
    var out = List[Mention]()
    var words = List[String]()
    for l in text.split("\n"):
        for w in String(l).split(" "):
            words.append(String(w))
    for w in words:
        var t = String(w.strip())
        if not t.startswith("@") or t.byte_length() < 2:
            continue
        # a trailing comma, full stop or bracket is not part of a path
        while t.byte_length() > 1 and (t.endswith(",") or t.endswith(".") or t.endswith(")") or t.endswith(";") or t.endswith("?")):
            var shorter = String(t[byte=0:t.byte_length() - 1])
            t = shorter
        var body = String(t[byte=1:])
        var first = 0
        var last = 0
        var colon = body.rfind(":")
        if colon > 0:
            var rng = String(body[byte=colon + 1:])
            var dash = rng.find("-")
            try:
                if dash > 0:
                    first = atol(String(rng[byte=0:dash]))
                    last = atol(String(rng[byte=dash + 1:]))
                else:
                    first = atol(rng)
                    last = first
                var name = String(body[byte=0:colon])
                body = name
            except:
                first = 0
                last = 0
        if first > last or first < 0:
            first = 0
            last = 0
        out.append(Mention(t, body, first, last))
    return out^


def lines_of(text: String, first: Int, last: Int) -> String:
    """Lines first..last (1-based, inclusive) of a text; all of it for 0, 0."""
    if first <= 0:
        return text
    var out = String("")
    var n = 1
    for l in text.split("\n"):
        if n >= first and n <= last:
            out += String(l) + "\n"
        n += 1
    return out^


def mime_for(path: String) -> String:
    if path.endswith(".mojo") or path.endswith(".🔥"):
        return "text/x-mojo"
    if path.endswith(".py"):
        return "text/x-python"
    if path.endswith(".md"):
        return "text/markdown"
    return "text/plain"
