"""The file explorer window: the project's files as a tree at the left edge."""
from responsive import explorer_width, outline_width, docpane_width
from glyphs import GLYPHS_NERD
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
from app_docs import *
from app_debug import *
from app_terminal import *
from app_tests import *
from app_git import *
from outline import *
from symindex import *
from docs import *
from watch import file_sig
from app_input import *
from app_mouse import *
from app_draw import *


comptime EXOP_NEW_FILE = 1
comptime EXOP_NEW_FOLDER = 2
comptime EXOP_RENAME = 3
comptime EXOP_MOVE = 4
comptime EX_REFRESH_MS = 2000


__extension App:
    def explorer_toggle(mut self):
        """Window > File explorer: open it (or go to it); from inside it: close it."""
        var xi = self.explorer_index()
        if xi >= 0:
            if self.top() != xi:
                self.focus(xi)
                return
            var w = self.wins[xi].w
            _ = self.wins.pop(xi)
            # the editors that made room get it back
            for i in range(len(self.wins)):
                if self.wins[i].kind == WK_EDITOR and self.wins[i].x == w:
                    self.wins[i].x = 0
                    self.wins[i].w += w
            self.layout_sync()
            return
        var w = explorer_width(self.scr.w)
        var h = self.desk_h()
        var mi = self.msg_index()
        if mi >= 0:
            h = max(6, self.wins[mi].y - 1)
        var win = Window(WK_EXPLORER, "Files", "", 0, 1, w, h, self.free_number())
        for i in range(len(self.wins)):
            if self.wins[i].kind == WK_EDITOR and self.wins[i].x < w and self.wins[i].x + self.wins[i].w - w >= 20:
                self.wins[i].w -= w - self.wins[i].x
                self.wins[i].x = w
        var te = self.top_editor()
        var current = self.wins[te].path if te >= 0 else String("")
        self.wins.append(win^)
        self.ex.set_root(self.symidx_root())
        var row = self.ex.reveal(current) if current.byte_length() > 0 else -1
        self.explorer_show()
        var t = self.top()
        self.wins[t].cr = max(0, row)
        self.wins[t].follow = True
        self.ex_checked_ns = now_ns()
        self.layout_sync()

    def explorer_show(mut self):
        """Put the tree's rows into the explorer window."""
        var xi = self.explorer_index()
        if xi < 0:
            return
        var text = List[Int]()
        var codes = List[Int]()
        for k in range(len(self.ex.rows)):
            if k > 0:
                text.append(10)
            var line = self.ex.line(k, self.scr.glyphs == GLYPHS_NERD)
            # git: the file's state as a letter after its name (folders: a dot)
            var code = self.git.code_of(self.ex.rows[k].path)
            codes.append(code)
            if code != GS_NONE:
                line += "  " + (String("•") if self.ex.rows[k].dir else status_letter(code))
            for c in decode(line):
                text.append(c)
        self.wins[xi].git_rows = codes^
        self.wins[xi].title = explorer_title(self.git.branch, self.ex.filter, len(self.ex.rows), self.ex.hidden_rows)
        if len(self.ex.rows) == 0:
            text = decode("(no files)" if self.ex.filter.byte_length() == 0 else "(no names contain \"" + self.ex.filter + "\" - C shows all)")
        if text == self.wins[xi].buf.all_text():
            return
        var keep = self.wins[xi].cr
        var keep_top = self.wins[xi].top
        self.wins[xi].buf.load(text)
        self.wins[xi].buf.modified = False
        self.wins[xi].cr = max(0, min(keep, self.wins[xi].buf.count() - 1))
        self.wins[xi].top = max(0, min(keep_top, self.wins[xi].buf.count() - 1))

    def explorer_tick(mut self, now: Int):
        """Now and then the open folders are read again, so files made or removed
        elsewhere show up; with the keyboard elsewhere the file being edited is marked."""
        var xi = self.explorer_index()
        if xi < 0:
            return
        if now - self.ex_checked_ns > EX_REFRESH_MS * 1000000:
            self.ex_checked_ns = now
            var marked = self.ex.rows[self.wins[xi].cr].path if self.wins[xi].cr < len(self.ex.rows) else String("")
            self.ex.rebuild()
            self.explorer_show()
            var again = self.ex.row_of(marked)
            if again >= 0:
                self.wins[xi].cr = again
        if self.top() != xi:
            var te = self.top_editor()
            if te >= 0:
                var row = self.ex.row_of(self.wins[te].path)
                if row >= 0 and self.wins[xi].cr != row:
                    self.wins[xi].cr = row
                    self.wins[xi].follow = True

    def explorer_refresh(mut self, mark: String):
        """After a change: read the folders again and mark `mark` (if it is shown)."""
        self.ex.rebuild()
        var row = self.ex.reveal(mark) if mark.byte_length() > 0 else -1
        self.explorer_show()
        var xi = self.explorer_index()
        if xi >= 0:
            if row >= 0:
                self.wins[xi].cr = row
            self.wins[xi].cr = max(0, min(self.wins[xi].cr, self.wins[xi].buf.count() - 1))
            self.wins[xi].follow = True
        self.ex_checked_ns = now_ns()

    def explorer_key(mut self, k: Int) raises -> Bool:
        """Keys in the explorer window beyond moving the mark. True if the key was used."""
        var t = self.top()
        var row = self.wins[t].cr
        var has = row >= 0 and row < len(self.ex.rows)
        if k == KEY_ESC:
            var te = self.top_editor()
            if te >= 0:
                self.focus(te)
            return True
        if k == KEY_ENTER or k == 32:
            if not has:
                return True
            if self.ex.rows[row].dir:
                self.ex.toggle(row)
                self.explorer_show()
            else:
                self.jump_mark()
                var chosen = self.ex.rows[row].path
                self.open_path(chosen)
                self.layout_sync()
            return True
        if k == KEY_RIGHT:
            if has and self.ex.rows[row].dir:
                if not self.ex.rows[row].open:
                    self.ex.toggle(row)
                    self.explorer_show()
                elif row + 1 < len(self.ex.rows) and self.ex.rows[row + 1].depth > self.ex.rows[row].depth:
                    self.wins[t].cr = row + 1
            return True
        if k == KEY_LEFT:
            if has and self.ex.rows[row].dir and self.ex.rows[row].open:
                self.ex.toggle(row)
                self.explorer_show()
            elif has:
                var up = self.ex.parent_row(row)
                if up >= 0:
                    self.wins[t].cr = up
            self.wins[t].follow = True
            return True
        if k == 46:                             # "." : what is ignored, too
            self.ex.show_all = not self.ex.show_all
            self.explorer_refresh(self.ex.rows[row].path if has else String(""))
            self.say("Hidden and ignored files are " + ("shown" if self.ex.show_all else "left out"))
            return True
        if k == 47:                             # "/": show only names containing ...
            var d = Dialog(D_EX_FILTER, "Filter files", min(60, self.scr.w - 4), 9)
            d.lines.append("Show the names containing (any case; empty: all):")
            d.fields.append(Field("~T~ext", self.ex.filter))
            d.fields[0].fresh = True
            d.buttons.append("~O~K")
            d.buttons.append("Cancel")
            self.show(d^)
            return True
        if (k == 99 or k == 67) and self.ex.filter.byte_length() > 0:      # "c": all again
            self.explorer_filter("")
            return True
        if k == 117 or k == 85:                 # "u": read the folders again
            self.explorer_refresh(self.ex.rows[row].path if has else String(""))
            return True
        if k == 110 or k == 78 or k == 102 or k == 70:      # n / f: new file / folder
            var folder = self.ex.folder_for(row if has else -1)
            self.ex_op = EXOP_NEW_FILE if (k == 110 or k == 78) else EXOP_NEW_FOLDER
            self.ex_target = folder
            var d = Dialog(D_EX_NAME, "New File" if self.ex_op == EXOP_NEW_FILE else "New Folder", min(60, self.scr.w - 4), 8)
            d.lines.append("In " + self.explorer_rel(folder))
            d.fields.append(Field("~N~ame", ""))
            d.buttons.append("~O~K")
            d.buttons.append("~C~ancel")
            self.show(d^)
            return True
        if not has:
            return k < K_BASE and k >= 32       # letters do nothing here
        if k == 114 or k == 82:                 # r: rename
            self.ex_op = EXOP_RENAME
            self.ex_target = self.ex.rows[row].path
            var d = Dialog(D_EX_NAME, "Rename", min(60, self.scr.w - 4), 8)
            d.lines.append("Rename " + self.explorer_rel(self.ex_target))
            d.fields.append(Field("~N~ew name", self.ex.rows[row].name))
            d.fields[0].fresh = True
            d.buttons.append("~O~K")
            d.buttons.append("~C~ancel")
            self.show(d^)
            return True
        if k == 109 or k == 77:                 # m: move
            self.ex_op = EXOP_MOVE
            self.ex_target = self.ex.rows[row].path
            var d = Dialog(D_EX_NAME, "Move", min(60, self.scr.w - 4), 8)
            d.lines.append("Move " + self.explorer_rel(self.ex_target) + " to the folder (empty: the project folder)")
            var here = self.explorer_rel(dirname(self.ex_target))
            d.fields.append(Field("~F~older", "" if here == "." else here))
            d.fields[0].fresh = True
            d.buttons.append("~O~K")
            d.buttons.append("~C~ancel")
            self.show(d^)
            return True
        if k == KEY_DELETE:
            self.ex_target = self.ex.rows[row].path
            var d = Dialog(D_EX_DELETE, "Delete", min(64, self.scr.w - 4), 9)
            d.lines.append("Move " + self.explorer_rel(self.ex_target) + (" and everything in it" if self.ex.rows[row].dir else "") + " to the trash?")
            d.lines.append("(" + self.trash_dir + ")")
            d.buttons.append("~M~ove to trash")
            d.buttons.append("~C~ancel")
            d.focus = d.button_focus_index(1)   # the safe answer is the one under Enter
            self.show(d^)
            return True
        return k < K_BASE and k >= 32           # other letters are not typed into the list

    def explorer_filter(mut self, text: String):
        """Show only the files and folders whose name contains `text` ('' all)."""
        var t = self.top()
        var keep = String("")
        if t >= 0 and self.wins[t].kind == WK_EXPLORER and self.wins[t].cr < len(self.ex.rows):
            keep = self.ex.rows[self.wins[t].cr].path
        self.ex.filter = text
        self.explorer_refresh(keep)
        if text.byte_length() > 0:
            self.say(String(len(self.ex.rows)) + " shown, " + String(self.ex.hidden_rows) + " left out - C shows all")

    def explorer_rel(self, path: String) -> String:
        """A path as shown to the user: from the project folder."""
        if path == self.ex.root:
            return "."
        if path.startswith(self.ex.root + "/"):
            return slice_str(decode(path), cp_len(self.ex.root) + 1, cp_len(path))
        return path

    def explorer_moved(mut self, old: String, new: String):
        """A file or folder has a new place: open windows follow it."""
        for i in range(len(self.wins)):
            if self.wins[i].kind != WK_EDITOR:
                continue
            var p = self.wins[i].path
            if p == old:
                self.wins[i].path = new
                self.wins[i].title = basename(new)
            elif p.startswith(old + "/"):
                self.wins[i].path = new + slice_str(decode(p), cp_len(old), cp_len(p))

    def explorer_apply(mut self, typed: String):
        """The name dialog was confirmed."""
        var text = String(typed.strip())
        var op = self.ex_op
        var target = self.ex_target
        var why = String("")
        var mark = String("")
        if op == EXOP_NEW_FILE:
            why = make_file(self.ex_target, text)
            mark = join_path(self.ex_target, text)
        elif op == EXOP_NEW_FOLDER:
            why = make_folder(self.ex_target, text)
            mark = join_path(self.ex_target, text)
        elif op == EXOP_RENAME:
            why = name_problem(text)
            mark = join_path(dirname(self.ex_target), text)
            if why.byte_length() == 0 and mark != self.ex_target:
                why = move_path(self.ex_target, mark)
                if why.byte_length() == 0:
                    self.explorer_moved(target, mark)
        elif op == EXOP_MOVE:
            var folder = self.ex.root
            for part in text.split("/"):
                var seg = String(String(part).strip())
                if seg == "..":
                    why = "The folder must be inside the project"
                elif seg.byte_length() > 0 and seg != ".":
                    folder = join_path(folder, seg)
            mark = join_path(folder, basename(self.ex_target))
            if why.byte_length() == 0 and text.startswith("/"):
                why = "Give the folder from the project folder, without a leading slash"
            if why.byte_length() == 0 and mark != self.ex_target:
                why = move_path(self.ex_target, mark)
                if why.byte_length() == 0:
                    self.explorer_moved(target, mark)
        if why.byte_length() > 0:
            self.say(why)
            return
        self.explorer_refresh(mark)
        if op == EXOP_NEW_FILE:
            try:
                self.open_path(mark)            # a new file is for writing in
                self.layout_sync()
            except e:
                self.say("Created " + self.explorer_rel(mark))
            return
        if op == EXOP_NEW_FOLDER:
            self.say("Created the folder " + self.explorer_rel(mark))
        elif op == EXOP_RENAME:
            self.say("Renamed to " + basename(mark))
        else:
            self.say("Moved to " + self.explorer_rel(mark))

    def explorer_delete(mut self):
        var path = self.ex_target
        var why = trash_path(path, self.trash_dir)
        if why.byte_length() > 0:
            self.say(why)
            return
        # windows that showed it keep their text: it can be saved back
        var still = 0
        for i in range(len(self.wins)):
            if self.wins[i].kind == WK_EDITOR and (self.wins[i].path == path or self.wins[i].path.startswith(path + "/")):
                self.wins[i].buf.modified = True
                still += 1
        self.explorer_refresh("")
        self.say("Moved " + basename(path) + " to the trash" + (" - still open here, Save writes it back" if still > 0 else ""))


def explorer_title(branch: String, filter: String, shown: Int, hidden: Int) -> String:
    """The explorer's title: "Files (main)"; with a filter its count first, then the
    filter - "2/9 /test" - so a narrow panel still shows the count."""
    if filter.byte_length() > 0:
        return String(shown) + "/" + String(shown + hidden) + " /" + filter
    return String("Files") if branch.byte_length() == 0 else "Files (" + branch + ")"
