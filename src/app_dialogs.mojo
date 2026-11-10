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
from buffer import TextBuffer, Pos
from window import Window, WK_EDITOR, WK_MESSAGE, ACT_OTHER, ACT_TYPE
from window_search import *
from window_draw import *
from menu import *
from commands import *
from dialog import *
from util import *
from appstate import *
from app_swap import *
from swap import *
from app_files import *
from app_menus import *
from app_exec import *
from app_pickers import *
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
        elif kind == D_FIND and b == 0:
            self.find_text = self.dlg.fields[0].text.copy()
            self.find_case = self.dlg.check_vals[0]
            self.find_again()
        elif kind == D_REPLACE and b <= 1:
            self.find_text = self.dlg.fields[0].text.copy()
            self.replace_text = self.dlg.fields[1].text.copy()
            self.find_case = self.dlg.check_vals[0]
            var ai = self.active_editor()
            if ai < 0:
                return
            if b == 1:
                var n = self.wins[ai].replace_all(self.find_text, self.replace_text, self.find_case)
                self.say(String(n) + " occurrence(s) replaced")
            else:
                if not self.wins[ai].sel_matches(self.find_text, self.find_case):
                    _ = self.wins[ai].find_next(self.find_text, self.find_case)
                if self.wins[ai].sel_matches(self.find_text, self.find_case):
                    self.wins[ai].insert_text(self.replace_text, ACT_OTHER)
                    self.wins[ai].break_group()
                    if not self.wins[ai].find_next(self.find_text, self.find_case):
                        self.say("No more matches")
                else:
                    self.info("Information", "Search string not found.")
        elif kind == D_GOTO and b == 0:
            var ai = self.active_editor()
            var t = self.dlg.field_text(0)
            if ai >= 0 and t.byte_length() > 0:
                try:
                    var n = atol(t)
                    self.wins[ai].goto(n - 1, 0)
                except:
                    self.say("Invalid line number")
        elif kind == D_PALETTE and b == 0:
            var s = self.dlg.selected_item()
            if s >= 0:
                self.exec(self.dlg.item_data[s])
        elif kind == D_SYMBOL and b == 0:
            var s = self.dlg.selected_item()
            var ai = self.active_editor()
            if s >= 0 and ai >= 0:
                self.wins[ai].goto(self.dlg.item_data[s], self.wins[ai].indent_of(self.dlg.item_data[s]))
        elif kind == D_WINLIST and b == 0:
            var s = self.dlg.selected_item()
            if s >= 0:
                self.focus(self.dlg.item_data[s])
        elif kind == D_ARGS and b == 0:
            self.run_args = self.dlg.field_text(0)
        elif kind == D_RECOVER:
            if b == 0:
                _ = self.recover_swaps()
            elif b == 1:
                self.discard_swaps()
            else:
                self.pending_swaps.clear()      # "Later": ask again next time
        elif kind == D_COMPILER and b == 0:
            var c = self.dlg.field_text(0)
            if c.byte_length() > 0:
                self.compiler = c
                self.persist_option("tools", "compiler", toml_quote(c))
                self.say("Compiler: " + c)

    def dialog_key(mut self, k: Int) raises:
        if self.dlg.kind == D_RESULT:
            # any key closes the box; editing keys are not swallowed
            self.mode = M_NORMAL
            if k != KEY_ESC and k != KEY_ENTER and k != 32:
                self.handle_key(k)
            return
        if k == KEY_ESC:
            self.mode = M_NORMAL
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
