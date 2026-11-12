"""Toasts and the notification centre (src/notify.mojo).

`notify` is called where something finishes or needs you: builds, test runs, pixi
tasks, git commits and branch switches, the agent (its turn ends, or it waits for an
answer while the panel is not in front), the language server failing, documentation
downloads. Toasts stand at the top right for a few seconds (errors longer); a click
takes one away. Help > Notifications (Shift-F10) lists what is running now (made from
the IDE's state, so nothing has to be registered) and the notices of this session.
"""
from glyphs import GLYPHS_NERD
from std.collections import List
from appstate import *
from util import *
from dialog import *
from notify import *
from helpbook import TURBOMOJO_VERSION
from acp import AS_STARTING, AS_OPENING
from lsp import LSP_STARTING
from app_jobs import *
from app_dialogs import *


__extension App:
    def notify(mut self, level: Int, title: String, text: String, own: Bool = False):
        """A notice. `own`: about a job the user started - it comes at once, first, and
        brings any held ones with it. Others that come while the user is typing are
        held until a pause (a save, the debugger stopping, a few seconds without keys)."""
        var now = now_ns()
        var hold = not own and self.typing(now)
        self.notes.add_held(level, title, text, now, clock_hm(), own, hold)
        if own:
            self.notes_release(now)
        if self.reader and not hold:
            # no toast for a screen reader: the status line, which it reads
            self.say(title + ((": " + text) if text.byte_length() > 0 else String("")))

    def typing(self, now: Int) -> Bool:
        return self.typed_ns > 0 and now - self.typed_ns < TYPING_PAUSE_MS * 1000000

    def waited_for_job(self) -> Bool:
        """No key went to an editor since the build or task began: the user is waiting
        for it, and its result box and the Message window may come up. Someone who went
        on typing gets the toast only (the box's "press any key" would take a key)."""
        return self.typed_ns <= self.job.t0

    def may_take_focus(self, owner: Int) -> Bool:
        """Calm by default: something that happens in the background (the agent asks,
        a plugin opens a panel) brings a window to the front only when the user already
        works with `owner` (it is in front) and is not typing; otherwise it is a notice,
        which says the key to go there. A key meant for one window never lands in
        another that came up under the fingers (the agent panel's Y allows a command)."""
        return owner >= 0 and self.top() == owner and not self.typing(now_ns())

    def notes_release(mut self, now: Int):
        """A moment to look up: the held toasts come."""
        var got = self.notes.release(now)
        if self.reader and len(got) > 0:
            ref n = self.notes.notices[got[len(got) - 1]]
            self.say(n.title + ((": " + n.text) if n.text.byte_length() > 0 else String("")) + ((" (and " + String(len(got) - 1) + " more: Shift-F10)") if len(got) > 1 else String("")))

    def notes_tick(mut self, now: Int):
        if self.notes.held_count() > 0 and not self.typing(now):
            self.notes_release(now)

    def running_tasks(self) -> List[String]:
        """What is going on in the background now, one line each."""
        var out = List[String]()
        var now = Int(now_ns())
        if self.job.active:
            out.append(self.job_header() + "  (" + String((now - self.job.t0) // 1000000000) + " s)")
        if self.git_proc.running and self.git_req >= 5:       # commit, branches, switch, blame
            out.append("git: " + ["", "", "", "", "", "commit", "listing branches", "switching branch", "blame"][self.git_req])
        if self.lsp.active() and self.lsp.state == LSP_STARTING:
            out.append("Starting the language server")
        if self.agent.busy():
            out.append((self.agent.agent_name if self.agent.agent_name.byte_length() > 0 else String("The agent")) + " is working")
        elif self.agent.state == AS_STARTING or self.agent.state == AS_OPENING:
            out.append("Starting the agent")
        for t in self.agent_terms:
            if not t.done:
                out.append("Agent command: " + t.title)
        if self.symidx.building:
            out.append("Indexing the project's symbols")
        if self.fsearch.active:
            out.append("Searching the project")
        if self.trun.started and self.trun.pty.running:
            out.append("Program running in the terminal")
        return out^

    def draw_toasts(mut self):
        var p = self.pal.copy()
        self.toast_rows.clear()
        self.toast_y0.clear()
        self.toast_y1.clear()
        var y = 1
        var w = min(52, self.scr.w - 4)
        if w < 20:
            return
        var x = self.scr.w - w - 1
        for k in self.notes.toasts(now_ns()):
            var n = self.notes.notices[k].copy()
            var lines = List[String]()
            lines.append(level_mark(n.level, self.scr.glyphs == GLYPHS_NERD) + " " + n.title)
            if n.text.byte_length() > 0:
                var wrapped = wrap_plain(n.text, w - 4)
                for q in range(min(2, len(wrapped))):
                    lines.append("  " + wrapped[q])
            var h = len(lines) + 2
            if y + h > self.scr.h - 1:
                break
            var edge = p.frame_act
            if n.level == NL_ERROR:
                edge = p.diag_err
            elif n.level == NL_WARN:
                edge = p.diag_warn
            elif n.level == NL_DONE:
                edge = p.msg_ok
            self.scr.fill(x, y, w, h, 32, p.dlg_fg, p.dlg_bg)
            self.scr.frame(x, y, w, h, False, edge, p.dlg_bg)
            for r in range(len(lines)):
                self.scr.clip(x + 1, y + 1 + r, w - 2, 1)
                _ = self.scr.text(x + 2, y + 1 + r, lines[r], edge if r == 0 else p.dlg_fg, p.dlg_bg)
                self.scr.no_clip()
            self.toast_rows.append(k)
            self.toast_y0.append(y)
            self.toast_y1.append(y + h)
            y += h
        self.toast_x = x

    def toast_click(mut self, mx: Int, my: Int) -> Bool:
        """A click on a toast takes it away."""
        if mx < self.toast_x:
            return False
        for k in range(len(self.toast_rows)):
            if my >= self.toast_y0[k] and my < self.toast_y1[k]:
                self.notes.dismiss(self.toast_rows[k])
                return True
        return False

    def notices_dialog(mut self):
        var items = List[String]()
        var data = List[Int]()
        var run = self.running_tasks()
        for r in run:
            items.append("⟳ " + r)
            data.append(-1)
        if len(run) == 0:
            items.append("  (nothing is running)")
            data.append(-1)
        var k = len(self.notes.notices) - 1
        while k >= 0:
            var n = self.notes.notices[k].copy()
            items.append(n.clock + " " + level_mark(n.level, self.scr.glyphs == GLYPHS_NERD) + " " + n.title + ((" - " + n.text) if n.text.byte_length() > 0 else String("")))
            data.append(k)
            k -= 1
        var d = Dialog(D_NOTICES, "Notifications", min(78, self.scr.w - 4), min(self.scr.h - 2, max(10, len(items) + 7)))
        d.has_list = True
        d.set_items(items^, data^)
        d.lines.append(String(len(run)) + " running, " + String(len(self.notes.notices)) + " notifications this session")
        d.buttons.append("~C~lose")
        d.buttons.append("Clear ~a~ll")
        self.notes.unread = 0
        self.notes.dismiss_all()
        self.show(d^)

    def whats_new_check(mut self, seen_file: String):
        """After an upgrade, once: a notice that Help > What's new tells what changed."""
        var seen = String(read_text(seen_file).strip())
        if seen == TURBOMOJO_VERSION:
            return
        if seen.byte_length() > 0:
            self.notify(NL_INFO, "TurboMojo " + TURBOMOJO_VERSION, "What changed: Help > What's new")
        _ = write_file(seen_file, str_bytes(TURBOMOJO_VERSION + "\n"))
