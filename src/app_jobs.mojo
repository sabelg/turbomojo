"""Compiler integration: background build/format jobs, messages, run."""
from std.collections import List, Dict
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
from buffer import TextBuffer, Pos
from window import Window, WK_EDITOR, WK_MESSAGE, ACT_OTHER, ACT_TYPE
from window_search import *
from window_multi import *
from window_draw import *
from menu import *
from commands import *
from dialog import *
from util import *
from appstate import *
from app_lsp import *
from lsp import *
from app_watch import *
from watch import *
from app_swap import *
from swap import *
from app_files import *
from app_dialogs import *
from app_menus import *
from app_exec import *
from app_pickers import *
from app_input import *
from app_mouse import *
from app_draw import *


__extension App:
    # ======================================================= compile & run
    def ensure_saved(mut self, i: Int) raises -> Bool:
        if self.wins[i].path.byte_length() == 0:
            self.saveas_dialog(i, NEXT_NONE)
            self.say("Save the file first")
            return False
        if self.wins[i].buf.modified:
            return self.save_window(i, NEXT_NONE)
        return True

    def parse_loc(self, line: List[Int]) -> ErrLoc:
        """Find `path:row:col:` at the start of a compiler message line."""
        var n = len(line)
        for i in range(1, n):
            if line[i] != 58:
                continue
            var j = i + 1
            var row = 0
            while j < n and is_digit(line[j]):
                row = row * 10 + line[j] - 48
                j += 1
            if j == i + 1 or j >= n or line[j] != 58:
                continue
            var k = j + 1
            var col = 0
            while k < n and is_digit(line[k]):
                col = col * 10 + line[k] - 48
                k += 1
            if k == j + 1 or k >= n or line[k] != 58:
                continue
            return ErrLoc(slice_str(line, 0, i), row, col, -1)
        return ErrLoc("", -1, -1, -1)

    def fill_messages(mut self, header: String, data: List[UInt8], footer: String) -> Tuple[Int, Int]:
        var mi = self.ensure_msg()
        var all = decode_list(data)
        var text = decode(header)
        text.append(10)
        var cur = List[Int]()
        var lines = List[List[Int]]()
        for c in all:
            if c == 10:
                lines.append(strip_ansi(cur))
                cur = List[Int]()
            else:
                cur.append(c)
        if len(cur) > 0:
            lines.append(strip_ansi(cur))
        self.errs.clear()
        self.err_idx = -1
        self.errs_from_search = False
        var errors = 0
        var warnings = 0
        var row = 1
        for l in lines:
            var s = to_str(l)
            var is_err = str_contains(s, "error:") and not s.startswith("mojo: ")
            var is_warn = str_contains(s, "warning:")
            if is_err:
                errors += 1
            if is_warn:
                warnings += 1
            if is_err or is_warn:
                var loc = self.parse_loc(l)
                if loc.row > 0:
                    loc.msg_line = row
                    loc.path = abs_path(self.cwd, loc.path)
                    self.errs.append(loc^)
            for c in l:
                text.append(c)
            text.append(10)
            row += 1
        for c in decode(footer):
            text.append(c)
        self.wins[mi].buf.load(text)
        self.wins[mi].cr = 0
        self.wins[mi].top = 0
        self.wins[mi].follow = True
        return (errors, warnings)

    # -------------------------------------------------- background jobs
    def start_job(mut self, kind: Int, cmd: String, path: String, exe: String) -> Bool:
        """Start `cmd` through popen with a non-blocking pipe; the main loop polls it."""
        self.fsearch.cancel()           # the Message window is about to show this job
        var c = "echo __PID__$$ && " + cmd
        var fp = popen_read(c)
        if fp == 0:
            self.info("Error", "Could not start: " + cmd)
            return False
        var fd = Int(external_call["fileno", Int32](fp))
        var fl = external_call["fcntl", Int32](Int32(fd), Int32(3), Int32(0))
        _ = external_call["fcntl", Int32](Int32(fd), Int32(4), fl | Int32(2048))  # O_NONBLOCK
        self.job.active = True
        self.job.kind = kind
        self.job.fp = fp
        self.job.fd = fd
        self.job.pid = 0
        self.job.data.clear()
        self.job.t0 = Int(perf_counter_ns())
        self.job.path = path
        self.job.exe = exe
        self.job.cancelled = False
        var i = self.find_editor(path)
        self.job.version = self.wins[i].buf.version if i >= 0 else -1
        return True

    def find_editor(self, path: String) -> Int:
        for i in range(len(self.wins)):
            if self.wins[i].kind == WK_EDITOR and self.wins[i].path == path:
                return i
        return -1

    def job_busy(mut self) -> Bool:
        if self.job.active:
            self.say("Compiler is busy - Ctrl-F2 cancels it")
            return True
        return False

    # -------------------------------------------------- find in files
    def start_file_search(mut self, s: Search):
        """Search the project folder in the background; hits go to the Message window."""
        if self.job_busy():
            return
        self.fsearch.start(self.cwd, s)
        self.fsearch_shown = -1
        self.fsearch_draw_ns = 0
        self.show_search_results()

    def search_title(self) -> String:
        var what = "/" + to_str(self.fsearch.s.pat) + "/" if self.fsearch.s.use_regex else "\"" + to_str(self.fsearch.s.pat) + "\""
        return what + " in " + self.fsearch.root

    def show_search_results(mut self):
        """Put the hits found so far into the Message window, one per line as
        path:line:column: text, and make each of them a place Enter jumps to."""
        var mi = self.ensure_msg()
        var keep_cr = self.wins[mi].cr
        var keep_top = self.wins[mi].top
        var first = self.fsearch_shown < 0
        var running = self.fsearch.active
        var text = decode(("Searching for " if running else "Search for ") + self.search_title() + (" ..." if running else ""))
        text.append(10)
        self.errs.clear()
        self.errs_from_search = True
        var prefix = self.fsearch.root + "/"
        var row = 1
        for i in range(len(self.fsearch.hits)):
            var shown = self.fsearch.hits[i].path
            if shown.startswith(prefix):
                shown = slice_str(decode(shown), cp_len(prefix), cp_len(shown))
            var line = shown + ":" + String(self.fsearch.hits[i].row) + ":" + String(self.fsearch.hits[i].col) + ": " + self.fsearch.hits[i].text
            for c in decode(line):
                text.append(c)
            text.append(10)
            self.errs.append(ErrLoc(self.fsearch.hits[i].path, self.fsearch.hits[i].row, self.fsearch.hits[i].col, row))
            row += 1
        for c in decode(self.fsearch.summary() + (" so far" if running else "")):
            text.append(c)
        self.wins[mi].buf.load(text)
        self.fsearch_shown = len(self.fsearch.hits)
        if first:
            self.err_idx = -1
            self.wins[mi].cr = 0
            self.wins[mi].top = 0
        else:
            self.wins[mi].cr = keep_cr
            self.wins[mi].top = keep_top
            self.wins[mi].clamp()

    def fsearch_tick(mut self, now: Int):
        """One slice of the running file search; called on every pass of the event loop."""
        if not self.fsearch.active:
            return
        self.fsearch.step(FSEARCH_SLICE_MS)
        if self.fsearch.active:
            if len(self.fsearch.hits) != self.fsearch_shown and now - self.fsearch_draw_ns > FSEARCH_REDRAW_MS * 1000000:
                self.fsearch_draw_ns = now
                self.show_search_results()
            return
        self.finish_file_search()

    def finish_file_search(mut self):
        self.show_search_results()
        var mi = self.msg_index()
        if len(self.fsearch.hits) > 0 and mi >= 0:
            # put the cursor on the first hit, ready for Enter
            if self.wins[mi].cr == 0:
                self.wins[mi].cr = 1
            self.wins[mi].follow = True
            if self.mode == M_NORMAL:
                self.focus(mi)
        self.say(self.fsearch.summary())

    def cancel_job(mut self):
        if self.fsearch.active:
            self.fsearch.cancel()
            self.finish_file_search()
            return
        if not self.job.active:
            self.say("Nothing to cancel")
            return
        if self.job.pid > 0:
            _ = external_call["kill", Int32](Int32(self.job.pid), Int32(15))
        self.job.cancelled = True
        self.say("Cancelling...")

    def job_elapsed(self) -> Float64:
        return Float64(Int(perf_counter_ns()) - self.job.t0) / 1e9

    def job_header(self) -> String:
        if self.job.kind == JOB_BUILD:
            return "Building " + self.job.path + " ..."
        return "Formatting " + self.job.path + " ..."

    def poll_job(mut self) raises:
        if not self.job.active:
            return
        var buf = List[UInt8](length=16384, fill=0)
        var got = False
        var eof = False
        for _ in range(64):
            var n = external_call["read", Int](Int32(self.job.fd), buf.unsafe_ptr(), Int(16384))
            if n > 0:
                for k in range(n):
                    self.job.data.append(buf[k])
                got = True
            else:
                eof = n == 0
                break
        if self.job.pid == 0 and len(self.job.data) >= 8 and self.job.data[0] == 95:
            var nl = -1
            for k in range(len(self.job.data)):
                if self.job.data[k] == 10:
                    nl = k
                    break
            if nl > 0:
                var digits = List[UInt8]()
                for k in range(7, nl):
                    digits.append(self.job.data[k])
                try:
                    self.job.pid = atol(bytes_to_str(digits))
                except:
                    self.job.pid = -1
                var rest = List[UInt8]()
                for k in range(nl + 1, len(self.job.data)):
                    rest.append(self.job.data[k])
                self.job.data = rest^
        if got and self.job.kind == JOB_BUILD and self.job.pid != 0:
            _ = self.fill_messages(self.job_header(), self.job.data.copy(), "Compiling...")
        if eof:
            self.finish_job()

    def finish_job(mut self) raises:
        var st = Int(external_call["pclose", Int32](self.job.fp))
        self.job.active = False
        var secs = self.job_elapsed()
        if self.job.kind == JOB_BUILD:
            self.finish_build(st, secs)
        else:
            self.finish_format(st)

    def build(mut self) raises:
        if self.job_busy():
            return
        var i = self.top_editor()
        if i < 0:
            self.info("Compile", "No file to compile.")
            return
        if not self.ensure_saved(i):
            return
        var path = self.wins[i].path
        var dir = dirname(path)
        var exe = join_path(dir, "build/" + stem(path))
        var cmd = "cd " + shell_quote(dir) + " && mkdir -p build && exec " + self.compiler_cmd() + " build " + shell_quote(path) + " -o " + shell_quote(exe) + " 2>&1"
        if self.start_job(JOB_BUILD, cmd, path, exe):
            _ = self.fill_messages(self.job_header(), List[UInt8](), "Compiling...")
            self.say("Building " + basename(path) + " - keep editing, Ctrl-F2 cancels")

    def finish_build(mut self, status: Int, secs: Float64) raises:
        var path = self.job.path
        var name = basename(path)
        var ok = status == 0 and not self.job.cancelled
        var footer: String
        if self.job.cancelled:
            footer = "Build cancelled"
        elif ok:
            footer = "Build succeeded: " + self.job.exe
        else:
            footer = "Build failed (exit " + String(status >> 8) + ")"
        var counts = self.fill_messages(self.job_header(), self.job.data.copy(), footer)
        var ei = self.find_editor(path)
        var nlines = self.wins[ei].buf.count() if ei >= 0 else 0
        var tstr = String(Int(secs * 10) // 10) + "." + String(Int(secs * 10) % 10) + " s"
        if self.job.cancelled:
            self.say("Build cancelled after " + tstr)
            return
        if self.mode == M_NORMAL:
            var d = Dialog(D_RESULT, "Compiling", 52, 13)
            d.lines.append("Main file:  " + name)
            d.lines.append("Output:     build/" + stem(path))
            d.lines.append("")
            d.lines.append("     Lines:  " + String(nlines))
            d.lines.append("  Warnings:  " + String(counts[1]))
            d.lines.append("    Errors:  " + String(counts[0]))
            d.lines.append("      Time:  " + tstr)
            d.lines.append("")
            if ok:
                d.lines.append("  ~Success~       :  Press any key")
            else:
                d.lines.append("  ~Errors~        :  Press any key")
            self.show(d^)
        else:
            self.say(("Build succeeded" if ok else "Build failed: " + String(counts[0]) + " error(s)") + " in " + tstr)
        if not ok or counts[1] > 0:
            var mi = self.msg_index()
            if self.mode == M_NORMAL or self.mode == M_DIALOG:
                self.focus(mi)
            mi = self.msg_index()
            if len(self.errs) > 0:
                self.err_idx = 0
                self.wins[mi].cr = self.errs[0].msg_line
                self.wins[mi].follow = True

    def goto_error(mut self, d: Int) raises:
        if len(self.errs) == 0:
            self.say("No compiler messages")
            return
        self.err_idx = (self.err_idx + d + len(self.errs)) % len(self.errs)
        self.jump_to_error(self.err_idx)

    def jump_to_error(mut self, j: Int) raises:
        var e = self.errs[j].copy()
        var mi = self.msg_index()
        if mi >= 0:
            self.wins[mi].cr = e.msg_line
            self.wins[mi].follow = True
        if e.path.byte_length() > 0 and path_exists(e.path):
            self.open_path(e.path)
            var t = self.top()
            self.wins[t].goto(e.row - 1, max(0, e.col - 1))
            if self.errs_from_search and self.fsearch.s.ok:
                # show the match itself, and the other matches in this file
                self.wins[t].set_highlight(self.fsearch.s)
                _ = self.wins[t].search_from(self.fsearch.s, e.row - 1, max(0, e.col - 1))
                self.find_text = self.fsearch.s.pat.copy()      # Ctrl+L continues in this file
            mi = self.msg_index()
            if mi >= 0 and e.msg_line < self.wins[mi].buf.count():
                self.say(to_str(self.wins[mi].buf.line(e.msg_line)))

    def format_file(mut self) raises:
        if self.job_busy():
            return
        var i = self.top_editor()
        if i < 0 or not self.ensure_saved(i):
            return
        var path = self.wins[i].path
        var cmd = "cd " + shell_quote(dirname(path)) + " && exec " + self.compiler_cmd() + " format -q " + shell_quote(path) + " 2>&1"
        if self.start_job(JOB_FORMAT, cmd, path, ""):
            self.say("Formatting " + basename(path) + "...")

    def finish_format(mut self, status: Int) raises:
        var path = self.job.path
        if self.job.cancelled:
            self.say("Format cancelled")
            return
        if status != 0:
            _ = self.fill_messages(self.job_header(), self.job.data.copy(), "Format failed")
            self.say("mojo format failed - see the Message window")
            return
        var i = self.find_editor(path)
        if i < 0:
            self.say("Formatted " + basename(path))
            return
        if self.wins[i].buf.version != self.job.version:
            self.say("Edited while formatting - buffer not reloaded (file on disk is formatted)")
            return
        var txt: String
        with open(path, "r") as f:
            txt = f.read()
        var cr = self.wins[i].cr
        var cc = self.wins[i].cc
        var tmp = TextBuffer()
        tmp.load(decode(txt))
        self.wins[i].replace_all_text(tmp.all_text())
        self.wins[i].cr = cr
        self.wins[i].cc = cc
        self.wins[i].clamp()
        self.wins[i].buf.modified = False
        self.note_disk_state(i)
        self.say("Formatted " + basename(path))

    def run_program(mut self, test: Bool) raises:
        if self.job_busy():
            return
        var i = self.top_editor()
        if i < 0:
            return
        if not self.ensure_saved(i):
            return
        var path = self.wins[i].path
        if test and not str_contains(to_str(self.wins[i].buf.all_text()), "TestSuite"):
            # `mojo test` was removed from Mojo; tests are programs that run a TestSuite
            self.info("Test", "No TestSuite here. Add: TestSuite.discover_tests[__functions_in_module()]().run()")
            return
        var sub = " run "
        var cmd = (
            "cd " + shell_quote(dirname(path)) + " && clear && printf '\\033[1m$ mojo" + sub + "%s\\033[0m\\n' " + shell_quote(basename(path))
            + " && " + self.compiler_cmd() + sub + shell_quote(path) + " " + self.run_args
            + "; printf '\\n\\033[7m Program exited with status %d - press any key to return to TurboMojo \\033[0m' $?"
        )
        self.term.leave()
        _ = run_system(cmd)
        self.term.raw()
        self.term.wait_byte()
        self.term.enter()
        self.scr.force = True
