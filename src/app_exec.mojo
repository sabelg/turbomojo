"""Command dispatch: App.exec() and window arrangement."""
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
from app_notify import *
from app_agent import *
from app_lsp import *
from lsp import *
from app_watch import *
from watch import *
from app_swap import *
from swap import *
from app_files import *
from app_dialogs import *
from app_menus import *
from app_pickers import *
from app_nav import *
from app_outline import *
from app_layout import *
from app_explorer import *
from app_docs import *
from app_debug import *
from app_terminal import *
from app_tests import *
from app_gitdiff import *
from app_gitcmd import *
from app_explain import *
from app_docpane import *
from app_agentexplain import *
from app_tips import *
from app_exercises import *
from app_newproject import *
from app_setup import *
from app_presets import *
from app_report import *
from app_gpu import *
from app_codegen import *
from app_plugins import *
from plugins import CM_PLUGIN0
from tips import TK_FIND
from app_jobs import *
from app_input import *
from app_mouse import *
from app_draw import *
from app_vim import *



def trust_needed(cmd: Int) -> Bool:
    """Commands that run programs or code that the project folder decides on."""
    return cmd == CM_AGENT_START or cmd == CM_BUILD or cmd == CM_CODEGEN or cmd == CM_GPU_PROFILE or cmd == CM_MAX_SERVE or cmd == CM_BENCH_RUN or cmd == CM_GPU_ROOFLINE or cmd == CM_DEBUG_ATTACH_PID or cmd == CM_DEBUG_CORE or cmd == CM_TERM_NEW or cmd == CM_TEST_RUN or cmd == CM_TEST_RUN_ALL or cmd == CM_TEST_LIST or cmd == CM_TEST_CURSOR or cmd == CM_REPL or cmd == CM_REPL_SEND or cmd == CM_RUN or cmd == CM_RUN_CELL or cmd == CM_RUN_CELL_NEXT or cmd == CM_RUN_ALL_CELLS or cmd == CM_RUN_CELLS_ABOVE or cmd == CM_DEBUG or cmd == CM_RUN_CURSOR or cmd == CM_TEST or cmd == CM_FORMAT or cmd == CM_LSP or cmd == CM_TASKS or cmd == CM_TASK_AGAIN or cmd == CM_DOCS

__extension App:
    # ============================================================= commands
    def shortcut(self, k: Int) -> Int:
        """Command bound to key k (bindings live in the command registry). While a
        program is being debugged, F7 and F8 step (and Shift-F5 pauses a running one)."""
        if self.dbg.active():
            var d = self.reg.find_debug_key(k)
            if d != CM_NONE and (d != CM_PAUSE or self.dbg.state == DS_RUNNING) and (d != CM_RESET or not (self.job.active or self.fsearch.active)):
                return d
        return self.reg.find_key(k)

    def cursor_command(mut self, cmd: Int) raises:
        """The commands that keymaps bind to cursor movement and small deletions. They do
        what the corresponding key does in the active window."""
        var t = self.top()
        if t < 0:
            return
        if cmd == CM_INSERT_MODE:
            self.insert_mode = not self.insert_mode
            return
        if self.wins[t].kind != WK_EDITOR:
            if cmd == CM_CUR_UP:
                self.message_key(KEY_UP)
            elif cmd == CM_CUR_DOWN:
                self.message_key(KEY_DOWN)
            return
        if cmd == CM_CUR_LEFT:
            self.editor_key(KEY_LEFT)
        elif cmd == CM_CUR_RIGHT:
            self.editor_key(KEY_RIGHT)
        elif cmd == CM_CUR_UP:
            self.editor_key(KEY_UP)
        elif cmd == CM_CUR_DOWN:
            self.editor_key(KEY_DOWN)
        elif cmd == CM_CUR_WORD_LEFT:
            self.editor_key(KEY_LEFT | MOD_CTRL)
        elif cmd == CM_CUR_WORD_RIGHT:
            self.editor_key(KEY_RIGHT | MOD_CTRL)
        elif cmd == CM_CUR_LINE_START:
            self.wins[t].multi(OP_LINE_START, 0, False, False, List[Int]())
        elif cmd == CM_CUR_LINE_END:
            self.editor_key(KEY_END)
        elif cmd == CM_CUR_PAGE_UP:
            self.editor_key(KEY_PGUP)
        elif cmd == CM_CUR_PAGE_DOWN:
            self.editor_key(KEY_PGDN)
        elif cmd == CM_CUR_TOP:
            self.editor_key(KEY_HOME | MOD_CTRL)
        elif cmd == CM_CUR_BOTTOM:
            self.editor_key(KEY_END | MOD_CTRL)
        elif cmd == CM_DEL_CHAR:
            self.editor_key(KEY_DELETE)
        elif cmd == CM_SCROLL_UP:
            self.wins[t].scroll(-1)
        elif cmd == CM_SCROLL_DOWN:
            self.wins[t].scroll(1)
        elif cmd == CM_DEL_WORD:
            self.wins[t].collapse()
            if not self.wins[t].has_sel():
                self.wins[t].move_right(True, True)
            _ = self.wins[t].delete_sel(self.wins[t].new_group())
            self.wins[t].follow = True
        elif cmd == CM_KILL_LINE:
            # cut to the end of the line; at the end of a line, the line break
            self.wins[t].collapse()
            var r = self.wins[t].cr
            var c = self.wins[t].cc
            var n = self.wins[t].buf.llen(r)
            self.wins[t].sel = True
            self.wins[t].ar = r
            self.wins[t].ac = c
            if c < n:
                self.wins[t].cc = n
            elif r + 1 < self.wins[t].buf.count():
                self.wins[t].cr = r + 1
                self.wins[t].cc = 0
            if self.wins[t].has_sel():
                self.clipboard = self.wins[t].selected_text()
                self.osc52(self.clipboard.copy())
                _ = self.wins[t].delete_sel(self.wins[t].new_group())
            self.wins[t].sel = False
            self.wins[t].sync_want()
            self.wins[t].follow = True

    # ---------------------------------------------------------------- macros
    def macro_note_cmd(mut self, cmd: Int):
        """A command was picked from a menu or the status line while recording."""
        if self.macro_rec and not self.macro_playing and cmd != CM_MACRO_REC and cmd != CM_MACRO_PLAY and cmd > CM_NONE:
            self.macro.append(Event(EV_COMMAND, cmd, 0, 0, 0, False, False, List[Int]()))

    def macro_toggle_record(mut self):
        if self.macro_playing:
            return
        if not self.macro_rec:
            self.macro.clear()
            self.macro_cmd_start = 0
            self.macro_rec = True
            self.say("Recording a macro - " + self.reg.key_label(CM_MACRO_REC) + " stops")
            return
        self.macro_rec = False
        # the key (or key sequence) that stopped the recording is not part of the macro
        while self.macro_key_live and len(self.macro) > self.macro_cmd_start:
            _ = self.macro.pop()
        self.say("Macro recorded: " + String(len(self.macro)) + (" step" if len(self.macro) == 1 else " steps") + " - " + self.reg.key_label(CM_MACRO_PLAY) + " plays it")

    def macro_play(mut self) raises:
        if self.macro_playing:
            return
        if self.macro_rec:
            # asked for while recording: not recorded, and not run
            while self.macro_key_live and len(self.macro) > self.macro_cmd_start:
                _ = self.macro.pop()
            self.say("Stop recording first")
            return
        if len(self.macro) == 0:
            self.say("No macro recorded")
            return
        self.macro_playing = True
        var steps = len(self.macro)
        var done = 0
        try:
            for i in range(steps):
                var e = self.macro[i].copy()
                if e.kind == EV_COMMAND:
                    self.exec(e.key)
                else:
                    self.handle(e)
                done += 1
        except err:
            self.macro_playing = False
            raise err
        self.macro_playing = False
        self.say("Macro played (" + String(done) + (" step)" if done == 1 else " steps)"))

    def exec(mut self, cmd: Int) raises:
        if cmd >= CM_PLUGIN0:
            self.plugin_run(cmd)            # a plugin's command
            return
        if trust_needed(cmd) and not self.trust_gate(cmd):
            return                      # the question is on screen; the command runs after a yes
        self.exec_command(cmd)
        self.sync_shared_buffers()
        # Options are remembered across sessions
        if cmd == CM_LINENUM:
            self.persist_option("ui", "line_numbers", toml_bool(self.line_numbers))
        elif cmd == CM_RELNUM:
            self.persist_option("editor", "relative_numbers", toml_bool(self.rel_numbers))
        elif cmd == CM_HLLINE:
            self.persist_option("ui", "highlight_line", toml_bool(self.hl_line))
        elif cmd == CM_CLOCK:
            self.persist_option("ui", "clock", toml_bool(self.show_clock))
        elif cmd == CM_GPU_STATUS:
            self.persist_option("ui", "gpu_status", toml_bool(self.gpu_status_on))
        elif cmd == CM_GIT_LINEBLAME:
            self.persist_option("ui", "line_blame", toml_bool(self.git_line_blame))
        elif cmd == CM_FORMAT_SAVE:
            self.persist_option("editor", "format_on_save", toml_bool(self.format_on_save))
        elif cmd == CM_INDENT_GUIDES:
            self.persist_option("editor", "indent_guides", toml_bool(self.indent_guides))
        elif cmd == CM_SHOWWS:
            self.persist_option("ui", "show_whitespace", toml_bool(self.show_ws))
        elif cmd == CM_WRAP:
            self.persist_option("editor", "soft_wrap", toml_bool(self.soft_wrap))
        elif cmd == CM_TILED:
            self.persist_option("ui", "layout", "\"tiled\"" if self.tiled else "\"classic\"")
        elif cmd == CM_SEMANTIC:
            self.persist_option("editor", "semantic_colors", toml_bool(self.semantic_on))
        elif cmd == CM_QUIET:
            self.persist_option("editor", "quiet_colors", toml_bool(self.quiet_on))
        elif cmd == CM_HINTS:
            self.persist_option("editor", "inlay_hints", toml_bool(self.hints_on))
        elif cmd == CM_AUTOINDENT:
            self.persist_option("editor", "auto_indent", toml_bool(self.auto_indent))
        elif cmd == CM_RAINBOW_BRACKETS:
            self.persist_option("editor", "rainbow_brackets", toml_bool(self.rainbow_brackets))
        elif cmd == CM_TEST_WATCH:
            self.persist_option("tools", "test_watch", toml_bool(self.test_watch_on))
        elif cmd >= CM_THEME0 and cmd < CM_THEME0 + THEME_COUNT:
            self.persist_option("ui", "theme", toml_quote(self.theme_id))
        elif cmd >= CM_KEYMAP0 and cmd < CM_KEYMAP0 + KEYMAP_COUNT:
            self.persist_option("ui", "keymap", toml_quote(keymap_name(self.keymap)))

    def exec_command(mut self, cmd: Int) raises:
        var ai = self.active_editor()
        if ai >= 0 and self.wins[ai].has_multi():
            # only these know about several cursors; everything else works on the main one
            if not (cmd == CM_ADDNEXT or cmd == CM_SKIPNEXT or cmd == CM_SELECT_ALL_OCC or cmd == CM_CURABOVE or cmd == CM_CURBELOW or cmd == CM_COMMENT or cmd == CM_INDENT or cmd == CM_UNINDENT or cmd == CM_UPPER or cmd == CM_LOWER or cmd == CM_CUT or cmd == CM_COPY or cmd == CM_PASTE or cmd == CM_CLEAR or cmd == CM_UNDO or cmd == CM_REDO or cmd == CM_MACRO_REC or cmd == CM_MACRO_PLAY or (cmd >= CM_CUR_LEFT and cmd <= CM_INSERT_MODE)):
                self.wins[ai].collapse()
        if cmd == CM_REPORT:
            self.report_problem()
            return
        if cmd == CM_PRESETS:
            self.presets_dialog()
            return
        if cmd == CM_SETUP:
            self.setup_dialog()
            return
        if cmd == CM_NEW_PROJECT:
            self.new_project_dialog()
            return
        if cmd == CM_NEW_NOTEBOOK:
            self.new_notebook_cmd()
            return
        if cmd == CM_VIM_ZEN:
            self.toggle_vim_zen()
            return
        if cmd == CM_NEW:
            var name = String("NONAME")
            if self.untitled_n < 10:
                name += "0"
            name += String(self.untitled_n) + ".mojo"
            self.untitled_n += 1
            _ = self.new_editor(name, "")
        elif cmd == CM_OPEN:
            self.open_dialog(String(self.cwd))
        elif cmd == CM_OPEN_NOTEBOOK:
            self.open_dialog(String(self.cwd), True)
        elif cmd == CM_SAVE:
            var i = self.top_editor()
            if i >= 0:
                _ = self.save_window(i, NEXT_NONE)
        elif cmd == CM_SAVEAS:
            var i = self.top_editor()
            if i >= 0:
                self.saveas_dialog(i, NEXT_NONE)
        elif cmd == CM_SAVEALL:
            var n = 0
            for i in range(len(self.wins)):
                if self.wins[i].kind == WK_EDITOR and self.wins[i].buf.modified and self.wins[i].path.byte_length() > 0:
                    _ = self.save_window(i, NEXT_NONE)
                    n += 1
            self.say(String(n) + " file(s) saved")
        elif cmd == CM_CLOSE:
            self.close_window(self.top(), NEXT_CLOSE)
        elif cmd == CM_CLOSEALL:
            var i = len(self.wins) - 1
            var kept_mod = False
            var kept_pin = False
            while i >= 0:
                if self.wins[i].pinned:
                    kept_pin = True
                elif self.wins[i].kind == WK_EDITOR and self.wins[i].buf.modified:
                    kept_mod = True
                else:
                    self.remove_window(i)
                i -= 1
            if kept_mod and kept_pin:
                self.say("Modified and pinned windows were kept open")
            elif kept_mod:
                self.say("Modified windows were kept open")
            elif kept_pin:
                self.say("Pinned windows were kept open")
        elif cmd == CM_SHELL:
            self.term.leave()
            _ = run_system("printf '\\nType exit to return to TurboMojo...\\n\\n'; ${SHELL:-/bin/sh}")
            self.term.enter()
            self.scr.force = True
        elif cmd == CM_QUIT:
            self.quit()
        elif cmd == CM_UNDO:
            if ai >= 0:
                if self.wins[ai].read_only:
                    self.say("Buffer is read-only")
                else:
                    self.wins[ai].undo()
        elif cmd == CM_REDO:
            if ai >= 0:
                if self.wins[ai].read_only:
                    self.say("Buffer is read-only")
                else:
                    self.wins[ai].redo()
        elif cmd == CM_CUT or cmd == CM_COPY:
            var src = ai if ai >= 0 else self.top()
            if cmd == CM_CUT and ai >= 0 and self.wins[ai].read_only:
                self.say("Buffer is read-only")
                return
            if src >= 0 and self.wins[src].kind == WK_EDITOR and self.wins[src].has_multi():
                var all = self.wins[src].selections_text()
                if len(all) > 0:
                    self.clipboard = all^
                    self.osc52(self.clipboard.copy())
                    if cmd == CM_CUT:
                        self.wins[src].multi(OP_DELSEL, 0, False, False, List[Int]())
                    self.say(String(len(self.clipboard)) + " characters copied")
            elif src >= 0 and self.wins[src].has_sel():
                self.clipboard = self.wins[src].selected_text()
                self.osc52(self.clipboard.copy())
                if cmd == CM_CUT and ai >= 0:
                    _ = self.wins[ai].delete_sel(self.wins[ai].new_group())
                    self.wins[ai].follow = True
                self.say(String(len(self.clipboard)) + " characters copied")
            elif src >= 0 and self.wins[src].kind == WK_MESSAGE:
                self.clipboard = self.wins[src].buf.line(self.wins[src].cr)
                self.osc52(self.clipboard.copy())
        elif cmd == CM_PASTE:
            if ai >= 0:
                if self.wins[ai].read_only:
                    self.say("Buffer is read-only")
                elif len(self.clipboard) > 0:
                    self.wins[ai].paste_multi(self.clipboard)
        elif cmd == CM_CLEAR:
            if ai >= 0:
                if self.wins[ai].read_only:
                    self.say("Buffer is read-only")
                else:
                    self.wins[ai].multi(OP_DELSEL, 0, False, False, List[Int]())
        elif cmd >= CM_KEYMAP0 and cmd < CM_KEYMAP0 + KEYMAP_COUNT:
            self.keymap = cmd - CM_KEYMAP0
            self.vim_reset()
            self.rebuild_keys(False)
            self.say("Keys: " + keymap_name(self.keymap))
        elif cmd >= CM_CUR_LEFT and cmd <= CM_INSERT_MODE:
            self.cursor_command(cmd)
        elif cmd == CM_INDENT or cmd == CM_UNINDENT:
            if ai >= 0:
                if self.wins[ai].has_multi():
                    self.wins[ai].indent_lines_multi(1 if cmd == CM_INDENT else -1)
                else:
                    self.wins[ai].indent_lines(1 if cmd == CM_INDENT else -1)
                self.wins[ai].follow = True
        elif cmd == CM_HOVER:
            self.hover_command()
        elif cmd == CM_SIGNATURE:
            self.sig_command()
        elif cmd == CM_DEFINITION:
            self.definition_command()
        elif cmd == CM_TYPEDEF:
            self.type_definition_command()
        elif cmd == CM_REFERENCES:
            self.references_command()
        elif cmd == CM_ACTIONS:
            self.actions_command()
        elif cmd == CM_RENAME:
            self.rename_command()
        elif cmd == CM_BACK:
            self.jump_back()
        elif cmd == CM_FORWARD:
            self.jump_forward()
        elif cmd == CM_MACRO_REC:
            self.macro_toggle_record()
        elif cmd == CM_MACRO_PLAY:
            self.macro_play()
        elif cmd == CM_LINEUP or cmd == CM_LINEDOWN:
            if ai >= 0:
                _ = self.wins[ai].move_lines(-1 if cmd == CM_LINEUP else 1)
        elif cmd == CM_JOIN:
            if ai >= 0 and not self.wins[ai].join_lines():
                self.say("No line to join")
        elif cmd == CM_SORT:
            if ai >= 0:
                var n = self.wins[ai].sort_lines()
                self.say(String(n) + " lines sorted" if n > 0 else "Already in order")
        elif cmd == CM_UPPER or cmd == CM_LOWER:
            if ai >= 0:
                self.wins[ai].case_multi(cmd == CM_UPPER)
        elif cmd == CM_FOLD:
            if ai >= 0 and not self.wins[ai].toggle_fold(self.wins[ai].cr):
                self.say("Nothing to fold here")
        elif cmd == CM_FOLDALL:
            if ai >= 0:
                var n = self.wins[ai].buf.fold_all()
                var h = self.wins[ai].buf.hidden_by(self.wins[ai].cr)
                if h >= 0:
                    self.wins[ai].goto(h, 0)
                self.wins[ai].top = 0
                self.wins[ai].top_seg = 0
                self.wins[ai].follow = True
                self.say(String(n) + " blocks folded")
        elif cmd == CM_UNFOLDALL:
            if ai >= 0:
                self.wins[ai].buf.unfold_all()
                self.wins[ai].follow = True
        elif cmd == CM_ADDNEXT:
            if ai >= 0:
                if not self.wins[ai].add_next_occurrence():
                    self.say("No more occurrences")
                elif self.wins[ai].has_multi():
                    self.say(String(self.wins[ai].cursor_count()) + " cursors")
        elif cmd == CM_SKIPNEXT:
            if ai >= 0:
                if not self.wins[ai].skip_next_occurrence():
                    self.say("No more occurrences to skip to")
                elif self.wins[ai].has_multi():
                    self.say(String(self.wins[ai].cursor_count()) + " cursors")
        elif cmd == CM_SELECT_ALL_OCC:
            if ai >= 0:
                var n_occ = self.wins[ai].select_all_occurrences()
                if n_occ <= 0:
                    self.say("No word or selection to match")
                else:
                    self.say(String(n_occ) + (" occurrence selected" if n_occ == 1 else " occurrences selected"))
        elif cmd == CM_EXPAND_SEL:
            if ai >= 0:
                if not self.wins[ai].expand_selection():
                    self.say("Selection already covers the buffer")
        elif cmd == CM_SHRINK_SEL:
            if ai >= 0:
                if not self.wins[ai].shrink_selection():
                    self.say("Nothing selected")
        elif cmd == CM_CURABOVE or cmd == CM_CURBELOW:
            if ai >= 0:
                if self.wins[ai].add_cursor_vert(-1 if cmd == CM_CURABOVE else 1):
                    self.say(String(self.wins[ai].cursor_count()) + " cursors")
        elif cmd == CM_SELALL:
            if ai >= 0:
                self.wins[ai].select_all()
        elif cmd == CM_COMMENT:
            if ai >= 0:
                self.wins[ai].toggle_comment_multi()
        elif cmd == CM_DUPLINE:
            if ai >= 0:
                self.wins[ai].duplicate_line()
        elif cmd == CM_DELLINE:
            if ai >= 0:
                _ = self.wins[ai].delete_line()
        elif cmd == CM_COMPLETE:
            self.start_complete()
        elif cmd == CM_FIND or cmd == CM_REPLACE:
            self.tip_feed(TK_FIND)
            self.open_find(cmd == CM_REPLACE)
        elif cmd == CM_TIPS_OFF:
            self.tips_off()
        elif cmd == CM_EXERCISES:
            self.exercises_dialog()
        elif cmd == CM_EX_CHECK:
            self.ex_check()
        elif cmd == CM_FINDFILES:
            self.open_find_files()
        elif cmd == CM_REPLACEFILES:
            self.open_replace_files()
        elif cmd == CM_AGAIN:
            self.find_again()
        elif cmd == CM_GOTO:
            if ai >= 0:
                var d = Dialog(D_GOTO, "Go to Line Number", 44, 7)
                d.fields.append(Field("Enter new line ~n~umber", ""))
                d.buttons.append("~O~K")
                d.buttons.append("~C~ancel")
                self.show(d^)
        elif cmd == CM_SYMBOL:
            self.symbol_dialog()
        elif cmd == CM_WSYMBOL:
            self.wsymbol_dialog()
        elif cmd == CM_MATCH:
            if ai >= 0:
                var p = self.wins[ai].match_bracket()
                if p.r >= 0:
                    self.wins[ai].begin_move(False)
                    self.wins[ai].cr = p.r
                    self.wins[ai].cc = p.c
                    self.wins[ai].sync_want()
                else:
                    self.say("No matching bracket")
        elif cmd == CM_PALETTE:
            self.quick_dialog(">")
        elif cmd == CM_QUICK:
            self.quick_dialog("")
        elif cmd == CM_RUN:
            self.run_program(False)
        elif cmd == CM_RUN_CELL:
            self.run_code_cell(False)
        elif cmd == CM_RUN_CELL_NEXT:
            self.run_code_cell(True)
        elif cmd == CM_RUN_ALL_CELLS:
            self.run_all_cells()
        elif cmd == CM_RUN_CELLS_ABOVE:
            self.run_cells_above()
        elif cmd == CM_CELL_INLINE_OUT:
            self.toggle_inline_cell_outputs()
        elif cmd == CM_CELL_CLEAR_OUT:
            self.clear_cell_outputs_cmd()
        elif cmd == CM_TEST:
            self.run_program(True)
        elif cmd == CM_TEST_CURSOR:
            self.test_at_cursor()
        elif cmd == CM_DEBUG:
            self.debug_command()
        elif cmd == CM_STEP_INTO:
            self.debug_step("stepIn")
        elif cmd == CM_STEP_OVER:
            self.debug_step("next")
        elif cmd == CM_STEP_OUT:
            self.debug_step("stepOut")
        elif cmd == CM_RUN_CURSOR:
            self.debug_run_to_cursor()
        elif cmd == CM_PAUSE:
            self.debug_pause()
        elif cmd == CM_RESET:
            if self.dbg.active():
                self.debug_end(True)
            else:
                self.say("No program is being debugged")
        elif cmd == CM_WATCH_ADD:
            self.watch_dialog(-1)
        elif cmd == CM_EVALUATE:
            self.eval_dialog("", List[String]())
        elif cmd == CM_DEBUG_GPU_LANE:
            self.gpu_lane_dialog()
        elif cmd == CM_GIT_DIFF:
            self.git_diff_open(False)
        elif cmd == CM_GIT_STATUS:
            self.git_status_open()
        elif cmd == CM_GIT_STASH:
            self.git_stash(False)
        elif cmd == CM_GIT_STASH_POP:
            self.git_stash(True)
        elif cmd == CM_GIT_STAGED:
            self.git_diff_open(True)
        elif cmd == CM_GIT_STAGE or cmd == CM_GIT_REVERT:
            self.git_change_command(cmd)
        elif cmd == CM_AGENT:
            self.agent_toggle()
        elif cmd == CM_AGENT_START:
            self.agent_start()
        elif cmd == CM_AGENT_MENTION:
            self.agent_mention()
        elif cmd == CM_AGENT_MODEL:
            self.agent_model_dialog()
        elif cmd == CM_AGENT_MODE:
            self.agent_mode_dialog()
        elif cmd == CM_AGENT_THINKING:
            self.agent_thinking_dialog()
        elif cmd == CM_AGENT_NEW:
            self.agent_new_session()
        elif cmd == CM_AGENT_PROBLEMS:
            self.agent_send_problems()
        elif cmd == CM_AGENT_REVERT:
            self.agent_revert_turn()
        elif cmd == CM_GIT_COMMIT:
            self.git_commit_dialog()
        elif cmd == CM_GIT_BRANCH:
            self.git_branch_dialog()
        elif cmd == CM_GIT_BLAME:
            self.git_blame_open()
        elif cmd == CM_GIT_NEXT:
            self.git_next_change(True)
        elif cmd == CM_GIT_PREV:
            self.git_next_change(False)
        elif cmd == CM_CONFLICT_NEXT:
            self.conflict_next()
        elif cmd == CM_CONFLICT_OURS:
            self.conflict_resolve(0)
        elif cmd == CM_CONFLICT_THEIRS:
            self.conflict_resolve(1)
        elif cmd == CM_CONFLICT_BOTH:
            self.conflict_resolve(2)
        elif cmd == CM_TESTEXP:
            self.tests_toggle()
        elif cmd == CM_TEST_RUN:
            self.tests_run_target()
        elif cmd == CM_TEST_RUN_ALL:
            self.tests_run_all()
        elif cmd == CM_TEST_LIST:
            self.tests_list()
        elif cmd == CM_REPL:
            self.repl_open()
        elif cmd == CM_REPL_SEND:
            self.repl_send()
        elif cmd == CM_TERMINAL:
            self.term_toggle()
        elif cmd == CM_CPUWIN:
            self.cpuwin_toggle()
        elif cmd == CM_DEBUGWIN:
            self.debugwin_toggle()
        elif cmd == CM_BP_TOGGLE:
            self.bp_toggle()
        elif cmd == CM_BP_EDIT:
            self.bp_edit_here()
        elif cmd == CM_BP_FUNC:
            self.bp_function_dialog()
        elif cmd == CM_BP_LIST:
            self.bp_list_dialog(0)
        elif cmd == CM_BP_CLEAR:
            self.bp_clear_all()
        elif cmd == CM_USERSCREEN:
            self.term.leave()
            self.term.raw()
            self.term.wait_byte()
            self.term.enter()
            self.scr.force = True
        elif cmd == CM_MOJODOCS:
            self.docs_open()
        elif cmd == CM_DOCFIND:
            var ai = self.active_editor()
            var word = String("")
            if ai >= 0 and self.wins[ai].has_sel() and self.wins[ai].ar == self.wins[ai].cr:
                word = self.word_under(ai)      # a selected name is what is looked for
            self.docs_find_dialog(word)
        elif cmd == CM_DOCFETCH:
            self.docs_fetch_ask()
        elif cmd == CM_TRUST:
            self.trust_dialog(0)
        elif cmd == CM_PIXI_ENV:
            self.pixi_env_dialog()
        elif cmd == CM_RUNCONFIGS:
            self.run_configs_dialog()
        elif cmd == CM_TASKS:
            self.tasks_dialog()
        elif cmd == CM_TASK_AGAIN:
            if self.last_task.byte_length() == 0:
                self.tasks_dialog()
            else:
                var again = self.last_task
                self.run_task(again)
        elif cmd == CM_ARGS:
            var d = Dialog(D_ARGS, "Program Arguments", 56, 7)
            d.fields.append(Field("~A~rguments", self.run_args))
            d.buttons.append("~O~K")
            d.buttons.append("~C~ancel")
            self.show(d^)
        elif cmd == CM_COMPILER:
            var d = Dialog(D_COMPILER, "Compiler", 60, 9)
            d.lines.append("Command used for build / run / format / test.")
            d.fields.append(Field("~M~ojo command", self.compiler))
            d.buttons.append("~O~K")
            d.buttons.append("~C~ancel")
            self.show(d^)
        elif cmd == CM_BUILD:
            self.build()
        elif cmd == CM_FORMAT:
            self.format_file()
        elif cmd == CM_CODEGEN:
            self.codegen_open()
        elif cmd == CM_GPU_PROFILE:
            self.gpu_profile_command()
        elif cmd == CM_MAX_SERVE:
            self.max_serve_dialog()
        elif cmd == CM_GPU_WIN:
            self.gpuwin_toggle()
        elif cmd == CM_NEXTERR:
            self.goto_error(1)
        elif cmd == CM_PREVERR:
            self.goto_error(-1)
        elif cmd == CM_LINENUM:
            self.line_numbers = not self.line_numbers
        elif cmd == CM_RELNUM:
            self.rel_numbers = not self.rel_numbers
            if self.rel_numbers and not self.line_numbers:
                self.exec(CM_LINENUM)           # (numbers to count with)
        elif cmd == CM_AUTOINDENT:
            self.auto_indent = not self.auto_indent
        elif cmd == CM_HLLINE:
            self.hl_line = not self.hl_line
        elif cmd == CM_CLOCK:
            self.show_clock = not self.show_clock
        elif cmd == CM_GPU_STATUS:
            self.gpu_status_on = not self.gpu_status_on
            self.gpu_asked = False if not self.gpu_status_on else self.gpu_asked
            self.gpu_start()
        elif cmd == CM_GIT_LINEBLAME:
            self.git_line_blame = not self.git_line_blame
            if not self.git_line_blame:
                self.git_inline_path = ""
                self.git_inline_ver = -1
                self.git_inline_rows.clear()
            else:
                self.git_tick(now_ns())
            self.say("Inline line blame " + ("on" if self.git_line_blame else "off"))
        elif cmd == CM_FORMAT_SAVE:
            self.format_on_save = not self.format_on_save
            self.say("Format on save " + ("on" if self.format_on_save else "off"))
        elif cmd == CM_INDENT_GUIDES:
            self.indent_guides = not self.indent_guides
            for i in range(len(self.wins)):
                if self.wins[i].kind == WK_EDITOR:
                    self.wins[i].indent_guides = self.indent_guides
            self.say("Indent guides " + ("on" if self.indent_guides else "off"))
        elif cmd == CM_SHOWWS:
            self.show_ws = not self.show_ws
        elif cmd == CM_SEMANTIC:
            self.semantic_on = not self.semantic_on
            self.decor_reset(True, False)
            self.say("Semantic colours " + ("on" if self.semantic_on else "off"))
        elif cmd == CM_QUIET:
            self.quiet_on = not self.quiet_on
            self.theme_apply()
            self.scr.force = True
            self.say("Quiet code colours " + ("on" if self.quiet_on else "off"))
        elif cmd == CM_HINTS:
            self.hints_on = not self.hints_on
            self.decor_reset(False, True)
            self.say("Inlay hints " + ("on" if self.hints_on else "off"))
        elif cmd == CM_WRAP:
            self.soft_wrap = not self.soft_wrap
            for i in range(len(self.wins)):
                if self.wins[i].kind == WK_EDITOR:
                    self.wins[i].set_wrap(self.soft_wrap)
            self.say("Soft wrap " + ("on" if self.soft_wrap else "off"))
        elif cmd == CM_USETABS:
            var i = self.top_editor()
            if i >= 0:
                self.wins[i].buf.use_tabs = not self.wins[i].buf.use_tabs
                self.say("Indent with " + ("tabs" if self.wins[i].buf.use_tabs else "spaces"))
        elif cmd == CM_CRLF:
            var i = self.top_editor()
            if i >= 0:
                self.wins[i].buf.crlf = not self.wins[i].buf.crlf
                self.wins[i].buf.modified = True
                self.say("Line endings: " + ("CRLF" if self.wins[i].buf.crlf else "LF"))
        elif cmd == CM_CANCEL:
            if self.dbg.active() and not self.job.active and not self.fsearch.active:
                self.debug_end(True)
            else:
                self.cancel_job()
        elif cmd == CM_LSP:
            self.lsp_command()
        elif cmd >= CM_THEME0 and cmd < CM_THEME0 + THEME_COUNT:
            self.theme_id = self.themes.ids[cmd - CM_THEME0]
            self.theme_apply()
            self.say("Theme: " + self.pal.name)
        elif cmd == CM_HELP_GUIDE:
            self.help_page("guide.md")
        elif cmd == CM_HELP_CHEAT:
            self.help_page("cheatsheet.md")
        elif cmd == CM_HELP_ERRORS:
            self.help_page("errors.md")
        elif cmd == CM_HELP_PYTHON:
            self.help_page("coming-from-python.md")
        elif cmd == CM_HELP_NOTEBOOKS:
            self.help_page("notebooks.md")
        elif cmd == CM_HELP_NEW:
            self.help_page("whats-new.md")
        elif cmd == CM_HELP_TUTORIAL:
            self.tutorial_open()
        elif cmd == CM_NOTICES:
            self.notices_dialog()
        elif cmd == CM_THEME_PICK:
            self.theme_dialog()
        elif cmd == CM_SCREEN_READER:
            self.reader = not self.reader
            self.motion_apply()
            self.persist_option("ui", "screen_reader", toml_bool(self.reader))
            self.say("Screen-reader mode on: plain screen, the cursor on what has the focus" if self.reader else "Screen-reader mode off")
        elif cmd == CM_ZOOM:
            self.zoom_step()
        elif cmd == CM_TILE or cmd == CM_CASCADE:
            if self.tiled:
                self.say("The tiled layout arranges the windows itself (Window > Tiled layout turns it off)")
            else:
                self.arrange(cmd == CM_TILE)
        elif cmd >= CM_TILED and cmd <= CM_PANE_SHRINK:
            self.layout_command(cmd)
        elif cmd == CM_CLONE_VIEW:
            self.clone_editor_view(True)
        elif cmd == CM_NEXTWIN or cmd == CM_PREVWIN:
            self.next_window(cmd == CM_NEXTWIN)
        elif cmd == CM_MESSAGE or cmd == CM_SEARCHRES or cmd == CM_PROBLEMS:
            self.panel_show(PG_MESSAGE if cmd == CM_MESSAGE else (PG_SEARCH if cmd == CM_SEARCHRES else PG_PROBLEMS))
            self.focus(self.msg_index())
        elif cmd == CM_EXPLORER:
            self.explorer_toggle()
        elif cmd == CM_OUTLINE:
            self.outline_toggle()
        elif cmd == CM_WINLIST:
            var d = Dialog(D_WINLIST, "Window List", 56, min(18, self.desk_h()))
            var items = List[String]()
            var data = List[Int]()
            var i = len(self.wins) - 1
            while i >= 0:
                var s = String(self.wins[i].number) + "  " + self.wins[i].title
                if self.wins[i].buf.modified and self.wins[i].kind == WK_EDITOR:
                    s += "  [modified]"
                items.append(s)
                data.append(i)
                i -= 1
            d.set_items(items^, data^)
            d.focus = 0
            d.buttons.append("~O~K")
            d.buttons.append("~C~ancel")
            self.show(d^)
        elif cmd == CM_HELP:
            # F1 on a name that has documentation shows it, as in Turbo; else the reference
            if not self.explain_command() and not self.docs_at_cursor(False):
                self.help_dialog()
        elif cmd == CM_DOCS:
            var ai = self.active_editor()
            if self.docpane_index() >= 0 and ai >= 0 and self.word_under(ai).byte_length() > 0:
                var name = self.word_under(ai)
                self.docpane_lookup(name, True)
            else:
                _ = self.docs_at_cursor(True)
        elif cmd == CM_DOCS_PANE:
            self.docpane_toggle()
        elif cmd == CM_AGENT_EXPLAIN:
            self.agent_explain_error()
        elif cmd == CM_AGENT_EXPLAIN_CODE:
            self.agent_explain_code()
        elif cmd == CM_ABOUT:
            var d = Dialog(D_ABOUT, "About", 52, 14)
            d.lines.append("")
            d.lines.append("        ~T U R B O   M O J O~")
            d.lines.append("")
            d.lines.append("      Version " + VERSION + "  -  written in pure Mojo")
            d.lines.append("  A tribute to Borland Turbo C++ 3.0 (1992)")
            d.lines.append("")
            d.lines.append(" Truecolor - mouse - undo - fuzzy palette")
            d.lines.append(" syntax colouring - build/run - OSC 52 copy")
            d.buttons.append("~O~K")
            d.focus = d.button_focus_index(0)
            self.show(d^)
        elif cmd == CM_BENCH_RUN:
            self.bench_run()
        elif cmd == CM_BENCH_SAVE:
            self.bench_save_baseline()
        elif cmd == CM_GPU_ROOFLINE:
            self.gpu_roofline_run()
        elif cmd == CM_TEST_WATCH:
            self.tests_toggle_watch()
        elif cmd == CM_CELL_RESTART:
            self.cell_restart_kernels()
        elif cmd == CM_CELL_INSERT_ABOVE:
            self.cell_insert_above()
        elif cmd == CM_CELL_INSERT_BELOW:
            self.cell_insert_below()
        elif cmd == CM_CELL_DELETE:
            self.cell_delete_current()
        elif cmd == CM_CELL_TOGGLE_MD:
            self.cell_toggle_markdown()
        elif cmd == CM_CELL_RESTART_RUN_ALL:
            self.cell_restart_and_run_all()
        elif cmd == CM_DEBUG_ATTACH_PID:
            self.debug_attach_pid_open()
        elif cmd == CM_DEBUG_CORE:
            self.debug_core_open()
        elif cmd == CM_CALL_HIERARCHY:
            self.hierarchy_open(False)
        elif cmd == CM_TYPE_HIERARCHY:
            self.hierarchy_open(True)
        elif cmd == CM_PEEK_DEF:
            self.peek_definition_open()
        elif cmd == CM_GIT_PREVIEW_HUNK:
            self.peek_hunk_open()
        elif cmd == CM_UNDO_TREE:
            if ai >= 0:
                var lines = self.wins[ai].buf.undo_tree_lines()
                var data = List[Int]()
                var sel_idx = 0
                for k in range(len(lines)):
                    if k < len(self.wins[ai].buf.core[].utree_nodes):
                        var nid = self.wins[ai].buf.core[].utree_nodes[k].id
                        data.append(nid)
                        if nid == self.wins[ai].buf.core[].utree_active:
                            sel_idx = k
                    else:
                        data.append(k)
                var d = Dialog(D_UNDO_TREE, "Undo Tree", min(72, self.scr.w - 4), min(18, max(9, len(lines) + 6)))
                d.set_items(lines^, data^)
                d.list_sel = sel_idx
                d.buttons.append("~J~ump")
                d.buttons.append("~C~ancel")
                self.show(d^)
        elif cmd == CM_HEX_VIEW:
            self.hex_view_toggle()
        elif cmd == CM_RAINBOW_BRACKETS:
            self.rainbow_brackets = not self.rainbow_brackets
            for k in range(len(self.wins)):
                if self.wins[k].kind == WK_EDITOR:
                    self.wins[k].rainbow_brackets = self.rainbow_brackets
            self.say("Rainbow brackets " + ("on" if self.rainbow_brackets else "off"))
        elif cmd == CM_PIN_TAB:
            self.toggle_pin_tab()
        elif cmd == CM_MD_PREVIEW:
            self.toggle_md_preview()
        elif cmd == CM_GIT_LOG:
            self.git_log_open()
        elif cmd == CM_GIT_PUSH:
            self.git_remote_sync("push")
        elif cmd == CM_GIT_PULL:
            self.git_remote_sync("pull")
        elif cmd == CM_GIT_FETCH:
            self.git_remote_sync("fetch")
        elif cmd == CM_GIT_STASH_LIST:
            self.git_stash_list_open()
        elif cmd == CM_SWITCH_PROJECT:
            self.switch_project_open()
        elif cmd == CM_GIT_WORKTREE:
            self.git_worktree_open()
        elif cmd == CM_PLUGINS:
            self.plugins_manager_open()
        elif cmd == CM_TERM_NEW:
            self.term_new_tab()
        elif cmd == CM_TERM_NEXT:
            self.term_next_tab()
        elif cmd == CM_TERM_PREV:
            self.term_prev_tab()
        elif cmd == CM_EXPORT_IPYNB:
            self.export_ipynb()
        elif cmd == CM_CELL_VIEW_PLOT:
            self.cell_open_plot_preview()
        elif cmd == CM_MIGRATE_MOJO12:
            self.migrate_mojo12_file()
        elif cmd == CM_MIGRATE_MOJO12_PROJECT:
            self.migrate_mojo12_project()
        elif cmd == CM_EXTRACT_VAR:
            self.extract_variable_ask()
        elif cmd == CM_EXTRACT_FUNC:
            self.extract_function_ask()
        elif cmd == CM_REFRESH:
            self.scr.force = True
        elif cmd == CM_GPU_OCCUPANCY:
            self.gpu_occupancy_open()
        elif cmd == CM_SWAP_CALL_ARGS:
            self.swap_call_args_cmd()
        elif cmd == CM_CHANGE_SIGNATURE:
            self.change_signature_ask()
        elif cmd == CM_INLINE_SYMBOL:
            self.inline_symbol_cmd()
        elif cmd == CM_IMPL_TRAIT_STUBS:
            self.implement_trait_stubs_cmd()
        elif cmd == CM_INLINE_AI:
            self.inline_ai_ask()
        elif cmd == CM_AI_VERIFY_TOGGLE:
            self.toggle_ai_verify_edits()
        elif cmd == CM_FIM_GHOST:
            self.fim_trigger_or_accept()
        elif cmd == CM_SELECT_TARGET:
            self.select_target_dialog()
        elif cmd == CM_PLUGIN_INSTALL:
            self.plugin_install_dialog()

    def arrange(mut self, tile: Bool):
        var idx = List[Int]()
        for i in range(len(self.wins)):
            if self.wins[i].kind == WK_EDITOR:
                idx.append(i)
        var n = len(idx)
        if n == 0:
            return
        var dh = self.desk_h()
        var mi = self.msg_index()
        if mi >= 0:
            dh = max(6, self.wins[mi].y - 1)
        var W = self.scr.w
        if tile:
            var cols = 1
            while cols * cols < n:
                cols += 1
            var rows = (n + cols - 1) // cols
            for k in range(n):
                var c = k % cols
                var r = k // cols
                var i = idx[k]
                self.wins[i].zoomed = False
                self.wins[i].half = False
                self.wins[i].x = (W * c) // cols
                self.wins[i].w = (W * (c + 1)) // cols - self.wins[i].x
                self.wins[i].y = 1 + (dh * r) // rows
                self.wins[i].h = 1 + (dh * (r + 1)) // rows - self.wins[i].y
        else:
            for k in range(n):
                var i = idx[k]
                var off = k % 8
                self.wins[i].zoomed = False
                self.wins[i].half = False
                self.wins[i].x = off
                self.wins[i].y = 1 + off
                self.wins[i].w = W - off
                self.wins[i].h = dh - off
        self.fit_windows()

    def find_again(mut self):
        var ai = self.active_editor()
        if ai < 0 or len(self.find_text) == 0:
            return
        var s = self.current_search()
        if not s.ok:
            return
        self.wins[ai].set_highlight(s)
        if not self.wins[ai].search_next(s):
            self.info("Information", "Search string not found.")
        else:
            self.say(self.match_note(ai, s))
