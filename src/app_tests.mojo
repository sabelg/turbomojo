"""The test explorer: the project's TestSuite files and their tests, run by file or
one at a time, with the place of each failure (see testexp.mojo)."""
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
from app_notify import *
from app_problems import *
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
from app_terminal import *
from testexp import *
from window import WK_TESTS
from config import read_text


__extension App:
    # ======================================================= the test explorer
    def tests_index(self) -> Int:
        for i in range(len(self.wins)):
            if self.wins[i].kind == WK_TESTS:
                return i
        return -1

    def tests_toggle(mut self):
        """Run > Test explorer: the project's TestSuite files and their tests, in a
        window at the right edge; again to close it."""
        var ti = self.tests_index()
        if ti >= 0:
            var x = self.wins[ti].x
            _ = self.wins.pop(ti)
            for i in range(len(self.wins)):
                if self.wins[i].kind == WK_EDITOR and self.wins[i].x + self.wins[i].w == x:
                    self.wins[i].w = self.scr.w - self.wins[i].x
            return
        var w = max(30, min(52, self.scr.w * 2 // 5))
        var x = self.scr.w - w
        var h = self.desk_h()
        var mi = self.msg_index()
        if mi >= 0:
            h = max(6, self.wins[mi].y - 1)
        var win = Window(WK_TESTS, "Tests", "", x, 1, w, h, self.free_number())
        for i in range(len(self.wins)):
            if self.wins[i].kind == WK_EDITOR and self.wins[i].x + self.wins[i].w > x and x - self.wins[i].x >= 20:
                self.wins[i].w = x - self.wins[i].x
        self.wins.append(win^)
        self.tests_scan()
        self.say("Tests: Enter goes to a test, R runs, D debugs, A runs all, L lists tests")

    def tests_scan(mut self):
        """Find the project's test files (programs that run a TestSuite) and their
        tests from the sources; results of earlier runs are kept."""
        var root = self.symidx_root()
        var r = run_capture("grep -rlI --include='*.mojo' --include='*.🔥' --exclude-dir=.pixi --exclude-dir=.git --exclude-dir=build --exclude-dir=node_modules -e discover_tests " + shell_quote(root) + " 2>/dev/null | sort")
        var found = List[TestFile]()
        for l in bytes_to_str(r.out).split("\n"):
            var path = String(String(l).strip())
            if path.byte_length() == 0:
                continue
            var text = read_text(path)
            if not is_test_source(text):
                continue
            var f = TestFile(path)
            for name in test_names(text):
                f.tests.append(TestCase(name))
            # what is known from before
            for old in self.test_files:
                if old.path == path:
                    f.open = old.open
                    f.problem = old.problem.copy()
                    for t in old.tests:
                        var k = f.find(t.name)
                        if k >= 0:
                            f.tests[k] = t.copy()
                        elif old.listed:
                            f.tests.append(t.copy())
                    f.listed = old.listed
            found.append(f^)
        self.test_files = found^
        self.tests_show()

    def tests_sync_lens(mut self):
        """Populate inline gutter test markers (`▷`/`✓`/`✗`) on open TestSuite buffers."""
        for wi in range(len(self.wins)):
            if self.wins[wi].kind != WK_EDITOR:
                continue
            self.wins[wi].test_lens_rows.clear()
            self.wins[wi].test_lens_states.clear()
            if self.wins[wi].path.byte_length() == 0 or self.wins[wi].buf.large or not is_mojo_file(self.wins[wi].path):
                continue
            var src = bytes_to_str(self.wins[wi].buf.text_bytes())
            if not is_test_source(src):
                continue
            var fi = -1
            for k in range(len(self.test_files)):
                if self.test_files[k].path == self.wins[wi].path:
                    fi = k
                    break
            for tname in test_names(src):
                var dline = def_line(src, tname)
                if dline <= 0:
                    continue
                var st = 1
                if fi >= 0:
                    var tk = self.test_files[fi].find(tname)
                    if tk >= 0:
                        if self.test_files[fi].tests[tk].state == TS_PASS:
                            st = 2
                        elif self.test_files[fi].tests[tk].state == TS_FAIL:
                            st = 3
                self.wins[wi].test_lens_rows.append(dline - 1)
                self.wins[wi].test_lens_states.append(st)

    def test_at_cursor(mut self) raises:
        """Run > Quick-run test at cursor: find enclosing `def test_*` and run `--only <name>`."""
        var ai = self.active_editor()
        if ai < 0 or self.wins[ai].path.byte_length() == 0:
            self.say("Open and save a test file first")
            return
        if not self.ensure_saved(ai):
            return
        var path = String(self.wins[ai].path)
        var src = bytes_to_str(self.wins[ai].buf.text_bytes())
        if not is_test_source(src):
            self.exec(CM_TEST)
            return
        var best_name = String("")
        var best_row = -1
        for tname in test_names(src):
            var dl = def_line(src, tname) - 1
            if dl >= 0 and dl <= self.wins[ai].cr and dl >= best_row:
                best_row = dl
                best_name = tname
        var fi = -1
        for k in range(len(self.test_files)):
            if self.test_files[k].path == path:
                fi = k
                break
        if fi < 0:
            self.tests_scan()
            for k in range(len(self.test_files)):
                if self.test_files[k].path == path:
                    fi = k
                    break
        if fi < 0:
            self.exec(CM_TEST)
            return
        var files = List[Int]()
        files.append(fi)
        var only = List[String]()
        if best_name.byte_length() > 0:
            only.append(best_name)
        self.tests_start(files, only, False)

    def tests_show(mut self):
        self.tests_sync_lens()
        var ti = self.tests_index()
        if ti < 0:
            return
        var lines = List[String]()
        self.test_rows_file.clear()
        self.test_rows_test.clear()
        var root = self.symidx_root()
        if len(self.test_files) == 0:
            lines.append("(no test files: programs that run a TestSuite)")
            self.test_rows_file.append(-1)
            self.test_rows_test.append(-1)
        for fi in range(len(self.test_files)):
            var f = self.test_files[fi].copy()
            var name = f.path
            if name.startswith(root + "/"):
                var rel = String(name[byte=root.byte_length() + 1:])
                name = rel
            var c = f.counts()
            var tally = String("")
            if c[0] + c[1] + c[2] > 0:
                tally = "   ✓" + String(c[0]) + (" ✗" + String(c[1]) if c[1] > 0 else String("")) + (" -" + String(c[2]) if c[2] > 0 else String(""))
            lines.append(("▾ " if f.open else "▸ ") + name + tally + ("   (did not run)" if len(f.problem) > 0 else String("")))
            self.test_rows_file.append(fi)
            self.test_rows_test.append(-1)
            if not f.open:
                continue
            for p in range(min(4, len(f.problem))):
                lines.append("      " + f.problem[p])
                self.test_rows_file.append(fi)
                self.test_rows_test.append(-2)
            for k in range(len(f.tests)):
                var t = f.tests[k].copy()
                lines.append("  " + state_mark(t.state) + " " + t.name + (("   " + t.ms + " ms") if t.ms.byte_length() > 0 and t.state != TS_SKIP else String("")))
                self.test_rows_file.append(fi)
                self.test_rows_test.append(k)
                if t.state == TS_FAIL:
                    for m in range(min(3, len(t.message))):
                        lines.append("      " + String(t.message[m].strip()))
                        self.test_rows_file.append(fi)
                        self.test_rows_test.append(k)
        var text = List[Int]()
        for k in range(len(lines)):
            if k > 0:
                text.append(10)
            for ch in decode(lines[k]):
                text.append(ch)
        var keep = self.wins[ti].cr
        var keep_top = self.wins[ti].top
        self.wins[ti].buf.load(text)
        self.wins[ti].buf.modified = False
        self.wins[ti].cr = max(0, min(keep, self.wins[ti].buf.count() - 1))
        self.wins[ti].top = max(0, min(keep_top, self.wins[ti].buf.count() - 1))

    def tests_key(mut self, k: Int) raises -> Bool:
        """Keys of the test explorer (False: not one of its keys)."""
        var ti = self.top()
        var row = self.wins[ti].cr
        var fi = self.test_rows_file[row] if row < len(self.test_rows_file) else -1
        var tk = self.test_rows_test[row] if row < len(self.test_rows_test) else -1
        if k == KEY_ENTER or k == 32 or k == KEY_LEFT or k == KEY_RIGHT:
            if fi < 0:
                return True
            if tk == -1:
                var open = self.test_files[fi].open
                if k == KEY_LEFT:
                    open = False
                elif k == KEY_RIGHT:
                    open = True
                else:
                    open = not open
                self.test_files[fi].open = open
                self.tests_show()
            elif k == KEY_ENTER or k == 32:
                self.tests_go(fi, tk)
            return True
        if k == 114 or k == 82:             # R
            self.test_target_file = fi
            self.test_target_test = tk
            self.exec(CM_TEST_RUN)
            return True
        if k == 100 or k == 68:             # D: debug this test or file
            if fi >= 0 and fi < len(self.test_files):
                var tpath = String(self.test_files[fi].path)
                var tname = String(self.test_files[fi].tests[tk].name) if tk >= 0 and tk < len(self.test_files[fi].tests) else String("")
                if not self.trust_gate(CM_DEBUG):
                    return True
                self.debug_test(tpath, tname)
            return True
        if k == 97 or k == 65:              # A
            self.exec(CM_TEST_RUN_ALL)
            return True
        if k == 108 or k == 76:             # L
            self.test_target_file = fi
            self.exec(CM_TEST_LIST)
            return True
        if k == 116 or k == 84:             # T: look for test files again
            self.tests_scan()
            self.say("Looked for test files again: " + count_of(len(self.test_files), "file"))
            return True
        return False

    def tests_go(mut self, fi: Int, tk: Int) raises:
        """To a test: where it failed when that is known, else its def."""
        var f = self.test_files[fi].copy()
        if tk == -2 or tk < 0 or tk >= len(f.tests):
            self.open_path(f.path)
            return
        var t = f.tests[tk].copy()
        var path = f.path
        var line = def_line(read_text(f.path), t.name)
        var col = 0
        if t.state == TS_FAIL and t.path.byte_length() > 0:
            # Mojo's build cache can report the folder where the same source was first
            # compiled (another, possibly deleted copy): a place in a file of the test
            # file's name is taken to be in the test file; another file (a helper
            # module) is used when it is there
            var usable = basename(t.path) == basename(f.path)
            if not usable and path_exists(t.path):
                path = t.path
                usable = True
            if usable and t.line > 0:
                line = t.line
                col = max(0, t.col - 1)
        self.jump_mark()
        self.open_path(path)
        var w = self.top()
        self.wins[w].goto(max(0, line - 1), col)
        var ti = self.tests_index()
        if ti >= 0:
            self.focus(ti)              # the keyboard stays in the explorer
        if t.state == TS_FAIL and len(t.message) > 0:
            self.say(t.name + ": " + String(t.message[0].strip()))

    def tests_command(mut self, files: List[Int], only: List[String], list_only: Bool) -> String:
        """One shell command for several files, each marked "### <path>" in the output."""
        var cmd = String("")
        for fi in files:
            var p = String(self.test_files[fi].path)
            var flags = String("")
            if list_only:
                flags = " --skip-all"
            elif len(only) > 0:
                flags = " --only"
                for n in only:
                    flags += " " + shell_quote(n)
            var inner = "cd " + shell_quote(dirname(p)) + " && exec " + self.mojo_for(p) + " run" + self.include_flags() + " " + shell_quote(p) + flags
            cmd += "echo " + shell_quote("### " + p) + "; (" + self.with_env(p, inner) + ") 2>&1; "
        return cmd + "echo '### end'"

    def tests_start(mut self, files: List[Int], only: List[String], list_only: Bool) raises:
        if self.job_busy():
            return
        if len(files) == 0:
            self.say("No test files")
            return
        for fi in files:
            for k in range(len(self.test_files[fi].tests)):
                if not list_only and (len(only) == 0 or self.test_files[fi].tests[k].name in only):
                    self.test_files[fi].tests[k].state = TS_RUNNING
        self.tests_show()
        var cmd = self.tests_command(files, only, list_only)
        self.test_list_only = list_only
        self.test_only_run = len(only) > 0
        var what = ("Listing the tests of " if list_only else "Running ") + (basename(self.test_files[files[0]].path) if len(files) == 1 else count_of(len(files), "test file"))
        if self.start_job(JOB_TESTS, cmd, self.symidx_root(), what):
            self.panel_write(PG_MESSAGE)
            _ = self.fill_messages(self.job_heading(), List[UInt8](), "Running...")
            self.say(what + " - " + self.reg.key_label(CM_CANCEL) + " stops")

    def tests_run_target(mut self) raises:
        var fi = self.test_target_file
        if fi < 0 or fi >= len(self.test_files):
            self.say("Choose a test file or a test first")
            return
        var files = List[Int]()
        files.append(fi)
        var only = List[String]()
        var tk = self.test_target_test
        if tk >= 0 and tk < len(self.test_files[fi].tests):
            only.append(self.test_files[fi].tests[tk].name)
        self.tests_start(files, only, False)

    def tests_run_all(mut self) raises:
        var files = List[Int]()
        for k in range(len(self.test_files)):
            files.append(k)
        self.tests_start(files, List[String](), False)

    def tests_list(mut self) raises:
        var files = List[Int]()
        if self.test_target_file >= 0 and self.test_target_file < len(self.test_files):
            files.append(self.test_target_file)
        else:
            for k in range(len(self.test_files)):
                files.append(k)
        self.tests_start(files, List[String](), True)

    def tests_take_output(mut self, done: Bool):
        """The run's output so far (or all of it) into the tests: each file's section."""
        var text = bytes_to_str(self.job.data)
        var sections = text.split("### ")
        for si in range(len(sections)):
            var sec = String(sections[si])
            var ended = si < len(sections) - 1   # another section follows: this one is complete
            var nl = sec.find("\n")
            if nl < 0:
                continue
            var path = String(sec[byte=0:nl].strip())
            var body = String(sec[byte=nl + 1:])
            var fi = -1
            for k in range(len(self.test_files)):
                if self.test_files[k].path == path:
                    fi = k
            if fi < 0:
                continue
            var reports = parse_run(body)
            if len(reports) > 0:
                var f = self.test_files[fi].copy()
                if self.test_list_only:
                    # the program's own list: names in its order, states as they were
                    var listed = List[TestCase]()
                    for n in reports[0].names:
                        var k = f.find(n)
                        listed.append(f.tests[k].copy() if k >= 0 else TestCase(n))
                    f.tests = listed^
                    f.listed = True
                    f.problem.clear()
                else:
                    apply_report(f, reports[0], self.test_only_run)
                self.test_files[fi] = f^
            elif done or ended:
                # it ended without running a test: it did not compile (or crashed)
                var problem = List[String]()
                for l in body.split("\n"):
                    var s = String(String(l).strip())
                    if s.byte_length() > 0 and not s.startswith("stack trace was not") and not s.startswith("mojo: error: execution exited"):
                        problem.append(s)
                self.test_files[fi].problem = problem^
                for k in range(len(self.test_files[fi].tests)):
                    if self.test_files[fi].tests[k].state == TS_RUNNING:
                        self.test_files[fi].tests[k].state = TS_UNKNOWN
        if done:
            for fi in range(len(self.test_files)):
                for k in range(len(self.test_files[fi].tests)):
                    if self.test_files[fi].tests[k].state == TS_RUNNING:
                        self.test_files[fi].tests[k].state = TS_UNKNOWN      # cancelled
        self.tests_show()

    def finish_tests(mut self, status: Int, secs: Float64):
        self.tests_take_output(True)
        self.panel_write(PG_MESSAGE)
        var passed = 0
        var failed = 0
        for f in self.test_files:
            var c = f.counts()
            passed += c[0]
            failed += c[1]
        var footer = ("Listed" if self.test_list_only else "Tests: " + String(passed) + " passed, " + String(failed) + " failed") + " (" + String(Int(secs * 10) // 10) + "." + String(Int(secs * 10) % 10) + " s)"
        if self.job.cancelled:
            footer = "Stopped"
        _ = self.fill_messages(self.job_heading(), self.job.data.copy(), footer)
        self.problems_show(False)           # failed tests are problems too
        if not self.test_list_only:
            self.notify_as("test", NL_INFO if self.job.cancelled else (NL_ERROR if failed > 0 else NL_DONE), "Tests" if failed == 0 else "Tests failed", footer, True)
        self.say(footer)

