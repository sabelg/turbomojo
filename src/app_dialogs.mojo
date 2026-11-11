"""Dialog flow: opening dialogs and acting on their buttons and keys."""
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
from app_watch import *
from watch import *
from app_swap import *
from swap import *
from app_files import *
from app_menus import *
from app_exec import *
from app_pickers import *
from app_nav import *
from app_outline import *
from app_layout import *
from app_explorer import *
from app_docs import *
from app_debug import *
from app_jobs import *
from app_input import *
from app_mouse import *
from app_draw import *


__extension App:
    # ============================================================== dialogs
    def show(mut self, var d: Dialog):
        self.dlg = d^
        self.mode = M_DIALOG

    def info(mut self, title: String, msg: String):
        var d = Dialog(D_INFO, title, max(36, min(self.scr.w - 4, cp_len(msg) + 8)), 8)
        d.lines.append(msg)
        d.buttons.append("~O~K")
        d.focus = d.button_focus_index(0)
        self.show(d^)

    def open_dialog(mut self, dir: String):
        var d = Dialog(D_OPEN, "Open a File", min(64, self.scr.w - 4), min(22, self.desk_h()))
        d.fields.append(Field("~N~ame", ""))
        d.list_filter = True
        d.dir = dir
        d.lines.append("Directory: " + dir)
        var items = list_dir(dir)
        var data = List[Int]()
        for _ in range(len(items)):
            data.append(0)
        d.set_items(items^, data^)
        d.buttons.append("~O~pen")
        d.buttons.append("~C~ancel")
        self.show(d^)

    def saveas_dialog(mut self, i: Int, next: Int):
        var d = Dialog(D_SAVEAS, "Save File As", 60, 9)
        var name = self.wins[i].path if self.wins[i].path.byte_length() > 0 else self.wins[i].title
        d.fields.append(Field("~S~ave file as", name))
        d.buttons.append("~O~K")
        d.buttons.append("~C~ancel")
        d.payload = i
        d.next = next
        self.show(d^)

    def accept_open(mut self) raises:
        var name = self.dlg.field_text(0)
        var dir = self.dlg.dir
        var sel = self.dlg.selected_item()
        var target = String("")
        if name.byte_length() > 0 and path_exists(join_path(dir, name)):
            target = join_path(dir, name)
        elif sel >= 0:
            target = join_path(dir, self.dlg.items[sel])
        elif name.byte_length() > 0:
            target = join_path(dir, name)
        else:
            return
        target = abs_path(self.cwd, target)
        if is_dir(target):
            self.open_dialog(target)
            return
        self.mode = M_NORMAL
        self.open_path(target)

    def dialog_button(mut self, b: Int) raises:
        var kind = self.dlg.kind
        if kind == D_OPEN:
            if b == 0:
                self.accept_open()
            else:
                self.mode = M_NORMAL
            return
        if kind == D_BUSY:
            return
        if kind == D_FIND or kind == D_REPLACE:
            self.find_button(b)
            return
        if kind == D_EVALUATE:
            self.eval_button(b)
            return
        self.mode = M_NORMAL
        if kind == D_SAVEAS and b == 0:
            var i = self.dlg.payload
            var name = self.dlg.field_text(0)
            if name.byte_length() == 0 or i < 0 or i >= len(self.wins):
                return
            var p = abs_path(self.cwd, name)
            self.wins[i].path = p
            self.wins[i].title = basename(p)
            self.apply_editorconfig(i)      # the new name may fall under other rules
            self.note_disk_state(i)         # Save As replaces whatever has that name
            var next = self.dlg.next
            if self.save_window(i, NEXT_NONE):
                if next == NEXT_CLOSE:
                    self.remove_window(i)
                elif next == NEXT_QUIT:
                    self.remove_window(i)
                    self.quit()
        elif (kind == D_CONFIRM_CLOSE or kind == D_CONFIRM_QUIT) and b <= 1:
            var i = self.dlg.payload
            var next = self.dlg.next
            if b == 1:
                self.remove_window(i)
                if next == NEXT_QUIT:
                    self.quit()
            else:
                if self.save_window(i, next):
                    self.remove_window(i)
                    if next == NEXT_QUIT:
                        self.quit()
        elif kind == D_FINDFILES and b == 0:
            self.find_text = self.dlg.fields[0].text.copy()
            self.find_case = self.dlg.check_vals[0]
            self.find_word = self.dlg.check_vals[1]
            self.find_regex = self.dlg.check_vals[2]
            var s = self.current_search()
            if len(s.pat) == 0:
                return
            if not s.ok:
                self.info("Find in Files", "Pattern error: " + s.error)
                return
            self.start_file_search(s)
        elif kind == D_GOTO and b == 0:
            var ai = self.active_editor()
            var t = self.dlg.field_text(0)
            if ai >= 0 and t.byte_length() > 0:
                try:
                    var n = atol(t)
                    self.jump_mark()
                    self.wins[ai].goto(n - 1, 0)
                except:
                    self.say("Invalid line number")
        elif kind == D_PALETTE and b == 0:
            self.quick_accept()
        elif kind == D_SYMBOL and b == 0:
            var s = self.dlg.selected_item()
            var ai = self.active_editor()
            if s >= 0 and ai >= 0:
                self.jump_mark()
                self.wins[ai].goto(self.dlg.item_data[s], self.wins[ai].indent_of(self.dlg.item_data[s]))
        elif kind == D_DOCFIND:
            if b == 0:
                self.docs_find_go(self.dlg.selected_item())
            elif self.doc_find_back:
                self.mode = M_DOCS
        elif kind == D_DOCFETCH:
            if b == 0:
                self.docs_fetch()
        elif kind == D_TRUST:
            self.trust_answer(b)
        elif kind == D_WATCH and b == 0:
            self.watch_save(String(self.dlg.field_text(0).strip()))
        elif kind == D_SETVALUE and b == 0:
            self.dv_set_save(self.dlg.field_text(0))
        elif kind == D_BREAKPOINT and b == 0:
            self.bp_edit_save()
        elif kind == D_BPFUNC and b == 0:
            self.bp_function_add(String(self.dlg.field_text(0).strip()))
        elif kind == D_BREAKPOINTS:
            self.bp_list_button(b, self.dlg.selected_item())
        elif kind == D_RUNCFGS:
            self.run_configs_button(b, self.dlg.selected_item())
        elif kind == D_RUNCFG and b == 0:
            self.run_config_save()
        elif kind == D_TASKS and b == 0:
            var s = self.dlg.selected_item()
            if s >= 0 and self.dlg.item_data[s] < len(self.tasks):
                var chosen = self.tasks[self.dlg.item_data[s]].name
                self.run_task(chosen)
        elif kind == D_EX_NAME and b == 0:
            self.explorer_apply(self.dlg.field_text(0))
        elif kind == D_EX_DELETE and b == 0:
            self.explorer_delete()
        elif kind == D_WSYMBOL and b == 0:
            self.wsymbol_go(self.dlg.selected_item())
        elif kind == D_WINLIST and b == 0:
            var s = self.dlg.selected_item()
            if s >= 0:
                self.focus(self.dlg.item_data[s])
        elif kind == D_ARGS and b == 0:
            self.run_args = self.dlg.field_text(0)
        elif kind == D_RENAME:
            if b == 0:
                self.rename_accept(self.dlg.field_text(0))
        elif kind == D_RENAME_APPLY:
            if b == 0:
                self.edit_apply()
            else:
                self.act_command_due = False
                self.say(self.edit_noun + " cancelled - nothing was changed")
        elif kind == D_ACTIONS:
            if b == 0:
                self.action_chosen(self.dlg.item_data[self.dlg.selected_item()] if self.dlg.selected_item() >= 0 else -1)
        elif kind == D_RECOVER:
            if b == 0:
                _ = self.recover_swaps()
            elif b == 1:
                self.discard_swaps()
            else:
                self.pending_swaps.clear()      # "Later": ask again next time
        elif kind == D_CHANGED:
            var i = self.dlg.payload
            if i >= 0 and i < len(self.wins):
                if b == 0:
                    self.reload_from_disk(i)
                    self.say("Reloaded " + self.wins[i].title + " from disk")
                else:
                    # keep the editor's version: remember the new disk state so the
                    # question is not repeated, and let the next save overwrite the file
                    self.wins[i].disk_sig = file_sig(self.wins[i].path)
                    self.wins[i].overwrite_ok = True
                    self.wins[i].buf.modified = True
            self.watch_recheck = True           # other files may be waiting
        elif kind == D_COMPILER and b == 0:
            var c = self.dlg.field_text(0)
            if c.byte_length() > 0:
                self.compiler = c
                self.persist_option("tools", "compiler", toml_quote(c))
                self.say("Compiler: " + c)

    # ------------------------------------------------------------ find / replace
    def current_search(self) -> Search:
        return make_search(self.find_text, self.find_case, self.find_word, self.find_regex)

    def match_note(self, ai: Int, s: Search) -> String:
        """"Match 3 of 17" for the match selected in window ai."""
        var n = self.wins[ai].count_matches(s, COUNT_LINE_LIMIT)
        var total = String(n.r1) + ("+" if n.r2 == 1 else "")
        if n.c1 > 0:
            return "Match " + String(n.c1) + " of " + total
        if n.r2 == 1:
            return "Found (the text is too long to count the matches)"
        return total + " match" + ("" if n.r1 == 1 else "es")

    def open_find(mut self, replace: Bool):
        var ai = self.active_editor()
        if ai < 0:
            return
        var sel = self.wins[ai].selected_text()
        var multi = 10 in sel
        var seed = to_str(sel) if len(sel) > 0 and not multi else to_str(self.find_text)
        var d = Dialog(D_REPLACE if replace else D_FIND, "Replace" if replace else "Find", 60, 14 if replace else 12)
        d.fields.append(Field("~T~ext to find", seed))
        d.fields[0].fresh = True               # typing replaces the remembered text
        if replace:
            d.fields.append(Field("~N~ew text", to_str(self.replace_text)))
            d.fields[1].fresh = True
            d.buttons.append("~R~eplace")
            d.buttons.append("Change ~a~ll")
        else:
            d.buttons.append("~O~K")
        d.buttons.append("~C~ancel")
        d.checks.append("Case sens~i~tive")
        d.check_vals.append(self.find_case)
        d.checks.append("~W~hole words")
        d.check_vals.append(self.find_word)
        d.checks.append("Regular e~x~pression")
        d.check_vals.append(self.find_regex)
        d.checks.append("In ~s~election")
        d.check_vals.append(multi)             # several lines selected: search inside them
        d.check_cols = 2
        d.at_bottom = True                     # leave the text and its matches in view
        d.payload = ai
        self.fo_cr = self.wins[ai].cr
        self.fo_cc = self.wins[ai].cc
        self.fo_sel = self.wins[ai].has_sel()
        self.fo_ar = self.wins[ai].ar
        self.fo_ac = self.wins[ai].ac
        self.fo_top = self.wins[ai].top
        self.wins[ai].scope_on = False
        self.show(d^)
        self.find_preview()

    def open_find_files(mut self):
        var seed = to_str(self.find_text)
        var ai = self.active_editor()
        if ai >= 0:
            var sel = self.wins[ai].selected_text()
            if len(sel) > 0 and not (10 in sel):
                seed = to_str(sel)
        var d = Dialog(D_FINDFILES, "Find in Files", 64, 12)
        d.lines.append("Folder: " + self.cwd)
        d.fields.append(Field("~T~ext to find", seed))
        d.fields[0].fresh = True
        d.buttons.append("~S~earch")
        d.buttons.append("~C~ancel")
        d.checks.append("Case sens~i~tive")
        d.check_vals.append(self.find_case)
        d.checks.append("~W~hole words")
        d.check_vals.append(self.find_word)
        d.checks.append("Regular e~x~pression")
        d.check_vals.append(self.find_regex)
        d.check_cols = 2
        self.show(d^)

    def find_window(self) -> Int:
        """The editor the open Find dialog works on (-1 if it is gone)."""
        var ai = self.dlg.payload
        if ai < 0 or ai >= len(self.wins) or self.wins[ai].kind != WK_EDITOR:
            return -1
        return ai

    def find_restore(mut self, ai: Int):
        """Put the cursor, selection and scroll position back where the dialog found them."""
        var last = self.wins[ai].buf.count() - 1
        self.wins[ai].cr = min(self.fo_cr, last)
        self.wins[ai].cc = self.fo_cc
        self.wins[ai].sel = self.fo_sel
        self.wins[ai].ar = min(self.fo_ar, last)
        self.wins[ai].ac = self.fo_ac
        self.wins[ai].top = self.fo_top
        self.wins[ai].clamp()
        self.wins[ai].sync_want()

    def find_signature(self) -> String:
        var sig = to_str(self.dlg.fields[0].text)
        for v in self.dlg.check_vals:
            sig += "\n1" if v else "\n0"
        return sig

    def find_refresh(mut self):
        """Incremental search: called after every event while the Find dialog is open."""
        if self.find_signature() != self.find_sig:
            self.find_preview()

    def find_preview(mut self):
        """Show the dialog's current search in the editor: select the first match at or
        after the place the search started from, highlight all matches, and report the
        count (or the pattern error) in the dialog."""
        self.find_sig = self.find_signature()
        var ai = self.find_window()
        if ai < 0:
            return
        self.find_restore(ai)
        var s = make_search(self.dlg.fields[0].text, self.dlg.check_vals[0], self.dlg.check_vals[1], self.dlg.check_vals[2])
        var in_sel = self.dlg.check_vals[3]
        if not in_sel:
            self.wins[ai].scope_on = False
        elif not self.wins[ai].scope_on and self.fo_sel:
            self.wins[ai].scope = self.wins[ai].sel_range()
            self.wins[ai].scope_on = True
        if len(s.pat) == 0:
            self.wins[ai].clear_highlight()
            self.dlg.note = ""
            return
        if not s.ok:
            self.wins[ai].clear_highlight()
            self.dlg.note = "Pattern error: " + s.error
            return
        if in_sel and not self.wins[ai].scope_on:
            self.wins[ai].clear_highlight()
            self.dlg.note = "Nothing is selected"
            return
        self.wins[ai].set_highlight(s)
        if self.wins[ai].buf.count() > PREVIEW_LINE_LIMIT:
            self.dlg.note = "Large text: press Enter to search"
            return
        var r0 = self.wins[ai].cr
        var c0 = self.wins[ai].cc
        if self.wins[ai].has_sel():
            var q = self.wins[ai].sel_range()
            r0 = q.r1
            c0 = q.c1
        if self.wins[ai].scope_on:
            var sc = self.wins[ai].scope.copy()
            if r0 < sc.r1 or (r0 == sc.r1 and c0 < sc.c1) or r0 > sc.r2:
                r0 = sc.r1
                c0 = sc.c1
        if not self.wins[ai].search_from(s, r0, c0):
            self.dlg.note = "No matches" + (" in the selection" if self.wins[ai].scope_on else "")
            return
        self.dlg.note = self.match_note(ai, s)
        self.find_keep_in_view(ai)

    def find_keep_in_view(mut self, ai: Int):
        """Scroll so the selected match is not hidden behind the dialog."""
        self.wins[ai].ensure_visible()
        var dh = min(self.dlg.h, self.scr.h - 2)
        var dy = max(1, self.scr.h - dh - 1)
        var row_y = self.wins[ai].cursor_cell().r
        if row_y >= dy:
            self.wins[ai].top = max(0, self.wins[ai].cr - 2)
            self.wins[ai].top_seg = 0

    def find_close(mut self, restore: Bool):
        self.mode = M_NORMAL
        var ai = self.find_window()
        if ai < 0:
            return
        self.wins[ai].scope_on = False
        if restore:
            self.find_restore(ai)
            self.wins[ai].clear_highlight()

    def dismiss_dialog(mut self):
        """Esc or the close box."""
        if self.dlg.kind == D_FIND or self.dlg.kind == D_REPLACE:
            self.find_close(True)
        else:
            self.mode = M_NORMAL
            if self.dlg.kind == D_DOCFIND and self.doc_find_back:
                self.mode = M_DOCS              # back to the page the finder was opened from
            if self.dlg.kind == D_RENAME_APPLY:
                self.act_command_due = False
                self.say(self.edit_noun + " cancelled - nothing was changed")

    def find_button(mut self, b: Int):
        var kind = self.dlg.kind
        var ai = self.find_window()
        if b == len(self.dlg.buttons) - 1 or ai < 0:
            self.find_close(True)
            return
        var big = self.wins[ai].buf.count() > PREVIEW_LINE_LIMIT
        self.find_preview()             # the editor now shows exactly what the dialog says
        self.find_text = self.dlg.fields[0].text.copy()
        self.find_case = self.dlg.check_vals[0]
        self.find_word = self.dlg.check_vals[1]
        self.find_regex = self.dlg.check_vals[2]
        if kind == D_REPLACE:
            self.replace_text = self.dlg.fields[1].text.copy()
        var s = self.current_search()
        if len(s.pat) == 0:
            self.find_close(True)
            return
        if not s.ok:
            return                      # stay open: the note shows what is wrong
        if big:
            # no live preview on a huge text: search now, from where the cursor was
            _ = self.wins[ai].search_next(s)
        if kind == D_FIND:
            var found = self.wins[ai].sel_is_match(s)
            var note = self.dlg.note
            self.find_close(not found)
            if not found:
                self.info("Information", "Search string not found.")
            else:
                self.say(self.match_note(ai, s) if big else note)
        elif b == 1:
            var n = self.wins[ai].replace_matches(s, self.replace_text)
            self.find_close(False)
            self.wins[ai].clear_highlight()
            self.say(String(n) + " occurrence(s) replaced")
        else:
            # replace this match and move to the next one; the dialog stays open
            if not self.wins[ai].replace_current(s, self.replace_text):
                self.dlg.note = "No matches"
                return
            self.fo_cr = self.wins[ai].cr
            self.fo_cc = self.wins[ai].cc
            self.fo_sel = False
            self.fo_top = self.wins[ai].top
            self.find_preview()
            if big:
                _ = self.wins[ai].search_next(s)
            if not self.wins[ai].sel_is_match(s):
                self.dlg.note = "Replaced. No more matches"

    def dialog_key(mut self, k: Int) raises:
        if self.dlg.kind == D_RESULT:
            # any key closes the box; editing keys are not swallowed
            self.mode = M_NORMAL
            if k != KEY_ESC and k != KEY_ENTER and k != 32:
                self.handle_key(k)
            return
        if k == KEY_ESC:
            self.dismiss_dialog()
            return
        if k & MOD_ALT != 0 and (self.dlg.kind == D_FIND or self.dlg.kind == D_REPLACE or self.dlg.kind == D_FINDFILES):
            # Alt+letter reaches every control, also while typing in a field
            var hk = lower(k & KEY_MASK)
            for i in range(len(self.dlg.fields)):
                if hot_char(self.dlg.fields[i].label) == hk:
                    self.dlg.focus = i
                    return
            for i in range(len(self.dlg.checks)):
                if hot_char(self.dlg.checks[i]) == hk:
                    self.dlg.check_vals[i] = not self.dlg.check_vals[i]
                    return
            for i in range(len(self.dlg.buttons)):
                if hot_char(self.dlg.buttons[i]) == hk:
                    self.dialog_button(i)
                    return
        var nf = self.dlg.n_focus()
        if k == KEY_TAB:
            if nf > 0:
                self.dlg.focus = (self.dlg.focus + 1) % nf
            return
        if k == (KEY_TAB | MOD_SHIFT):
            if nf > 0:
                self.dlg.focus = (self.dlg.focus - 1 + nf) % nf
            return
        var fi = self.dlg.focus_field()
        var ci = self.dlg.focus_check()
        var bi = self.dlg.focus_button()
        if k == KEY_ENTER:
            if ci >= 0:
                self.dlg.check_vals[ci] = not self.dlg.check_vals[ci]
                return
            self.dialog_button(bi if bi >= 0 else 0)
            return
        if self.dlg.has_list and (k == KEY_UP or k == KEY_DOWN or k == KEY_PGUP or k == KEY_PGDN):
            var d = -1 if k == KEY_UP else (1 if k == KEY_DOWN else (-10 if k == KEY_PGUP else 10))
            self.dlg.list_move(d)
            return
        if k == KEY_UP or k == KEY_DOWN:
            if nf > 0:
                self.dlg.focus = (self.dlg.focus + (1 if k == KEY_DOWN else nf - 1)) % nf
            return
        if fi >= 0:
            if k == KEY_LEFT or k == KEY_RIGHT or k == KEY_HOME or k == KEY_END:
                self.dlg.fields[fi].fresh = False       # moving the cursor keeps the text
            if k == KEY_LEFT:
                self.dlg.fields[fi].cur = max(0, self.dlg.fields[fi].cur - 1)
            elif k == KEY_RIGHT:
                self.dlg.fields[fi].cur = min(len(self.dlg.fields[fi].text), self.dlg.fields[fi].cur + 1)
            elif k == KEY_HOME:
                self.dlg.fields[fi].cur = 0
            elif k == KEY_END:
                self.dlg.fields[fi].cur = len(self.dlg.fields[fi].text)
            elif k == KEY_BACKSPACE:
                self.dlg.field_backspace(fi)
            elif k == KEY_DELETE:
                self.dlg.field_delete(fi)
            elif k == ctrl(118):
                self.dlg.field_key_insert(fi, self.clipboard)
            elif k == ctrl(117):
                self.dlg.fields[fi].text.clear()
                self.dlg.fields[fi].cur = 0
                if self.dlg.list_filter and fi == 0:
                    self.dlg.refilter()
            elif k < K_BASE and k >= 32:
                var t = List[Int]()
                t.append(k)
                self.dlg.field_key_insert(fi, t)
            return
        if ci >= 0 and k == 32:
            self.dlg.check_vals[ci] = not self.dlg.check_vals[ci]
            return
        if bi >= 0 and (k == KEY_LEFT or k == KEY_RIGHT):
            var nb = len(self.dlg.buttons)
            var nbi = (bi + (1 if k == KEY_RIGHT else nb - 1)) % nb
            self.dlg.focus = self.dlg.button_focus_index(nbi)
            return
        if k < K_BASE and k >= 32:
            var lk = lower(k & KEY_MASK)
            for i in range(len(self.dlg.buttons)):
                if hot_char(self.dlg.buttons[i]) == lk:
                    self.dialog_button(i)
                    return
            if self.dlg.list_filter and len(self.dlg.fields) > 0:
                self.dlg.focus = 0
                var t = List[Int]()
                t.append(k)
                self.dlg.field_key_insert(0, t)
            elif self.dlg.has_list:
                # type-ahead: jump to the first item starting with this letter
                for i in range(len(self.dlg.shown)):
                    var cps = decode(self.dlg.items[self.dlg.shown[i]])
                    if len(cps) > 0 and lower(cps[0]) == lk:
                        self.dlg.list_move(i - self.dlg.list_sel)
                        break
        if k & MOD_ALT != 0:
            var lk = lower(k & KEY_MASK)
            for i in range(len(self.dlg.buttons)):
                if hot_char(self.dlg.buttons[i]) == lk:
                    self.dialog_button(i)
                    return
