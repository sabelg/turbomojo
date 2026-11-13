"""The integrated terminal: a shell (Window > Terminal) and the program Run starts, each
in a window of its own at the bottom, on a pty with libghostty-vt keeping the screen."""
from std.collections import List, Dict
from marks import marked_run, marks_wanted
from std.time import perf_counter_ns
from std.ffi import external_call
from term import (
    Terminal, Event, EV_KEY, EV_MOUSE, EV_PASTE, K_BASE, KEY_ESC, KEY_ENTER, KEY_TAB,
    KEY_BACKSPACE, KEY_UP, KEY_DOWN, KEY_LEFT, KEY_RIGHT, KEY_HOME, KEY_END, KEY_PGUP,
    KEY_PGDN, KEY_INSERT, KEY_DELETE, MOD_SHIFT, MOD_ALT, MOD_CTRL, KEY_MASK, fkey, ctrl, alt,
    MB_LEFT, MB_WHEEL_UP, MB_WHEEL_DOWN,
)
from screen import Screen
from palette import Palette, theme, THEME_COUNT
from highlight import Highlighter
from buffer import TextBuffer, Pos, ENC_UTF8, ENC_LATIN1
from window import Window, WK_EDITOR, WK_MESSAGE, WK_OUTLINE, WK_EXPLORER, ACT_OTHER, ACT_TYPE
from window_search import *
from window_multi import *
from window_lines import *
from window_draw import *
from menu import *
from commands import *
from dialog import *
from util import *
from appstate import *
from app_lsp import *
from lsp import *
from markdown import *
from app_watch import *
from watch import *
from app_swap import *
from swap import *
from app_files import *
from app_dialogs import *
from app_menus import *
from app_exec import *
from app_jobs import *
from app_pickers import *
from app_nav import *
from app_outline import *
from layout import *
from app_layout import *
from explorer import *
from app_explorer import *
from doclib import *
from stdref import *
from docfetch import FETCH_SCRIPT
from outline import *
from symindex import *
from docs import *
from watch import file_sig
from app_input import *
from app_mouse import *
from app_draw import *
from app_docs import *
from dap import *
from breakpoints import *
from dbgview import *
from json import json_quote
from window import WK_DEBUG, WK_CPU
from cpuview import *
from app_debug import *
from termsession import *
from vt import *
from pty import Pty, exit_code
from termkeys import encode_key, paste_bytes
from window import WK_TERM
from palette import Palette
from term import Event, MB_LEFT, MB_WHEEL_UP, MB_WHEEL_DOWN, KEY_MASK


__extension App:
    # ========================================================= the terminal
    def term_kind_of(self, i: Int) -> Int:
        """Which session window i shows (its path names it)."""
        if self.wins[i].path == "terminal:run":
            return TS_RUN
        if self.wins[i].path == "terminal:repl":
            return TS_REPL
        return TS_SHELL

    def term_index(self, which: Int) -> Int:
        for i in range(len(self.wins)):
            if self.wins[i].kind == WK_TERM and self.term_kind_of(i) == which:
                return i
        return -1

    def term_open_window(mut self, which: Int) -> Int:
        """The terminal window of a session: at the bottom, in front, made if needed."""
        var ti = self.term_index(which)
        if ti >= 0:
            self.focus(ti)
            return self.top()
        var dh = self.desk_h()
        var h = max(8, min(dh - 4, dh * 2 // 5))
        var y = 1 + dh - h
        var names = ["Terminal", "Run", "REPL"]
        var paths = ["terminal:shell", "terminal:run", "terminal:repl"]
        var win = Window(WK_TERM, String(names[which]), String(paths[which]), 0, y, self.scr.w, h, self.free_number())
        win.gut = 0
        for i in range(len(self.wins)):
            if self.wins[i].kind == WK_EDITOR and self.wins[i].y + self.wins[i].h > y and y - self.wins[i].y >= 6:
                self.wins[i].h = y - self.wins[i].y
                if self.wins[i].zoomed:
                    self.wins[i].sh = self.wins[i].h
        self.wins.append(win^)
        return self.top()

    def term_start(mut self, which: Int, argv: List[String], cwd: String, title: String) -> Bool:
        """Start a program in a session's window (a session's earlier program must have
        ended: see term_session_busy)."""
        var i = self.term_open_window(which)
        var cols = max(10, self.wins[i].w - 2)
        var rows = max(2, self.wins[i].h - 2)
        var s = TermSession()
        var ok = s.vt.open(cols, rows) and s.pty.start(argv, cwd, List[String](), rows, cols)
        s.started = ok
        s.title = title
        s.pty_argv = argv.copy()
        s.pty_cwd = cwd
        var old = self.term_take(which)
        _ = old.pty.stop()
        self.term_put(which, s^)
        self.wins[i].title = title
        if not ok:
            self.say("The terminal could not be started")
        return ok

    def term_session_busy(self, which: Int) -> Bool:
        if which == TS_RUN:
            return self.trun.started and self.trun.pty.running
        if which == TS_REPL:
            return self.trepl.started and self.trepl.pty.running
        return self.tshell.started and self.tshell.pty.running

    def term_toggle(mut self):
        """Window > Terminal (Alt-F11): a shell in a window at the bottom; again to
        close the window (the shell goes on and is there when it is opened again)."""
        var ti = self.term_index(TS_SHELL)
        if ti >= 0 and ti == self.top():
            self.term_close_window(ti)
            return
        if ti >= 0:
            self.focus(ti)
            return
        _ = self.term_open_window(TS_SHELL)
        if not self.term_session_busy(TS_SHELL):
            var sh = self.shell_program
            if sh.byte_length() == 0 or not path_exists(sh):
                sh = "/bin/sh"
            var argv = List[String]()
            argv.append(sh)
            var here = self.cwd
            _ = self.term_start(TS_SHELL, argv, here, "Terminal - " + basename(sh))
        self.say("Terminal: keys go to the program; F6 or Alt-F11 back to the editor, Shift-PgUp scrolls back, Ctrl-Shift-Up goes to the last run")

    def term_close_window(mut self, i: Int):
        var y = self.wins[i].y
        _ = self.wins.pop(i)
        for j in range(len(self.wins)):
            if self.wins[j].kind == WK_EDITOR and self.wins[j].y + self.wins[j].h == y:
                self.wins[j].h = 1 + self.desk_h() - self.wins[j].y

    def term_fds(self) -> List[Int]:
        var out = List[Int]()
        if self.tshell.started and self.tshell.pty.fd() >= 0:
            out.append(self.tshell.pty.fd())
        if self.trun.started and self.trun.pty.fd() >= 0:
            out.append(self.trun.pty.fd())
        if self.trepl.started and self.trepl.pty.fd() >= 0:
            out.append(self.trepl.pty.fd())
        return out^

    def term_tick(mut self):
        """Output of the terminals' programs into their emulators, the emulators'
        answers back to the programs, sizes kept in step, ends noticed."""
        var replies = vt_take_replies()
        for which in [TS_SHELL, TS_RUN, TS_REPL]:
            var s = self.term_take(which)
            var running = s.ended_note.byte_length() == 0
            self.term_pump(s, replies, self.term_index(which))
            var ended = which == TS_RUN and running and s.ended_note.byte_length() > 0
            var status = exit_code(s.pty.status)
            self.term_put(which, s^)
            if ended:
                self.run_report(status)

    def term_take(mut self, which: Int) -> TermSession:
        """A session taken out of the App to work on it (put it back with term_put)."""
        var s = TermSession()
        if which == TS_RUN:
            swap(s, self.trun)
        elif which == TS_REPL:
            swap(s, self.trepl)
        else:
            swap(s, self.tshell)
        return s^

    def term_put(mut self, which: Int, var s: TermSession):
        if which == TS_RUN:
            swap(s, self.trun)
        elif which == TS_REPL:
            swap(s, self.trepl)
        else:
            swap(s, self.tshell)

    def term_pump(mut self, mut s: TermSession, replies: List[VtReply], wi: Int):
        if not s.started:
            return
        if wi >= 0:
            var cols = max(10, self.wins[wi].w - 2)
            var rows = max(2, self.wins[wi].h - 2)
            if cols != s.vt.cols or rows != s.vt.rows:
                s.vt.resize(cols, rows)
                s.pty.resize(rows, cols)
                s.dirty = True
        for r in replies:
            if r.term == s.vt.term:
                s.pty.write(r.data)
        s.pty.flush()
        if s.pty.read_available() > 0:
            s.vt.write(s.pty.take())
            s.dirty = True
            s.last_output_ns = Int(perf_counter_ns())
        if len(s.pending) > 0:
            # code waiting for the REPL: it goes once the first prompt ("1> ") is shown
            # and the REPL has been quiet for half a second (what is typed during its
            # start-up is lost)
            if s.dirty:
                s.vt.update()
                s.dirty = False
            var last = String("")
            if s.vt.is_open() and s.vt.cursor_y < s.vt.rows:
                last = s.vt.row_text(s.vt.cursor_y)
            if last.endswith(">") and Int(perf_counter_ns()) - s.last_output_ns > 500000000:
                s.pty.write(s.pending)
                s.pending.clear()
        if s.ended_note.byte_length() == 0 and s.pty.eof and s.pty.poll_exit():
            s.ended_note = "[the program ended with status " + String(exit_code(s.pty.status)) + " - Enter starts it again, Esc closes]"
            s.vt.write_text("\r\n\x1b[7m" + s.ended_note + "\x1b[0m")
            s.dirty = True
            if wi >= 0 and s.title.find(" (ended)") < 0:
                s.title += " (ended)"
                self.wins[wi].title = s.title
        if s.dirty:
            s.vt.update()
            s.dirty = False

    def term_draw(mut self, i: Int):
        """The emulator's screen in window i."""
        var p = self.pal.copy()
        var which = self.term_kind_of(i)
        var s = self.term_take(which)
        self.term_paint(s, i, p)
        self.term_put(which, s^)

    def term_paint(mut self, mut s: TermSession, i: Int, p: Palette):
        var x0 = self.wins[i].x + 1
        var y0 = self.wins[i].y + 1
        var w = self.wins[i].w - 2
        var h = self.wins[i].h - 2
        var dfg = p.ed_fg
        var dbg = p.ed_bg
        self.scr.fill(x0, y0, w, h, 32, dfg, dbg)
        if not s.started or not s.vt.is_open():
            _ = self.scr.text(x0 + 1, y0, "(no program)", p.gutter_fg, dbg)
            return
        var vt = s.vt.cols
        var lo = min(s.sel_a, s.sel_b)
        var hi = max(s.sel_a, s.sel_b)
        for y in range(min(h, s.vt.rows)):
            for x in range(min(w, s.vt.cols)):
                var k = y * vt + x
                var c = s.vt.cp[k]
                if c == -1:
                    continue                    # the right half of a wide character
                var fl = s.vt.flags[k]
                var f = s.vt.fg[k]
                var b = s.vt.bg[k]
                var fr = dfg if f == -1 else (ansi_color(-2 - f) if f <= -2 else f)
                var br = dbg if b == -1 else (ansi_color(-2 - b) if b <= -2 else b)
                if fl & VF_BOLD != 0 and f <= -2 and -2 - f < 8:
                    fr = ansi_color(-2 - f + 8)     # bold palette colours are the bright ones
                if fl & VF_INVERSE != 0:
                    var t = fr
                    fr = br
                    br = t
                if s.sel_on and k >= lo and k <= hi:
                    fr = p.sel_fg
                    br = p.sel_bg
                if fl & VF_INVISIBLE != 0:
                    c = 32
                if k in s.vt.extra:
                    try:
                        var cps = s.vt.extra[k].copy()
                        self.scr.put_cluster(x0 + x, y0 + y, cps, 0, len(cps), 2 if x + 1 < s.vt.cols and s.vt.cp[k + 1] == -1 else 1, fr, br)
                    except:
                        self.scr.put(x0 + x, y0 + y, c if c > 0 else 32, fr, br)
                else:
                    self.scr.put(x0 + x, y0 + y, c if c > 0 else 32, fr, br)
                if fl & VF_UNDERLINE != 0:
                    self.scr.underline(x0 + x, y0 + y, False, fr)
        if not s.vt.at_bottom():
            var tag = " scrolled back - Shift-PgDn / typing returns "
            _ = self.scr.text(x0 + max(0, w - tag.byte_length()), y0, tag, p.status_fg, p.status_bg)
        elif i == self.top() and s.vt.cursor_shown and s.ended_note.byte_length() == 0 and self.mode == M_NORMAL:
            self.scr.cx = x0 + min(s.vt.cursor_x, w - 1)
            self.scr.cy = y0 + min(s.vt.cursor_y, h - 1)
            self.scr.cvis = True
            self.scr.cblock = True
        elif i == self.top() and s.ended_note.byte_length() == 0 and self.mode == M_NORMAL:
            # the program hides its cursor: it waits there, hidden
            self.scr.fx = x0 + min(s.vt.cursor_x, w - 1)
            self.scr.fy = y0 + min(s.vt.cursor_y, h - 1)

    def term_reserved(self, k: Int) -> Bool:
        """Keys the IDE keeps while a terminal has the keyboard."""
        if k == fkey(10) or k == fkey(6) or k == (fkey(6) | MOD_SHIFT) or k == (fkey(11) | MOD_ALT):
            return True
        if k == (KEY_PGUP | MOD_SHIFT) or k == (KEY_PGDN | MOD_SHIFT):
            return True
        if k == (KEY_UP | MOD_CTRL | MOD_SHIFT) or k == (KEY_DOWN | MOD_CTRL | MOD_SHIFT):
            return True                 # jump between runs (OSC 133 prompts)
        if k & MOD_ALT != 0 and (k & KEY_MASK) >= 48 and (k & KEY_MASK) <= 57 and k & MOD_CTRL == 0:
            return True                 # Alt-digit: windows by number
        return False

    def term_key(mut self, k: Int) -> Bool:
        """A key for the terminal in front; False if the IDE should handle it."""
        var t = self.top()
        if t < 0 or self.wins[t].kind != WK_TERM or self.term_reserved(k):
            if t >= 0 and self.wins[t].kind == WK_TERM and (k == (KEY_PGUP | MOD_SHIFT) or k == (KEY_PGDN | MOD_SHIFT)):
                self.term_scroll(self.term_kind_of(t), -max(1, self.wins[t].h - 3) if k == (KEY_PGUP | MOD_SHIFT) else max(1, self.wins[t].h - 3))
                return True
            if t >= 0 and self.wins[t].kind == WK_TERM and (k == (KEY_UP | MOD_CTRL | MOD_SHIFT) or k == (KEY_DOWN | MOD_CTRL | MOD_SHIFT)):
                self.term_jump_prompt(self.term_kind_of(t), -1 if k == (KEY_UP | MOD_CTRL | MOD_SHIFT) else 1)
                return True
            return False
        var which = self.term_kind_of(t)
        var s = self.term_take(which)
        if s.ended_note.byte_length() > 0:
            # the program has ended: Enter starts it again, Esc closes the window
            var argv = s.pty_argv.copy()
            var cwd = s.pty_cwd
            var title = String(s.title.replace(" (ended)", ""))
            self.term_put(which, s^)
            if k == KEY_ENTER:
                _ = self.term_start(which, argv, cwd, title)
            elif k == KEY_ESC:
                self.term_close_window(self.top())
            return True
        self.term_send_key(s, k)
        self.term_put(which, s^)
        return True

    def term_send_key(mut self, mut s: TermSession, k: Int):
        if not s.vt.at_bottom():
            s.vt.scroll_view(SCROLL_BOTTOM, 0)
            s.dirty = True
        s.sel_on = False
        var bytes = encode_key(k, s.vt.mode(MODE_CURSOR_KEYS))
        if len(bytes) > 0:
            s.pty.write(bytes)

    def term_paste(mut self, text: List[Int]) -> Bool:
        var t = self.top()
        if t < 0 or self.wins[t].kind != WK_TERM:
            return False
        var which = self.term_kind_of(t)
        var s = self.term_take(which)
        s.pty.write(paste_bytes(text, s.vt.mode(MODE_BRACKETED_PASTE)))
        self.term_put(which, s^)
        return True

    def term_scroll(mut self, which: Int, rows: Int):
        var s = self.term_take(which)
        s.vt.scroll_view(SCROLL_DELTA, rows)
        s.vt.update()
        self.term_put(which, s^)

    def term_jump_prompt(mut self, which: Int, d: Int):
        """The view to the previous (d < 0) or next run: the prompts the program or the
        shell marked with OSC 133. Nothing marked: says so."""
        var s = self.term_take(which)
        s.vt.update()
        var before = s.vt.view_top()
        s.vt.scroll_view(SCROLL_PROMPT, d)
        s.vt.update()
        var moved = s.vt.view_top() != before
        s.dirty = True
        self.term_put(which, s^)
        if not moved:
            self.say("No " + ("earlier" if d < 0 else "later") + " run marked here (the shell or program sends OSC 133 marks for this)")

    def term_mouse(mut self, i: Int, e: Event) -> Bool:
        """Mouse in a terminal window: the wheel scrolls back; a drag selects, and the
        selection is copied when the button is let go."""
        var x = e.mx - self.wins[i].x - 1
        var y = e.my - self.wins[i].y - 1
        if x < 0 or y < 0 or x >= self.wins[i].w - 2 or y >= self.wins[i].h - 2:
            return False
        var which = self.term_kind_of(i)
        if e.button == MB_WHEEL_UP or e.button == MB_WHEEL_DOWN:
            self.term_scroll(which, -3 if e.button == MB_WHEEL_UP else 3)
            return True
        if e.button != MB_LEFT:
            return False
        self.focus(i)
        var s = self.term_take(which)
        self.term_select(s, x, y, e)
        self.term_put(which, s^)
        return True

    def term_select(mut self, mut s: TermSession, x: Int, y: Int, e: Event):
        if not s.vt.is_open():
            return
        var k = min(y, s.vt.rows - 1) * s.vt.cols + min(x, s.vt.cols - 1)
        if e.pressed and not e.drag:
            s.sel_on = False
            s.sel_a = k
            s.sel_b = k
            return
        if e.pressed and e.drag:
            s.sel_on = True
            s.sel_b = k
            return
        if not e.pressed and s.sel_on:
            s.sel_b = k
            var text = List[Int]()
            var lo = min(s.sel_a, s.sel_b)
            var hi = max(s.sel_a, s.sel_b)
            var line = List[Int]()
            for j in range(lo, hi + 1):
                var c = s.vt.cp[j]
                if c != -1:
                    line.append(c if c > 0 else 32)
                if (j + 1) % s.vt.cols == 0 or j == hi:
                    while len(line) > 0 and line[len(line) - 1] == 32:
                        _ = line.pop()
                    for c2 in line:
                        text.append(c2)
                    line.clear()
                    if j != hi:
                        text.append(10)
            self.clipboard = text.copy()
            self.osc52(text^)
            self.say("Copied from the terminal")

    def run_in_window(mut self, label: String, core: String):
        """Run (Ctrl-F9) without leaving the IDE: the program in the Run window, where it
        can be typed to; a program still running there from the last Run is ended first."""
        if self.term_session_busy(TS_RUN):
            _ = self.trun.pty.stop()
            self.say("The program of the last Run was still running - it was ended")
        var argv = List[String]()
        argv.append("/bin/sh")
        argv.append("-c")
        # (the marks always: the window's own terminal reads them - Ctrl-Shift-Up/Down)
        argv.append(marked_run(label, core, True, "\\r\\n") + "; exit $st")
        var here = self.cwd
        _ = self.term_start(TS_RUN, argv, here, "Run - " + label)

    # ============================================================== the REPL
    def repl_command(mut self) -> List[String]:
        var argv = List[String]()
        argv.append("/bin/sh")
        argv.append("-c")
        # LLDB's status line (it runs the REPL) redraws the last row with a scroll region
        # and mixes into the output: it is switched off
        argv.append("exec " + self.tool(self.compiler_cmd()) + " repl" + self.include_flags() + " -O 'settings set show-statusline false'")
        return argv^

    def repl_open(mut self):
        """Run > Mojo REPL: `mojo repl` in a window at the bottom (started once; again
        brings its window to the front, or closes it when it is in front)."""
        var ri = self.term_index(TS_REPL)
        if ri >= 0 and ri == self.top():
            self.term_close_window(ri)
            return
        if ri >= 0:
            self.focus(ri)
            return
        _ = self.term_open_window(TS_REPL)
        if not self.term_session_busy(TS_REPL):
            var argv = self.repl_command()
            var here = self.cwd
            _ = self.term_start(TS_REPL, argv, here, "REPL - mojo repl")
        self.say("Mojo REPL: an expression ends with a blank line; " + self.reg.key_label(CM_REPL_SEND) + " in the editor sends the selection")

    def repl_send(mut self) raises:
        """Send the selection (or the cursor's line) to the REPL, ended by a blank line
        so that it is evaluated; the keyboard stays in the editor."""
        var i = self.top_editor()
        if i < 0:
            return
        var text: List[Int]
        if self.wins[i].sel:
            text = self.wins[i].selected_text()
        else:
            text = self.wins[i].buf.line(self.wins[i].cr)
            # the next line, so that F-key presses walk through a file line by line
            if self.wins[i].cr + 1 < self.wins[i].buf.count():
                self.wins[i].goto(self.wins[i].cr + 1, 0)
        var started = False
        if not self.term_session_busy(TS_REPL):
            var argv = self.repl_command()
            var here = self.cwd
            if not self.term_start(TS_REPL, argv, here, "REPL - mojo repl"):
                return
            started = True
        elif self.term_index(TS_REPL) < 0:
            _ = self.term_open_window(TS_REPL)
        var ed = self.top_editor()
        if ed >= 0:
            self.focus(ed)
        # what is sent waits for the REPL's prompt: while it starts (a few seconds) and
        # while it is still printing, input is lost - also the blank line that ends an
        # expression
        for b2 in repl_bytes(text):
            self.trepl.pending.append(b2)
        if started or self.trepl.last_output_ns == 0:
            self.say("The REPL is starting - the code goes to it when it is ready")
        else:
            self.say("Sent to the REPL")
