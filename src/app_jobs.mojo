"""Compiler integration: background build/format jobs, messages, run."""
from platform import make_nonblocking
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
from highlight import Highlighter, HL_PYTHON, lang_for_path
from cells import (
    CodeCell,
    PYTHON_CELL_DAEMON_SCRIPT,
    parse_cells,
    cell_at_row,
    build_cell_runner_mapped,
    format_python_cell_packet,
    format_mojo_repl_packet,
    parse_cell_kernel_output,
    remap_cell_runner_output,
    extract_cell_plots,
    format_cell_divider_badge,
    CELL_SUCCESS,
    CELL_ERROR,
    CELL_INTERRUPTED,
)
from symindex import is_mojo_file
from signals import own_pid
from swap import delete_file
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
from app_watch import *
from watch import *
from app_swap import *
from swap import *
from app_files import *
from gitdiff import Side, side_hunks
from app_dialogs import *
from app_menus import *
from app_exec import *
from app_pickers import *
from app_nav import *
from app_outline import *
from app_layout import *
from app_explorer import *
from app_docs import *
from app_debug import *
from app_terminal import *
from app_tests import *
from app_input import *
from app_mouse import *
from app_draw import *
from app_plugins import *
from app_gpu import *
from app_codegen import *
from app_pkginstall import *
from gpuinfo import parse_gpus
from pty import exit_code
from runreport import uses_gpu, visible_gpu_index, run_gpu_name, run_summary
from remote_target import remap_remote_output_paths
from grep import collect_search_files, file_matches_filter, MAX_FILE_BYTES, is_binary



def shown_command(cmd: String) -> String:
    """A job's command as the Message page shows it: the same shell command without
    the plumbing the IDE adds (`exec`, `2>&1`, `</dev/null`), so pasted into a shell
    it does the same."""
    var c = cmd.replace(" && exec ", " && ")
    if c.startswith("exec "):
        var rest = String(c[byte=5:])
        c = rest
    for tail in [" </dev/null", " 2>&1"]:
        c = c.replace(String(tail), "")
    return String(c.strip())

def parse_py_traceback_loc(line: String) -> ErrLoc:
    """Parse Python traceback location `  File "<path>", line <row>[, ...]`."""
    var tr = String(line.lstrip())
    if not tr.startswith("File \""):
        return ErrLoc("", -1, -1, -1)
    var marker = "\", line "
    var mpos = tr.find(marker, 6)
    if mpos < 6:
        return ErrLoc("", -1, -1, -1)
    var fpath = String(tr[byte=6:mpos])
    if fpath == "<string>" or fpath == "<stdin>" or fpath == "<cell>":
        return ErrLoc("", -1, -1, -1)
    var rest = decode(String(tr[byte=mpos + marker.byte_length():]))
    var k = 0
    var row = 0
    while k < len(rest) and is_digit(rest[k]):
        row = row * 10 + (rest[k] - 48)
        k += 1
    if k == 0 or row <= 0:
        return ErrLoc("", -1, -1, -1)
    return ErrLoc(fpath, row, 1, -1)


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
        """Put compiler-style output into the page of the bottom panel that is showing
        (the caller chooses the page with panel_page first)."""
        var mi = self.ensure_msg()
        var eff_data = data.copy()
        var tgt = self.active_compute_target()
        if tgt.kind != "local" and tgt.name != "local":
            eff_data = str_bytes(remap_remote_output_paths(tgt, self.symidx_root(), bytes_to_str(data)))
        var all = decode_list(eff_data)
        var text = decode(header)
        text.append(10)
        var head_rows = 1                   # (the header may have the command under it)
        for c in text[0:len(text) - 1]:
            if c == 10:
                head_rows += 1
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
        if self.msg_page == PG_MESSAGE:
            self.out_filtered = False       # new output: unfiltered
            self.out_filter = ""
        var errors = 0
        var warnings = 0
        var row = head_rows
        for l in lines:
            var s = to_str(l)
            var is_err = str_contains(s, "error:") and not s.startswith("mojo: ")
            var is_warn = str_contains(s, "warning:")
            var py_loc = parse_py_traceback_loc(s)
            if is_err or s.startswith("Traceback (most recent call last):"):
                errors += 1
            if is_warn:
                warnings += 1
            if is_err or is_warn:
                var loc = self.parse_loc(l)
                if loc.row > 0:
                    loc.msg_line = row
                    if not path_exists(loc.path) and self.find_editor_or_title(loc.path) < 0:
                        loc.path = abs_path(self.msg_base if self.msg_base.byte_length() > 0 else String(self.cwd), loc.path)
                    self.errs.append(loc^)
            elif py_loc.row > 0:
                py_loc.msg_line = row
                if not path_exists(py_loc.path) and self.find_editor_or_title(py_loc.path) < 0:
                    py_loc.path = abs_path(self.msg_base if self.msg_base.byte_length() > 0 else String(self.cwd), py_loc.path)
                self.errs.append(py_loc^)
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
        if self.job.active:
            self.say("Compiler is busy - Ctrl-F2 cancels it")
            return False
        self.fsearch.cancel()           # the Message window is about to show this job
        var c = "echo __PID__$$ && " + cmd
        var fp = popen_read(c)
        if fp == 0:
            self.info("Error", "Could not start: " + cmd)
            return False
        var fd = Int(external_call["fileno", Int32](fp))
        _ = external_call["fcntl", Int32](Int32(fd), Int32(3), Int32(0))
        make_nonblocking(fd)
        self.job.active = True
        self.job.kind = kind
        self.job.fp = fp
        self.job.fd = fd
        self.job.pid = 0
        self.job.data.clear()
        self.job.t0 = Int(perf_counter_ns())
        self.job.path = path
        self.job.exe = exe
        self.job.cmd = cmd
        self.job.cancelled = False
        var i = self.find_editor(path)
        self.job.version = self.wins[i].buf.version if i >= 0 else -1
        return True

    def start_aux_job(mut self, kind: Int, cmd: String, path: String, exe: String) -> Bool:
        """Start a lightweight background job (`JOB_FORMAT` or `JOB_CODEGEN`) on `aux_job`
        so formatting and codegen run concurrently even while `self.job` builds or tests."""
        if self.aux_job.active:
            self.say("Background format/codegen job is already running")
            return False
        var c = "echo __PID__$$ && " + cmd
        var fp = popen_read(c)
        if fp == 0:
            self.info("Error", "Could not start: " + cmd)
            return False
        var fd = Int(external_call["fileno", Int32](fp))
        _ = external_call["fcntl", Int32](Int32(fd), Int32(3), Int32(0))
        make_nonblocking(fd)
        self.aux_job.active = True
        self.aux_job.kind = kind
        self.aux_job.fp = fp
        self.aux_job.fd = fd
        self.aux_job.pid = 0
        self.aux_job.data.clear()
        self.aux_job.t0 = Int(perf_counter_ns())
        self.aux_job.path = path
        self.aux_job.exe = exe
        self.aux_job.cmd = cmd
        self.aux_job.cancelled = False
        var i = self.find_editor(path)
        self.aux_job.version = self.wins[i].buf.version if i >= 0 else -1
        return True

    def find_editor(self, path: String) -> Int:
        for i in range(len(self.wins)):
            if self.wins[i].kind == WK_EDITOR and self.wins[i].path == path:
                return i
        return -1

    def find_editor_or_title(self, name: String) -> Int:
        if name.byte_length() == 0:
            return -1
        var ei = self.find_editor(name)
        if ei >= 0:
            return ei
        var bname = basename(name)
        for k in range(len(self.wins)):
            if self.wins[k].kind == WK_EDITOR and (self.wins[k].title == name or self.wins[k].title == bname):
                return k
        return -1

    def job_busy(mut self) -> Bool:
        if self.job.active:
            self.say("Compiler is busy - Ctrl-F2 cancels it")
            return True
        if self.cell_k_active:
            self.say("Cell kernel is busy - Ctrl-F2 interrupts it")
            return True
        return False

    # -------------------------------------------------- find in files
    def start_file_search(mut self, s: Search, filter_glob: String = ""):
        """Search the project folder in the background; hits go to the Message window."""
        if self.job_busy():
            return
        self.fsearch.start(self.cwd, s, filter_glob)
        for k in range(len(self.wins)):
            if self.wins[k].kind == WK_EDITOR and self.wins[k].buf.modified and self.wins[k].path.byte_length() > 0:
                self.fsearch.set_overlay(self.wins[k].path, self.wins[k].buf.to_bytes())
        self.fsearch_shown = -1
        self.fsearch_draw_ns = 0
        self.show_search_results()

    def search_title(self) -> String:
        var what = "/" + to_str(self.fsearch.s.pat) + "/" if self.fsearch.s.use_regex else "\"" + to_str(self.fsearch.s.pat) + "\""
        var title = what + " in " + self.fsearch.root
        if self.fsearch.filter_glob.byte_length() > 0:
            title += " (" + self.fsearch.filter_glob + ")"
        return title

    def replace_in_files(mut self, s: Search, rep: List[Int], filter_glob: String) raises:
        """Build a multi-file WorkspaceEdit across matching files (overlaying unsaved
        open buffers) and present it through offer_edit() for preview and 1-step Undo."""
        self.snapshot_versions()
        var paths = collect_search_files(self.cwd, filter_glob)
        var prefix = self.cwd + "/"
        for k in range(len(self.wins)):
            if self.wins[k].kind == WK_EDITOR and self.wins[k].path.startswith(prefix):
                var wp = self.wins[k].path
                if not (wp in paths) and file_matches_filter(self.cwd, wp, filter_glob):
                    paths.append(wp)
        var we = WorkspaceEdit()
        for p in paths:
            var wi = self.find_editor(p)
            if wi < 0:
                var raw = read_file(p)
                if len(raw) == 0 or len(raw) > MAX_FILE_BYTES or is_binary(raw):
                    continue
            var lines: List[List[Int]]
            try:
                lines = self.lines_of(p)
            except:
                continue
            for r in range(len(lines)):
                var ln = lines[r].copy()
                var col = 0
                while col <= len(ln):
                    var caps = s.caps_in(ln, col)
                    if len(caps) == 0:
                        break
                    var repl_cps = s.replacement(rep, ln, caps)
                    var c1_u16 = col_to_utf16(ln, caps[0])
                    var c2_u16 = col_to_utf16(ln, caps[1])
                    we.add(p, LspEdit(r, c1_u16, r, c2_u16, to_str(repl_cps)))
                    col = max(caps[1], caps[0] + 1)
        if we.count() == 0:
            self.say("Replace in Files: 0 matches found")
            return
        var what = "/" + to_str(s.pat) + "/" if s.use_regex else "\"" + to_str(s.pat) + "\""
        self.offer_edit(we^, "Replace in Files", "Replace in Files", "Replace " + what + " with \"" + to_str(rep) + "\"", "Replaced")

    def show_search_results(mut self):
        """Put the hits found so far into the Message window, one per line as
        path:line:column: text, and make each of them a place Enter jumps to."""
        self.panel_write(PG_SEARCH)
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
        if self.cell_k_active:
            self.cell_queue_indices.clear()
            self.cell_queue_target = ""
            if self.cell_k_is_py and self.cell_py_proc.running and self.cell_py_proc.pid > 0 and self.cell_k_interrupt_ns == 0:
                _ = external_call["kill", Int32](Int32(self.cell_py_proc.pid), Int32(2))
                self.cell_k_interrupt_ns = Int(perf_counter_ns())
                self.say("Interrupting Python cell...")
                return
            self.cell_kernel_abort("interrupted")
            return
        if not self.job.active:
            if self.aux_job.active:
                if self.aux_job.pid > 0:
                    _ = external_call["kill", Int32](Int32(self.aux_job.pid), Int32(15))
                self.aux_job.cancelled = True
                self.say("Cancelling...")
                return
            self.say("Nothing to cancel")
            return
        if self.job.pid > 0:
            _ = external_call["kill", Int32](Int32(self.job.pid), Int32(15))
        self.job.cancelled = True
        self.cell_queue_indices.clear()
        self.cell_queue_target = ""
        self.say("Cancelling...")

    def stop_job_now(mut self):
        """Force-terminate and reap `self.job` without blocking on `pclose`, cleaning any temp outputs."""
        if not self.job.active:
            return
        var buf = List[UInt8](length=4096, fill=0)
        var eof = False
        for step in range(30):
            var n = external_call["read", Int](Int32(self.job.fd), buf.unsafe_ptr(), Int(4096))
            if n > 0:
                for k in range(n):
                    self.job.data.append(buf[k])
            elif n == 0:
                eof = True
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
            if self.job.pid > 0 and step == 0:
                _ = external_call["kill", Int32](Int32(self.job.pid), Int32(15))
            elif self.job.pid > 0 and step == 20 and not eof:
                _ = external_call["kill", Int32](Int32(self.job.pid), Int32(9))
            if eof:
                break
            _ = external_call["usleep", Int32](UInt32(10000))
        if self.job.pid > 0 and not eof:
            _ = external_call["kill", Int32](Int32(self.job.pid), Int32(9))
        _ = external_call["pclose", Int32](self.job.fp)
        if self.job.kind == JOB_CELL and self.cell_tmp_path.byte_length() > 0:
            delete_file(self.cell_tmp_path)
            self.cell_tmp_path = ""
        if self.job.kind == JOB_MAX_BENCH and self.max_bench_out_file.byte_length() > 0:
            delete_file(self.max_bench_out_file)
            self.max_bench_out_file = ""
        if self.job.kind == JOB_ROOFLINE and self.job.exe.byte_length() > 0:
            delete_file(self.job.exe)
        self.job = Job()

    def stop_aux_job_now(mut self):
        """Force-terminate and reap `self.aux_job` without blocking on `pclose`, cleaning any temp outputs."""
        if not self.aux_job.active:
            return
        var buf = List[UInt8](length=4096, fill=0)
        var eof = False
        for step in range(30):
            var n = external_call["read", Int](Int32(self.aux_job.fd), buf.unsafe_ptr(), Int(4096))
            if n > 0:
                for k in range(n):
                    self.aux_job.data.append(buf[k])
            elif n == 0:
                eof = True
                break
            if self.aux_job.pid == 0 and len(self.aux_job.data) >= 8 and self.aux_job.data[0] == 95:
                var nl = -1
                for k in range(len(self.aux_job.data)):
                    if self.aux_job.data[k] == 10:
                        nl = k
                        break
                if nl > 0:
                    var digits = List[UInt8]()
                    for k in range(7, nl):
                        digits.append(self.aux_job.data[k])
                    try:
                        self.aux_job.pid = atol(bytes_to_str(digits))
                    except:
                        self.aux_job.pid = -1
            if self.aux_job.pid > 0 and step == 0:
                _ = external_call["kill", Int32](Int32(self.aux_job.pid), Int32(15))
            elif self.aux_job.pid > 0 and step == 20 and not eof:
                _ = external_call["kill", Int32](Int32(self.aux_job.pid), Int32(9))
            if eof:
                break
            _ = external_call["usleep", Int32](UInt32(10000))
        if self.aux_job.pid > 0 and not eof:
            _ = external_call["kill", Int32](Int32(self.aux_job.pid), Int32(9))
        _ = external_call["pclose", Int32](self.aux_job.fp)
        if self.aux_job.kind == JOB_CODEGEN and self.codegen_out_file.byte_length() > 0:
            delete_file(self.codegen_out_file)
            self.codegen_out_file = ""
        if self.aux_job.kind == JOB_ROOFLINE and self.aux_job.exe.byte_length() > 0:
            delete_file(self.aux_job.exe)
        self.aux_job = Job()

    def job_elapsed(self) -> Float64:
        return Float64(Int(perf_counter_ns()) - self.job.t0) / 1e9

    def job_heading(self) -> String:
        """The Message page's first lines for this job: what it is, then the exact
        command, as it can be pasted into a shell."""
        var c = shown_command(self.job.cmd)
        return self.job_header() + (("\n$ " + c) if c.byte_length() > 0 else String(""))

    def job_header(self) -> String:
        if self.job.kind == JOB_DOCS:
            return "Downloading the Mojo documentation into " + self.job.path
        if self.job.kind == JOB_TASK:
            return "pixi run " + self.job.exe + "   (in " + self.job.path + ")"
        if self.job.kind == JOB_BUILD:
            return "Building " + self.job.path + " ..."
        if self.job.kind == JOB_TESTS:
            return self.job.exe
        if self.job.kind == JOB_CELL:
            return "Cell [" + self.job.exe + "] in " + basename(self.job.path)
        if self.job.kind == JOB_DEBUG:
            return "Building " + self.job.path + " for debugging (no optimization, full debug information) ..."
        if self.job.kind == JOB_BENCH:
            return "Benchmarking " + self.job.path + " (-O3) ..."
        if self.job.kind == JOB_ROOFLINE:
            return "Profiling GPU roofline for " + self.job.path + " ..."
        if self.job.kind == JOB_MAX_BENCH:
            return "Running MAX benchmark " + self.job.exe + " ..."
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
        if got and (self.job.kind == JOB_BUILD or self.job.kind == JOB_DEBUG) and self.job.pid != 0:
            self.panel_write(PG_MESSAGE)
            _ = self.fill_messages(self.job_heading(), self.job.data.copy(), "Compiling...")
        if got and self.job.kind == JOB_TESTS and self.job.pid != 0:
            self.tests_take_output(False)
        if got and (self.job.kind == JOB_TASK or self.job.kind == JOB_DOCS or self.job.kind == JOB_CELL) and self.job.pid != 0:
            self.task_output("Running...")
        if eof:
            self.finish_job()

    def finish_job(mut self) raises:
        var st = Int(external_call["pclose", Int32](self.job.fp))
        self.job.active = False
        var secs = self.job_elapsed()
        if self.job.kind == JOB_DOCS:
            self.docs_fetched(st)
        elif self.job.kind == JOB_TASK:
            self.finish_task(st, secs)
        elif self.job.kind == JOB_CELL:
            self.finish_cell(st, secs)
        elif self.job.kind == JOB_BUILD:
            self.finish_build(st, secs)
        elif self.job.kind == JOB_DEBUG:
            self.finish_debug_build(st, secs)
        elif self.job.kind == JOB_TESTS:
            self.finish_tests(st, secs)
        elif self.job.kind == JOB_BENCH:
            self.finish_bench_job(st)
        elif self.job.kind == JOB_ROOFLINE:
            self.finish_gpu_roofline(st)
        elif self.job.kind == JOB_MAX_BENCH:
            self.finish_max_bench(st)
        else:
            self.finish_format(st)

    def poll_aux_job(mut self) raises:
        if not self.aux_job.active:
            return
        var buf = List[UInt8](length=16384, fill=0)
        var eof = False
        for _ in range(64):
            var n = external_call["read", Int](Int32(self.aux_job.fd), buf.unsafe_ptr(), Int(16384))
            if n > 0:
                for k in range(n):
                    self.aux_job.data.append(buf[k])
            else:
                eof = n == 0
                break
        if self.aux_job.pid == 0 and len(self.aux_job.data) >= 8 and self.aux_job.data[0] == 95:
            var nl = -1
            for k in range(len(self.aux_job.data)):
                if self.aux_job.data[k] == 10:
                    nl = k
                    break
            if nl > 0:
                var digits = List[UInt8]()
                for k in range(7, nl):
                    digits.append(self.aux_job.data[k])
                try:
                    self.aux_job.pid = atol(bytes_to_str(digits))
                except:
                    self.aux_job.pid = -1
                var rest = List[UInt8]()
                for k in range(nl + 1, len(self.aux_job.data)):
                    rest.append(self.aux_job.data[k])
                self.aux_job.data = rest^
        if eof:
            var st = Int(external_call["pclose", Int32](self.aux_job.fp))
            self.aux_job.active = False
            if self.aux_job.kind == JOB_CODEGEN:
                self.finish_codegen(st)
            elif self.aux_job.kind == JOB_DOCS:
                self.finish_docs_job(st)
            elif self.aux_job.kind == JOB_BENCH:
                self.finish_bench_job(st)
            elif self.aux_job.kind == JOB_ROOFLINE:
                self.finish_gpu_roofline(st)
            else:
                var p = String(self.aux_job.path)
                var v = self.aux_job.version
                var c = String(self.aux_job.cmd)
                var d = self.aux_job.data.copy()
                var canc = self.aux_job.cancelled
                self.finish_format_job(st, p, v, c, d, canc)

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
        var cmd = "cd " + shell_quote(dir) + " && mkdir -p build && exec " + self.mojo_for(path) + " build" + self.include_flags_for(path) + " " + shell_quote(path) + " -o " + shell_quote(exe) + " 2>&1"
        cmd = self.with_env(path, cmd)
        if self.start_job(JOB_BUILD, cmd, path, exe):
            self.panel_write(PG_MESSAGE)
            _ = self.fill_messages(self.job_heading(), List[UInt8](), "Compiling...")
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
        self.panel_write(PG_MESSAGE)
        var counts = self.fill_messages(self.job_heading(), self.job.data.copy(), footer)
        if not self.job.cancelled:
            # the Problems page shows the build's errors too (behind this page)
            self.prob_build = parse_compiler_output(bytes_to_str(self.job.data), self.msg_base if self.msg_base.byte_length() > 0 else String(self.cwd))
            self.problems_show(False)
        var ei = self.find_editor(path)
        var nlines = self.wins[ei].buf.count() if ei >= 0 else 0
        var tstr = String(Int(secs * 10) // 10) + "." + String(Int(secs * 10) % 10) + " s"
        if self.job.cancelled:
            self.say("Build cancelled after " + tstr)
            self.notify_as("build", NL_INFO, "Build cancelled", name, True)
            return
        self.plugins_event("build", path, ok)
        if not ok and self.pkg_check(bytes_to_str(self.job.data), String(path), 1):
            return              # a library to install is offered instead of the result box (P11-13)
        if ok:
            self.notify_as("build", NL_DONE if counts[1] == 0 else NL_WARN, "Build succeeded", name + " in " + tstr + ((", " + String(counts[1]) + " warning(s)") if counts[1] > 0 else String("")), True)
        else:
            self.notify_as("build", NL_ERROR, "Build failed", name + ": " + String(counts[0]) + " error(s)", True)
        var waited = self.waited_for_job()
        if self.mode == M_NORMAL and waited:
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
            if (self.mode == M_NORMAL or self.mode == M_DIALOG) and waited:
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
            self.jump_mark()
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
        elif e.path.byte_length() > 0:
            var wi = self.find_editor_or_title(e.path)
            if wi >= 0:
                self.jump_mark()
                self.focus(wi)
                var t = self.top()
                self.wins[t].goto(e.row - 1, max(0, e.col - 1))
                mi = self.msg_index()
                if mi >= 0 and e.msg_line < self.wins[mi].buf.count():
                    self.say(to_str(self.wins[mi].buf.line(e.msg_line)))

    def format_file(mut self) raises:
        var i = self.top_editor()
        if i < 0:
            return
        var path = String(self.wins[i].path)
        if path.byte_length() > 0 and not is_mojo_file(path):
            if self.lsp_format_request(i):
                return
        if not self.ensure_saved(i):
            return
        path = String(self.wins[i].path)
        var inner = "cd " + shell_quote(dirname(path)) + " && exec " + self.mojo_for(path) + " format -q " + shell_quote(path)
        var cmd = self.with_env(path, inner) + " 2>&1"
        if self.job.active:
            if self.start_aux_job(JOB_FORMAT, cmd, path, ""):
                self.say("Formatting " + basename(path) + "...")
            return
        if self.start_job(JOB_FORMAT, cmd, path, ""):
            self.say("Formatting " + basename(path) + "...")

    def finish_format(mut self, status: Int) raises:
        var p = String(self.job.path)
        var v = self.job.version
        var c = String(self.job.cmd)
        var d = self.job.data.copy()
        var canc = self.job.cancelled
        self.finish_format_job(status, p, v, c, d, canc)

    def finish_format_job(mut self, status: Int, path: String, version: Int, cmd: String, data: List[UInt8], cancelled: Bool) raises:
        if cancelled:
            self.say("Format cancelled")
            return
        if status != 0:
            self.panel_write(PG_MESSAGE)
            var shown = shown_command(cmd)
            var heading = "Formatting " + path + " ..." + (("\n$ " + shown) if shown.byte_length() > 0 else String(""))
            _ = self.fill_messages(heading, data.copy(), "Format failed")
            self.say("mojo format failed - see the Message window")
            return
        var i = self.find_editor(path)
        if i < 0:
            self.say("Formatted " + basename(path))
            return
        if self.wins[i].buf.version != version:
            self.say("Edited while formatting - buffer not reloaded (file on disk is formatted)")
            return
        var txt: String
        with open(path, "r") as f:
            txt = f.read()
        var old_txt = bytes_to_str(self.wins[i].buf.text_bytes())
        var on_disk = str_bytes(txt)
        if old_txt == txt:
            self.wins[i].buf.modified = False
            self.wins[i].disk_hash = content_hash(on_disk)
            self.wins[i].disk_size = len(on_disk)
            self.note_disk_state(i)
            self.say("Formatted " + basename(path) + " (no changes)")
            return
        var cr = self.wins[i].cr
        var cc = self.wins[i].cc
        var top = self.wins[i].top
        var old_side = Side.of(old_txt)
        var new_side = Side.of(txt)
        var hunks = side_hunks(old_side, new_side)
        if len(hunks) > 0 and len(hunks) <= 500:
            var g = self.wins[i].new_group()
            var hi = len(hunks) - 1
            while hi >= 0:
                var hk = hunks[hi].copy()
                var nlines = self.wins[i].buf.count()
                # Build replacement codepoint sequence for new_side.lines[hk.b .. hk.b + hk.lb]
                var repl = List[Int]()
                for li in range(hk.lb):
                    if li > 0:
                        repl.append(10)
                    for cp in decode(new_side.lines[hk.b + li]):
                        if cp != 13:
                            repl.append(cp)
                if hk.la == 0:
                    # Pure insertion before line hk.a
                    if hk.a < nlines:
                        repl.append(10)
                        _ = self.wins[i].buf.insert(hk.a, 0, repl, cr, cc, g)
                    else:
                        var last_r = max(0, nlines - 1)
                        var ins = List[Int]()
                        ins.append(10)
                        for cp in repl:
                            ins.append(cp)
                        _ = self.wins[i].buf.insert(last_r, self.wins[i].buf.llen(last_r), ins, cr, cc, g)
                    if cr >= hk.a:
                        cr += hk.lb
                elif hk.lb == 0:
                    # Pure deletion of lines [hk.a .. hk.a + hk.la)
                    if hk.a + hk.la < nlines:
                        _ = self.wins[i].buf.delete(hk.a, 0, hk.a + hk.la, 0, cr, cc, g)
                    elif hk.a > 0:
                        _ = self.wins[i].buf.delete(hk.a - 1, self.wins[i].buf.llen(hk.a - 1), nlines - 1, self.wins[i].buf.llen(nlines - 1), cr, cc, g)
                    else:
                        _ = self.wins[i].buf.delete(0, 0, nlines - 1, self.wins[i].buf.llen(nlines - 1), cr, cc, g)
                    if cr >= hk.a + hk.la:
                        cr -= hk.la
                    elif cr >= hk.a:
                        cr = hk.a
                else:
                    # Replace lines [hk.a .. hk.a + hk.la - 1] in place
                    var end_r = min(nlines - 1, hk.a + hk.la - 1)
                    _ = self.wins[i].buf.delete(hk.a, 0, end_r, self.wins[i].buf.llen(end_r), cr, cc, g)
                    if len(repl) > 0:
                        _ = self.wins[i].buf.insert(hk.a, 0, repl, cr, cc, g)
                    if cr > end_r:
                        cr += hk.lb - hk.la
                    elif cr >= hk.a:
                        cr = min(hk.a + hk.lb - 1, cr)
                hi -= 1
            self.wins[i].sel = False
            self.wins[i].break_group()
            # Verify exact textual parity; fall back to full replace if trailing-newline edge differed
            if bytes_to_str(self.wins[i].buf.text_bytes()) != txt:
                var tmp = TextBuffer()
                tmp.load(decode(txt))
                self.wins[i].replace_all_text(tmp.all_text())
        else:
            var tmp = TextBuffer()
            tmp.load(decode(txt))
            self.wins[i].replace_all_text(tmp.all_text())
        self.wins[i].cr = cr
        self.wins[i].cc = cc
        self.wins[i].top = max(0, min(top, self.wins[i].buf.count() - 1))
        self.wins[i].clamp()
        self.wins[i].buf.modified = False
        self.wins[i].disk_hash = content_hash(on_disk)
        self.wins[i].disk_size = len(on_disk)
        self.note_disk_state(i)
        self.sync_shared_buffers(i)
        self.say("Formatted " + basename(path))

    def run_report(mut self, status: Int, output: String = ""):
        """The run that just ended, as one line on the Message page: its status, its
        time and, when it uses the GPU, which one (P11-10b)."""
        if self.run_t0_ns == 0:
            return
        var ns = Int(perf_counter_ns()) - self.run_t0_ns
        self.run_t0_ns = 0
        var gpu = String("")
        if self.run_wants_gpu and self.gpu_known():
            gpu = run_gpu_name(parse_gpus(bytes_to_str(self.gpu_out)), visible_gpu_index(env_or("CUDA_VISIBLE_DEVICES", ""), env_or("HIP_VISIBLE_DEVICES", "")))
        var line = run_summary(self.run_label, status, ns, self.run_wants_gpu, gpu)
        self.panel_write(PG_MESSAGE)
        _ = self.fill_messages("Run - " + self.run_label, List[UInt8](), line)
        self.say(line)
        if status != 0:
            var f = self.run_file
            _ = self.pkg_check(output, f, 2)     # a library it lacks? (P11-13)

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
        # Run uses the active run configuration, if the project has one; Test and a
        # project without one run the file being edited
        var core = self.run_core(test)
        var label = "mojo run " + basename(path)
        if not test and self.run_active.byte_length() > 0:
            label = "configuration " + self.run_active
        # timed, and the GPU learnt meanwhile for a program that uses one (P11-10b)
        self.run_label = label
        self.run_file = path
        self.run_wants_gpu = uses_gpu(to_str(self.wins[i].buf.all_text()))
        if self.run_wants_gpu:
            self.gpu_start(True)
        self.run_t0_ns = Int(perf_counter_ns())
        if self.run_in_terminal:
            self.run_in_window(label, core)
            return
        var cmd = (
            "clear && " + marked_run(label, core, marks_wanted(env_or("TERM", "")), "\\n")
            + "; printf '\\n\\033[7m Program exited with status %d - press any key to return to TurboMojo \\033[0m' $st; exit $st"
        )
        self.term.leave()
        var st = run_system(cmd)
        self.run_report(exit_code(st))
        self.term.raw()
        self.term.wait_byte()
        self.term.enter()
        self.scr.force = True

    def cell_kernels_stop(mut self):
        """Terminate persistent Mojo and Python cell kernel daemons cleanly."""
        if self.cell_mojo_proc.running:
            _ = self.cell_mojo_proc.stop()
        if self.cell_py_proc.running:
            _ = self.cell_py_proc.stop()
        self.cell_k_active = False
        self.cell_k_interrupt_ns = 0
        self.cell_k_buf.clear()
        self.cell_mojo_preamble = ""
        self.cell_py_preamble = ""
        self.cell_warmed_paths.clear()

    def cell_restart_kernels(mut self):
        """Restart both persistent cell kernels, clearing namespace state and inline badges."""
        if self.job.active and self.job.kind == JOB_CELL:
            self.stop_job_now()
        self.cell_kernels_stop()
        self.cell_queue_indices.clear()
        self.cell_queue_target = ""
        self.cell_exec_counter = 0
        self.cell_mojo_env = ""
        self.cell_py_env = ""
        for k in range(len(self.wins)):
            if self.wins[k].kind == WK_EDITOR:
                self.wins[k].clear_cell_badges()
                self.wins[k].clear_cell_outputs()
        self.say("Cell kernel restarted")

    def cell_apply_output(
        mut self,
        target_name: String,
        cell_idx: Int,
        fallback_hdr: Int,
        text: String,
        is_err: Bool,
        plots: List[String],
    ):
        """Attach virtual cell output lines and PNG plot references to the executed `# %%` cell."""
        var ei = self.find_editor_or_title(target_name)
        if ei < 0:
            return
        self.wins[ei].sync_cell_badges()
        var hdr_row = -1
        for bi in range(len(self.wins[ei].buf.cell_badge_rows)):
            if bi < len(self.wins[ei].buf.cell_badges) and self.wins[ei].buf.cell_badges[bi] == "[⟳ running…]":
                hdr_row = self.wins[ei].buf.cell_badge_rows[bi]
                break
        if hdr_row < 0:
            var cells = parse_cells(self.wins[ei].buf)
            if cell_idx >= 0 and cell_idx < len(cells):
                hdr_row = cells[cell_idx].header_row if cells[cell_idx].header_row >= 0 else 0
            elif fallback_hdr >= 0 and fallback_hdr < self.wins[ei].buf.count():
                hdr_row = fallback_hdr
        if hdr_row >= 0 and hdr_row < self.wins[ei].buf.count():
            self.cell_exec_counter += 1
            var plot_str = "\n".join(plots)
            self.wins[ei].set_cell_output(hdr_row, text, is_err, plot_str, self.cell_exec_counter)
            self.sync_shared_buffers(ei)
            if ei == self.top_editor() and len(self.cell_queue_indices) == 0:
                self.wins[ei].reveal_cell_output(hdr_row, self.cell_advance)

    def cell_apply_badge(mut self, target_name: String, cell_idx: Int, fallback_hdr: Int, badge: String):
        """Attach `badge` to the exact `# %%` cell (or row 0 for single-cell buffers),
        honoring live buffer line shifts even if edits occurred mid-execution."""
        var ei = self.find_editor_or_title(target_name)
        if ei < 0:
            return
        self.wins[ei].sync_cell_badges()
        var hdr_row = -1
        for bi in range(len(self.wins[ei].buf.cell_badge_rows)):
            if bi < len(self.wins[ei].buf.cell_badges) and self.wins[ei].buf.cell_badges[bi] == "[⟳ running…]":
                hdr_row = self.wins[ei].buf.cell_badge_rows[bi]
                break
        if hdr_row < 0:
            var cells = parse_cells(self.wins[ei].buf)
            if cell_idx >= 0 and cell_idx < len(cells):
                hdr_row = cells[cell_idx].header_row if cells[cell_idx].header_row >= 0 else 0
            elif fallback_hdr >= 0 and fallback_hdr < self.wins[ei].buf.count():
                hdr_row = fallback_hdr
        if hdr_row >= 0 and hdr_row < self.wins[ei].buf.count():
            self.wins[ei].set_cell_badge(hdr_row, badge)
            self.sync_shared_buffers(ei)

    def cell_kernel_abort(mut self, reason: String):
        """Force-stop the active persistent kernel run (on Ctrl-F2 or crash) and report status."""
        if not self.cell_k_active:
            return
        if self.cell_k_is_py:
            if self.cell_py_proc.running:
                _ = self.cell_py_proc.stop()
            self.cell_py_preamble = ""
            self.cell_py_env = ""
        else:
            if self.cell_mojo_proc.running:
                _ = self.cell_mojo_proc.stop()
            self.cell_mojo_preamble = ""
            self.cell_mojo_env = ""
        var ms = max(0, (Int(perf_counter_ns()) - self.cell_k_t0) // 1000000)
        var secs = Float64(ms) / 1000.0
        var dur = (String(ms) + " ms") if ms < 1000 else (String(Int(secs * 10) // 10) + "." + String(Int(secs * 10) % 10) + " s")
        var title = String(self.cell_k_title)
        var tpath = String(self.cell_k_path)
        var cidx = self.cell_k_index
        var hrow = self.cell_k_header_row
        var raw_copy = self.cell_k_buf.copy()
        self.cell_k_active = False
        self.cell_k_interrupt_ns = 0
        self.cell_k_buf.clear()
        self.cell_queue_indices.clear()
        self.cell_queue_target = ""
        var footer = "Cell [" + title + "] " + reason + " after " + dur
        self.panel_write(PG_MESSAGE)
        _ = self.fill_messages("Cell [" + title + "] in " + basename(tpath), raw_copy, footer)
        var raw_txt = String(bytes_to_str(raw_copy).strip())
        if raw_txt.byte_length() == 0:
            raw_txt = reason
        self.cell_apply_output(tpath, cidx, hrow, raw_txt, True, List[String]())
        var badge = format_cell_divider_badge(CELL_INTERRUPTED, ms, reason)
        self.cell_apply_badge(tpath, cidx, hrow, badge)
        self.say(footer)

    def cell_kernel_tick(mut self):
        """Non-blocking poll of persistent Mojo & Python cell kernels from the main event loop."""
        self.cell_mojo_proc.flush()
        self.cell_py_proc.flush()
        if not self.cell_k_active:
            if self.cell_mojo_proc.running:
                _ = self.cell_mojo_proc.read_available()
                _ = self.cell_mojo_proc.take()
            if self.cell_py_proc.running:
                _ = self.cell_py_proc.read_available()
                _ = self.cell_py_proc.take()
            return
        var got_bytes = False
        var proc_dead: Bool
        if self.cell_k_is_py:
            _ = self.cell_py_proc.read_available()
            var chunk = self.cell_py_proc.take()
            if len(chunk) > 0:
                got_bytes = True
                for b in chunk:
                    self.cell_k_buf.append(b)
            proc_dead = not self.cell_py_proc.alive() and self.cell_py_proc.eof
        else:
            _ = self.cell_mojo_proc.read_available()
            var chunk = self.cell_mojo_proc.take()
            if len(chunk) > 0:
                got_bytes = True
                for b in chunk:
                    self.cell_k_buf.append(b)
            proc_dead = not self.cell_mojo_proc.alive() and self.cell_mojo_proc.eof

        var raw_str = bytes_to_str(self.cell_k_buf)
        var parsed = parse_cell_kernel_output(
            raw_str, self.cell_k_seq, self.cell_k_is_py, self.cell_k_path, self.cell_k_code_row
        )
        if not parsed[0]:
            if self.cell_k_interrupt_ns > 0 and Int(perf_counter_ns()) - self.cell_k_interrupt_ns > 400000000:
                self.cell_kernel_abort("interrupted")
                return
            if proc_dead:
                self.cell_kernel_abort("kernel exited unexpectedly")
                return
            if got_bytes and parsed[2].byte_length() > 0:
                # Stream live `__TM_FRAME__ <png>` / `__TM_LIVE_FRAME__ <png>` frames in real time!
                var latest_f = String("")
                var clean_part = List[String]()
                for pln_s in parsed[2].split("\n"):
                    var pln = String(pln_s)
                    var ptr = String(pln.strip())
                    if ptr.startswith("__TM_FRAME__ ") or ptr.startswith("__TM_LIVE_FRAME__ "):
                        var foff = 13 if ptr.startswith("__TM_FRAME__ ") else 18
                        var cand_f = String(ptr[byte=foff:].strip())
                        if cand_f.byte_length() > 0 and path_exists(cand_f):
                            latest_f = cand_f
                    else:
                        clean_part.append(pln)
                if latest_f.byte_length() > 0 and latest_f != self.cell_live_last_frame:
                    self.cell_live_last_frame = latest_f
                    var ei_l = self.find_editor_or_title(self.cell_k_path)
                    if ei_l >= 0 and self.cell_k_header_row >= 0 and self.cell_k_header_row < self.wins[ei_l].buf.count():
                        var part_txt = String("\n".join(clean_part).rstrip("\r\n"))
                        self.wins[ei_l].set_cell_output(
                            self.cell_k_header_row,
                            part_txt,
                            False,
                            latest_f,
                            max(1, self.cell_exec_counter + 1),
                        )
                        self.sync_shared_buffers(ei_l)
                    for wi_l in range(len(self.wins)):
                        if self.wins[wi_l].kind == 20:  # WK_IMGVIEW
                            self.wins[wi_l].img_paths.clear()
                            self.wins[wi_l].img_paths.append(latest_f)
                            self.wins[wi_l].img_idx = 0
                            self.wins[wi_l].path = latest_f
                            self.wins[wi_l].imgview_sync_title()
                self.panel_write(PG_MESSAGE)
                _ = self.fill_messages(
                    "Cell [" + self.cell_k_title + "] in " + basename(self.cell_k_path),
                    str_bytes("\n".join(clean_part)),
                    "Running cell...",
                )
            return

        # Sentinel arrived: cell finished cleanly in persistent kernel!
        if parsed[1] != CELL_SUCCESS:
            if self.cell_k_is_py and raw_str.find("__TM_PRE_ERR_" + String(self.cell_k_seq) + "__") >= 0:
                self.cell_py_preamble = ""
            elif not self.cell_k_is_py and raw_str.find("__TM_PRE_END_" + String(self.cell_k_seq) + "__") >= 0:
                var pre_idx = raw_str.find("__TM_PRE_END_" + String(self.cell_k_seq) + "__")
                var pre_part = String(raw_str[byte=0:pre_idx])
                if pre_part.find("error: Expression [") >= 0 or pre_part.find("[User] Unhandled exception") >= 0:
                    self.cell_mojo_preamble = ""
        var ms = max(0, (Int(perf_counter_ns()) - self.cell_k_t0) // 1000000)
        var secs = Float64(ms) / 1000.0
        var dur = (String(ms) + " ms") if ms < 1000 else (String(Int(secs * 10) // 10) + "." + String(Int(secs * 10) % 10) + " s")
        var ok = parsed[1] == CELL_SUCCESS
        var title = String(self.cell_k_title)
        var tpath = String(self.cell_k_path)
        var cidx = self.cell_k_index
        var hrow = self.cell_k_header_row
        self.cell_k_active = False
        self.cell_k_interrupt_ns = 0
        self.cell_k_buf.clear()
        var footer = ("Cell [" + title + "] completed in " + dur) if ok else ("Cell [" + title + "] failed in " + dur)
        var plot_res = extract_cell_plots(parsed[2])
        var disp_out = plot_res[0]
        var n_plots = len(plot_res[1])
        if n_plots > 0:
            self.cell_last_plots = plot_res[1].copy()
            footer += " · " + String(n_plots) + " plot(s) (Text > Open cell plot preview)"
        self.panel_write(PG_MESSAGE)
        _ = self.fill_messages("Cell [" + title + "] in " + basename(tpath), str_bytes(disp_out), footer)
        if not ok and len(self.errs) > 0:
            var mi = self.msg_index()
            if mi >= 0:
                self.wins[mi].cr = self.errs[0].msg_line
                self.wins[mi].follow = True
        var preview_clean = extract_cell_plots(parsed[3])[0]
        var preview = String(preview_clean.strip())
        if preview.byte_length() == 0:
            preview = "ok" if ok else "error"
        self.cell_apply_output(tpath, cidx, hrow, String(disp_out.rstrip("\r\n")), not ok, plot_res[1].copy())
        var badge = format_cell_divider_badge(CELL_SUCCESS if ok else CELL_ERROR, ms, preview, n_plots)
        self.cell_apply_badge(tpath, cidx, hrow, badge)
        self.say(footer)
        if ok:
            self.cell_pump_queue()
        else:
            self.cell_queue_indices.clear()
            self.cell_queue_target = ""

    def toggle_inline_cell_outputs(mut self):
        """Toggle virtual multi-line output rendering beneath `# %%` notebook cells."""
        var next_state = True
        var ed = self.active_editor()
        if ed >= 0:
            next_state = not self.wins[ed].inline_cell_outputs
        for k in range(len(self.wins)):
            if self.wins[k].kind == WK_EDITOR:
                self.wins[k].inline_cell_outputs = next_state
        self.say("Inline cell outputs " + ("on" if next_state else "off"))

    def clear_cell_outputs_cmd(mut self):
        """Clear virtual inline outputs and divider badges on the active notebook buffer."""
        var i = self.top_editor()
        if i < 0:
            self.say("No open notebook buffer")
            return
        self.wins[i].clear_cell_outputs()
        self.wins[i].clear_cell_badges()
        self.sync_shared_buffers(i)
        self.say("Cleared cell outputs")

    def cell_append_bottom(mut self, i: Int):
        """Append a fresh `# %%` code cell at the bottom of editor `i` and place the cursor inside it."""
        if i < 0 or i >= len(self.wins) or self.wins[i].read_only:
            return
        var last_r = max(0, self.wins[i].buf.count() - 1)
        var last_txt = to_str(self.wins[i].buf.line(last_r))
        var g = self.wins[i].new_group()
        var prefix = "\n\n" if String(last_txt.strip()).byte_length() > 0 else "\n"
        var ins = prefix + "# %%\n"
        _ = self.wins[i].buf.insert(last_r, self.wins[i].buf.llen(last_r), decode(ins), self.wins[i].cr, self.wins[i].cc, g)
        self.wins[i].break_group()
        var new_r = max(0, self.wins[i].buf.count() - 1)
        self.wins[i].goto(new_r, 0)
        self.wins[i].nb_cmd_mode = False
        self.sync_shared_buffers(i)

    def cell_insert_above(mut self):
        """Insert a new `# %%` cell above the cell at the cursor (Jupyter `a`)."""
        var i = self.top_editor()
        if i < 0 or self.wins[i].read_only:
            return
        var cells = parse_cells(self.wins[i].buf)
        var ci = max(0, cell_at_row(cells, self.wins[i].cr))
        var r0 = cells[ci].header_row if (len(cells) > 0 and cells[ci].header_row >= 0) else 0
        var g = self.wins[i].new_group()
        _ = self.wins[i].buf.insert(r0, 0, decode("# %%\n\n"), self.wins[i].cr, self.wins[i].cc, g)
        self.wins[i].break_group()
        self.wins[i].goto(r0 + 1, 0)
        self.sync_shared_buffers(i)
        self.say("Inserted cell above")

    def cell_insert_below(mut self):
        """Insert a new `# %%` cell below the cell at the cursor (Jupyter `b`)."""
        var i = self.top_editor()
        if i < 0 or self.wins[i].read_only:
            return
        var cells = parse_cells(self.wins[i].buf)
        if len(cells) == 0:
            self.cell_append_bottom(i)
            return
        var ci = max(0, cell_at_row(cells, self.wins[i].cr))
        var er = min(cells[ci].end_row, max(0, self.wins[i].buf.count() - 1))
        var end_c = self.wins[i].buf.llen(er)
        var g = self.wins[i].new_group()
        _ = self.wins[i].buf.insert(er, end_c, decode("\n# %%\n"), self.wins[i].cr, self.wins[i].cc, g)
        self.wins[i].break_group()
        self.wins[i].goto(min(er + 2, self.wins[i].buf.count() - 1), 0)
        self.sync_shared_buffers(i)
        self.say("Inserted cell below")

    def _cell_slice_text(self, i: Int, c: CodeCell) -> String:
        var r0 = c.header_row if c.header_row >= 0 else c.start_row
        var r1 = min(c.end_row, max(0, self.wins[i].buf.count() - 1))
        var lines = List[String]()
        if c.header_row < 0:
            lines.append("# %%")
        for r in range(r0, r1 + 1):
            lines.append(to_str(self.wins[i].buf.line(r)))
        return "\n".join(lines)

    def cell_copy_current(mut self):
        """Copy the current `# %%` cell into `nb_clip` (Jupyter `c`)."""
        var i = self.top_editor()
        if i < 0:
            return
        var cells = parse_cells(self.wins[i].buf)
        if len(cells) == 0:
            return
        var ci = max(0, cell_at_row(cells, self.wins[i].cr))
        self.wins[i].nb_clip = self._cell_slice_text(i, cells[ci])
        self.say("Copied cell [" + cells[ci].title + "]")

    def cell_paste_below(mut self):
        """Paste `nb_clip` as a cell below the cursor (Jupyter `v`)."""
        var i = self.top_editor()
        if i < 0 or self.wins[i].read_only or self.wins[i].nb_clip.byte_length() == 0:
            return
        var cells = parse_cells(self.wins[i].buf)
        var er = max(0, self.wins[i].buf.count() - 1)
        if len(cells) > 0:
            var ci = max(0, cell_at_row(cells, self.wins[i].cr))
            er = min(cells[ci].end_row, er)
        var g = self.wins[i].new_group()
        _ = self.wins[i].buf.insert(er, self.wins[i].buf.llen(er), decode("\n" + self.wins[i].nb_clip), self.wins[i].cr, self.wins[i].cc, g)
        self.wins[i].break_group()
        self.wins[i].goto(min(er + 2, self.wins[i].buf.count() - 1), 0)
        self.sync_shared_buffers(i)
        self.say("Pasted cell below")

    def cell_delete_current(mut self):
        """Delete (and store in `nb_clip`) the `# %%` cell at the cursor (Jupyter `dd` / `x`)."""
        var i = self.top_editor()
        if i < 0 or self.wins[i].read_only:
            return
        var cells = parse_cells(self.wins[i].buf)
        if len(cells) == 0:
            return
        var ci = max(0, cell_at_row(cells, self.wins[i].cr))
        self.wins[i].nb_clip = self._cell_slice_text(i, cells[ci])
        if len(cells) == 1:
            self.wins[i].replace_lines_undoable(0, max(0, self.wins[i].buf.count() - 1), "# %%\n")
            self.wins[i].clear_cell_outputs()
            self.wins[i].clear_cell_badges()
            self.wins[i].goto(min(1, self.wins[i].buf.count() - 1), 0)
            self.sync_shared_buffers(i)
            self.say("Cleared last cell")
            return
        var r0 = cells[ci].header_row if cells[ci].header_row >= 0 else cells[ci].start_row
        var r1 = min(cells[ci].end_row, max(0, self.wins[i].buf.count() - 1))
        var g = self.wins[i].new_group()
        if r1 + 1 < self.wins[i].buf.count():
            _ = self.wins[i].buf.delete(r0, 0, r1 + 1, 0, self.wins[i].cr, self.wins[i].cc, g)
        elif r0 > 0:
            _ = self.wins[i].buf.delete(r0 - 1, self.wins[i].buf.llen(r0 - 1), r1, self.wins[i].buf.llen(r1), self.wins[i].cr, self.wins[i].cc, g)
        else:
            _ = self.wins[i].buf.delete(r0, 0, r1, self.wins[i].buf.llen(r1), self.wins[i].cr, self.wins[i].cc, g)
        self.wins[i].break_group()
        var target_r = min(r0, max(0, self.wins[i].buf.count() - 1))
        var new_cells = parse_cells(self.wins[i].buf)
        var nci = cell_at_row(new_cells, target_r)
        if nci >= 0 and nci < len(new_cells):
            target_r = new_cells[nci].start_row
        self.wins[i].goto(target_r, 0)
        self.sync_shared_buffers(i)
        self.say("Deleted cell")

    def cell_set_type(mut self, to_markdown: Bool):
        """Convert the cell at the cursor to `# %% [markdown]` (`m`) or `# %%` Code (`y`)."""
        var i = self.top_editor()
        if i < 0 or self.wins[i].read_only:
            return
        var cells = parse_cells(self.wins[i].buf)
        if len(cells) == 0:
            return
        var ci = max(0, cell_at_row(cells, self.wins[i].cr))
        var c = cells[ci].copy()
        var r0 = c.header_row if c.header_row >= 0 else c.start_row
        var r1 = min(c.end_row, max(0, self.wins[i].buf.count() - 1))
        var cur_md = lower_str(c.title).startswith("[markdown]") or lower_str(c.title).startswith("[md]")
        if cur_md == to_markdown and c.header_row >= 0:
            self.say("Cell is already " + ("Markdown" if to_markdown else "Code"))
            return
        var new_lines = List[String]()
        new_lines.append("# %% [markdown]" if to_markdown else "# %%")
        var body_start = (c.header_row + 1) if c.header_row >= 0 else c.start_row
        for r in range(body_start, r1 + 1):
            var ln = to_str(self.wins[i].buf.line(r))
            if to_markdown:
                if ln.byte_length() == 0:
                    new_lines.append("#")
                elif ln.startswith("# ") or ln == "#":
                    new_lines.append(ln)
                else:
                    new_lines.append("# " + ln)
            else:
                if ln.startswith("# "):
                    new_lines.append(String(ln[byte=2:]))
                elif ln == "#":
                    new_lines.append("")
                else:
                    new_lines.append(ln)
        self.wins[i].replace_lines_undoable(r0, r1, "\n".join(new_lines))
        self.wins[i].goto(min(r0 + 1, max(0, self.wins[i].buf.count() - 1)), 0)
        self.sync_shared_buffers(i)
        self.say("Cell converted to " + ("Markdown" if to_markdown else "Code"))

    def cell_toggle_markdown(mut self):
        var i = self.top_editor()
        if i < 0:
            return
        var cells = parse_cells(self.wins[i].buf)
        if len(cells) == 0:
            return
        var ci = max(0, cell_at_row(cells, self.wins[i].cr))
        var is_md = lower_str(cells[ci].title).startswith("[markdown]") or lower_str(cells[ci].title).startswith("[md]")
        self.cell_set_type(not is_md)

    def cell_restart_and_run_all(mut self) raises:
        self.cell_restart_kernels()
        self.run_all_cells()

    def run_code_cell_insert_below(mut self) raises:
        """Execute current cell and insert a new `# %%` cell directly below it (Jupyter `Alt-Enter`)."""
        if self.job.active and self.job_busy():
            return
        var i = self.top_editor()
        if i < 0:
            return
        var cells = parse_cells(self.wins[i].buf)
        if len(cells) == 0:
            return
        var ci = max(0, cell_at_row(cells, self.wins[i].cr))
        var tname = self.wins[i].path if self.wins[i].path.byte_length() > 0 else self.wins[i].title
        if self.cell_k_active:
            var badge_r = cells[ci].header_row if cells[ci].header_row >= 0 else 0
            self.wins[i].set_cell_badge(badge_r, "[⋯ queued]")
            self.cell_queue_target = tname
            self.cell_queue_indices.append(ci)
            self.sync_shared_buffers(i)
        else:
            self.cell_queue_indices.clear()
            self.cell_queue_target = ""
            self.run_code_cell_by_index(i, ci, False)
        # Re-read cells and insert below `ci`
        var after_cells = parse_cells(self.wins[i].buf)
        if ci < len(after_cells) and not self.wins[i].read_only:
            var er = min(after_cells[ci].end_row, max(0, self.wins[i].buf.count() - 1))
            var g = self.wins[i].new_group()
            _ = self.wins[i].buf.insert(er, self.wins[i].buf.llen(er), decode("\n# %%\n"), self.wins[i].cr, self.wins[i].cc, g)
            self.wins[i].break_group()
            self.wins[i].goto(min(er + 2, self.wins[i].buf.count() - 1), 0)
            self.wins[i].nb_cmd_mode = False
            self.sync_shared_buffers(i)

    def cell_pump_queue(mut self):
        """Launch the next queued `# %%` cell when `Run all cells` / `Run cells above` is active."""
        while len(self.cell_queue_indices) > 0 and not self.cell_k_active and not self.job.active:
            var ei = self.find_editor_or_title(self.cell_queue_target)
            if ei < 0:
                self.cell_queue_indices.clear()
                self.cell_queue_target = ""
                return
            var next_ci = self.cell_queue_indices[0]
            _ = self.cell_queue_indices.pop(0)
            var cells = parse_cells(self.wins[ei].buf)
            if next_ci < 0 or next_ci >= len(cells):
                continue
            try:
                self.run_code_cell_by_index(ei, next_ci, False)
            except:
                self.cell_queue_indices.clear()
                self.cell_queue_target = ""
                return
        if len(self.cell_queue_indices) == 0 and not self.cell_k_active and not self.job.active:
            self.cell_queue_target = ""

    def run_all_cells(mut self) raises:
        """Execute every `# %%` cell in the active editor sequentially from top to bottom."""
        if self.job_busy():
            return
        var i = self.top_editor()
        if i < 0:
            self.say("No open file to run cells from")
            return
        var cells = parse_cells(self.wins[i].buf)
        if len(cells) == 0:
            self.say("Empty buffer")
            return
        self.cell_queue_indices.clear()
        for ci in range(len(cells)):
            self.cell_queue_indices.append(ci)
        self.cell_queue_target = self.wins[i].path if self.wins[i].path.byte_length() > 0 else self.wins[i].title
        self.cell_pump_queue()

    def run_cells_above(mut self) raises:
        """Execute all `# %%` cells strictly above the cell at the cursor sequentially."""
        if self.job_busy():
            return
        var i = self.top_editor()
        if i < 0:
            self.say("No open file to run cells from")
            return
        var cells = parse_cells(self.wins[i].buf)
        if len(cells) == 0:
            self.say("Empty buffer")
            return
        var cur_ci = cell_at_row(cells, self.wins[i].cr)
        if cur_ci <= 0:
            self.say("No cells above the cursor")
            return
        self.cell_queue_indices.clear()
        for ci in range(cur_ci):
            self.cell_queue_indices.append(ci)
        self.cell_queue_target = self.wins[i].path if self.wins[i].path.byte_length() > 0 else self.wins[i].title
        self.cell_pump_queue()

    def _advance_after_cell_trigger(mut self, i: Int, ci: Int, cells: List[CodeCell], cur_hdr: Int):
        """Move cursor to the next cell smoothly (preserving collapsed folds & keeping outputs in view)."""
        if ci + 1 < len(cells):
            var nh = cells[ci + 1].header_row
            var target_r = (
                nh
                if (nh >= 0 and (self.wins[i].buf.fold_index(nh) >= 0 or self.wins[i].nb_cmd_mode))
                else cells[ci + 1].start_row
            )
            self.wins[i].goto_cell(target_r, 0)
        elif self.wins[i].has_cells() or self.wins[i].is_notebook():
            self.cell_append_bottom(i)
        if cur_hdr >= 0:
            self.wins[i].reveal_cell_output(cur_hdr, True)

    def run_code_cell(mut self, advance: Bool) raises:
        """Execute the `# %%` cell at the cursor in a persistent non-blocking Mojo or Python
        kernel (queuing seamlessly on rapid `Shift-Enter` and auto-warming saved prerequisite
        cells on cold `.ipynb` starts)."""
        if self.job.active and self.job_busy():
            return
        var i = self.top_editor()
        if i < 0:
            self.say("No open file to run cell from")
            return
        var cells = parse_cells(self.wins[i].buf)
        if len(cells) == 0:
            if self.wins[i].is_notebook():
                self.cell_append_bottom(i)
                return
            self.say("Empty buffer")
            return
        var ci = cell_at_row(cells, self.wins[i].cr)
        if ci < 0 or ci >= len(cells):
            ci = 0
        var tname = self.wins[i].path if self.wins[i].path.byte_length() > 0 else self.wins[i].title

        # Rapid Shift-Enter / Ctrl-Enter while a cell is already executing: queue & advance!
        if self.cell_k_active:
            var hdr_q = cells[ci].header_row if cells[ci].header_row >= 0 else 0
            if not self.wins[i].is_markdown_header(hdr_q):
                self.wins[i].set_cell_badge(hdr_q, "[⋯ queued]")
                self.sync_shared_buffers(i)
            self.cell_queue_target = tname
            self.cell_queue_indices.append(ci)
            if advance:
                self._advance_after_cell_trigger(i, ci, cells, hdr_q)
            self.say("Queued cell [" + cells[ci].title + "] (" + String(len(self.cell_queue_indices)) + " queued)")
            return

        # Cold-kernel jump-in on a saved `.ipynb`: if no cell in this notebook has run in the
        # live kernel yet and preceding code cells had saved `execution_count > 0`, warm them first!
        var is_py = self.wins[i].effective_lang() == HL_PYTHON
        var kern_alive = (self.cell_py_proc.running and self.cell_py_proc.alive()) if is_py else (self.cell_mojo_proc.running and self.cell_mojo_proc.alive())
        if not kern_alive:
            self.cell_warmed_paths.clear()
        if ci > 0 and self.wins[i].is_notebook() and tname not in self.cell_warmed_paths:
            var prereqs = List[Int]()
            for pk in range(ci):
                var phdr = cells[pk].header_row if cells[pk].header_row >= 0 else 0
                if not self.wins[i].is_markdown_header(phdr) and self.wins[i].cell_exec_count_at_header(phdr) > 0:
                    prereqs.append(pk)
            if len(prereqs) > 0:
                self.cell_warmed_paths.append(tname)
                self.cell_queue_indices.clear()
                for pk in prereqs:
                    var phdr = cells[pk].header_row if cells[pk].header_row >= 0 else 0
                    self.wins[i].set_cell_badge(phdr, "[⋯ queued]")
                    self.cell_queue_indices.append(pk)
                var chdr = cells[ci].header_row if cells[ci].header_row >= 0 else 0
                if not self.wins[i].is_markdown_header(chdr):
                    self.wins[i].set_cell_badge(chdr, "[⋯ queued]")
                self.cell_queue_indices.append(ci)
                self.cell_queue_target = tname
                self.sync_shared_buffers(i)
                if advance:
                    self._advance_after_cell_trigger(i, ci, cells, chdr)
                self.cell_pump_queue()
                return

        self.cell_queue_indices.clear()
        self.cell_queue_target = ""
        self.run_code_cell_by_index(i, ci, advance)

    def run_code_cell_by_index(mut self, i: Int, ci: Int, advance: Bool) raises:
        """Execute cell `ci` of editor window `i`."""
        var cells = parse_cells(self.wins[i].buf)
        if ci < 0 or ci >= len(cells):
            return
        var hdr_txt = lower_str(cells[ci].title)
        if hdr_txt.startswith("[markdown]") or hdr_txt.startswith("[md]") or hdr_txt.startswith("[raw]"):
            var md_row = cells[ci].header_row if cells[ci].header_row >= 0 else 0
            self.wins[i].set_cell_badge(md_row, "[✓ markdown]")
            self.sync_shared_buffers(i)
            if advance:
                self._advance_after_cell_trigger(i, ci, cells, md_row)
            self.say("Markdown cell [" + cells[ci].title + "]")
            return
        var is_py = self.wins[i].effective_lang() == HL_PYTHON
        var p = self.wins[i].path
        var dir = dirname(p) if p.byte_length() > 0 else String(self.cwd)
        var env_ref = p if p.byte_length() > 0 else dir
        var env_key = dir + "|" + self.lsp_env_key(env_ref)
        var label = cells[ci].title
        var target_name = p if p.byte_length() > 0 else self.wins[i].title
        var badge_row = cells[ci].header_row if cells[ci].header_row >= 0 else 0
        if target_name not in self.cell_warmed_paths:
            self.cell_warmed_paths.append(target_name)

        if is_py:
            if self.cell_py_proc.running and (not self.cell_py_proc.alive() or self.cell_py_env != env_key):
                _ = self.cell_py_proc.stop()
                self.cell_py_preamble = ""
            if not self.cell_py_proc.running:
                var py_inner = "cd " + shell_quote(dir) + " && exec python3 -u -c " + shell_quote(PYTHON_CELL_DAEMON_SCRIPT)
                var py_cmd = "sh -c " + shell_quote(self.with_env(env_ref, py_inner))
                if self.cell_py_proc.start(py_cmd, ""):
                    self.cell_py_env = env_key
                    self.cell_py_preamble = ""
        else:
            if self.cell_mojo_proc.running and (not self.cell_mojo_proc.alive() or self.cell_mojo_env != env_key):
                _ = self.cell_mojo_proc.stop()
                self.cell_mojo_preamble = ""
            if not self.cell_mojo_proc.running:
                var mj_exe = self.mojo_for(env_ref)
                var imp_setup = self.mojo_repl_import_setup(mj_exe, dir, env_ref)
                var mj_inner = "cd " + shell_quote(dir) + " && " + imp_setup + "exec " + mj_exe + " repl -O 'settings set show-statusline false'"
                var mj_cmd = "sh -c " + shell_quote(self.with_env(env_ref, mj_inner))
                if self.cell_mojo_proc.start(mj_cmd, ""):
                    self.cell_mojo_env = env_key
                    self.cell_mojo_preamble = ""

        var use_kernel = self.cell_py_proc.running if is_py else self.cell_mojo_proc.running
        if use_kernel:
            self.fsearch.cancel()
            self.cell_k_seq += 1
            var seq = self.cell_k_seq
            var code_row: Int
            var pre_sig = String("")
            if cells[0].header_row == -1:
                var plines = List[String]()
                for pr in range(cells[0].start_row, cells[0].end_row + 1):
                    plines.append(to_str(self.wins[i].buf.line(pr)))
                pre_sig = target_name + "\n" + "\n".join(plines)
            if is_py:
                _ = self.cell_py_proc.read_available()
                _ = self.cell_py_proc.take()
                if ci > 0 and cells[0].header_row == -1 and pre_sig != self.cell_py_preamble:
                    var pre_pkt = format_python_cell_packet(self.wins[i].buf, cells[0], seq, target_name, True)
                    self.cell_py_proc.write(str_bytes(pre_pkt[0]))
                    self.cell_py_preamble = pre_sig
                var pkt = format_python_cell_packet(self.wins[i].buf, cells[ci], seq, target_name, False)
                code_row = pkt[1]
                self.cell_py_proc.write(str_bytes(pkt[0]))
                if ci == 0 and cells[0].header_row == -1:
                    self.cell_py_preamble = pre_sig
            else:
                _ = self.cell_mojo_proc.read_available()
                _ = self.cell_mojo_proc.take()
                if ci > 0 and cells[0].header_row == -1 and pre_sig != self.cell_mojo_preamble:
                    var pre_pkt = format_mojo_repl_packet(self.wins[i].buf, cells[0], seq, True)
                    self.cell_mojo_proc.write(str_bytes(pre_pkt[0]))
                    self.cell_mojo_preamble = pre_sig
                var pkt = format_mojo_repl_packet(self.wins[i].buf, cells[ci], seq, False)
                code_row = pkt[1]
                self.cell_mojo_proc.write(str_bytes(pkt[0]))
                if ci == 0 and cells[0].header_row == -1:
                    self.cell_mojo_preamble = pre_sig
            self.cell_k_active = True
            self.cell_k_is_py = is_py
            self.cell_k_t0 = Int(perf_counter_ns())
            self.cell_k_path = target_name
            self.cell_k_title = label
            self.cell_k_index = ci
            self.cell_k_header_row = badge_row
            self.cell_k_code_row = code_row
            self.cell_k_buf.clear()
            self.cell_live_last_frame = ""
            self.cell_k_interrupt_ns = 0
            self.cell_advance = advance
            self.wins[i].set_cell_badge(badge_row, "[⟳ running…]")
            self.sync_shared_buffers(i)
            if advance:
                self._advance_after_cell_trigger(i, ci, cells, badge_row)
            self.panel_write(PG_MESSAGE)
            _ = self.fill_messages("Cell [" + label + "] in " + basename(target_name), List[UInt8](), "Running cell...")
            self.say("Running cell [" + label + "] ...")
            return

        var mapped = build_cell_runner_mapped(self.wins[i].buf, cells, ci, is_py)
        var tmp = env_or("TMPDIR", "/tmp") + "/turbomojo-cell-" + String(own_pid()) + (".py" if is_py else ".mojo")
        if not write_file(tmp, str_bytes(mapped.source)):
            self.say("Could not write cell runner: " + tmp)
            return
        self.cell_tmp_path = tmp
        self.cell_line_map = mapped.line_map.copy()
        self.cell_k_index = ci
        self.cell_k_header_row = badge_row
        self.cell_advance = advance
        var inner: String
        if is_py:
            inner = "cd " + shell_quote(dir) + " && exec python3 " + shell_quote(tmp)
        else:
            var inc = " -I " + shell_quote(dir) + self.include_flags_for(env_ref)
            inner = "cd " + shell_quote(dir) + " && exec " + self.mojo_for(env_ref) + " run" + inc + " " + shell_quote(tmp)
        var cmd = self.with_env(env_ref, inner) + " 2>&1"
        if self.start_job(JOB_CELL, cmd, target_name, label):
            self.wins[i].set_cell_badge(badge_row, "[⟳ running…]")
            self.sync_shared_buffers(i)
            if advance:
                self._advance_after_cell_trigger(i, ci, cells, badge_row)
            self.panel_write(PG_MESSAGE)
            _ = self.fill_messages("Cell [" + label + "] in " + basename(target_name), List[UInt8](), "Running cell...")
            self.say("Running cell [" + label + "] ...")

    def finish_cell(mut self, status: Int, secs: Float64):
        var tmp_used = String(self.cell_tmp_path)
        if self.cell_tmp_path.byte_length() > 0:
            delete_file(self.cell_tmp_path)
            self.cell_tmp_path = ""
        var ok = status == 0 and not self.job.cancelled
        var ms = Int(secs * 1000.0)
        var dur = (String(ms) + " ms") if ms < 1000 else (String(Int(secs * 10) // 10) + "." + String(Int(secs * 10) % 10) + " s")
        var footer: String
        if self.job.cancelled:
            footer = "Cell cancelled after " + dur
        elif ok:
            footer = "Cell [" + self.job.exe + "] completed in " + dur
        else:
            footer = "Cell [" + self.job.exe + "] failed (exit " + String(status >> 8) + ") in " + dur
        var remapped_raw = remap_cell_runner_output(
            bytes_to_str(self.job.data), tmp_used, self.job.path, self.cell_line_map
        )
        var plot_res = extract_cell_plots(remapped_raw)
        var remapped = plot_res[0]
        var n_plots = len(plot_res[1])
        if n_plots > 0:
            self.cell_last_plots = plot_res[1].copy()
        self.panel_write(PG_MESSAGE)
        _ = self.fill_messages("Cell [" + self.job.exe + "] in " + basename(self.job.path), str_bytes(remapped), footer)
        if not ok and len(self.errs) > 0:
            var mi = self.msg_index()
            if mi >= 0:
                self.wins[mi].cr = self.errs[0].msg_line
                self.wins[mi].follow = True
        var jpath = String(self.job.path)
        var jcidx = self.cell_k_index
        var jhrow = self.cell_k_header_row
        if not self.job.cancelled:
            var out_txt = String(remapped.strip())
            self.cell_apply_output(jpath, jcidx, jhrow, String(remapped.rstrip("\r\n")), not ok, plot_res[1].copy())
            var badge = format_cell_divider_badge(CELL_SUCCESS if ok else CELL_ERROR, ms, out_txt if out_txt.byte_length() > 0 else ("ok" if ok else "error"), n_plots)
            self.cell_apply_badge(jpath, jcidx, jhrow, badge)
            self.say(footer)
            if ok:
                self.cell_pump_queue()
            else:
                self.cell_queue_indices.clear()
                self.cell_queue_target = ""
        else:
            self.cell_queue_indices.clear()
            self.cell_queue_target = ""
            self.cell_apply_output(jpath, jcidx, jhrow, "cancelled", True, List[String]())
            var badge = format_cell_divider_badge(CELL_INTERRUPTED, ms, "cancelled")
            self.cell_apply_badge(jpath, jcidx, jhrow, badge)
            self.say(footer)
