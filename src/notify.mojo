"""Notifications: short messages that show for a few seconds at the top right ("toasts")
when something finishes or needs attention while you work elsewhere, and are kept in
the notification centre (Help > Notifications) with what is running now.
"""
from std.collections import List

comptime NL_INFO = 0
comptime NL_DONE = 1        # something finished well
comptime NL_WARN = 2        # it needs you (a question waits), or finished with problems
comptime NL_ERROR = 3       # it failed

comptime TOAST_MS = 5000
comptime TOAST_ERROR_MS = 10000
comptime TOASTS_SHOWN = 3
comptime NOTICES_KEPT = 100


struct Notice(Copyable, Movable):
    var level: Int
    var title: String
    var text: String
    var at_ns: Int
    var clock: String       # the time it came, as shown in the centre
    var shown: Bool         # still a toast (not dismissed)

    def __init__(out self, level: Int, title: String, text: String, at_ns: Int, clock: String):
        self.level = level
        self.title = title
        self.text = text
        self.at_ns = at_ns
        self.clock = clock
        self.shown = True

    def until_ns(self) -> Int:
        return self.at_ns + (TOAST_ERROR_MS if self.level == NL_ERROR else TOAST_MS) * 1000000


def level_mark(level: Int) -> String:
    if level == NL_DONE:
        return "✓"
    if level == NL_WARN:
        return "!"
    if level == NL_ERROR:
        return "✗"
    return "•"


struct NotifyCenter(Copyable, Movable):
    var notices: List[Notice]       # oldest first
    var unread: Int                 # come since the centre was last opened

    def __init__(out self):
        self.notices = List[Notice]()
        self.unread = 0

    def add(mut self, level: Int, title: String, text: String, now: Int, clock: String):
        # the same message again soon after: the toast is shown anew, not twice
        var n = len(self.notices)
        if n > 0 and self.notices[n - 1].title == title and self.notices[n - 1].text == text and now - self.notices[n - 1].at_ns < TOAST_MS * 1000000:
            self.notices[n - 1].at_ns = now
            self.notices[n - 1].shown = True
            return
        self.notices.append(Notice(level, title, text, now, clock))
        self.unread += 1
        if len(self.notices) > NOTICES_KEPT:
            _ = self.notices.pop(0)

    def toasts(self, now: Int) -> List[Int]:
        """The notices to show as toasts now (indices, newest first)."""
        var out = List[Int]()
        var k = len(self.notices) - 1
        while k >= 0 and len(out) < TOASTS_SHOWN:
            if self.notices[k].shown and now < self.notices[k].until_ns():
                out.append(k)
            k -= 1
        return out^

    def next_change_ns(self, now: Int) -> Int:
        """When the toasts shown change by themselves (0: no toast is shown)."""
        var best = 0
        for k in self.toasts(now):
            var u = self.notices[k].until_ns()
            if best == 0 or u < best:
                best = u
        return best

    def dismiss(mut self, k: Int):
        if k >= 0 and k < len(self.notices):
            self.notices[k].shown = False

    def dismiss_all(mut self):
        for k in range(len(self.notices)):
            self.notices[k].shown = False

    def clear(mut self):
        self.notices.clear()
        self.unread = 0
