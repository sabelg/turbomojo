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
comptime TYPING_PAUSE_MS = 2500    # this long without a key in the editor is a pause: held toasts come


struct Notice(Copyable, Movable):
    var level: Int
    var title: String
    var text: String
    var at_ns: Int
    var clock: String       # the time it came, as shown in the centre
    var shown: Bool         # still a toast (not dismissed)
    var own: Bool           # about a job the user started (a build, tests, a task, a commit)
    var held: Bool          # came while the user was typing: its toast waits for a pause

    def __init__(out self, level: Int, title: String, text: String, at_ns: Int, clock: String):
        self.level = level
        self.title = title
        self.text = text
        self.at_ns = at_ns
        self.clock = clock
        self.shown = True
        self.own = False
        self.held = False

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
        self.add_held(level, title, text, now, clock, False, False)

    def add_held(mut self, level: Int, title: String, text: String, now: Int, clock: String, own: Bool, hold: Bool):
        """A notice. `own`: about the user's own job - its toast comes at once (the job
        ending is a moment the user waits for) and before the others. `hold`: the user
        is typing - the toast waits until `release`."""
        # the same message again soon after: the toast is shown anew, not twice
        var n = len(self.notices)
        if n > 0 and self.notices[n - 1].title == title and self.notices[n - 1].text == text and now - self.notices[n - 1].at_ns < TOAST_MS * 1000000:
            self.notices[n - 1].at_ns = now
            self.notices[n - 1].shown = True
            self.notices[n - 1].held = hold and not own
            return
        var note = Notice(level, title, text, now, clock)
        note.own = own
        note.held = hold and not own
        self.notices.append(note^)
        self.unread += 1
        if len(self.notices) > NOTICES_KEPT:
            _ = self.notices.pop(0)

    def toasts(self, now: Int) -> List[Int]:
        """The notices to show as toasts now (indices): the user's own jobs first, then
        the others, newest first in each; none that is held."""
        var out = List[Int]()
        for own in [True, False]:
            var k = len(self.notices) - 1
            while k >= 0 and len(out) < TOASTS_SHOWN:
                ref n = self.notices[k]
                if n.own == own and n.shown and not n.held and now < n.until_ns():
                    out.append(k)
                k -= 1
        return out^

    def held_count(self) -> Int:
        var c = 0
        for n in self.notices:
            if n.held and n.shown:
                c += 1
        return c

    def release(mut self, now: Int) -> List[Int]:
        """A pause: the held toasts come now (their time starts now). Returns them."""
        var out = List[Int]()
        for k in range(len(self.notices)):
            if self.notices[k].held:
                self.notices[k].held = False
                if self.notices[k].shown:
                    self.notices[k].at_ns = now
                    out.append(k)
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
