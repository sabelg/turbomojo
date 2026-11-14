"""The Outline window: the symbols of the file being edited, as a tree to jump from."""
from responsive import explorer_width, outline_width, docpane_width
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
from app_layout import *
from app_explorer import *
from app_docs import *
from app_debug import *
from app_terminal import *
from app_tests import *
from outline import *
from symindex import *
from docs import *
from docpane import infer_receiver_owner
from pydocs import dotted_at
from project import *
from runconfig import *
from trust import *
from toml import toml_parse
from watch import file_sig
from app_input import *
from app_mouse import *
from app_draw import *
from app_exercises import *
from app_pkginstall import *
from app_newproject import *


comptime SYMIDX_SLICE_MS = 8          # work per pass of the event loop
comptime SYMIDX_FIRST_MS = 40         # ... and when the dialog opens
comptime DOCS_MAX_FILES = 4            # at most this many files are documented for one name
comptime SYMIDX_FRESH_MS = 20000      # an index older than this is rebuilt on the next use


__extension App:
    def outline_toggle(mut self):
        """Window > Outline: show the outline window at the right edge, or close it."""
        var oi = self.outline_index()
        if oi >= 0:
            var x = self.wins[oi].x
            _ = self.wins.pop(oi)
            # the editors that made room get it back
            for i in range(len(self.wins)):
                if self.wins[i].kind == WK_EDITOR and self.wins[i].x + self.wins[i].w == x:
                    self.wins[i].w = self.scr.w - self.wins[i].x
            return
        var w = outline_width(self.scr.w)
        var x = self.scr.w - w
        var h = self.desk_h()
        var mi = self.msg_index()
        if mi >= 0:
            h = max(6, self.wins[mi].y - 1)
        var win = Window(WK_OUTLINE, "Outline", "", x, 1, w, h, self.free_number())
        for i in range(len(self.wins)):
            if self.wins[i].kind == WK_EDITOR and self.wins[i].x + self.wins[i].w > x and x - self.wins[i].x >= 20:
                self.wins[i].w = x - self.wins[i].x
        self.wins.insert(0, win^)
        self.outline_key = ""
        self.outline_version = -1
        self.outline_asked_key = ""
        self.outline_tick(now_ns())

    def outline_show(mut self):
        """Put self.outline_items into the Outline window, one per line."""
        var oi = self.outline_index()
        if oi < 0:
            return
        var text = List[Int]()
        for k in range(len(self.outline_items)):
            if k > 0:
                text.append(10)
            for c in decode(outline_line(self.outline_items[k])):
                text.append(c)
        if len(self.outline_items) == 0:
            text = decode("(no symbols)")
        var keep = self.wins[oi].cr
        var keep_top = self.wins[oi].top
        self.wins[oi].buf.load(text)
        self.wins[oi].buf.modified = False
        self.wins[oi].cr = max(0, min(keep, self.wins[oi].buf.count() - 1))
        self.wins[oi].top = max(0, min(keep_top, self.wins[oi].buf.count() - 1))

    def outline_tick(mut self, now: Int):
        """Keep the Outline window in step with the editor in front: a scan of the text
        at once, the language server's answer when it comes; the line of the symbol the
        cursor is in is marked."""
        var oi = self.outline_index()
        if oi < 0:
            return
        var ti = self.top_editor()
        if ti < 0:
            if self.outline_key.byte_length() > 0 or self.outline_version != -2:
                self.outline_items.clear()
                self.outline_key = ""
                self.outline_version = -2
                self.outline_show()
            return
        var key = self.wins[ti].path if self.wins[ti].path.byte_length() > 0 else "untitled:" + self.wins[ti].title
        var v = self.wins[ti].buf.version
        var server = self.lsp.state == LSP_READY and self.wins[ti].path.byte_length() > 0 and self.lsp.find_doc(path_to_uri(self.wins[ti].path)) >= 0
        if key != self.outline_key or v != self.outline_version:
            # while typing with a server at hand its (slightly old) list stays until the
            # new answer comes, so the list does not jump between the two sources
            if key != self.outline_key or not (server and self.outline_from_server):
                self.outline_items = scan_outline(self.wins[ti].buf)
                self.outline_from_server = False
                self.outline_show()
            self.outline_key = key
            self.outline_version = v
        if self.outline_req_id >= 0 and now - self.outline_req_ns > 5000000000:
            self.outline_req_id = -1            # never answered
        if server and self.outline_req_id < 0 and self.wins[ti].lsp_sent_version == v and (self.outline_asked_key != key or self.outline_asked_version != v):
            var id = self.lsp.request_symbols(path_to_uri(self.wins[ti].path), now)
            if id >= 0:
                self.outline_req_id = id
                self.outline_req_ns = now
                self.outline_asked_key = key
                self.outline_asked_version = v
        oi = self.outline_index()
        if self.top() != oi:
            var cur = outline_current(self.outline_items, self.wins[ti].cr)
            if cur >= 0 and self.wins[oi].cr != cur:
                self.wins[oi].cr = cur
                self.wins[oi].follow = True

    def outline_arrived(mut self, m: RpcMessage):
        self.outline_req_id = -1
        var oi = self.outline_index()
        var ti = self.top_editor()
        if oi < 0 or ti < 0 or self.wins[ti].path != self.outline_asked_key or self.wins[ti].buf.version != self.outline_asked_version:
            return                              # for other text: outline_tick asks again
        if m.kind == RPC_ERROR:
            if self.outline_from_server:
                self.outline_from_server = False
                self.outline_version = -1       # back to the scan
            return
        var items = parse_symbols(m.doc, m.result())
        if len(items) == 0:
            # nothing from the server (or it does not do this): the scan stays
            if self.outline_from_server:
                self.outline_from_server = False
                self.outline_version = -1
            return
        var count = self.wins[ti].buf.count()
        var kept = List[OutlineItem]()
        for it in items:
            if it.row < count:
                kept.append(OutlineItem(it.name, it.kind, it.row, utf16_to_col(self.wins[ti].buf.line(it.row), it.col), it.depth))
        self.outline_items = kept^
        self.outline_from_server = True
        self.outline_show()

    def outline_go(mut self, k: Int) raises:
        """Enter on line k of the Outline window: go to that symbol in the editor."""
        if k < 0 or k >= len(self.outline_items):
            return
        var ti = self.top_editor()
        if ti < 0:
            return
        var it = self.outline_items[k].copy()
        self.focus(ti)
        self.jump_mark()
        var t = self.top()
        self.wins[t].goto(it.row, it.col)
        self.say(it.name)

    # ============================================ symbols of the whole project
    def symidx_root(self) -> String:
        if self.project_dir.byte_length() > 0:
            return self.project_dir
        var px = self.pixi_dir()
        return px if px.byte_length() > 0 else String(self.cwd)

    def pixi_dir(self) -> String:
        """The folder of the project's pixi.toml: at or above where the IDE runs
        ('' if there is none)."""
        if self.pixi_for == self.cwd:
            return self.pixi_found
        return find_up(self.cwd, "pixi.toml")

    def pixi_locate(mut self) -> String:
        """pixi_dir(), looked up once per folder."""
        if self.pixi_for != self.cwd:
            self.pixi_found = find_up(self.cwd, "pixi.toml")
            self.pixi_for = self.cwd
        return self.pixi_found

    # ============================================================ pixi tasks
    def tasks_dialog(mut self):
        """Run > Pixi tasks: the tasks of the project's pixi.toml in a list; Enter runs
        the chosen one with `pixi run`, its output goes to the Message page."""
        var dir = self.pixi_locate()
        if dir.byte_length() == 0:
            self.say("No pixi.toml in this folder or above it")
            return
        self.tasks = parse_pixi_tasks(read_text(join_path(dir, "pixi.toml")))
        if len(self.tasks) == 0:
            self.say("The pixi.toml in " + dir + " defines no tasks")
            return
        var items = List[String]()
        var data = List[Int]()
        var keys = List[String]()
        var first = 0
        for k in range(len(self.tasks)):
            var what = self.tasks[k].cmd
            if len(self.tasks[k].depends) > 0:
                var deps = String("")
                for dname in self.tasks[k].depends:
                    deps += (", " if deps.byte_length() > 0 else "") + dname
                what = (what + "   " if what.byte_length() > 0 else String("")) + "(after " + deps + ")"
            if self.tasks[k].description.byte_length() > 0:
                what = self.tasks[k].description
            var name = self.tasks[k].name
            if self.tasks[k].feature.byte_length() > 0:
                name += " [" + self.tasks[k].feature + "]"
            items.append(pad_right(name, 18) + " " + what)
            keys.append(self.tasks[k].name)
            data.append(k)
            if self.tasks[k].name == self.last_task:
                first = k
        var name = pixi_project_name(read_text(join_path(dir, "pixi.toml")))
        var d = Dialog(D_TASKS, "Pixi Tasks" + ((" - " + name) if name.byte_length() > 0 else String("")), min(76, self.scr.w - 4), min(20, max(9, len(items) + 7)))
        d.fields.append(Field("~T~ask", ""))
        d.list_filter = True
        d.keys = keys^
        d.set_items(items^, data^)
        d.list_sel = first                  # the task run last is the one under Enter
        d.buttons.append("~R~un")
        d.buttons.append("~C~ancel")
        self.show(d^)

    def run_task(mut self, name: String):
        if self.job_busy():
            return
        var dir = self.pixi_locate()
        if dir.byte_length() == 0:
            self.say("No pixi.toml in this folder or above it")
            return
        var unsaved = 0
        for i in range(len(self.wins)):
            if self.wins[i].kind == WK_EDITOR and self.wins[i].buf.modified and self.wins[i].path.byte_length() > 0:
                unsaved += 1
        var cmd = "cd " + shell_quote(dir) + " && exec " + self.pixi_cmd + " run " + shell_quote(name) + " 2>&1 </dev/null"
        if self.start_job(JOB_TASK, cmd, dir, name):
            self.last_task = name
            self.task_output("Running...")
            self.say("Task " + name + " is running - Ctrl-F2 cancels it" + ((" (" + count_of(unsaved, "file") + " not saved)") if unsaved > 0 else String("")))

    def task_output(mut self, footer: String):
        """The running (or finished) task's output on the Message page."""
        self.panel_write(PG_MESSAGE)
        self.msg_base = self.job.path
        _ = self.fill_messages(self.job_heading(), self.job.data.copy(), footer)
        self.msg_base = ""

    def finish_task(mut self, status: Int, secs: Float64):
        var name = self.job.exe
        var tstr = String(Int(secs * 10) // 10) + "." + String(Int(secs * 10) % 10) + " s"
        var ok = status == 0 and not self.job.cancelled
        if name == "newproject:install":
            self.np_installed(ok, self.job.cancelled, tstr)
            return
        if name == "pkg:search":
            self.pkg_searched(ok, bytes_to_str(self.job.data))
            return
        if name == "pkg:add":
            self.pkg_added(ok, self.job.cancelled, tstr)
            return
        if name == "puzzle:install":
            self.puzzle_env_installed(ok, self.job.cancelled, tstr)
            return
        if name.startswith("puzzle:"):
            self.task_output("Puzzle checked in " + tstr)
            self.puzzle_finished(String(name[byte=7:]), ok, bytes_to_str(self.job.data))
            return
        if name.startswith("exercise:"):
            self.task_output("Exercise checked in " + tstr)
            self.ex_finished(String(name[byte=9:]), ok, bytes_to_str(self.job.data))
            return
        var result = String("Task " + name + " finished in " + tstr)
        if self.job.cancelled:
            result = "Task " + name + " cancelled after " + tstr
        elif not ok:
            result = "Task " + name + " failed (exit " + String(status >> 8) + ") after " + tstr
        self.task_output(result)
        var mi = self.msg_index()
        if mi >= 0:
            # the end of the output is what one wants to see
            self.wins[mi].cr = self.wins[mi].buf.count() - 1
            self.wins[mi].follow = True
            if len(self.errs) > 0:
                self.err_idx = 0
                self.wins[mi].cr = self.errs[0].msg_line
            if not ok and not self.job.cancelled and self.mode == M_NORMAL and self.waited_for_job():
                self.focus(mi)
        self.notify_as("task", NL_DONE if ok else (NL_INFO if self.job.cancelled else NL_ERROR), "Task " + name, result, True)
        self.say(result)

    def symidx_tick(mut self):
        """One slice of the index pass; called on every pass of the event loop. When a
        pass finishes while the dialog is open, its list is completed."""
        if not self.symidx.building:
            return
        self.symidx.step(SYMIDX_SLICE_MS)
        if not self.symidx.building:
            if self.mode == M_DIALOG and (self.dlg.kind == D_WSYMBOL or (self.dlg.kind == D_PALETTE and self.quick_mode == 3)) and self.ws_building:
                self.wsymbol_fill()
                self.say(self.symidx.summary())

    def wsymbol_items(mut self) -> List[IndexedSymbol]:
        """The index as it stands, with open files taken from their windows (they may
        have unsaved changes) and files of this pass not yet reached left as they were."""
        var all = List[IndexedSymbol]()
        var open_paths = List[String]()
        for i in range(len(self.wins)):
            if self.wins[i].kind == WK_EDITOR and is_mojo_file(self.wins[i].path) and not self.wins[i].buf.large:
                open_paths.append(self.wins[i].path)
                self.symidx.add_items(self.wins[i].path, scan_outline(self.wins[i].buf), all)
        var source = self.symidx.syms.copy()
        if not self.symidx.built:
            source = self.symidx.fresh.copy()       # the first pass: what it has so far
        for s in source:
            if not (s.path in open_paths):
                all.append(s.copy())
        return all^

    def wsymbol_fill(mut self):
        """(Re)fill the open dialog's list, keeping what was typed."""
        self.ws_list = self.wsymbol_items()
        self.ws_building = self.symidx.building
        var items = List[String]()
        var data = List[Int]()
        var keys = List[String]()           # typing matches names, not file paths
        var prefix = self.symidx_root() + "/"
        for k in range(len(self.ws_list)):
            var shown = self.ws_list[k].path
            if shown.startswith(prefix):
                shown = slice_str(decode(shown), cp_len(prefix), cp_len(shown))
            var name = outline_tag(self.ws_list[k].kind) + " " + self.ws_list[k].name
            if self.ws_list[k].owner.byte_length() > 0:
                name += "  (" + self.ws_list[k].owner + ")"
            items.append(pad_right(name, 34) + " " + shown + ":" + String(self.ws_list[k].row + 1))
            data.append(k)
            keys.append(self.ws_list[k].name + " " + self.ws_list[k].owner)
        self.dlg.keys = keys^
        self.dlg.set_items(items^, data^)

    def wsymbol_dialog(mut self):
        """Search > Go to symbol in project: a list of every def / struct / trait of the
        project's Mojo files, narrowed by typing. The index is (re)built in the
        background; the list fills in when it is ready."""
        var now = now_ns()
        if not self.symidx.building and (not self.symidx.built or self.symidx.root != self.symidx_root() or now - self.symidx.built_ns > SYMIDX_FRESH_MS * 1000000):
            self.symidx.start(self.symidx_root())
            self.symidx.step(SYMIDX_FIRST_MS)       # small projects are done at once
        var d = Dialog(D_WSYMBOL, "Go to Symbol in Project", min(76, self.scr.w - 4), min(22, self.desk_h()))
        d.fields.append(Field("~S~ymbol", ""))
        d.list_filter = True
        d.buttons.append("~G~o")
        d.buttons.append("~C~ancel")
        self.show(d^)
        self.wsymbol_fill()
        if self.symidx.building:
            self.say("Reading the project's files...")
        else:
            self.say(self.symidx.summary())

    def wsymbol_go(mut self, k: Int) raises:
        if k < 0 or k >= len(self.dlg.item_data):
            return
        var idx = self.dlg.item_data[k]
        if idx < 0 or idx >= len(self.ws_list):
            return
        var s = self.ws_list[idx].copy()
        if not (self.find_editor(s.path) >= 0 or path_exists(s.path)):
            self.say(basename(s.path) + " is no longer there")
            return
        self.jump_mark()
        self.open_path(s.path)
        var t = self.top()
        if self.wins[t].kind == WK_EDITOR and self.wins[t].path == s.path:
            self.wins[t].goto(s.row, s.col)
            self.say(s.name)

    # ====================================================== documentation
    def docs_files_for(mut self, name: String, wait: Bool) -> List[String]:
        """The files that define `name`: of the project (from the symbol index) and of
        the documentation folders. With `wait` the indexes are completed first; without
        it only what is already known is used (and missing indexes are started)."""
        var files = List[String]()
        if not self.symidx.built and not self.symidx.building:
            self.symidx.start(self.symidx_root())
        if wait:
            while self.symidx.building:
                self.symidx.step(50)
        for i in range(len(self.wins)):
            # open files are looked at as they are now
            if self.wins[i].kind == WK_EDITOR and is_mojo_file(self.wins[i].path) and not self.wins[i].buf.large:
                for it in scan_outline(self.wins[i].buf):
                    if it.name == name and not (self.wins[i].path in files):
                        files.append(self.wins[i].path)
        for s in self.symidx.syms:
            if s.name == name and not (s.path in files):
                files.append(s.path)
        for k in range(len(self.doc_idx)):
            if not self.doc_idx[k].built and not self.doc_idx[k].building:
                self.doc_idx[k].start(self.docs_paths[k])
            if wait:
                while self.doc_idx[k].building:
                    self.doc_idx[k].step(50)
            for s in self.doc_idx[k].syms:
                if s.name == name and not (s.path in files):
                    files.append(s.path)
        return files^

    def docs_of_file(mut self, path: String) -> List[DocEntry]:
        """What `mojo doc` says about a file; run once per version of the file on disk."""
        var sig = file_sig(path)
        if not sig.exists or not self.trust_ok():
            return List[DocEntry]()         # `mojo doc` compiles the file: not in a folder that is not trusted
        var stamp = sig.mtime_s * 1000000000 + sig.mtime_ns
        for k in range(len(self.doc_files)):
            if self.doc_files[k] == path:
                if self.doc_sizes[k] == sig.size and self.doc_times[k] == stamp:
                    return self.doc_entries[k].copy()
                _ = self.doc_files.pop(k)
                _ = self.doc_sizes.pop(k)
                _ = self.doc_times.pop(k)
                _ = self.doc_entries.pop(k)
                break
        var entries = List[DocEntry]()
        var limit = String("timeout 20 ") if which("timeout").byte_length() > 0 else String("")
        var res = run_capture("cd " + shell_quote(dirname(path)) + " && " + limit + self.compiler_cmd() + " doc" + self.include_flags() + " " + shell_quote(path) + " 2>/dev/null")
        if res.status == 0 and len(res.out) > 0:
            try:
                var doc = json_parse(bytes_to_str(res.out))
                entries = parse_mojo_doc(doc)
            except e:
                entries = List[DocEntry]()
        self.doc_files.append(path)
        self.doc_sizes.append(sig.size)
        self.doc_times.append(stamp)
        self.doc_entries.append(entries.copy())
        return entries^

    def docs_at_cursor(mut self, asked: Bool) -> Bool:
        """Show the documentation of the name at the cursor in a window. `asked`
        (Help > Topic search): look everywhere and say so if there is nothing - with
        the language server's description as a last resort. Otherwise (F1) only what
        can be found at once; False means the caller shows the general help."""
        var ai = self.active_editor()
        if ai < 0 or self.mode != M_NORMAL:
            if asked:
                self.say("Put the cursor on a name first")
            return False
        var name = self.word_under(ai)
        if name.byte_length() == 0 or (decode(name)[0] >= 48 and decode(name)[0] <= 57):
            if asked:
                self.say("Put the cursor on a name first")
            return False
        var py = self.docs_python(ai)           # a name of a Python library the file imports (P11-14)
        if py != 0:
            return py > 0 or asked
        var files = self.docs_files_for(name, asked)
        var md = String("")
        var n = 0
        for f in files:
            if n >= DOCS_MAX_FILES:
                break
            n += 1
            var part = docs_for(self.docs_of_file(f), name)
            if part.byte_length() > 0:
                md += ("\n\n---\n\n" if md.byte_length() > 0 else "") + part
        if md.byte_length() == 0:
            # not in the project: a name of the standard library, if its reference is downloaded
            var owner_hint = String("")
            var chain = dotted_at(self.wins[ai].buf.line(self.wins[ai].cr), self.wins[ai].cc)
            if chain.find(".") >= 0:
                owner_hint = infer_receiver_owner(to_str(self.wins[ai].buf.all_text()), self.wins[ai].cr, chain)
            if self.docs_api_lookup(name, asked, owner_hint):
                return True
            if not asked:
                return False
            if self.lsp.state == LSP_READY and self.lsp.table.hover and self.wins[ai].path.byte_length() > 0 and self.lsp.find_doc(path_to_uri(self.wins[ai].path)) >= 0:
                self.hover_command()            # what the language server knows
                return True
            self.say("No documentation found for " + name)
            return False
        self.hover_lines = md_render(md, max(20, min(76, self.scr.w - 6)), self.hl)
        if len(self.hover_lines) == 0:
            return False
        self.hover_scroll = 0
        self.mode = M_HOVER
        self.say("")
        return True

    # ==================================================== run configurations
    def project_file(self) -> String:
        """The project's settings file (it may not exist yet)."""
        return join_path(self.symidx_root(), ".turbomojo.toml")

    def run_configs_load(mut self):
        """Read the configurations and which one is active from the project file."""
        var doc = toml_parse(read_text(self.project_file()))
        self.run_cfgs = load_run_configs(doc)
        var active = active_run_config(doc)
        self.run_active = ""
        for c in self.run_cfgs:
            if c.name == active:
                self.run_active = active

    def run_core(mut self, test: Bool) -> String:
        """The command Run (or Test) executes, without the screen handling around it."""
        var te = self.top_editor()
        var current = self.wins[te].path if te >= 0 else String("")
        var cfg = RunConfig("")
        cfg.args = self.run_args
        if not test:
            self.run_configs_load()
            for c in self.run_cfgs:
                if c.name == self.run_active:
                    cfg = c.copy()
        var core = run_core_command(cfg, self.symidx_root(), current, self.mojo_for(current), self.include_flags())
        if core.byte_length() == 0:
            return core
        return self.with_env(current, core)      # (in a project's environment: what pixi added is found)

    def run_configs_dialog(mut self):
        """Run > Run configurations: choose the one Run uses, edit, add, delete."""
        self.run_configs_load()
        var items = List[String]()
        var data = List[Int]()
        items.append(("• " if self.run_active.byte_length() == 0 else "  ") + "(the file being edited)")
        data.append(-1)
        var sel = 0
        for k in range(len(self.run_cfgs)):
            var c = self.run_cfgs[k].copy()
            var what = c.file if c.file.byte_length() > 0 else String("(the file being edited)")
            if c.args.byte_length() > 0:
                what += " " + c.args
            if c.build:
                what += "   [build first]"
            items.append(("• " if c.name == self.run_active else "  ") + pad_right(c.name, 16) + " " + what)
            data.append(k)
            if c.name == self.run_active:
                sel = k + 1
        var d = Dialog(D_RUNCFGS, "Run Configurations", min(76, self.scr.w - 4), min(20, max(10, len(items) + 7)))
        d.lines.append("Run (" + self.reg.key_label(CM_RUN) + ") uses the one marked with •")
        d.set_items(items^, data^)
        d.list_sel = sel
        d.buttons.append("~S~elect")
        d.buttons.append("~E~dit")
        d.buttons.append("~N~ew")
        d.buttons.append("~D~elete")
        d.buttons.append("~C~ancel")
        self.show(d^)

    def run_configs_button(mut self, b: Int, sel: Int):
        """A button of the configurations list (0 Select, 1 Edit, 2 New, 3 Delete)."""
        var k = self.dlg.item_data[sel] if sel >= 0 and sel < len(self.dlg.item_data) else -1
        var name = self.run_cfgs[k].name if k >= 0 and k < len(self.run_cfgs) else String("")
        if b == 0:
            if sel < 0:
                return
            var text = set_active_config(read_text(self.project_file()), name)
            if name.byte_length() == 0 and not path_exists(self.project_file()):
                self.run_active = ""            # nothing to write: there are no configurations
            elif not write_file(self.project_file(), str_bytes(text)):
                self.say("Cannot write " + self.project_file())
                return
            self.run_active = name
            self.say("Run now uses " + (("the configuration " + name) if name.byte_length() > 0 else String("the file being edited")))
        elif b == 1:
            if name.byte_length() == 0:
                self.say("That entry has nothing to edit: it runs whatever file is in front")
                return
            self.run_config_edit(name)
        elif b == 2:
            self.run_config_edit("")
        elif b == 3:
            if name.byte_length() == 0:
                self.say("That entry cannot be deleted")
                return
            var text = remove_table(read_text(self.project_file()), "run." + name)
            if name == self.run_active:
                text = set_active_config(text, "")
            if not write_file(self.project_file(), str_bytes(text)):
                self.say("Cannot write " + self.project_file())
                return
            self.run_configs_load()
            self.say("Deleted the configuration " + name)

    def run_config_edit(mut self, name: String):
        """The dialog for one configuration ('' = a new one)."""
        var c = RunConfig("")
        for x in self.run_cfgs:
            if x.name == name and name.byte_length() > 0:
                c = x.copy()
        if name.byte_length() == 0:
            # a new one starts from the file in front
            var te = self.top_editor()
            var root = self.symidx_root()
            if te >= 0 and self.wins[te].path.startswith(root + "/"):
                c.file = slice_str(decode(self.wins[te].path), cp_len(root) + 1, cp_len(self.wins[te].path))
                c.name = stem(c.file)
        self.run_edit_old = name
        var d = Dialog(D_RUNCFG, "Run Configuration", min(72, self.scr.w - 4), 20)
        d.lines.append("Paths count from the project folder.")
        d.fields.append(Field("~N~ame", c.name))
        d.fields.append(Field("~F~ile (empty: the one in front)", c.file))
        d.fields.append(Field("~A~rguments", c.args))
        d.fields.append(Field("~E~nvironment (NAME=value ...)", env_text(c.env)))
        d.fields.append(Field("~W~orking folder (empty: the file's)", c.cwd))
        d.checks.append("~B~uild first, then run the program")
        d.check_vals.append(c.build)
        d.buttons.append("~O~K")
        d.buttons.append("~C~ancel")
        self.show(d^)

    def run_config_save(mut self):
        """OK in the configuration dialog: check, write to the project file."""
        var c = RunConfig(String(self.dlg.field_text(0).strip()))
        c.file = String(self.dlg.field_text(1).strip())
        c.args = String(self.dlg.field_text(2).strip())
        c.cwd = String(self.dlg.field_text(4).strip())
        c.build = self.dlg.check_vals[0]
        var why = config_name_problem(c.name)
        var env = parse_env(self.dlg.field_text(3))
        if why.byte_length() == 0:
            why = env[1]
        var root = self.symidx_root()
        if why.byte_length() == 0 and c.name != self.run_edit_old:
            for x in self.run_cfgs:
                if x.name == c.name:
                    why = "There is a configuration called " + c.name + " already"
        if why.byte_length() == 0 and c.file.byte_length() > 0 and not path_exists(abs_path(root, c.file)):
            why = "The file " + c.file + " does not exist"
        if why.byte_length() == 0 and c.cwd.byte_length() > 0 and not is_dir(abs_path(root, c.cwd)):
            why = "The folder " + c.cwd + " does not exist"
        if why.byte_length() > 0:
            self.say(why)
            return
        c.env = env[0].copy()
        var text = read_text(self.project_file())
        if self.run_edit_old.byte_length() > 0 and self.run_edit_old != c.name:
            text = remove_table(text, "run." + self.run_edit_old)       # renamed
        text = save_run_config(text, c)
        var first = len(self.run_cfgs) == 0
        if first or self.run_active == self.run_edit_old and self.run_edit_old.byte_length() > 0:
            text = set_active_config(text, c.name)      # the first one is used at once; a renamed active one stays active
        if not write_file(self.project_file(), str_bytes(text)):
            self.say("Cannot write " + self.project_file())
            return
        self.run_configs_load()
        self.say("Saved the configuration " + c.name + (" - Run uses it now" if self.run_active == c.name else ""))

    # ========================================================== folder trust
    def trust_enable(mut self, path: String):
        """Start asking before commands and code of a folder are run; the folders
        trusted so far are read from `path`."""
        self.trust_path = path
        self.trust.decode_text(read_text(path))
        self.trust_enforced = True

    def trust_ok(self) -> Bool:
        return not self.trust_enforced or self.trust.is_trusted(self.symidx_root())

    def trust_gate(mut self, cmd: Int) -> Bool:
        """True if `cmd` may run now. If the folder is not trusted yet the question is
        put (and the command remembered); the caller does nothing more."""
        if self.trust_ok():
            return True
        self.trust_dialog(cmd)
        return False

    def trust_dialog(mut self, cmd: Int):
        """The question (or, for a trusted folder, the offer to take the trust back).
        `cmd` runs after a yes (0 = nothing)."""
        var root = self.symidx_root()
        self.trust_cmd = cmd
        var d = Dialog(D_TRUST, "Folder Trust", min(72, self.scr.w - 4), 12)
        if not self.trust_enforced:
            self.say("Folder trust is not in use here")
            return
        if self.trust.is_trusted(root):
            d.lines.append("This folder is trusted:")
            d.lines.append("  " + root)
            d.lines.append("")
            d.lines.append("Builds, runs, tasks and the language server work without asking.")
            d.buttons.append("~K~eep")
            d.buttons.append("~D~o not trust it any more")
            d.payload = 1
        else:
            d.lines.append("Do you trust the files in this folder?")
            d.lines.append("  " + root)
            d.lines.append("")
            d.lines.append("Building, running, tasks and the language server execute")
            d.lines.append("commands and code from it. Say yes only for folders whose")
            d.lines.append("content you know.")
            d.buttons.append("~T~rust this folder")
            d.buttons.append("~N~ot now")
            d.payload = 0
            d.focus = d.button_focus_index(1)   # Enter is the careful answer
        self.show(d^)

    def trust_save(mut self) -> Bool:
        if self.trust_path.byte_length() == 0:
            return True
        if not path_exists(dirname(self.trust_path)):
            _ = run_system("mkdir -p " + shell_quote(dirname(self.trust_path)))
        return write_file(self.trust_path, str_bytes(self.trust.encode()))

    def trust_answer(mut self, b: Int) raises:
        var root = self.symidx_root()
        var cmd = self.trust_cmd
        self.trust_cmd = 0
        if self.dlg.payload == 1:
            # a trusted folder: button 1 takes the trust back
            if b != 1:
                return
            if not self.trust.remove(root):
                self.say("It is trusted through a folder above it; take the trust back there")
                return
            _ = self.trust_save()
            self.lsp_stop()
            self.load_config()
            self.say("This folder is not trusted any more")
            return
        if b != 0:
            self.say("Not run: the folder is not trusted (Options > Folder trust)" if cmd != 0 else "The folder stays untrusted")
            return
        self.trust.add(root)
        if not self.trust_save():
            self.say("Cannot write " + self.trust_path + " - trusted for now only")
        var held = self.trust_held
        self.load_config()                  # the project's own tool commands count now
        self.say("This folder is trusted" + (" - its compiler and server commands are in use" if held else ""))
        if cmd != 0:
            self.exec(cmd)
