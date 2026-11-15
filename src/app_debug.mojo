"""Debugging: building a program with debug information, running it under Mojo's
debug adapter and showing what happens (see dap.mojo)."""
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
from app_lsp import *
from app_notify import *
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
from signals import own_pid


__extension App:
    def debug_adapter_command(mut self) -> String:
        """How the debug adapter is started ('' if it is not installed). The setting
        names the program; a setting with arguments is a whole command, used as it is."""
        var a = String(self.debug_adapter.strip())
        if a.find(" ") >= 0:
            return a
        var path = String("")
        if a.find("/") >= 0:
            path = a
        else:
            var ed = self.active_editor()
            var ref_path = String(self.wins[ed].path) if ed >= 0 and self.wins[ed].path.byte_length() > 0 else join_path(self.cwd, "main.mojo")
            var pdir = find_up(dirname(ref_path), "pixi.toml")
            if pdir.byte_length() > 0:
                var env_bin = join_path(pdir, ".pixi/envs/" + self.active_pixi_env() + "/bin/" + a)
                if path_exists(env_bin):
                    path = env_bin
                else:
                    var def_bin = join_path(pdir, ".pixi/envs/default/bin/" + a)
                    if path_exists(def_bin):
                        path = def_bin
            if path.byte_length() == 0:
                path = which(a)
        if path.byte_length() == 0 or not path_exists(path):
            return ""
        return adapter_command(path)

    def debug_badge(self) -> String:
        if self.dbg.state == DS_STOPPED:
            return "DEBUG:stopped"
        if self.dbg.state == DS_RUNNING:
            return "DEBUG:running"
        return "DEBUG:starting"

    def debug_command(mut self) raises:
        """Run > Debug: build the current file with debug information and run it under
        the debugger. While a program is stopped, the same command lets it continue."""
        if self.dbg.active():
            if self.dbg_post_mortem or self.dbg.post_mortem:
                self.say("Cannot step in a core dump")
                return
            if self.dbg.state == DS_RUNNING:
                self.debug_pause()
                return
            if self.dbg.resume():
                self.debug_mark_clear()
                self.say("Continuing " + basename(self.dbg_source))
            else:
                self.say("A program is being debugged - " + self.reg.key_label(CM_CANCEL) + " ends it")
            return
        if self.job_busy():
            return
        var i = self.top_editor()
        if i < 0:
            self.info("Debug", "No file to debug.")
            return
        if not self.ensure_saved(i):
            return
        if self.debug_adapter_command().byte_length() == 0:
            self.info("Debug", "The debug adapter was not found: " + self.debug_adapter + " (it comes with Mojo; tools.debug_adapter names it)")
            return
        var path = String(self.wins[i].path)
        self.run_configs_load()
        for c in self.run_cfgs:
            if c.name == self.run_active and c.file.byte_length() > 0 and self.dbg_temp_path.byte_length() == 0:
                var cand = c.file if c.file.startswith("/") else join_path(self.symidx_root(), c.file)
                if path_exists(cand):
                    path = cand
        var dir = dirname(path)
        var exe = join_path(dir, "build/" + stem(path) + ".debug")
        var inner = "cd " + shell_quote(dir) + " && mkdir -p build && exec " + self.mojo_for(path) + " build -g -O0" + self.include_flags() + " " + shell_quote(path) + " -o " + shell_quote(exe)
        var cmd = self.with_env(path, inner) + " 2>&1"
        if self.start_job(JOB_DEBUG, cmd, path, exe):
            self.panel_write(PG_MESSAGE)
            _ = self.fill_messages(self.job_heading(), List[UInt8](), "Compiling...")
            self.say("Building " + basename(path) + " for debugging - keep editing, " + self.reg.key_label(CM_CANCEL) + " cancels")

    def debug_test(mut self, path: String, test_name: String) raises:
        """Build a TestSuite file with `-g -O0` and launch it under `mojo-lldb-dap`."""
        if self.dbg.active():
            self.say("A program is already being debugged - " + self.reg.key_label(CM_CANCEL) + " ends it")
            return
        if self.job_busy():
            return
        if self.debug_adapter_command().byte_length() == 0:
            self.info("Debug", "The debug adapter was not found: " + self.debug_adapter + " (it comes with Mojo; tools.debug_adapter names it)")
            return
        self.dbg_override_on = True
        self.dbg_override_args = ("--only " + shell_quote(test_name)) if test_name.byte_length() > 0 else String("")
        var dir = dirname(path)
        var exe = join_path(dir, "build/" + stem(path) + ".debug")
        var inner = "cd " + shell_quote(dir) + " && mkdir -p build && exec " + self.mojo_for(path) + " build -g -O0" + self.include_flags() + " " + shell_quote(path) + " -o " + shell_quote(exe)
        var cmd = self.with_env(path, inner) + " 2>&1"
        if self.start_job(JOB_DEBUG, cmd, path, exe):
            self.panel_write(PG_MESSAGE)
            _ = self.fill_messages(self.job_heading(), List[UInt8](), "Compiling test for debugging...")
            self.say("Building " + basename(path) + (" (" + test_name + ")" if test_name.byte_length() > 0 else String("")) + " for debugging")
        else:
            self.dbg_override_on = False
            self.dbg_override_args = ""

    def finish_debug_build(mut self, status: Int, secs: Float64) raises:
        if status != 0 or self.job.cancelled:
            self.dbg_override_on = False
            self.dbg_override_args = ""
            self.finish_build(status, secs)         # the messages, as for any build
            return
        self.panel_write(PG_MESSAGE)
        _ = self.fill_messages(self.job_heading(), self.job.data.copy(), "Starting the debugger...")
        var exe = self.job.exe
        var source = self.job.path
        self.debug_launch(exe, source)

    def debug_launch(mut self, exe: String, source: String) raises:
        var log = (dirname(self.log_path) + "/dap.log") if self.log_path.byte_length() > 0 else String("/dev/null")
        self.dbg_source = source
        var cmd = self.debug_adapter_command()
        var args = split_arguments(self.run_args)
        var launch_cwd = dirname(source)
        var launch_env = List[String]()
        if self.dbg_override_on:
            args = split_arguments(self.dbg_override_args)
            self.dbg_override_on = False
            self.dbg_override_args = ""
        else:
            self.run_configs_load()
            for c in self.run_cfgs:
                if c.name == self.run_active:
                    if c.args.byte_length() > 0 or self.run_args.byte_length() == 0:
                        args = split_arguments(c.args)
                    if c.cwd.byte_length() > 0:
                        launch_cwd = c.cwd if c.cwd.startswith("/") else join_path(self.symidx_root(), c.cwd)
                    launch_env = c.env.copy()
                    if c.gpu_sync:
                        launch_env.append("MODULAR_DEVICE_CONTEXT_SYNC_MODE=true")
        # the breakpoints go to the adapter while it is being configured
        self.bp_sync()
        self.dbg.clear_config()
        var files = self.bps.files()
        if self.dbg_temp_path.byte_length() > 0 and self.dbg_temp_path not in files:
            files.append(self.dbg_temp_path)
        for f in files:
            var extra = self.dbg_temp_line if f == self.dbg_temp_path else 0
            self.dbg.set_config(f, "setBreakpoints", self.bps.source_request(f, extra))
        if len(self.bps.sent_functions()) > 0:
            self.dbg.set_config("", "setFunctionBreakpoints", self.bps.function_request())
        if len(self.bps.data_bps) > 0:
            self.dbg.set_config("@data", "setDataBreakpoints", self.bps.data_request())
        if not self.dbg.begin(cmd, exe, launch_cwd, args, log, launch_env):
            var why = self.dbg.error
            self.notify_as("debug", NL_ERROR, "The debugger did not start", why, True)
            self.say("The debugger did not start: " + why)
            return
        self.debug_show("Starting " + basename(exe) + " under the debugger...")
        self.say("Starting the debugger...")

    def debug_show(mut self, footer: String):
        """The program's output so far in the Message window, with the state below."""
        self.panel_write(PG_MESSAGE)
        var out = self.dbg.output.copy()
        self.msg_base = dirname(self.dbg_source)
        _ = self.fill_messages("Debugging " + self.dbg_source, out, footer)
        self.msg_base = ""
        # keep the newest output and the state in view, unless the window is being read
        var mi = self.msg_index()
        if mi >= 0 and mi != self.top():
            self.wins[mi].cr = max(0, self.wins[mi].buf.count() - 1)
            self.wins[mi].follow = True

    def debug_state_line(self) -> String:
        if self.dbg.state == DS_STOPPED:
            var s = "Stopped: " + self.dbg.stop_text
            if self.dbg.stop_file.byte_length() > 0:
                s += " at " + basename(self.dbg.stop_file) + ":" + String(self.dbg.stop_line)
            if self.dbg.stop_func.byte_length() > 0:
                s += " in " + self.dbg.stop_func
            if self.dbg.stop_file.byte_length() == 0:
                s += " (no source)"
            elif self.dbg.stop_depth > 0:
                s += " (called it: the stop is in " + self.dbg.stop_top + ")"
            return s + "  (" + self.reg.key_label(CM_STEP_INTO) + "/" + self.reg.key_label(CM_STEP_OVER) + " step, " + self.reg.key_label(CM_DEBUG) + " continues, " + self.reg.key_label(CM_CANCEL) + " ends)"
        if self.dbg.state == DS_RUNNING:
            return "Running...  (" + self.reg.key_label(CM_PAUSE) + " pauses, " + self.reg.key_label(CM_CANCEL) + " ends the program)"
        return "Starting..."

    def debug_tick(mut self) raises:
        """Take what the debug adapter reported since the last look."""
        if not self.dbg.active():
            return
        var evs = self.dbg.pump()
        if len(evs) == 0:
            return
        var over = False
        for e in evs:
            if e == DE_RUNNING:
                self.debug_mark_clear()
                self.dv_running()
                self.cpu_running()
                self.say("Debugging " + basename(self.dbg_source) + " - " + self.reg.key_label(CM_CANCEL) + " ends it")
            elif e == DE_STOPPED:
                self.typed_ns = 0               # the program stopped: a moment to look up (held toasts come)
                self.say("Stopped: " + self.dbg.stop_text)
                self.debug_temp_clear()
            elif e == DE_LOCATED:
                var in_cpu = self.top() >= 0 and self.wins[self.top()].kind == WK_CPU
                self.debug_show_stop()
                self.dv_stopped()
                self.cpu_stopped()
                if in_cpu and self.cpuwin_index() >= 0:
                    self.focus(self.cpuwin_index())      # instruction steps stay in it
            elif e == DE_BREAKPOINTS:
                self.bp_take_reports()
            elif e == DE_ANSWER:
                self.dv_answers()
            elif e == DE_FAILED or e == DE_ENDED:
                over = True
        if over:
            self.debug_end(False)
        else:
            self.debug_show(self.debug_state_line())

    def debug_show_stop(mut self) raises:
        """The program stopped and the place is known: show the line, marked."""
        var file = self.dbg.stop_file
        var line = self.dbg.stop_line
        self.debug_mark_clear()
        if file.byte_length() > 0 and path_exists(file) and line > 0:
            if self.mode == M_NORMAL:
                var already = self.top_editor() >= 0 and self.wins[self.top_editor()].path == file
                if not already:
                    self.jump_mark()
                self.open_path(file)
                var t = self.top()
                self.wins[t].goto(line - 1, 0)
            for i in range(len(self.wins)):
                if self.wins[i].kind == WK_EDITOR and self.wins[i].path == file:
                    self.wins[i].buf.exec_row = line - 1
        self.say(self.debug_state_line())

    def debug_mark_clear(mut self):
        for i in range(len(self.wins)):
            self.wins[i].buf.exec_row = -1
            self.wins[i].dbg_inline_rows.clear()
            self.wins[i].dbg_inline_vals.clear()

    def debug_sync_inline_locals(mut self):
        """Render top-level debugger locals inline at the end of lines in the stopped function."""
        if not self.dbg.active() or self.dbg.state != DS_STOPPED or self.dbg.stop_file.byte_length() == 0 or self.dbg.stop_line <= 0:
            return
        var stop_r = self.dbg.stop_line - 1
        for wi in range(len(self.wins)):
            if self.wins[wi].kind != WK_EDITOR or self.wins[wi].path != self.dbg.stop_file:
                continue
            self.wins[wi].dbg_inline_rows.clear()
            self.wins[wi].dbg_inline_vals.clear()
            var nlines = self.wins[wi].buf.count()
            if stop_r < 0 or stop_r >= nlines:
                continue
            var fn_start = max(0, stop_r - 80)
            var r = stop_r
            while r >= fn_start:
                var ind = self.wins[wi].indent_of(r)
                var rest = slice_str(self.wins[wi].buf.line(r), ind, self.wins[wi].buf.llen(r))
                if rest.startswith("def ") or rest.startswith("fn "):
                    fn_start = r
                    break
                r -= 1
            for ni in range(len(self.dview.nodes)):
                var nd = self.dview.nodes[ni].copy()
                if nd.depth != 0 or nd.name.byte_length() == 0 or nd.name == "self" or nd.value.byte_length() == 0:
                    continue
                var n_cps = decode(nd.name)
                var hit_row = -1
                var scan_r = stop_r
                while scan_r >= fn_start:
                    var ln = self.wins[wi].buf.line(scan_r)
                    var pos = find_cps(ln, n_cps, 0)
                    while pos >= 0:
                        var left_ok = pos == 0 or not is_ident(ln[pos - 1])
                        var right_ok = pos + len(n_cps) >= len(ln) or not is_ident(ln[pos + len(n_cps)])
                        if left_ok and right_ok:
                            hit_row = scan_r
                            break
                        pos = find_cps(ln, n_cps, pos + 1)
                    if hit_row >= 0:
                        break
                    scan_r -= 1
                if hit_row < 0:
                    continue
                var val_str = nice_value(nd.value)
                if cp_len(val_str) > 36:
                    val_str = slice_str(decode(val_str), 0, 35) + "…"
                var entry = nd.name + " = " + val_str
                var existing = -1
                for k in range(len(self.wins[wi].dbg_inline_rows)):
                    if self.wins[wi].dbg_inline_rows[k] == hit_row:
                        existing = k
                        break
                if existing >= 0:
                    if cp_len(self.wins[wi].dbg_inline_vals[existing]) < 64:
                        self.wins[wi].dbg_inline_vals[existing] = self.wins[wi].dbg_inline_vals[existing] + ", " + entry
                else:
                    self.wins[wi].dbg_inline_rows.append(hit_row)
                    self.wins[wi].dbg_inline_vals.append("  // " + entry)

    def debug_step(mut self, kind: String) raises:
        """F7 / F8 / Shift-F8 while a program is stopped."""
        if not self.dbg.active():
            self.say("No program is being debugged - " + self.reg.key_label(CM_DEBUG) + " starts one, " + self.reg.key_label(CM_RUN_CURSOR) + " runs to the cursor")
            return
        if self.dbg_post_mortem or self.dbg.post_mortem:
            self.say("Cannot step in a core dump")
            return
        if self.dbg.state != DS_STOPPED:
            self.say("The program is running - " + self.reg.key_label(CM_PAUSE) + " pauses it")
            return
        var t = self.top()
        var by_instruction = t >= 0 and self.wins[t].kind == WK_CPU
        if self.dbg.step(kind, by_instruction):
            self.debug_mark_clear()

    def debug_pause(mut self):
        if self.dbg_post_mortem or self.dbg.post_mortem:
            self.say("Cannot step in a core dump")
            return
        if self.dbg.state != DS_RUNNING:
            self.say("No program is running under the debugger")
            return
        if self.dbg.pause():
            self.say("Pausing...")

    def debug_run_to_cursor(mut self) raises:
        """F4: run until the cursor's line - a breakpoint there for one stop. Without
        a session, debugging starts and runs to it."""
        if self.dbg.active() and (self.dbg_post_mortem or self.dbg.post_mortem):
            self.say("Cannot step in a core dump")
            return
        var i = self.top_editor()
        if i < 0:
            return
        var path = self.wins[i].path
        if path.byte_length() == 0:
            self.say("Save the file first")
            return
        var line = self.wins[i].cr + 1
        if self.dbg.active() and self.dbg.state != DS_STOPPED:
            self.say("The program is running - " + self.reg.key_label(CM_PAUSE) + " pauses it")
            return
        self.bp_sync()
        self.dbg_temp_path = path
        self.dbg_temp_line = line
        if not self.dbg.active():
            self.debug_command()
            if not self.job.active:
                self.debug_temp_clear()     # (nothing was started)
            return
        self.dbg.send_breakpoints(path, "setBreakpoints", self.bps.source_request(path, line))
        if self.dbg.resume():
            self.debug_mark_clear()
            self.say("Running to line " + String(line))

    def debug_temp_clear(mut self):
        """The stop came (wherever it is): the breakpoint of Run to cursor goes."""
        if self.dbg_temp_path.byte_length() == 0:
            return
        var path = self.dbg_temp_path
        self.dbg_temp_path = ""
        self.dbg_temp_line = 0
        if self.dbg.can_send():
            self.dbg.send_breakpoints(path, "setBreakpoints", self.bps.source_request(path))

    def debug_end(mut self, by_user: Bool):
        """The session is over (or the user ends it): stop the adapter and the program,
        and say how it ended."""
        var failed = self.dbg.error
        var was_attached_live = self.dbg.attached_live or self.dbg_attached_pid > 0
        self.dbg.finish()
        self.dbg_post_mortem = False
        self.dbg_attached_pid = 0
        self.debug_mark_clear()
        self.dv_running()
        self.dview.note = "(no program is being debugged)"
        self.dview.watch_shown.clear()          # "?" until the next stop
        self.cpu_running()
        self.cpu.ibps.clear()
        self.cpu.src_map.clear()
        self.cpu.note = "(no program is stopped)"
        self.cpuwin_show()
        self.debugwin_show()
        self.dbg_temp_path = ""
        self.dbg_temp_line = 0
        self.bps.forget_debugger()
        self.bp_stamp += 1
        var footer: String
        if failed.byte_length() > 0:
            footer = failed
        elif by_user and was_attached_live:
            footer = "Detached from process"
        elif by_user:
            footer = "Debugging ended - the program was stopped"
        elif self.dbg.exited:
            footer = "Program exited with status " + String(self.dbg.exit_code)
        else:
            footer = "The debugger ended"
        self.debug_show(footer)
        self.say(footer)
        if failed.byte_length() > 0:
            # what the debugger said last usually explains it
            var tail = String("")
            if len(self.dbg.console) > 0:
                tail = " - " + String(self.dbg.console[len(self.dbg.console) - 1].strip())
            self.notify_as("debug", NL_ERROR, "Debugging failed", failed + tail, True)

    def debug_attach_pid_open(mut self):
        """Run > Attach to PID: open dialog to attach debugger to a live process."""
        if self.dbg.active():
            self.say("A program is already being debugged - " + self.reg.key_label(CM_CANCEL) + " ends it")
            return
        self.dbg_core_entries.clear()
        var r = run_capture("ps -eo pid=,comm= --sort=-pid 2>/dev/null | head -n 25")
        var items = List[String]()
        var data = List[Int]()
        for raw in bytes_to_str(r.out).split("\n"):
            var ln = String(String(raw).strip())
            if ln.byte_length() == 0:
                continue
            var sp = ln.find(" ")
            var pid_s = String(ln[byte=0:sp].strip()) if sp > 0 else ln
            try:
                var pid_v = atol(pid_s)
                if pid_v > 0 and pid_v != own_pid():
                    self.dbg_core_entries.append("pid:" + String(pid_v))
                    items.append(ln)
                    data.append(len(items) - 1)
            except:
                pass
        var h = min(20, max(10, len(items) + 9))
        var d = Dialog(D_DEBUG_ATTACH, "Attach to Process (PID)", min(72, self.scr.w - 4), h)
        d.lines.append("Enter a running process PID (or choose from the list); detaching leaves it running.")
        if len(items) > 0:
            d.set_items(items^, data^)
        d.fields.append(Field("~P~ID", ""))
        d.fields[0].fresh = True
        d.buttons.append("~A~ttach")
        d.buttons.append("Cancel")
        self.show(d^)

    def debug_core_open(mut self):
        """Run > Open Core Dump: open post-mortem core dump via coredumpctl or path."""
        if self.dbg.active():
            self.say("A program is already being debugged - " + self.reg.key_label(CM_CANCEL) + " ends it")
            return
        self.dbg_core_entries.clear()
        var r = run_capture("coredumpctl list --no-legend 2>/dev/null | tail -n 25")
        var items = List[String]()
        var data = List[Int]()
        for raw in bytes_to_str(r.out).split("\n"):
            var ln = String(String(raw).strip())
            if ln.byte_length() == 0:
                continue
            var entry = parse_coredumpctl_line(ln)
            if entry.exe.byte_length() > 0 and entry.core_path.byte_length() > 0:
                self.dbg_core_entries.append(entry.exe + "\t" + entry.core_path)
                items.append(entry.timestamp + "  PID " + String(entry.pid) + "  " + entry.signal_name + "  " + basename(entry.exe))
                data.append(len(items) - 1)
        var h = min(22, max(11, len(items) + 10))
        var d = Dialog(D_DEBUG_ATTACH, "Open Core Dump", min(80, self.scr.w - 4), h)
        d.lines.append("Inspect a post-mortem core dump: enter `<executable> <core_file>` or select below.")
        if len(items) > 0:
            d.set_items(items^, data^)
        d.fields.append(Field("~E~xecutable and core file", ""))
        d.fields[0].fresh = True
        d.buttons.append("~O~pen")
        d.buttons.append("Cancel")
        self.show(d^)

    def debug_attach_start(mut self, target: String) raises:
        """Start either a live PID attach session or a post-mortem core dump session."""
        if self.dbg.active():
            self.say("A program is already being debugged")
            return
        var t = String(target.strip())
        if t.byte_length() == 0 and self.dlg.kind == D_DEBUG_ATTACH:
            if self.dlg.list_sel >= 0 and self.dlg.list_sel < len(self.dbg_core_entries):
                t = self.dbg_core_entries[self.dlg.list_sel]
        if t.byte_length() == 0:
            self.say("Specify a PID or `<executable> <core_file>`")
            return
        var cmd = self.debug_adapter_command()
        if cmd.byte_length() == 0:
            self.info("Debug", "The debug adapter was not found: " + self.debug_adapter)
            return
        var log = (dirname(self.log_path) + "/dap.log") if self.log_path.byte_length() > 0 else String("/dev/null")
        var pid_val = -1
        if t.startswith("pid:"):
            try:
                pid_val = atol(String(t[byte=4:].strip()))
            except:
                pid_val = -1
        elif t.find("/") < 0 and t.find("\t") < 0 and t.find(" ") < 0:
            try:
                pid_val = atol(t)
            except:
                pid_val = -1
        if pid_val > 0:
            self.bp_sync()
            self.dbg.clear_config()
            for f in self.bps.files():
                self.dbg.set_config(f, "setBreakpoints", self.bps.source_request(f))
            if len(self.bps.sent_functions()) > 0:
                self.dbg.set_config("", "setFunctionBreakpoints", self.bps.function_request())
            if not self.dbg.attach_pid(cmd, pid_val, log):
                self.say("Could not attach to PID " + String(pid_val) + ": " + self.dbg.error)
                return
            self.dbg_attached_pid = pid_val
            self.dbg_post_mortem = False
            self.dbg_source = "PID " + String(pid_val)
            self.debug_show("Attaching to PID " + String(pid_val) + "...")
            self.say("Attaching to PID " + String(pid_val) + "...")
            return

        # Core dump target: `<exe>\t<core>` or `<exe> <core>`
        var exe = String("")
        var core_file = String("")
        var tab = t.find("\t")
        if tab > 0:
            exe = String(t[byte=0:tab].strip())
            core_file = String(t[byte=tab + 1:].strip())
        else:
            var parts = split_arguments(t)
            if len(parts) >= 2:
                exe = parts[0]
                core_file = parts[1]
            elif len(parts) == 1:
                core_file = parts[0]
                var ed = self.top_editor()
                if ed >= 0 and self.wins[ed].path.byte_length() > 0:
                    var p = self.wins[ed].path
                    exe = join_path(dirname(p), "build/" + stem(p) + ".debug")
        if core_file.byte_length() == 0 or not path_exists(core_file):
            self.say("Core file not found: " + core_file)
            return
        self.dbg.clear_config()
        if not self.dbg.attach_core(cmd, exe, core_file, log):
            self.say("Could not open core dump: " + self.dbg.error)
            return
        self.dbg_post_mortem = True
        self.dbg_attached_pid = 0
        self.dbg_source = core_file
        self.debug_show("Opening core dump " + basename(core_file) + "...")
        self.say("Opening core dump " + basename(core_file) + "...")

    # ========================================================== breakpoints
    def bp_file(self) -> String:
        """The file this project's breakpoints are kept in ('' if they are not kept)."""
        if self.bp_dir.byte_length() == 0:
            return ""
        var h = content_hash(str_bytes(self.symidx_root()))
        var digits = "0123456789abcdef"
        var name = String("")
        for _ in range(16):
            name = String(digits[byte=h % 16:h % 16 + 1]) + name
            h = h // 16
        return self.bp_dir + "/" + name + ".breakpoints"

    def bp_enable(mut self, dir: String):
        """Keep breakpoints between runs of the IDE, in `dir`; read this project's."""
        self.bp_dir = dir
        var f = self.bp_file()
        if f.byte_length() > 0 and path_exists(f):
            self.bps.decode(read_text(f))
            self.bp_stamp += 1
        self.watches_load()             # (kept next to them)

    def bp_save(mut self):
        var f = self.bp_file()
        if f.byte_length() == 0:
            return
        if len(self.bps.items) == 0:
            if path_exists(f):
                _ = run_system("rm -f " + shell_quote(f))
            return
        if not path_exists(self.bp_dir):
            _ = run_system("mkdir -p " + shell_quote(self.bp_dir))
        _ = write_file(f, str_bytes(self.bps.encode()))

    def bp_sync(mut self):
        """Bring the list and the open files together: a file that already shows the
        current list tells where its breakpoints have moved to with the text; any
        other file is given its breakpoints."""
        var moved = List[String]()
        for i in range(len(self.wins)):
            if self.wins[i].kind != WK_EDITOR or self.wins[i].path.byte_length() == 0:
                continue
            if self.wins[i].buf.bp_stamp == self.bp_stamp:
                var rows = self.wins[i].buf.bps.copy()
                var path = self.wins[i].path
                if path not in moved and self.bps.set_rows(path, rows):
                    moved.append(path)
        if len(moved) > 0:
            self.bp_stamp += 1
        for i in range(len(self.wins)):
            if self.wins[i].kind != WK_EDITOR or self.wins[i].path.byte_length() == 0:
                continue
            if self.wins[i].buf.bp_stamp != self.bp_stamp:
                var rows = List[Int]()
                var looks = List[Int]()
                for k in self.bps.of_file(self.wins[i].path):
                    rows.append(self.bps.items[k].line - 1)
                    looks.append(self.bps.items[k].look())
                self.wins[i].buf.bps = rows^
                self.wins[i].buf.bp_looks = looks^
                self.wins[i].buf.bp_stamp = self.bp_stamp
        for p in moved:
            self.bp_send(p)

    def bp_send(mut self, path: String):
        """Tell a running debugger about the breakpoints of a file ('' = functions)."""
        if not self.dbg.can_send():
            return
        if path.byte_length() == 0:
            self.dbg.send_breakpoints("", "setFunctionBreakpoints", self.bps.function_request())
        else:
            self.dbg.send_breakpoints(path, "setBreakpoints", self.bps.source_request(path))

    def bp_changed(mut self, path: String):
        """The list was changed (for this file; '' = function breakpoints): show it,
        keep it, tell the debugger."""
        self.bp_stamp += 1
        self.bp_sync()
        self.bp_save()
        self.bp_send(path)

    def bp_take_reports(mut self):
        """What the debugger said about breakpoints goes into the list."""
        for r in self.dbg.reports:
            self.bps.apply_report(r.tag, r.verified, r.lines, r.ids)
        self.dbg.reports.clear()
        for k in range(len(self.dbg.changed_ids)):
            self.bps.apply_change(self.dbg.changed_ids[k], self.dbg.changed_ok[k], self.dbg.changed_lines[k])
        self.dbg.changed_ids.clear()
        self.dbg.changed_ok.clear()
        self.dbg.changed_lines.clear()
        self.bp_sync()              # (edits first: the stamp is about to change)
        self.bp_stamp += 1
        self.bp_sync()

    def bp_toggle_at(mut self, i: Int, row: Int):
        var path = self.wins[i].path
        if path.byte_length() == 0:
            self.say("Save the file first: a breakpoint needs its name")
            return
        self.bp_sync()
        var added = self.bps.toggle(path, row + 1)
        self.bp_changed(path)
        self.say(("Breakpoint set on line " if added else "Breakpoint removed from line ") + String(row + 1))

    def bp_toggle(mut self):
        var i = self.top_editor()
        if i < 0:
            return
        self.bp_toggle_at(i, self.wins[i].cr)

    def bp_edit_dialog(mut self, k: Int, path: String, line: Int):
        """The dialog for one breakpoint: the k-th of the list, or (k < 0) a new one."""
        var b = Breakpoint(path, line)
        if k >= 0:
            b = self.bps.items[k].copy()
        self.bp_edit = k
        self.bp_edit_path = path
        self.bp_edit_line = line
        var what = (b.name + "()") if b.is_function() else (basename(b.path) + ":" + String(b.line))
        var d = Dialog(D_BREAKPOINT, "Breakpoint " + what, min(76, self.scr.w - 4), 16 if b.is_function() else 18)
        d.lines.append("Empty fields mean: stop every time.")
        # found by trying: Mojo 1.2's debugger cannot evaluate Mojo expressions, and a
        # condition it cannot evaluate makes it stop every time
        d.lines.append("Note: Mojo's debugger cannot evaluate most conditions yet - it then stops every time.")
        d.fields.append(Field("~C~ondition (stop only when true)", b.condition))
        d.fields.append(Field("~H~it count (as the debugger reads it, e.g. 5)", b.hit))
        if not b.is_function():
            d.fields.append(Field("~L~og message instead of stopping ({name} = a value)", b.log))
        d.checks.append("~E~nabled")
        d.check_vals.append(b.enabled)
        d.buttons.append("~O~K")
        d.buttons.append("Cancel")
        self.show(d^)

    def bp_edit_here(mut self):
        """Run > Breakpoint condition: the breakpoint of the cursor's line."""
        var i = self.top_editor()
        if i < 0:
            return
        var path = self.wins[i].path
        if path.byte_length() == 0:
            self.say("Save the file first: a breakpoint needs its name")
            return
        self.bp_sync()
        var line = self.wins[i].cr + 1
        self.bp_edit_dialog(self.bps.find(path, line), path, line)

    def bp_edit_save(mut self):
        var k = self.bp_edit
        if k < 0:
            k = self.bps.find(self.bp_edit_path, self.bp_edit_line)
            if k < 0:
                self.bps.items.append(Breakpoint(self.bp_edit_path, self.bp_edit_line))
                k = len(self.bps.items) - 1
        if k >= len(self.bps.items):
            return
        self.bps.items[k].condition = String(self.dlg.field_text(0).strip())
        self.bps.items[k].hit = String(self.dlg.field_text(1).strip())
        if not self.bps.items[k].is_function():
            self.bps.items[k].log = String(self.dlg.field_text(2).strip())
        self.bps.items[k].enabled = self.dlg.check_vals[0]
        var path = self.bps.items[k].path
        var text = self.bps.items[k].describe()
        self.bp_changed(path)
        self.say("Breakpoint " + text)

    def bp_function_dialog(mut self):
        var d = Dialog(D_BPFUNC, "Function Breakpoint", min(64, self.scr.w - 4), 10)
        d.lines.append("Stop when this function is entered.")
        var word = String("")
        var i = self.top_editor()
        if i >= 0:
            word = self.word_under(i)
        d.fields.append(Field("~F~unction name", word))
        d.buttons.append("~O~K")
        d.buttons.append("Cancel")
        self.show(d^)

    def bp_function_add(mut self, name: String):
        if name.byte_length() == 0:
            return
        if not self.bps.add_function(name):
            self.say("There is a breakpoint on " + name + "() already")
            return
        self.bp_changed("")
        self.say("Breakpoint set on the function " + name)

    def bp_list_dialog(mut self, sel: Int):
        """Run > Breakpoints: every breakpoint of the project."""
        self.bp_sync()
        var order = self.bps.ordered()
        if len(order) == 0:
            self.say("No breakpoints - " + self.reg.key_label(CM_BP_TOGGLE) + " sets one on the cursor's line")
            return
        var items = List[String]()
        var data = List[Int]()
        var signs = ["●", "○", "◆", "◌"]
        var root = self.symidx_root()
        for k in order:
            var b = self.bps.items[k].copy()
            var text = b.describe()
            if not b.is_function() and b.path.startswith(root + "/"):
                # inside the project the folder tells files of one name apart
                var rel = String(b.path[byte=root.byte_length() + 1:])
                if rel != basename(b.path):
                    text += "   " + dirname(rel) + "/"
            items.append(String(signs[b.look() - 1]) + " " + text)
            data.append(k)
        var d = Dialog(D_BREAKPOINTS, "Breakpoints", min(84, self.scr.w - 4), min(22, max(10, len(items) + 7)))
        d.lines.append("● stops   ◆ has a condition, count or message   ○ off   ◌ not placed by the debugger")
        d.set_items(items^, data^)
        d.list_sel = max(0, min(sel, len(order) - 1))
        d.buttons.append("~G~o to")
        d.buttons.append("~E~dit")
        d.buttons.append("~O~n/off")
        d.buttons.append("~D~elete")
        d.buttons.append("~C~lose")
        self.show(d^)

    def bp_list_button(mut self, b: Int, sel: Int) raises:
        """A button of the list (0 Go to, 1 Edit, 2 On/off, 3 Delete)."""
        if sel < 0 or sel >= len(self.dlg.item_data) or b > 3:
            return
        var k = self.dlg.item_data[sel]
        if k < 0 or k >= len(self.bps.items):
            return
        var path = self.bps.items[k].path
        var line = self.bps.items[k].line
        if b == 0:
            if path.byte_length() == 0:
                self.say("A function breakpoint has no line to go to")
                return
            if not path_exists(path):
                self.say("The file is gone: " + path)
                return
            self.jump_mark()
            self.open_path(path)
            var t = self.top()
            self.wins[t].goto(line - 1, 0)
        elif b == 1:
            self.bp_edit_dialog(k, path, line)
        elif b == 2:
            self.bps.items[k].enabled = not self.bps.items[k].enabled
            self.bp_changed(path)
            self.bp_list_dialog(sel)
        elif b == 3:
            _ = self.bps.items.pop(k)
            self.bp_changed(path)
            self.bp_list_dialog(sel)

    def bp_clear_all(mut self):
        var n = len(self.bps.items)
        if n == 0:
            self.say("No breakpoints")
            return
        var files = self.bps.files()
        self.bps.items.clear()
        self.bp_stamp += 1
        self.bp_sync()
        self.bp_save()
        for f in files:
            self.bp_send(f)
        self.bp_send("")
        self.say("Removed " + count_of(n, "breakpoint"))

    # ======================================================= the Debug window
    def debugwin_index(self) -> Int:
        for i in range(len(self.wins)):
            if self.wins[i].kind == WK_DEBUG:
                return i
        return -1

    def debugwin_toggle(mut self):
        """Window > Call stack and variables: the Debug window at the right edge (it
        takes the Outline's place), or close it."""
        var di = self.debugwin_index()
        if di >= 0:
            var x = self.wins[di].x
            _ = self.wins.pop(di)
            for i in range(len(self.wins)):
                if self.wins[i].kind == WK_EDITOR and self.wins[i].x + self.wins[i].w == x:
                    self.wins[i].w = self.scr.w - self.wins[i].x
            return
        if self.outline_index() >= 0:
            self.outline_toggle()
        var w = max(30, min(48, self.scr.w * 2 // 5))
        var x = self.scr.w - w
        var h = self.desk_h()
        var mi = self.msg_index()
        if mi >= 0:
            h = max(6, self.wins[mi].y - 1)
        var win = Window(WK_DEBUG, "Debug", "", x, 1, w, h, self.free_number())
        for i in range(len(self.wins)):
            if self.wins[i].kind == WK_EDITOR and self.wins[i].x + self.wins[i].w > x and x - self.wins[i].x >= 20:
                self.wins[i].w = x - self.wins[i].x
        self.wins.insert(0, win^)
        if not self.dbg.active() and len(self.dview.frames) == 0:
            self.dview.note = "(no program is being debugged)"
        self.debugwin_show()

    def debugwin_show(mut self):
        var di = self.debugwin_index()
        if di < 0:
            return
        self.dview.data_bps = self.bps.data_bps.copy()
        var text = List[Int]()
        var lines = self.dview.lines()
        for k in range(len(lines)):
            if k > 0:
                text.append(10)
            for c in decode(lines[k]):
                text.append(c)
        var keep = self.wins[di].cr
        var keep_top = self.wins[di].top
        self.wins[di].buf.load(text)
        self.wins[di].buf.modified = False
        self.wins[di].cr = max(0, min(keep, self.wins[di].buf.count() - 1))
        self.wins[di].top = max(0, min(keep_top, self.wins[di].buf.count() - 1))

    def dv_running(mut self):
        """The program runs: there is no stack to show."""
        self.dview.frames.clear()
        self.dview.nodes.clear()
        self.dview.note = "(the program is running)"
        self.dview.watch_shown.clear()
        for w in self.dview.watches:
            self.dview.watch_shown.append(w + ": (the program is running)")
        self.dv_scope_seq = -1
        self.dv_var_seqs.clear()
        self.dv_var_paths.clear()
        self.debugwin_show()

    def dv_stopped(mut self):
        """The program stopped: its stack, and the variables of the frame shown."""
        if self.debugwin_index() < 0 and self.mode == M_NORMAL:
            self.debugwin_toggle()          # the first stop opens the window
        self.dview.frames = self.dbg.frames.copy()
        self.dview.sel = min(self.dbg.stop_depth, max(0, len(self.dview.frames) - 1))
        self.dv_load_frame()

    def dv_load_frame(mut self):
        self.dview.nodes.clear()
        self.dv_var_seqs.clear()
        self.dv_var_paths.clear()
        if self.dview.sel >= len(self.dview.frames):
            self.dview.note = "(no frame)"
            self.debugwin_show()
            return
        self.dview.note = "(asking the debugger...)"
        self.dv_scope_seq = self.dbg.ask("scopes", "{\"frameId\":" + String(self.dview.frames[self.dview.sel].id) + "}")
        self.dv_ask_watches()
        self.debugwin_show()

    def dv_ask_watches(mut self):
        """Every watch, evaluated in the frame shown."""
        self.dv_watch_seqs.clear()
        self.dv_watch_idx.clear()
        while len(self.dview.watch_shown) < len(self.dview.watches):
            self.dview.watch_shown.append("")
        if self.dbg.state != DS_STOPPED or self.dview.sel >= len(self.dview.frames):
            return
        var fid = self.dview.frames[self.dview.sel].id
        for k in range(len(self.dview.watches)):
            self.dv_watch_seqs.append(self.dbg.ask("evaluate", "{\"expression\":" + json_quote(self.dview.watches[k]) + ",\"frameId\":" + String(fid) + ",\"context\":\"watch\"}"))
            self.dv_watch_idx.append(k)

    def dv_ask_children(mut self, handle: Int, path: String):
        self.dv_var_seqs.append(self.dbg.ask("variables", "{\"variablesReference\":" + String(handle) + "}"))
        self.dv_var_paths.append(path)

    def dv_answers(mut self):
        """Answers to the Debug window's requests."""
        var got = self.dbg.answers.copy()
        self.dbg.answers.clear()
        for m in got:
            var b = m.body()
            if m.request_seq == self.dv_scope_seq:
                self.dv_scope_seq = -1
                if not m.success:
                    self.dview.note = "(" + m.message + ")"
                    continue
                var handle = 0
                for sc in m.doc.children(m.doc.get(b, "scopes")):
                    var hint = m.doc.str(m.doc.get(sc, "presentationHint"), "")
                    if hint == "locals" or (handle == 0 and m.doc.str(m.doc.get(sc, "name"), "") == "Locals"):
                        handle = m.doc.int(m.doc.get(sc, "variablesReference"), 0)
                self.dview.scope_handle = handle
                if handle > 0:
                    self.dv_ask_children(handle, "")
                else:
                    self.dview.note = "(no variables)"
                continue
            if m.request_seq == self.dbg.data_info_seq:
                self.dbg.data_info_seq = -1
                var wname = self.dbg.data_info_name
                var waddr = self.dbg.data_info_addr
                self.dbg.data_info_name = ""
                self.dbg.data_info_addr = ""
                var data_id_idx = m.doc.get(b, "dataId")
                var data_id = m.doc.str(data_id_idx, "") if (m.success and data_id_idx >= 0 and not m.doc.is_null(data_id_idx)) else String("")
                if data_id.byte_length() == 0:
                    self.say("The debugger cannot place a hardware watchpoint on " + wname)
                else:
                    var dbi = self.bps.find_data_bp(wname, waddr)
                    if dbi >= 0:
                        self.bps.data_bps[dbi].data_id = data_id
                        self.bps.data_bps[dbi].access_type = "write"
                    else:
                        self.bps.data_bps.append(DataBreakpoint(data_id, "write", wname, waddr))
                    var dbps = self.bps.data_bps.copy()
                    self.dbg.data_bp_seq = self.dbg.set_data_breakpoints(dbps)
                    self.say("Watchpoint on " + wname + ": write")
                continue
            if m.request_seq == self.dbg.data_bp_seq:
                self.dbg.data_bp_seq = -1
                if m.success:
                    var children = m.doc.children(m.doc.get(b, "breakpoints"))
                    var nb = min(len(self.bps.data_bps), len(children))
                    for bi in range(nb):
                        var cn = children[bi]
                        var is_ver = m.doc.bool(m.doc.get(cn, "verified"), False)
                        self.bps.data_bps[bi].id = m.doc.int(m.doc.get(cn, "id"), -1)
                        self.bps.data_bps[bi].verified = BV_OK if is_ver else BV_NOT
                continue
            var handled = False
            for k in range(len(self.dv_watch_seqs)):
                if self.dv_watch_seqs[k] == m.request_seq:
                    var w = self.dv_watch_idx[k]
                    _ = self.dv_watch_seqs.pop(k)
                    _ = self.dv_watch_idx.pop(k)
                    if w < len(self.dview.watches):
                        while len(self.dview.watch_shown) <= w:
                            self.dview.watch_shown.append("")
                        self.dview.watch_shown[w] = watch_text(self.dview.watches[w], m.success, m.doc.str(m.doc.get(b, "result"), ""), m.doc.str(m.doc.get(b, "type"), ""), m.message)
                    handled = True
                    break
            if handled:
                continue
            if self.cpu_answer(m):
                continue
            if m.request_seq == self.dv_eval_seq:
                self.dv_eval_seq = -1
                self.eval_answer(m.success, m.doc.str(m.doc.get(b, "result"), ""), m.message)
                continue
            if m.request_seq == self.dv_write_seq:
                self.dv_write_seq = -1
                if m.success:
                    self.say("Value set")
                    self.dv_load_frame()        # what the program now has
                else:
                    self.say("The debugger did not set it: " + m.message)
                continue
            for k in range(len(self.dv_var_seqs)):
                if self.dv_var_seqs[k] != m.request_seq:
                    continue
                var path = self.dv_var_paths[k]
                _ = self.dv_var_seqs.pop(k)
                _ = self.dv_var_paths.pop(k)
                if not m.success:
                    if path.byte_length() == 0:
                        self.dview.note = "(" + m.message + ")"
                    break
                var kids = List[VarNode]()
                for v in m.doc.children(m.doc.get(b, "variables")):
                    kids.append(VarNode(m.doc.str(m.doc.get(v, "name"), "?"), m.doc.str(m.doc.get(v, "type"), ""), m.doc.str(m.doc.get(v, "value"), ""), m.doc.int(m.doc.get(v, "variablesReference"), 0), m.doc.str(m.doc.get(v, "memoryReference"), ""), m.doc.str(m.doc.get(v, "evaluateName"), ""), 0, ""))
                self.dview.put_children(path, kids^)
                if path.byte_length() == 0:
                    self.debug_sync_inline_locals()
                # nodes that were open at the last stop open again
                for w in self.dview.wanted():
                    self.dview.nodes[w].open = True     # (asked for once)
                    var wh = self.dview.nodes[w].handle
                    var wp = self.dview.nodes[w].path
                    self.dv_ask_children(wh, wp)
                break
        self.debugwin_show()

    def debugwin_key(mut self, k: Int, row: Int) raises:
        """Enter / Space / → / ← / = on a line of the Debug window."""
        if row < 0 or row >= len(self.dview.rows_kind):
            return
        var kind = self.dview.rows_kind[row]
        var idx = self.dview.rows_index[row]
        if kind == VK_FRAME and k != KEY_LEFT:
            if not self.dbg.active() or self.dbg.state != DS_STOPPED:
                return
            self.dview.sel = idx
            var f = self.dview.frames[idx].copy()
            if f.path.byte_length() > 0 and f.line > 0:
                var back = self.top()
                self.open_path(f.path)
                var t = self.top()
                self.wins[t].goto(f.line - 1, 0)
                var di = self.debugwin_index()
                if di >= 0 and back >= 0:
                    self.focus(di)              # the keyboard stays in the Debug window
            self.dv_load_frame()
            return
        if kind == VK_WATCH:
            if k == KEY_DELETE:
                _ = self.dview.watches.pop(idx)
                if idx < len(self.dview.watch_shown):
                    _ = self.dview.watch_shown.pop(idx)
                self.watches_save()
                self.debugwin_show()
            elif k == KEY_ENTER or k == 32:
                self.watch_dialog(idx)
            return
        if kind != VK_VAR:
            return
        var n = self.dview.nodes[idx].copy()
        if k == 119 or k == 87:
            var dbi = self.bps.find_data_bp(n.name, n.address())
            if dbi >= 0:
                var next_mode = cycle_watchpoint_access_type(self.bps.data_bps[dbi].access_type)
                if next_mode.byte_length() == 0:
                    _ = self.bps.data_bps.pop(dbi)
                    self.say("Watchpoint cleared on " + n.name)
                else:
                    self.bps.data_bps[dbi].access_type = next_mode
                    self.say("Watchpoint on " + n.name + ": " + next_mode)
                if self.dbg.can_send():
                    var dbps = self.bps.data_bps.copy()
                    self.dbg.data_bp_seq = self.dbg.set_data_breakpoints(dbps)
                self.debugwin_show()
                return
            if self.dbg.state != DS_STOPPED:
                self.say("Stop the program first to set a hardware watchpoint")
                return
            var vref = self.dview.parent_handle_of(idx)
            self.dbg.data_info_name = n.name
            self.dbg.data_info_addr = n.address()
            self.dbg.data_info_seq = self.dbg.data_breakpoint_info(n.name, vref)
            self.say("Setting watchpoint on " + n.name + "...")
            return
        if k == 61 or ((k == KEY_ENTER or k == 32) and not n.has_children()):
            self.dv_set_dialog(idx)
            return
        if not n.has_children():
            return
        if k == KEY_LEFT or ((k == KEY_ENTER or k == 32) and n.open):
            if n.open:
                self.dview.close(idx)
                self.debugwin_show()
            return
        if not n.open and self.dbg.state == DS_STOPPED:
            self.dview.mark_open(idx)
            self.dview.nodes[idx].open = True
            self.dv_ask_children(n.handle, n.path)
            self.debugwin_show()

    def dv_set_dialog(mut self, idx: Int):
        var n = self.dview.nodes[idx].copy()
        if self.dbg.state != DS_STOPPED:
            return
        if not n.settable():
            if not n.scalar():
                self.say("Only numbers and Bools can be set (" + n.name + " is a " + nice_type(n.type) + ")")
            else:
                self.say("The debugger does not say where " + n.name + " is: it cannot be set (fields of structs)")
            return
        self.dv_set = idx
        var d = Dialog(D_SETVALUE, "Set " + n.name, min(56, self.scr.w - 4), 10)
        d.lines.append(nice_type(n.type) + " at " + n.address())
        d.fields.append(Field("~N~ew value", nice_value(n.value)))
        d.fields[0].fresh = True        # typing replaces the old value
        d.buttons.append("~O~K")
        d.buttons.append("Cancel")
        self.show(d^)

    def dv_set_save(mut self, text: String):
        if self.dv_set < 0 or self.dv_set >= len(self.dview.nodes) or self.dbg.state != DS_STOPPED:
            return
        var n = self.dview.nodes[self.dv_set].copy()
        var enc = encode_value(n.type, text)
        if enc[1].byte_length() > 0:
            self.say("Not set: " + enc[1])
            return
        self.dv_write_seq = self.dbg.ask("writeMemory", "{\"memoryReference\":" + json_quote(n.address()) + ",\"data\":\"" + base64(enc[0]) + "\"}")
        self.say("Setting " + n.name + "...")

    # ======================================================= watches, Evaluate
    def watches_file(self) -> String:
        var f = self.bp_file()
        if f.byte_length() == 0:
            return ""
        return String(f[byte=0:f.byte_length() - 12]) + ".watches"

    def watches_load(mut self):
        var f = self.watches_file()
        if f.byte_length() == 0 or not path_exists(f):
            return
        self.dview.watches.clear()
        for l in read_text(f).split("\n"):
            var w = String(String(l).strip())
            if w.byte_length() > 0 and w not in self.dview.watches:
                self.dview.watches.append(w)
        self.dview.watch_shown.clear()

    def watches_save(mut self):
        var f = self.watches_file()
        if f.byte_length() == 0:
            return
        if len(self.dview.watches) == 0:
            if path_exists(f):
                _ = run_system("rm -f " + shell_quote(f))
            return
        if not path_exists(self.bp_dir):
            _ = run_system("mkdir -p " + shell_quote(self.bp_dir))
        _ = write_file(f, str_bytes("\n".join(self.dview.watches) + "\n"))

    def watch_dialog(mut self, k: Int):
        """Add watch (Ctrl-F7) or, for k >= 0, change the k-th."""
        var start = String("")
        if k >= 0 and k < len(self.dview.watches):
            start = self.dview.watches[k]
        else:
            var i = self.top_editor()
            if i >= 0:
                start = self.word_under(i)
        self.dv_watch_edit = k
        var d = Dialog(D_WATCH, "Watch" if k < 0 else "Change Watch", min(60, self.scr.w - 4), 10)
        d.lines.append("A name or a field (a, a.b) - Mojo's debugger evaluates no more.")
        d.fields.append(Field("~E~xpression", start))
        d.fields[0].fresh = True
        d.buttons.append("~O~K")
        d.buttons.append("Cancel")
        self.show(d^)

    def watch_save(mut self, expr: String):
        var k = self.dv_watch_edit
        if expr.byte_length() == 0:
            if k >= 0 and k < len(self.dview.watches):
                _ = self.dview.watches.pop(k)       # emptied: removed
                self.dview.watch_shown.clear()
        elif expr in self.dview.watches and not (k >= 0 and k < len(self.dview.watches) and self.dview.watches[k] == expr):
            self.say(expr + " is watched already")
            return
        elif k >= 0 and k < len(self.dview.watches):
            self.dview.watches[k] = expr
        elif expr in self.dview.watches:
            self.say(expr + " is watched already")
            return
        else:
            self.dview.watches.append(expr)
        self.watches_save()
        if self.debugwin_index() < 0:
            self.debugwin_toggle()
        if self.dbg.state == DS_STOPPED:
            self.dv_ask_watches()
        else:
            self.dview.watch_shown.clear()
        self.debugwin_show()

    def eval_dialog(mut self, expr: String, result: List[String]):
        """Run > Evaluate (Ctrl-F4): a name or field, or a debugger command after ':'.
        The answer is shown here and written to the Message window too."""
        var h = min(self.scr.h - 2, max(11, len(result) + 10))
        var d = Dialog(D_EVALUATE, "Evaluate", min(76, self.scr.w - 4), h)
        if len(result) == 0:
            d.lines.append("A name or field (total, p.x), or :command for the debugger (:frame variable).")
        for l in result:
            d.lines.append(l)
        var start = expr
        if start.byte_length() == 0:
            var i = self.top_editor()
            if i >= 0:
                start = self.word_under(i)
        d.fields.append(Field("~E~xpression", start))
        d.fields[0].fresh = True
        d.buttons.append("~E~valuate")
        d.buttons.append("~W~atch")
        d.buttons.append("~C~lose")
        self.show(d^)

    def eval_button(mut self, b: Int):
        var expr = String(self.dlg.field_text(0).strip())
        if b == 2 or b < 0:
            self.mode = M_NORMAL
            return
        if expr.byte_length() == 0:
            return
        if b == 1:
            self.mode = M_NORMAL
            self.dv_watch_edit = -1
            self.watch_save(expr)
            return
        if not self.dbg.active() or self.dbg.state != DS_STOPPED:
            var lines = List[String]()
            lines.append("The program has to be stopped first (a breakpoint, F4, Shift-F5 pauses).")
            self.eval_dialog(expr, lines)
            return
        var args = "{\"expression\":" + json_quote(console_command(expr)) + ",\"context\":\"repl\""
        if self.dview.sel < len(self.dview.frames):
            args += ",\"frameId\":" + String(self.dview.frames[self.dview.sel].id)
        elif self.dbg.stop_frame >= 0:
            args += ",\"frameId\":" + String(self.dbg.stop_frame)
        self.dv_eval_seq = self.dbg.ask("evaluate", args + "}")
        self.dv_eval_expr = expr
        var waiting = List[String]()
        waiting.append("(asking the debugger...)")
        self.eval_dialog(expr, waiting)

    def gpu_lane_dialog(mut self):
        """Run > GPU y/x/z thread: switch GPU block/thread or LLDB thread while stopped."""
        if not self.dbg.active() or self.dbg.state != DS_STOPPED:
            self.say("Stop the program at a breakpoint first to switch GPU thread/lane")
            return
        var d = Dialog(D_GPU_LANE, "GPU Thread / Block Focus", min(68, self.scr.w - 4), 13)
        d.lines.append("Adapter: " + self.debug_adapter)
        d.lines.append("cuda-gdb uses block/thread (x,y,z); rocgdb uses lane x; LLDB selects thread x.")
        d.fields.append(Field("~B~lock (x,y,z)", self.dbg_gpu_block))
        d.fields.append(Field("~T~hread / lane (x,y,z)", self.dbg_gpu_thread))
        d.fields[1].fresh = True
        d.buttons.append("~S~witch")
        d.buttons.append("Cancel")
        self.show(d^)

    def gpu_lane_apply(mut self, block_txt: String, thread_txt: String):
        self.dbg_gpu_block = String(block_txt.strip()) if String(block_txt.strip()).byte_length() > 0 else String("0,0,0")
        self.dbg_gpu_thread = String(thread_txt.strip()) if String(thread_txt.strip()).byte_length() > 0 else String("0,0,0")
        if not self.dbg.active() or self.dbg.state != DS_STOPPED:
            self.say("The program is no longer stopped")
            return
        var cmd = format_gpu_focus_command(self.debug_adapter, self.dbg_gpu_block, self.dbg_gpu_thread)
        var args = "{\"expression\":" + json_quote(cmd) + ",\"context\":\"repl\""
        if self.dview.sel < len(self.dview.frames):
            args += ",\"frameId\":" + String(self.dview.frames[self.dview.sel].id)
        elif self.dbg.stop_frame >= 0:
            args += ",\"frameId\":" + String(self.dbg.stop_frame)
        self.dv_eval_seq = self.dbg.ask("evaluate", args + "}")
        self.dv_eval_expr = cmd
        self.say("Debugger focus: " + cmd)

    def eval_answer(mut self, ok: Bool, result: String, message: String):
        var text = console_result(result) if ok else ("error: " + message if not message.startswith("error") else message)
        if not ok and message == "error: invalid value object":
            text = "cannot be evaluated: Mojo's debugger knows names and fields (a, a.b), not expressions"
        # the console transcript, with the program's output
        self.dbg.add_text("> " + self.dv_eval_expr + "\n" + text + ("" if text.endswith("\n") else "\n"))
        self.debug_show(self.debug_state_line())
        if self.mode == M_DIALOG and self.dlg.kind == D_EVALUATE:
            var lines = List[String]()
            for l in text.split("\n"):
                if len(lines) < max(1, self.scr.h - 12):
                    lines.append(String(l))
            while len(lines) > 0 and lines[len(lines) - 1].byte_length() == 0:
                _ = lines.pop()
            var again = self.dv_eval_expr
            self.eval_dialog(again, lines)

    # ========================================================= the CPU window
    def cpuwin_index(self) -> Int:
        for i in range(len(self.wins)):
            if self.wins[i].kind == WK_CPU:
                return i
        return -1

    def cpuwin_toggle(mut self):
        """Window > CPU (Alt-F2): a window over the editors with the machine code,
        the registers and memory; again to close it."""
        var ci = self.cpuwin_index()
        if ci >= 0:
            _ = self.wins.pop(ci)
            return
        var dh = self.desk_h()
        var mi = self.msg_index()
        if mi >= 0:
            dh = max(8, self.wins[mi].y - 1)
        var w = min(self.scr.w, 96)
        var di = self.debugwin_index()
        if di >= 0:
            w = min(w, max(40, self.wins[di].x))
        var win = Window(WK_CPU, "CPU", "", 0, 1, w, dh, self.free_number())
        self.wins.append(win^)
        self.cpuwin_show()
        if self.dbg.state == DS_STOPPED:
            self.cpu_stopped()

    def cpuwin_show(mut self):
        var ci = self.cpuwin_index()
        if ci < 0:
            return
        var text = List[Int]()
        var lines = self.cpu.lines()
        for k in range(len(lines)):
            if k > 0:
                text.append(10)
            for c in decode(lines[k]):
                text.append(c)
        var keep = self.wins[ci].cr
        var keep_top = self.wins[ci].top
        self.wins[ci].buf.load(text)
        self.wins[ci].buf.modified = False
        # the line of the instruction stopped at stays in view
        var at = -1
        for k in range(len(lines)):
            if lines[k].startswith("► "):
                at = k
        if at >= 0 and (at < keep_top or at >= keep_top + self.wins[ci].rows()):
            keep_top = max(0, at - 3)
        self.wins[ci].cr = max(0, min(keep, self.wins[ci].buf.count() - 1))
        self.wins[ci].top = max(0, min(keep_top, self.wins[ci].buf.count() - 1))

    def cpu_running(mut self):
        self.cpu.code.clear()
        self.cpu.ip = ""
        self.cpu.note = "(the program is running)"
        self.cpu_dis_seq = -1
        self.cpu_scope_seq = -1
        self.cpu_set_seq = -1
        self.cpu_reg_seq = -1
        self.cpu_vreg_seq = -1
        self.cpu_mem_seq = -1
        self.cpuwin_show()

    def cpu_ask_disasm(mut self):
        if self.cpu.ip.byte_length() > 0:
            self.cpu_dis_seq = self.dbg.ask("disassemble", "{\"memoryReference\":" + json_quote(self.cpu.ip) + ",\"instructionOffset\":-24,\"instructionCount\":96,\"resolveSymbols\":true}")

    def cpu_stopped(mut self):
        """Ask for what the CPU window shows (only while it is open)."""
        if self.cpuwin_index() < 0 or self.dbg.state != DS_STOPPED:
            return
        self.cpu.ip = self.dbg.stop_ip
        self.cpu_ask_disasm()
        if len(self.dbg.frames) > 0:
            self.cpu_scope_seq = self.dbg.ask("scopes", "{\"frameId\":" + String(self.dbg.frames[0].id) + "}")
        self.cpu_read_memory()
        self.cpu.note = "(asking the debugger...)"
        self.cpuwin_show()

    def cpu_read_memory(mut self):
        if self.cpu.mem_address < 0 or self.dbg.state != DS_STOPPED:
            return
        self.cpu_mem_seq = self.dbg.ask("readMemory", "{\"memoryReference\":" + json_quote(hex_text(self.cpu.mem_address)) + ",\"count\":128}")

    def cpu_answer(mut self, m: DapMessage) -> Bool:
        """An answer for the CPU window (False: not one of its requests)."""
        var b = m.body()
        if m.request_seq == self.cpu_dis_seq:
            self.cpu_dis_seq = -1
            self.cpu.code.clear()
            self.cpu.src_map.clear()
            if not m.success:
                self.cpu.note = "(no disassembly: " + m.message + ")"
            var cached_paths = List[String]()
            var cached_texts = List[String]()
            for ins in m.doc.children(m.doc.get(b, "instructions")):
                var ipath = m.doc.str(m.doc.path(ins, "location/path"), "")
                var iline = m.doc.int(m.doc.get(ins, "line"), 0)
                self.cpu.code.append(Instr(m.doc.str(m.doc.get(ins, "address"), ""), m.doc.str(m.doc.get(ins, "instruction"), ""), ipath, iline))
                if ipath.byte_length() > 0 and iline > 0 and path_exists(ipath):
                    var key = ipath + ":" + String(iline)
                    if self.cpu.src_map.get(key).byte_length() == 0:
                        var ftxt = String("")
                        var found_cached = False
                        for ci in range(len(cached_paths)):
                            if cached_paths[ci] == ipath:
                                ftxt = cached_texts[ci]
                                found_cached = True
                                break
                        if not found_cached:
                            ftxt = read_text(ipath)
                            cached_paths.append(ipath)
                            cached_texts.append(ftxt)
                        var flines = ftxt.split("\n")
                        if iline - 1 < len(flines):
                            self.cpu.src_map.put(key, String(String(flines[iline - 1]).strip()))
        elif m.request_seq == self.dbg.ibp_seq:
            self.dbg.ibp_seq = -1
            if m.success:
                var bnodes = m.doc.children(m.doc.get(b, "breakpoints"))
                var nb = min(len(self.cpu.ibps), len(bnodes))
                for bi in range(nb):
                    self.cpu.ibps[bi].verified = m.doc.bool(m.doc.get(bnodes[bi], "verified"), False)
                    self.cpu.ibps[bi].id = m.doc.int(m.doc.get(bnodes[bi], "id"), -1)
        elif m.request_seq == self.cpu_scope_seq:
            self.cpu_scope_seq = -1
            for sc in m.doc.children(m.doc.get(b, "scopes")):
                if m.doc.str(m.doc.get(sc, "name"), "") == "Registers" or m.doc.str(m.doc.get(sc, "presentationHint"), "") == "registers":
                    self.cpu_set_seq = self.dbg.ask("variables", "{\"variablesReference\":" + String(m.doc.int(m.doc.get(sc, "variablesReference"), 0)) + "}")
                    break
        elif m.request_seq == self.cpu_set_seq:
            self.cpu_set_seq = -1
            var sets = m.doc.children(m.doc.get(b, "variables"))
            var gen_found = False
            var vec_found = False
            for s in sets:
                var name = m.doc.str(m.doc.get(s, "name"), "")
                var vref = m.doc.int(m.doc.get(s, "variablesReference"), 0)
                if not gen_found and (name.find("General") >= 0 or s == sets[0]):
                    self.cpu_reg_seq = self.dbg.ask("variables", "{\"variablesReference\":" + String(vref) + "}")
                    if name.find("General") >= 0:
                        gen_found = True
                if not vec_found and name.find("General") < 0 and (name.find("Vector") >= 0 or name.find("SIMD") >= 0 or name.find("Floating") >= 0):
                    self.cpu_vreg_seq = self.dbg.ask("variables", "{\"variablesReference\":" + String(vref) + "}")
                    vec_found = True
        elif m.request_seq == self.cpu_reg_seq:
            self.cpu_reg_seq = -1
            var names = List[String]()
            var values = List[String]()
            for v in m.doc.children(m.doc.get(b, "variables")):
                names.append(m.doc.str(m.doc.get(v, "name"), ""))
                values.append(m.doc.str(m.doc.get(v, "value"), ""))
            self.cpu.set_regs(names, values)
            if self.cpu_vreg_seq < 0 and len(self.cpu.vregs) == 0:
                self.cpu.set_vregs(names, values)
            if self.cpu.mem_address < 0:
                # memory starts where the stack is
                var sp = self.cpu.register("sp")
                if sp < 0:
                    sp = self.cpu.register("rsp")
                if sp >= 0:
                    self.cpu.mem_address = sp
                    self.cpu_read_memory()
        elif m.request_seq == self.cpu_vreg_seq:
            self.cpu_vreg_seq = -1
            var vnames = List[String]()
            var vvalues = List[String]()
            for v in m.doc.children(m.doc.get(b, "variables")):
                vnames.append(m.doc.str(m.doc.get(v, "name"), ""))
                vvalues.append(m.doc.str(m.doc.get(v, "value"), ""))
            self.cpu.set_vregs(vnames, vvalues)
        elif m.request_seq == self.cpu_mem_seq:
            self.cpu_mem_seq = -1
            self.cpu.mem = base64_decode(m.doc.str(m.doc.get(b, "data"), ""))
            self.cpu.mem_known = len(self.cpu.mem)
            var lost = m.doc.int(m.doc.get(b, "unreadableBytes"), 0)
            for _ in range(lost):
                self.cpu.mem.append(0)
            if not m.success:
                self.say("Memory cannot be read there: " + m.message)
        elif m.request_seq == self.cpu_addr_seq:
            self.cpu_addr_seq = -1
            var where = m.doc.str(m.doc.get(b, "memoryReference"), "")
            if m.success and address_value(where) >= 0:
                self.cpu.mem_address = address_value(where)
                self.cpu_read_memory()
            else:
                self.say("The debugger does not say where that is" + ((": " + m.message) if not m.success else String("")))
        else:
            return False
        self.cpuwin_show()
        return True

    def cpuwin_key(mut self, k: Int) raises:
        """G: memory at an address or a variable; + / - / ] / [: next / previous 128 bytes;
        V: SIMD lanes; B: toggle instruction breakpoint; Enter: jump to source line."""
        if k == 118 or k == 86:
            var m = self.cpu.cycle_simd_mode()
            self.cpuwin_show()
            self.say("SIMD lanes: " + m)
            return
        if k == 43 or k == 45 or k == 93 or k == 91:
            if self.cpu.mem_address < 0:
                return
            var forward = k == 43 or k == 93
            self.cpu.mem_address = max(0, self.cpu.mem_address + (128 if forward else -128))
            self.cpu_read_memory()
            self.cpuwin_show()
            return
        if k == 98 or k == 66:
            var ci = self.cpuwin_index()
            if ci < 0:
                return
            var idx = self.cpu.instr_at_row(self.wins[ci].cr)
            if idx < 0 or idx >= len(self.cpu.code):
                self.say("Move cursor to an instruction line to toggle an instruction breakpoint")
                return
            var addr = String(self.cpu.code[idx].address)
            var added = toggle_instruction_breakpoint(self.cpu.ibps, addr)
            if self.dbg.can_send():
                var ibps_copy = self.cpu.ibps.copy()
                self.dbg.ibp_seq = self.dbg.set_instruction_breakpoints(ibps_copy)
            self.cpuwin_show()
            self.say(("Instruction breakpoint set at " if added else "Instruction breakpoint removed at ") + addr)
            return
        if k == KEY_ENTER:
            var ci = self.cpuwin_index()
            if ci < 0:
                return
            var idx = self.cpu.instr_at_row(self.wins[ci].cr)
            if idx < 0 or idx >= len(self.cpu.code):
                return
            var jt = handle_enter_key_on_instruction(self.cpu.code[idx])
            if jt.ok and path_exists(jt.path):
                self.jump_mark()
                self.open_path(jt.path)
                var ed = self.top()
                self.wins[ed].goto(jt.editor_row, 0)
            else:
                self.say(jt.error_message if jt.error_message.byte_length() > 0 else String("No source line for this instruction"))
            return
        if k != 103 and k != 71:
            return
        var d = Dialog(D_MEMADDR, "Memory At", min(60, self.scr.w - 4), 10)
        d.lines.append("An address (0x...) or the name of a variable (total, p).")
        d.fields.append(Field("~A~ddress", hex_text(self.cpu.mem_address) if self.cpu.mem_address >= 0 else String("")))
        d.fields[0].fresh = True
        d.buttons.append("~O~K")
        d.buttons.append("Cancel")
        self.show(d^)

    def cpu_goto(mut self, text: String):
        if text.byte_length() == 0:
            return
        var a = address_value(text)
        if a >= 0:
            self.cpu.mem_address = a
            self.cpu_read_memory()
            self.cpuwin_show()
            return
        if self.dbg.state != DS_STOPPED:
            self.say("The program has to be stopped to find " + text)
            return
        var args = "{\"expression\":" + json_quote(text) + ",\"context\":\"watch\""
        if len(self.dbg.frames) > 0:
            args += ",\"frameId\":" + String(self.dbg.frames[min(self.dview.sel, len(self.dbg.frames) - 1)].id)
        self.cpu_addr_seq = self.dbg.ask("evaluate", args + "}")
