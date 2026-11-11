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
from window import WK_DEBUG


__extension App:
    def debug_adapter_command(mut self) -> String:
        """How the debug adapter is started ('' if it is not installed). The setting
        names the program; a setting with arguments is a whole command, used as it is."""
        var a = String(self.debug_adapter.strip())
        if a.find(" ") >= 0:
            return a
        var path = a if a.find("/") >= 0 else which(a)
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
        var path = self.wins[i].path
        var dir = dirname(path)
        var exe = join_path(dir, "build/" + stem(path) + ".debug")
        var cmd = "cd " + shell_quote(dir) + " && mkdir -p build && exec " + self.compiler_cmd() + " build -g -O0" + self.include_flags() + " " + shell_quote(path) + " -o " + shell_quote(exe) + " 2>&1"
        if self.start_job(JOB_DEBUG, cmd, path, exe):
            self.panel_write(PG_MESSAGE)
            _ = self.fill_messages(self.job_header(), List[UInt8](), "Compiling...")
            self.say("Building " + basename(path) + " for debugging - keep editing, " + self.reg.key_label(CM_CANCEL) + " cancels")

    def finish_debug_build(mut self, status: Int, secs: Float64) raises:
        if status != 0 or self.job.cancelled:
            self.finish_build(status, secs)         # the messages, as for any build
            return
        self.panel_write(PG_MESSAGE)
        _ = self.fill_messages(self.job_header(), self.job.data.copy(), "Starting the debugger...")
        var exe = self.job.exe
        var source = self.job.path
        self.debug_launch(exe, source)

    def debug_launch(mut self, exe: String, source: String) raises:
        var log = (dirname(self.log_path) + "/dap.log") if self.log_path.byte_length() > 0 else String("/dev/null")
        self.dbg_source = source
        var cmd = self.debug_adapter_command()
        var args = split_arguments(self.run_args)
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
        if not self.dbg.begin(cmd, exe, dirname(source), args, log):
            var why = self.dbg.error
            self.info("Debug", why)
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
                self.say("Debugging " + basename(self.dbg_source) + " - " + self.reg.key_label(CM_CANCEL) + " ends it")
            elif e == DE_STOPPED:
                self.say("Stopped: " + self.dbg.stop_text)
                self.debug_temp_clear()
            elif e == DE_LOCATED:
                self.debug_show_stop()
                self.dv_stopped()
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

    def debug_step(mut self, kind: String) raises:
        """F7 / F8 / Shift-F8 while a program is stopped."""
        if not self.dbg.active():
            self.say("No program is being debugged - " + self.reg.key_label(CM_DEBUG) + " starts one, " + self.reg.key_label(CM_RUN_CURSOR) + " runs to the cursor")
            return
        if self.dbg.state != DS_STOPPED:
            self.say("The program is running - " + self.reg.key_label(CM_PAUSE) + " pauses it")
            return
        if self.dbg.step(kind):
            self.debug_mark_clear()

    def debug_pause(mut self):
        if self.dbg.state != DS_RUNNING:
            self.say("No program is running under the debugger")
            return
        if self.dbg.pause():
            self.say("Pausing...")

    def debug_run_to_cursor(mut self) raises:
        """F4: run until the cursor's line - a breakpoint there for one stop. Without
        a session, debugging starts and runs to it."""
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
        self.dbg.finish()
        self.debug_mark_clear()
        self.dv_running()
        self.dview.note = "(no program is being debugged)"
        self.debugwin_show()
        self.dbg_temp_path = ""
        self.dbg_temp_line = 0
        self.bps.forget_debugger()
        self.bp_stamp += 1
        var footer: String
        if failed.byte_length() > 0:
            footer = failed
        elif by_user:
            footer = "Debugging ended - the program was stopped"
        elif self.dbg.exited:
            footer = "Program exited with status " + String(self.dbg.exit_code)
        else:
            footer = "The debugger ended"
        self.debug_show(footer)
        self.say(footer)
        if failed.byte_length() > 0 and self.mode == M_NORMAL:
            # what the debugger said last usually explains it
            var tail = String("")
            if len(self.dbg.console) > 0:
                tail = " - " + String(self.dbg.console[len(self.dbg.console) - 1].strip())
            self.info("Debug", failed + tail)

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
        self.debugwin_show()

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
                if handle > 0:
                    self.dv_ask_children(handle, "")
                else:
                    self.dview.note = "(no variables)"
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
        if kind != VK_VAR:
            return
        var n = self.dview.nodes[idx].copy()
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
