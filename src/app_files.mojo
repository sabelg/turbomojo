"""File handling: opening, saving, closing windows, quitting."""
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
from highlight import Highlighter, HL_MOJO, HL_PYTHON, HL_JSON
from ipynb import is_ipynb_path, ipynb_to_percent_text, percent_text_to_ipynb, strip_utf8_bom, IpynbCellOutput, ipynb_b64_decode
from cells import parse_cells, format_cell_divider_badge, CELL_SUCCESS, CELL_ERROR
from signals import own_pid
from buffer import TextBuffer, Pos, ENC_UTF8, ENC_LATIN1
from hexview import is_binary_data, render_hex_rows
from markdown import md_render_rich
from window import Window, WK_EDITOR, WK_HEX, WK_MDPREVIEW, WK_MESSAGE, WK_OUTLINE, WK_EXPLORER, ACT_OTHER, ACT_TYPE
from window_search import *
from window_multi import *
from window_lines import *
from window_draw import *
from menu import *
from commands import *
from dialog import *
from util import *
from appstate import *
from symindex import *
from outline import scan_outline
from app_lsp import *
from app_problems import *
from lsp import *
from app_watch import *
from watch import *
from app_swap import *
from swap import *
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
from app_git import *
from app_jobs import *
from app_input import *
from app_mouse import *
from app_draw import *
from app_plugins import *


__extension App:
    # ================================================================ files
    def _workspace_prefers_mojo(self, file_path: String) -> Bool:
        """Heuristic for empty/new `.ipynb` notebooks: True when inside a Mojo workspace."""
        var base_dir = dirname(file_path) if file_path.byte_length() > 0 else String(self.cwd)
        if base_dir.byte_length() == 0:
            base_dir = String(self.cwd)
        var cur = base_dir
        for _ in range(5):
            if path_exists(join_path(cur, "mojoproject.toml")) or path_exists(join_path(cur, "turbomojo.toml")) or path_exists(join_path(cur, "main.mojo")) or path_exists(join_path(cur, "src/main.mojo")):
                return True
            var pixi_p = join_path(cur, "pixi.toml")
            if path_exists(pixi_p):
                var px = lower_str(bytes_to_str(read_file(pixi_p)))
                if px.find("mojo") >= 0:
                    return True
            var par = dirname(cur)
            if par == cur or par.byte_length() == 0:
                break
            cur = par
        if path_exists(join_path(base_dir, "pyproject.toml")) or path_exists(join_path(base_dir, "requirements.txt")):
            return False
        return True

    def _init_new_ipynb_window(mut self, i: Int, p: String):
        """Configure window `i` as a fresh interactive `# %%` Jupyter notebook."""
        var is_mj = self._workspace_prefers_mojo(p)
        self.wins[i].lang_override = HL_MOJO if is_mj else HL_PYTHON
        self.wins[i].inline_cell_outputs = True
        if self.wins[i].buf.count() == 1 and self.wins[i].buf.llen(0) == 0:
            self.wins[i].buf.load_bytes(str_bytes("# %%\n\n"))
            self.wins[i].buf.modified = False
            self.wins[i].cr = 1
            self.wins[i].cc = 0
            self.wins[i].top = 0

    def new_notebook_cmd(mut self):
        """Create a new interactive Jupyter notebook buffer (`notebook.ipynb`)."""
        var i = self.new_editor("notebook.ipynb", "")
        self._init_new_ipynb_window(i, join_path(self.cwd, "notebook.ipynb"))
        var kind_lbl = "Mojo" if self.wins[i].lang_override == HL_MOJO else "Python"
        self.say("New " + kind_lbl + " Jupyter notebook — Ctrl-Enter runs cell, F2 saves .ipynb")

    def open_path(mut self, path: String) raises:
        var p = abs_path(self.cwd, path)
        if path_exists(p) and not is_dir(p) and not self.restoring:
            self.frec_note(p)
        for i in range(len(self.wins)):
            if (self.wins[i].kind == WK_EDITOR or self.wins[i].kind == WK_HEX) and self.wins[i].path == p:
                self.focus(i)
                return
        if is_dir(p):
            self.open_dialog(p)
            return
        # reuse a pristine untitled window (Turbo behaviour)
        var reuse = -1
        var ti = self.top_editor()
        if ti >= 0 and self.wins[ti].path.byte_length() == 0 and not self.wins[ti].buf.modified and self.wins[ti].buf.count() == 1 and self.wins[ti].buf.llen(0) == 0:
            reuse = ti
        var i = reuse
        if i < 0:
            i = self.new_editor(basename(p), p)
        else:
            self.wins[i].title = basename(p)
            self.wins[i].path = p
            self.focus(i)
            i = self.top()
        if path_exists(p):
            var bytes = read_file(p)
            if is_binary_data(bytes):
                self.wins[i].kind = WK_HEX
                self.wins[i].read_only = True
                self.wins[i].gut = 0
                self.wins[i].hex_bytes = bytes^
                var n_hex = max(1, (len(self.wins[i].hex_bytes) + 15) // 16)
                self.wins[i].buf.load(List[Int](length=max(0, n_hex - 1), fill=10))
                self.wins[i].buf.modified = False
                self.wins[i].cr = 0
                self.wins[i].cc = 0
                self.wins[i].top = 0
                self.note_disk_state(i)
                self.say("Binary file detected: opened read-only in hex inspector")
                return
            var big = len(bytes) > self.large_file_bytes
            if is_ipynb_path(p) and len(bytes) <= 256 * 1024 * 1024:
                var prefer_mj = self._workspace_prefers_mojo(p)
                var nb_doc = ipynb_to_percent_text(bytes_to_str(bytes), prefer_mj)
                if nb_doc.ok:
                    self.wins[i].buf.load_bytes(str_bytes(nb_doc.text))
                    self.wins[i].buf.modified = False
                    self.wins[i].buf.large = False
                    self.wins[i].lang_override = nb_doc.lang_id()
                    self.wins[i].inline_cell_outputs = True
                    for co in nb_doc.outputs:
                        var plot_paths = List[String]()
                        for pi in range(len(co.png_b64)):
                            var pb_entry = co.png_b64[pi]
                            if pb_entry.startswith("ANIM|"):
                                var abody = String(pb_entry[byte=5:])
                                var abar = abody.find("|")
                                if abar > 0:
                                    var afps_s = String(abody[byte=0:abar])
                                    var arest = String(abody[byte=abar + 1 :])
                                    var aframes = List[String]()
                                    var f_ord = 0
                                    for fb_s in arest.split("\t"):
                                        var raw_af = ipynb_b64_decode(String(fb_s))
                                        if len(raw_af) > 0:
                                            var afp = (
                                                env_or("TMPDIR", "/tmp")
                                                + "/turbomojo-ipynb-anim-"
                                                + String(own_pid())
                                                + "-"
                                                + String(co.code_ordinal)
                                                + "-"
                                                + String(pi)
                                                + "-"
                                                + String(f_ord)
                                                + ".png"
                                            )
                                            if write_file(afp, raw_af):
                                                aframes.append(afp)
                                                f_ord += 1
                                    if len(aframes) >= 2:
                                        plot_paths.append("ANIM|" + afps_s + "|" + "|".join(aframes))
                                    elif len(aframes) == 1:
                                        plot_paths.append(aframes[0])
                                continue
                            var raw_png = ipynb_b64_decode(pb_entry)
                            if len(raw_png) > 0:
                                var pp = env_or("TMPDIR", "/tmp") + "/turbomojo-ipynb-plot-" + String(own_pid()) + "-" + String(co.code_ordinal) + "-" + String(pi) + ".png"
                                if write_file(pp, raw_png):
                                    plot_paths.append(pp)
                        if len(plot_paths) > 0:
                            self.cell_last_plots = plot_paths.copy()
                        if co.execution_count > self.cell_exec_counter:
                            self.cell_exec_counter = co.execution_count
                        var p_joined = "\n".join(plot_paths)
                        if co.text.byte_length() > 0 or p_joined.byte_length() > 0 or co.is_error or co.execution_count > 0:
                            self.wins[i].set_cell_output(
                                co.header_row, co.text, co.is_error, p_joined, co.execution_count
                            )
                        var prev_line = co.text if co.text.byte_length() > 0 else ("error" if co.is_error else ("#" + String(co.execution_count)))
                        var bdg = format_cell_divider_badge(
                            CELL_ERROR if co.is_error else CELL_SUCCESS,
                            0,
                            prev_line,
                            len(plot_paths),
                        )
                        self.wins[i].set_cell_badge(co.header_row, bdg)
                    for fh in nb_doc.folded_headers:
                        _ = self.wins[i].buf.set_fold(fh, True)
                    self.wins[i].cr = 0
                    self.wins[i].cc = 0
                    self.wins[i].top = 0
                    self.wins[i].disk_hash = content_hash(bytes)
                    self.wins[i].disk_size = len(bytes)
                    self.apply_editorconfig(i)
                    self.note_disk_state(i)
                    self.wins[i].sync_ver = self.wins[i].buf.version
                    self.plugins_event("open", p)
                    var n_cells = len(parse_cells(self.wins[i].buf))
                    self.say("Loaded Jupyter notebook (" + ("Mojo" if nb_doc.is_mojo else "Python") + ", " + String(n_cells) + (" cell" if n_cells == 1 else " cells") + ") — Shift-Enter runs cell · Esc Command Mode")
                    if nb_doc.is_mojo and self.lsp_auto_start and self.lsp_auto_checked and self.log_path.byte_length() > 0 and not self.trust_held and self.trust_ok() and not self.lsp.active():
                        self.lsp_track(i, now_ns())
                    return
                var raw_ipynb = strip_utf8_bom(bytes_to_str(bytes))
                if not String(raw_ipynb.lstrip()).startswith("{"):
                    var body = raw_ipynb if raw_ipynb.find("# %%") >= 0 else ("# %%\n" + raw_ipynb)
                    self.wins[i].buf.load_bytes(str_bytes(body))
                    self.wins[i].buf.modified = False
                    self.wins[i].buf.large = False
                    self.wins[i].lang_override = HL_MOJO if prefer_mj else HL_PYTHON
                    self.wins[i].inline_cell_outputs = True
                    self.wins[i].cr = 0
                    self.wins[i].cc = 0
                    self.wins[i].top = 0
                    self.wins[i].disk_hash = content_hash(bytes)
                    self.wins[i].disk_size = len(bytes)
                    self.apply_editorconfig(i)
                    self.note_disk_state(i)
                    self.wins[i].sync_ver = self.wins[i].buf.version
                    self.plugins_event("open", p)
                    self.say("Opened plain-text .ipynb as notebook (Save writes valid Jupyter JSON)")
                    return
                self.wins[i].buf.load_bytes(bytes)
                self.wins[i].buf.modified = False
                self.wins[i].buf.large = big
                self.wins[i].lang_override = HL_JSON
                self.wins[i].cr = 0
                self.wins[i].cc = 0
                self.wins[i].top = 0
                self.wins[i].disk_hash = 0 if big else content_hash(bytes)
                self.wins[i].disk_size = -1 if big else len(bytes)
                self.apply_editorconfig(i)
                self.note_disk_state(i)
                self.wins[i].sync_ver = self.wins[i].buf.version
                self.say("Invalid .ipynb JSON (" + nb_doc.error + ") — opened raw JSON")
                return
            self.wins[i].buf.load_bytes(bytes)
            self.wins[i].buf.large = big
            self.wins[i].cr = 0
            self.wins[i].cc = 0
            self.wins[i].top = 0
            self.wins[i].disk_hash = 0 if big else content_hash(bytes)
            self.wins[i].disk_size = -1 if big else len(bytes)
            self.restore_history(i)
            if big:
                self.say("Opened in large-file mode: syntax colours, recovery snapshots and language server are off")
            else:
                self.say("Loaded " + p)
        else:
            if is_ipynb_path(p):
                self._init_new_ipynb_window(i, p)
                self.say("New Jupyter notebook (" + ("Mojo" if self.wins[i].lang_override == HL_MOJO else "Python") + "): " + p + " — Ctrl-Enter runs cell")
            else:
                self.say("New file: " + p)
        self.apply_editorconfig(i)
        self.note_disk_state(i)
        self.wins[i].sync_ver = self.wins[i].buf.version
        self.tests_sync_lens()
        self.plugins_event("open", p)
        if self.lsp_auto_start and self.lsp_auto_checked and not self.wins[i].buf.large and self.log_path.byte_length() > 0 and not self.trust_held and self.trust_ok() and is_mojo_file(p) and not self.lsp.active():
            self.lsp_track(i, now_ns())

    def apply_buffer_settings(mut self, i: Int, ec: EcProps):
        """Give a buffer its indentation and line-ending rules: user defaults first, then
        whatever .editorconfig specifies for the file."""
        self.wins[i].buf.tab_width = ec.effective_tab_width(self.tab_width)
        self.wins[i].buf.indent_size = ec.effective_indent_size(self.indent_size)
        if ec.has_indent_style:
            self.wins[i].buf.use_tabs = ec.use_tabs
        if ec.has_eol:
            self.wins[i].buf.crlf = ec.crlf
        if ec.has_final_newline:
            self.wins[i].buf.eol_at_eof = ec.final_newline
        # the user's setting, unless .editorconfig says something for this file
        self.wins[i].buf.trim_on_save = ec.trim if ec.has_trim else self.trim_trailing

    def apply_editorconfig(mut self, i: Int):
        if self.wins[i].path.byte_length() > 0:
            self.apply_buffer_settings(i, ec_for_file(self.wins[i].path))
        else:
            self.apply_buffer_settings(i, EcProps())

    def save_window(mut self, i: Int, next: Int) raises -> Bool:
        if self.wins[i].read_only or self.wins[i].kind == WK_HEX:
            self.say("Buffer is read-only")
            return False
        self.typed_ns = 0                       # a save is a pause: held toasts come now
        if self.wins[i].path.byte_length() == 0:
            self.saveas_dialog(i, next)
            return False
        if self.disk_changed(i) and file_sig(self.wins[i].path).exists and not self.wins[i].overwrite_ok:
            # the file changed behind our back and nobody has decided yet: ask first
            self.ask_changed(i)
            return False
        self.wins[i].overwrite_ok = False
        if self.wins[i].buf.trim_on_save:
            _ = self.wins[i].trim_trailing_whitespace()
        var note = String("")
        if self.wins[i].buf.encoding == ENC_LATIN1 and not self.wins[i].buf.latin1_ok():
            # the text now has characters Latin-1 cannot hold
            self.wins[i].buf.encoding = ENC_UTF8
            note = " as UTF-8 (it has characters Latin-1 cannot hold)"
        var b: List[UInt8]
        if is_ipynb_path(self.wins[i].path) and self.wins[i].lang_override != HL_JSON:
            if self.wins[i].lang_override < 0:
                self.wins[i].lang_override = HL_MOJO if self._workspace_prefers_mojo(self.wins[i].path) else HL_PYTHON
            self.wins[i].inline_cell_outputs = True
            var prev_raw = bytes_to_str(read_file(self.wins[i].path)) if path_exists(self.wins[i].path) else String("")
            var live_outs = self.collect_ipynb_outputs(i)
            var folded_cells = self.collect_ipynb_folded_cells(i)
            var ipynb_json = percent_text_to_ipynb(
                bytes_to_str(self.wins[i].buf.to_bytes()),
                self.wins[i].lang_override == HL_MOJO,
                prev_raw,
                live_outs,
                folded_cells,
            )
            b = str_bytes(ipynb_json)
        else:
            b = self.wins[i].buf.to_bytes()
        if not write_file(self.wins[i].path, b):
            raise Error("Could not write " + self.wins[i].path)
        self.wins[i].buf.modified = False
        self.wins[i].buf.mixed_eol = False      # written with one kind of line end
        self.wins[i].buf.lstate.clear()
        self.wins[i].buf.lstate.append(0)
        self.wins[i].disk_hash = 0 if self.wins[i].buf.large else content_hash(b)
        self.wins[i].disk_size = -1 if self.wins[i].buf.large else len(b)
        self.store_history(i)
        self.lsp_note_saved(i)
        if self.symidx.built and is_mojo_file(self.wins[i].path):
            self.symidx.replace_file(self.wins[i].path, scan_outline(self.wins[i].buf))
        self.note_disk_state(i)
        self.drop_swap(i)
        self.wins[i].sync_ver = self.wins[i].buf.version
        self.sync_shared_buffers(i)
        self.git_saved()
        self.tests_sync_lens()
        self.say("Saved " + self.wins[i].path + note)
        var saved = String(self.wins[i].path)
        self.plugins_event("save", saved)
        self.export_ide_state()
        self.tests_on_save(saved)
        if self.format_on_save and next == NEXT_NONE and is_mojo_file(saved) and not self.wins[i].buf.large and not self.trust_held and self.trust_ok() and not self.aux_job.active:
            var inner = "cd " + shell_quote(dirname(saved)) + " && exec " + self.mojo_for(saved) + " format -q " + shell_quote(saved)
            var cmd = self.with_env(saved, inner) + " 2>&1"
            _ = self.start_aux_job(JOB_FORMAT, cmd, saved, "")
        return True

    # ------------------------------------------------- history between sessions
    def history_file(self, i: Int) -> String:
        return self.history_dir + "/" + state_name(self.wins[i].path)

    def store_history(mut self, i: Int):
        """Write the undo history, cursor position, scroll and folds of window i next to nothing but the
        state directory. Only for a buffer that equals its file on disk: the history is
        tied to that exact content."""
        if self.history_dir.byte_length() == 0 or self.wins[i].kind != WK_EDITOR:
            return
        if self.wins[i].path.byte_length() == 0 or self.wins[i].buf.modified or self.wins[i].disk_size < 0:
            return
        if not path_exists(self.history_dir):
            _ = run_system("mkdir -p " + shell_quote(self.history_dir) + " && chmod 700 " + shell_quote(self.history_dir))
        var data = state_encode(
            self.wins[i].disk_hash, self.wins[i].disk_size, self.wins[i].cr, self.wins[i].cc, self.wins[i].top,
            self.wins[i].buf.undos, self.wins[i].buf.redos, self.wins[i].buf.folds,
        )
        if not write_file(self.history_file(i), data):
            self.log_error("could not write history for " + self.wins[i].path)

    def restore_history(mut self, i: Int):
        """After loading a file: bring back its cursor position and undo history if the
        file still has the content they were saved for."""
        if self.history_dir.byte_length() == 0 or self.wins[i].disk_size < 0:
            return
        var data = read_file(self.history_file(i))
        if len(data) == 0:
            return
        var st = state_decode(data)
        if not st.ok or st.hash != self.wins[i].disk_hash or st.size != self.wins[i].disk_size:
            return
        var top_group = 0
        for u in st.undos:
            top_group = max(top_group, u.group)
        for u in st.redos:
            top_group = max(top_group, u.group)
        self.wins[i].buf.undos = st.undos.copy()
        self.wins[i].buf.redos = st.redos.copy()
        # new edits must not join a group from the earlier session
        self.wins[i].gseq = max(self.wins[i].gseq, top_group)
        self.wins[i].break_group()
        self.wins[i].cr = st.cr
        self.wins[i].cc = st.cc
        self.wins[i].clamp()
        self.wins[i].sync_want()
        self.wins[i].top = max(0, min(st.top, self.wins[i].buf.count() - 1))
        self.restore_folds(i, st.folds)
        self.wins[i].follow = True

    def restore_folds(mut self, i: Int, folds: List[Int]):
        """Fold again the blocks that were folded (a row that starts no block now is
        passed over); a fold that would hide the cursor stays open."""
        for r in folds:
            if r >= 0 and r < self.wins[i].buf.count():
                _ = self.wins[i].buf.set_fold(r, True)
        self.wins[i].reveal_cursor()

    def prune_history(mut self):
        """Keep the state directory from growing for ever: only the 500 most recently
        written history files stay."""
        if self.history_dir.byte_length() == 0 or not path_exists(self.history_dir):
            return
        var d = shell_quote(self.history_dir)
        _ = run_system("cd " + d + " && ls -1t | tail -n +501 | while IFS= read -r f; do rm -f -- \"$f\"; done")

    # ------------------------------------------------- shared split views
    def same_shared_buffer(self, i: Int, j: Int) -> Bool:
        if i == j or i < 0 or j < 0 or i >= len(self.wins) or j >= len(self.wins):
            return False
        if self.wins[i].kind != WK_EDITOR or self.wins[j].kind != WK_EDITOR:
            return False
        if self.wins[i].buf_id >= 0 and self.wins[i].buf_id == self.wins[j].buf_id:
            return True
        if self.wins[i].path.byte_length() > 0 and self.wins[i].path == self.wins[j].path:
            return True
        return self.wins[i].clone_group > 0 and self.wins[i].clone_group == self.wins[j].clone_group

    def has_shared_sibling(self, i: Int) -> Bool:
        for j in range(len(self.wins)):
            if self.same_shared_buffer(i, j):
                return True
        return False

    def sync_shared_buffers(mut self, preferred: Int = -1):
        """Propagate edits, undo/redo stacks, marks and disk state across split views
        editing the same file or untitled clone group while preserving each view's own
        cursor, scroll offset and code folds."""
        var done = List[Int]()
        var n = len(self.wins)
        var pass_idx = -1
        while pass_idx < n:
            var src = preferred if pass_idx < 0 else pass_idx
            pass_idx += 1
            if src < 0 or src >= n or self.wins[src].kind != WK_EDITOR or (src in done):
                continue
            if preferred != src and self.wins[src].buf.version == self.wins[src].sync_ver:
                continue
            var has_sib = False
            for j in range(n):
                if self.same_shared_buffer(src, j):
                    has_sib = True
                    break
            self.wins[src].sync_cell_badges()
            self.wins[src].sync_ver = self.wins[src].buf.version
            done.append(src)
            if not has_sib:
                continue
            for dst in range(n):
                if not self.same_shared_buffer(src, dst):
                    continue
                var d_want = self.wins[dst].want
                var d_top = self.wins[dst].top
                var d_top_seg = self.wins[dst].top_seg
                var d_left = self.wins[dst].left
                # Zero-copy sync: BufferCore (Rope) is shared via ArcPointer.
                # Propagate buffer state and clamp view-local cursor/scroll offsets without deep-copying Rope.
                self.wins[dst].buf.core = self.wins[src].buf.core
                self.wins[dst].buf.version = self.wins[src].buf.version
                self.wins[dst].buf.modified = self.wins[src].buf.modified
                self.wins[dst].buf.undos = self.wins[src].buf.undos.copy()
                self.wins[dst].buf.redos = self.wins[src].buf.redos.copy()
                self.wins[dst].buf.marks = self.wins[src].buf.marks.copy()
                self.wins[dst].buf.bps = self.wins[src].buf.bps.copy()
                self.wins[dst].buf.bp_looks = self.wins[src].buf.bp_looks.copy()
                self.wins[dst].buf.bp_stamp = self.wins[src].buf.bp_stamp
                self.wins[dst].buf.cell_badge_rows = self.wins[src].buf.cell_badge_rows.copy()
                self.wins[dst].buf.cell_badges = self.wins[src].buf.cell_badges.copy()
                self.wins[dst].buf.cell_out_rows = self.wins[src].buf.cell_out_rows.copy()
                self.wins[dst].buf.cell_out_texts = self.wins[src].buf.cell_out_texts.copy()
                self.wins[dst].buf.cell_out_errs = self.wins[src].buf.cell_out_errs.copy()
                self.wins[dst].buf.cell_out_plots = self.wins[src].buf.cell_out_plots.copy()
                self.wins[dst].buf.cell_out_counts = self.wins[src].buf.cell_out_counts.copy()
                self.wins[dst].sync_cell_badges()
                self.wins[dst].buf.exec_row = self.wins[src].buf.exec_row
                self.wins[dst].buf.git_state = self.wins[src].buf.git_state
                self.wins[dst].buf.git_path = self.wins[src].buf.git_path
                self.wins[dst].buf.git_base = self.wins[src].buf.git_base.copy()
                self.wins[dst].buf.git_base_text = self.wins[src].buf.git_base_text
                self.wins[dst].buf.git_ver = self.wins[src].buf.git_ver
                self.wins[dst].buf.git_marks = self.wins[src].buf.git_marks.copy()
                self.wins[dst].buf.sem = self.wins[src].buf.sem.copy()
                self.wins[dst].buf.hints = self.wins[src].buf.hints.copy()
                self.wins[dst].buf.changes = self.wins[src].buf.changes.copy()
                self.wins[dst].buf.changes_lost = self.wins[src].buf.changes_lost
                self.wins[dst].buf.changes_chars = self.wins[src].buf.changes_chars
                self.wins[dst].buf.lstate = self.wins[src].buf.lstate.copy()
                self.wins[dst].buf.ldirty_from = self.wins[src].buf.ldirty_from
                self.wins[dst].buf.ldirty_to = self.wins[src].buf.ldirty_to
                self.wins[dst].buf.lex_work = self.wins[src].buf.lex_work
                self.wins[dst].buf.crlf = self.wins[src].buf.crlf
                self.wins[dst].buf.use_tabs = self.wins[src].buf.use_tabs
                self.wins[dst].buf.tab_width = self.wins[src].buf.tab_width
                self.wins[dst].buf.indent_size = self.wins[src].buf.indent_size
                self.wins[dst].clamp()
                self.wins[dst].want = d_want
                self.wins[dst].top = max(0, min(d_top, self.wins[dst].buf.count() - 1))
                self.wins[dst].top_seg = d_top_seg
                self.wins[dst].left = d_left
                self.wins[dst].gseq = max(self.wins[dst].gseq, self.wins[src].gseq)
                self.wins[dst].disk_hash = self.wins[src].disk_hash
                self.wins[dst].disk_size = self.wins[src].disk_size
                self.wins[dst].disk_sig = self.wins[src].disk_sig.copy()
                self.wins[dst].gut = self.wins[dst].gutter_for(self.line_numbers)
                self.wins[dst].sync_ver = self.wins[dst].buf.version
                done.append(dst)
        for pv in range(n):
            if self.wins[pv].kind == WK_MDPREVIEW and self.wins[pv].preview_peer_wid > 0:
                var peer = self.win_by_wid(self.wins[pv].preview_peer_wid)
                if peer >= 0 and self.wins[peer].kind == WK_EDITOR:
                    self.wins[pv].buf.core = self.wins[peer].buf.core
                    self.wins[pv].buf.version = self.wins[peer].buf.version
                    var pcount = max(1, self.wins[peer].buf.count() - 1)
                    var md_links = List[String]()
                    var md_lines = md_render_rich(to_str(self.wins[pv].buf.all_text()), max(8, self.wins[pv].w - 4), self.hl, md_links, True)
                    var mcount = max(0, len(md_lines) - 1)
                    self.wins[pv].top = (min(self.wins[peer].top, pcount) * mcount) // pcount

    def clone_editor_view(mut self, right: Bool = True):
        """Open a second synchronized view of the active editor in a split pane."""
        var ti = self.top_editor()
        if ti < 0:
            self.say("Open a file first")
            return
        if self.wins[ti].clone_group == 0:
            self.wins[ti].clone_group = self.next_clone_group
            self.next_clone_group += 1
        if self.wins[ti].buf_id < 0:
            self.wins[ti].buf_id = len(self.buffers)
            self.buffers.append(self.wins[ti].buf.copy())
        var bid = self.wins[ti].buf_id
        var cg = self.wins[ti].clone_group
        var title = String(self.wins[ti].title)
        var path = String(self.wins[ti].path)
        var cr = self.wins[ti].cr
        var cc = self.wins[ti].cc
        var want = self.wins[ti].want
        var top = self.wins[ti].top
        var top_seg = self.wins[ti].top_seg
        var left = self.wins[ti].left
        var cb = self.wins[ti].buf.copy()
        var gseq = self.wins[ti].gseq
        var dhash = self.wins[ti].disk_hash
        var dsize = self.wins[ti].disk_size
        var dsig = self.wins[ti].disk_sig.copy()
        var lsent = self.wins[ti].lsp_sent_version
        var lseen = self.wins[ti].lsp_seen_version
        var sver = self.wins[ti].sem_version
        self.wins[ti].sync_ver = self.wins[ti].buf.version
        var ci = self.new_editor(title, path)
        self.wins[ci].clone_group = cg
        self.wins[ci].buf_id = bid
        self.wins[ci].buf = cb^
        self.wins[ci].cr = cr
        self.wins[ci].cc = cc
        self.wins[ci].want = want
        self.wins[ci].top = top
        self.wins[ci].top_seg = top_seg
        self.wins[ci].left = left
        self.wins[ci].gseq = gseq
        self.wins[ci].disk_hash = dhash
        self.wins[ci].disk_size = dsize
        self.wins[ci].disk_sig = dsig^
        self.wins[ci].lsp_sent_version = lsent
        self.wins[ci].lsp_seen_version = lseen
        self.wins[ci].sem_version = sver
        self.wins[ci].gut = self.wins[ci].gutter_for(self.line_numbers)
        self.wins[ci].sync_ver = self.wins[ci].buf.version
        if self.tiled:
            self.layout_sync()
            var why = self.lay.split(right)
            if why.byte_length() > 0:
                self.say(why)
            else:
                self.layout_focus_shown()
                self.say("Split view: " + (basename(path) if path.byte_length() > 0 else title))
        else:
            var rx = self.wins[ti].x
            var ry = self.wins[ti].y
            var rw = self.wins[ti].w
            var rh = self.wins[ti].h
            self.wins[ti].zoomed = False
            self.wins[ti].half = False
            self.wins[ci].zoomed = False
            self.wins[ci].half = False
            if right and rw >= 32:
                var hw = rw // 2
                self.wins[ti].w = rw - hw
                self.wins[ci].x = rx + rw - hw
                self.wins[ci].y = ry
                self.wins[ci].w = hw
                self.wins[ci].h = rh
            elif not right and rh >= 8:
                var hh = rh // 2
                self.wins[ti].h = rh - hh
                self.wins[ci].x = rx
                self.wins[ci].y = ry + rh - hh
                self.wins[ci].w = rw
                self.wins[ci].h = hh
            self.fit_windows()
            self.say("Split view: " + (basename(path) if path.byte_length() > 0 else title))

    def split_window_horiz(mut self):
        """Split the active editor window horizontally (above/below)."""
        self.clone_editor_view(False)

    def split_window_vert(mut self):
        """Split the active editor window vertically (side-by-side)."""
        self.clone_editor_view(True)

    def remove_window(mut self, i: Int):
        if self.wins[i].kind == WK_MESSAGE:
            self.panel_keep()       # the panel's page is there again when it is reopened
        self.store_history(i)   # remembers the cursor position (if the file is unchanged)
        if not self.has_shared_sibling(i):
            self.drop_swap(i)   # closing the last view is a decision: nothing left to recover
        self.wins[i].img_cache[].invalidate_shown(self.scr)
        self.wins[i].img_cache[].clear(self.gfx_tmux)
        if self.wins[i].img_cache[].pending_out.byte_length() > 0:
            self.gfx_out += self.wins[i].img_cache[].pending_out
            self.wins[i].img_cache[].pending_out = ""
        _ = self.wins.pop(i)

    def hex_view_toggle(mut self):
        """Toggle virtualized 16-byte/row hex + ASCII inspector (`WK_HEX`) on the active window."""
        var t = self.top()
        if t < 0:
            return
        if self.wins[t].kind == WK_HEX:
            if is_binary_data(self.wins[t].hex_bytes):
                self.say("Binary file stays read-only in hex inspector")
                return
            var raw = self.wins[t].hex_bytes.copy()
            self.wins[t].hex_bytes.clear()
            self.wins[t].kind = WK_EDITOR
            self.wins[t].read_only = False
            self.wins[t].buf.load_bytes(raw)
            self.wins[t].gut = self.wins[t].gutter_for(self.line_numbers)
            self.wins[t].cr = 0
            self.wins[t].cc = 0
            self.wins[t].top = 0
            self.say("Exited hex inspector")
        elif self.wins[t].kind == WK_EDITOR:
            if self.wins[t].buf.modified:
                self.say("Save or revert changes before switching to read-only hex inspector")
                return
            var raw = self.wins[t].buf.to_bytes()
            self.wins[t].hex_bytes = raw^
            self.wins[t].kind = WK_HEX
            self.wins[t].read_only = True
            self.wins[t].gut = 0
            var n_hex = max(1, (len(self.wins[t].hex_bytes) + 15) // 16)
            self.wins[t].buf.load(List[Int](length=max(0, n_hex - 1), fill=10))
            self.wins[t].buf.modified = False
            self.wins[t].cr = 0
            self.wins[t].cc = 0
            self.wins[t].top = 0
            self.say("Hex inspector (read-only)")

    def close_window(mut self, i: Int, next: Int):
        if i < 0:
            return
        if self.wins[i].pinned and next == NEXT_CLOSE:
            self.say("Tab is pinned (unpin first to close)")
            return
        if self.wins[i].kind == WK_EDITOR and self.wins[i].buf.modified and (next == NEXT_QUIT or not self.has_shared_sibling(i)):
            self.focus(i)
            var d = Dialog(D_CONFIRM_CLOSE if next != NEXT_QUIT else D_CONFIRM_QUIT, "Information", 50, 9)
            d.lines.append(self.wins[self.top()].title + " has been modified.")
            d.lines.append("Save?")
            d.buttons.append("~Y~es")
            d.buttons.append("~N~o")
            d.buttons.append("~C~ancel")
            d.payload = self.top()
            d.next = next
            d.focus = d.button_focus_index(0)
            self.show(d^)
            return
        self.remove_window(i)

    def quit(mut self):
        for i in range(len(self.wins)):
            if self.wins[i].kind == WK_EDITOR and self.wins[i].buf.modified:
                self.close_window(i, NEXT_QUIT)
                return
        for i in range(len(self.wins)):
            self.store_history(i)
        self.session_save()
        self.running = False

    def collect_ipynb_outputs(self, i: Int) -> List[IpynbCellOutput]:
        """Gather live cell outputs, execution counts, and base64 PNG plots from buffer `i`."""
        var outs = List[IpynbCellOutput]()
        if i < 0 or i >= len(self.wins) or len(self.wins[i].buf.cell_out_rows) == 0:
            return outs^
        var cells = parse_cells(self.wins[i].buf)
        var code_ord = 0
        for c in cells:
            var low_t = lower_str(c.title)
            if low_t.startswith("[markdown]") or low_t.startswith("[md]") or low_t.startswith("[raw]"):
                continue
            var hrow = c.header_row if c.header_row >= 0 else 0
            for oi in range(len(self.wins[i].buf.cell_out_rows)):
                if self.wins[i].buf.cell_out_rows[oi] == hrow:
                    var pngs = List[String]()
                    var pstr = self.wins[i].buf.cell_out_plots[oi]
                    if pstr.byte_length() > 0:
                        for pp_s in pstr.split("\n"):
                            var pp = String(pp_s.strip())
                            if pp.startswith("ANIM|"):
                                var abody = String(pp[byte=5:])
                                var abar = abody.find("|")
                                if abar > 0:
                                    var afps_s = String(abody[byte=0:abar])
                                    var arest = String(abody[byte=abar + 1 :])
                                    var fb64_list = List[String]()
                                    for fp_s in arest.split("|"):
                                        var fp_p = String(fp_s.strip())
                                        if fp_p.byte_length() > 0 and path_exists(fp_p):
                                            var raw_fp = read_file(fp_p)
                                            if len(raw_fp) > 0:
                                                fb64_list.append(base64(raw_fp))
                                    if len(fb64_list) >= 2:
                                        pngs.append("ANIM|" + afps_s + "|" + "\t".join(fb64_list))
                                    elif len(fb64_list) == 1:
                                        pngs.append(fb64_list[0])
                                continue
                            if pp.byte_length() > 0 and path_exists(pp):
                                var raw_p = read_file(pp)
                                if len(raw_p) > 0:
                                    pngs.append(base64(raw_p))
                    var clean_lines = List[String]()
                    for ln_s in self.wins[i].buf.cell_out_texts[oi].split("\n"):
                        var ln = String(ln_s)
                        if not ln.startswith("[📊 plot saved: "):
                            clean_lines.append(ln)
                    var txt = "\n".join(clean_lines)
                    outs.append(
                        IpynbCellOutput(
                            code_ord,
                            hrow,
                            self.wins[i].buf.cell_out_counts[oi],
                            txt,
                            self.wins[i].buf.cell_out_errs[oi],
                            pngs^,
                        )
                    )
                    break
            code_ord += 1
        return outs^

    def collect_ipynb_folded_cells(self, i: Int) -> List[Int]:
        """Return 0-based cell indices whose `# %%` header is folded (`jupyter.source_hidden`)."""
        var out = List[Int]()
        if i < 0 or i >= len(self.wins) or len(self.wins[i].buf.folds) == 0:
            return out^
        var cells = parse_cells(self.wins[i].buf)
        for idx in range(len(cells)):
            var hr = cells[idx].header_row
            if hr >= 0 and self.wins[i].buf.fold_index(hr) >= 0:
                out.append(idx)
        return out^

    def export_ipynb(mut self) raises:
        """Export the active `# %%` notebook or script to `<stem>.ipynb` (nbformat v4)."""
        var i = self.top_editor()
        if i < 0:
            self.say("Open a # %% notebook or script first")
            return
        var p = String(self.wins[i].path)
        var out_path: String
        if p.byte_length() > 0:
            out_path = join_path(dirname(p), stem(p) + ".ipynb")
        else:
            var st = stem(self.wins[i].title) if self.wins[i].title.byte_length() > 0 else String("notebook")
            out_path = join_path(self.cwd, st + ".ipynb")
        var prev_raw = bytes_to_str(read_file(out_path)) if path_exists(out_path) else String("")
        var is_mj = self.wins[i].effective_lang() == HL_MOJO
        var live_outs = self.collect_ipynb_outputs(i)
        var folded_cells = self.collect_ipynb_folded_cells(i)
        var ipynb_json = percent_text_to_ipynb(
            bytes_to_str(self.wins[i].buf.to_bytes()),
            is_mj,
            prev_raw,
            live_outs,
            folded_cells,
        )
        if not write_file(out_path, str_bytes(ipynb_json)):
            self.say("Could not write " + out_path)
            return
        self.say("Exported Jupyter notebook: " + out_path)
