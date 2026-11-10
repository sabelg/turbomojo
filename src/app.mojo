"""TurboMojo application: desktop, event loop, commands, compiler integration."""
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
from menu import *
from commands import *
from dialog import *
from util import *

comptime M_NORMAL = 0
comptime M_MENU = 1
comptime M_DIALOG = 2
comptime M_COMPLETE = 3

comptime VERSION = "1.0"


comptime JOB_BUILD = 1
comptime JOB_FORMAT = 2
comptime SPINNER = "⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏"


struct Job(Copyable, Movable):
    var active: Bool
    var kind: Int
    var fp: Int
    var fd: Int
    var pid: Int
    var data: List[UInt8]
    var t0: Int
    var path: String
    var exe: String
    var cancelled: Bool
    var version: Int

    def __init__(out self):
        self.active = False
        self.kind = 0
        self.fp = 0
        self.fd = -1
        self.pid = 0
        self.data = List[UInt8]()
        self.t0 = 0
        self.path = ""
        self.exe = ""
        self.cancelled = False
        self.version = -1


@fieldwise_init
struct ErrLoc(Copyable, Movable):
    var path: String
    var row: Int
    var col: Int
    var msg_line: Int


struct App(Movable):
    var term: Terminal
    var scr: Screen
    var pal: Palette
    var theme_idx: Int
    var hl: Highlighter
    var wins: List[Window]
    var reg: Registry
    var menus: List[Menu]
    var mode: Int
    var menu_idx: Int
    var menu_item: Int
    var dlg: Dialog
    var clipboard: List[Int]
    var line_numbers: Bool
    var auto_indent: Bool
    var hl_line: Bool
    var insert_mode: Bool
    var show_clock: Bool
    var running: Bool
    var find_text: List[Int]
    var replace_text: List[Int]
    var find_case: Bool
    var run_args: String
    var compiler: String
    var errs: List[ErrLoc]
    var err_idx: Int
    var status: String
    var status_ttl: Int
    var drag: Int
    var drag_dx: Int
    var drag_dy: Int
    var untitled_n: Int
    var cwd: String
    var comp_items: List[String]
    var comp_sel: Int
    var comp_start: Int
    var st_x0: List[Int]
    var st_x1: List[Int]
    var st_cmd: List[Int]
    var last_click_item: Int
    var job: Job
    var tick: Int
    var show_ws: Bool

    def __init__(out self):
        self.term = Terminal()
        var sz = self.term.size()
        self.scr = Screen(sz[0], sz[1])
        self.theme_idx = 0
        self.pal = theme(0)
        self.hl = Highlighter()
        self.wins = List[Window]()
        self.reg = build_registry()
        self.menus = build_menus(self.reg)
        self.mode = M_NORMAL
        self.menu_idx = 0
        self.menu_item = 0
        self.dlg = Dialog(D_NONE, "", 10, 5)
        self.clipboard = List[Int]()
        self.line_numbers = True
        self.auto_indent = True
        self.hl_line = True
        self.insert_mode = True
        self.show_clock = True
        self.running = True
        self.find_text = List[Int]()
        self.replace_text = List[Int]()
        self.find_case = False
        self.run_args = ""
        self.compiler = env_or("TURBOMOJO_COMPILER", "mojo")
        self.errs = List[ErrLoc]()
        self.err_idx = -1
        self.status = ""
        self.status_ttl = 0
        self.drag = 0
        self.drag_dx = 0
        self.drag_dy = 0
        self.untitled_n = 0
        self.cwd = getcwd()
        self.comp_items = List[String]()
        self.comp_sel = 0
        self.comp_start = 0
        self.st_x0 = List[Int]()
        self.st_x1 = List[Int]()
        self.st_cmd = List[Int]()
        self.last_click_item = -1
        self.job = Job()
        self.tick = 0
        self.show_ws = False

    # =================================================================== utils
    def desk_h(self) -> Int:
        return max(3, self.scr.h - 2)

    def top(self) -> Int:
        return len(self.wins) - 1

    def active_editor(self) -> Int:
        """Index of the active window if it is an editor, else -1."""
        var t = self.top()
        if t >= 0 and self.wins[t].kind == WK_EDITOR:
            return t
        return -1

    def top_editor(self) -> Int:
        var i = len(self.wins) - 1
        while i >= 0:
            if self.wins[i].kind == WK_EDITOR:
                return i
            i -= 1
        return -1

    def msg_index(self) -> Int:
        for i in range(len(self.wins)):
            if self.wins[i].kind == WK_MESSAGE:
                return i
        return -1

    def focus(mut self, i: Int):
        if i < 0 or i >= len(self.wins) or i == len(self.wins) - 1:
            return
        var w = self.wins.pop(i)
        self.wins.append(w^)

    def say(mut self, msg: String):
        self.status = msg
        self.status_ttl = 40

    def free_number(self) -> Int:
        for n in range(1, 10):
            var used = False
            for w in self.wins:
                if w.number == n:
                    used = True
            if not used:
                return n
        return 0

    def new_editor(mut self, title: String, path: String) -> Int:
        var k = 0
        for w in self.wins:
            if w.kind == WK_EDITOR:
                k += 1
        var off = k % 6
        var dh = self.desk_h()
        var mi = self.msg_index()
        if mi >= 0:
            dh = max(6, self.wins[mi].y - 1)
        var win = Window(WK_EDITOR, title, path, off, 1 + off, self.scr.w - off, dh - off, self.free_number())
        win.gut = win.gutter_for(self.line_numbers)
        self.wins.append(win^)
        return len(self.wins) - 1

    def ensure_msg(mut self) -> Int:
        var mi = self.msg_index()
        if mi >= 0:
            return mi
        var h = max(5, min(10, self.desk_h() // 3))
        var y = 1 + self.desk_h() - h
        var win = Window(WK_MESSAGE, "Message", "", 0, y, self.scr.w, h, self.free_number())
        # shrink full-height editors so the message window does not cover them
        for i in range(len(self.wins)):
            if self.wins[i].kind == WK_EDITOR and self.wins[i].y + self.wins[i].h > y and y - self.wins[i].y >= 6:
                self.wins[i].h = y - self.wins[i].y
                if self.wins[i].zoomed:
                    self.wins[i].sh = self.wins[i].h
        self.wins.insert(0, win^)
        return 0

    def fit_windows(mut self):
        var W = self.scr.w
        var dh = self.desk_h()
        for i in range(len(self.wins)):
            if self.wins[i].zoomed:
                self.wins[i].x = 0
                self.wins[i].y = 1
                self.wins[i].w = W
                self.wins[i].h = dh
            else:
                self.wins[i].w = max(16, min(self.wins[i].w, W))
                self.wins[i].h = max(4, min(self.wins[i].h, dh))
                self.wins[i].x = max(0, min(self.wins[i].x, W - self.wins[i].w))
                self.wins[i].y = max(1, min(self.wins[i].y, 1 + dh - self.wins[i].h))

    def osc52(mut self, text: List[Int]):
        var b = List[UInt8]()
        for c in text:
            encode_cp(c, b)
        append_str(self.term.out, "\x1b]52;c;" + base64(b) + "\x07")
        self.term.flush()

    # ================================================================ files
    def open_path(mut self, path: String) raises:
        var p = abs_path(self.cwd, path)
        for i in range(len(self.wins)):
            if self.wins[i].kind == WK_EDITOR and self.wins[i].path == p:
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
            var txt: String
            with open(p, "r") as f:
                txt = f.read()
            self.wins[i].buf.load(decode(txt))
            self.wins[i].cr = 0
            self.wins[i].cc = 0
            self.wins[i].top = 0
            self.say("Loaded " + p)
        else:
            self.say("New file: " + p)

    def save_window(mut self, i: Int, next: Int) raises -> Bool:
        if self.wins[i].path.byte_length() == 0:
            self.saveas_dialog(i, next)
            return False
        var b = self.wins[i].buf.to_bytes()
        with open(self.wins[i].path, "w") as f:
            f.write(bytes_to_str(b))
        self.wins[i].buf.modified = False
        self.say("Saved " + self.wins[i].path)
        return True

    def remove_window(mut self, i: Int):
        _ = self.wins.pop(i)

    def close_window(mut self, i: Int, next: Int):
        if i < 0:
            return
        if self.wins[i].kind == WK_EDITOR and self.wins[i].buf.modified:
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
        self.running = False

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
        elif kind == D_COMPILER and b == 0:
            var c = self.dlg.field_text(0)
            if c.byte_length() > 0:
                self.compiler = c
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

    # ================================================================= menus
    def open_menu(mut self, idx: Int):
        self.mode = M_MENU
        self.menu_idx = idx
        self.menu_item = 0
        while self.menu_item < len(self.menus[idx].items) and self.menus[idx].items[self.menu_item].cmd == CM_NONE:
            self.menu_item += 1

    def menu_step(mut self, d: Int):
        var n = len(self.menus[self.menu_idx].items)
        var i = self.menu_item
        for _ in range(n):
            i = (i + d + n) % n
            if self.menus[self.menu_idx].items[i].cmd != CM_NONE:
                break
        self.menu_item = i

    def menu_for_letter(self, c: Int) -> Int:
        for i in range(len(self.menus)):
            if hot_char(self.menus[i].title) == c:
                return i
        return -1

    def menu_key(mut self, k: Int) raises:
        var n = len(self.menus)
        if k == KEY_ESC or k == fkey(10):
            self.mode = M_NORMAL
        elif k == KEY_LEFT:
            self.open_menu((self.menu_idx - 1 + n) % n)
        elif k == KEY_RIGHT:
            self.open_menu((self.menu_idx + 1) % n)
        elif k == KEY_UP:
            self.menu_step(-1)
        elif k == KEY_DOWN:
            self.menu_step(1)
        elif k == KEY_HOME:
            self.open_menu(self.menu_idx)
        elif k == KEY_ENTER:
            var cmd = self.menus[self.menu_idx].items[self.menu_item].cmd
            self.mode = M_NORMAL
            self.exec(cmd)
        elif (k & MOD_ALT) != 0:
            var m = self.menu_for_letter(lower(k & KEY_MASK))
            if m >= 0:
                self.open_menu(m)
            else:
                self.mode = M_NORMAL
                self.handle_key(k)
        elif k < K_BASE and k > 32:
            var lk = lower(k)
            for i in range(len(self.menus[self.menu_idx].items)):
                if hot_char(self.menus[self.menu_idx].items[i].label) == lk:
                    var cmd = self.menus[self.menu_idx].items[i].cmd
                    self.mode = M_NORMAL
                    self.exec(cmd)
                    return
        else:
            var cmd = self.shortcut(k)
            if cmd != CM_NONE:
                self.mode = M_NORMAL
                self.exec(cmd)

    def checked(self) -> List[Int]:
        var out = List[Int]()
        if self.line_numbers:
            out.append(CM_LINENUM)
        if self.auto_indent:
            out.append(CM_AUTOINDENT)
        if self.hl_line:
            out.append(CM_HLLINE)
        if self.show_clock:
            out.append(CM_CLOCK)
        if self.show_ws:
            out.append(CM_SHOWWS)
        var ti = self.top_editor()
        if ti >= 0 and self.wins[ti].buf.use_tabs:
            out.append(CM_USETABS)
        if ti >= 0 and self.wins[ti].buf.crlf:
            out.append(CM_CRLF)
        out.append(CM_THEME0 + self.theme_idx)
        return out^

    # ============================================================= commands
    def shortcut(self, k: Int) -> Int:
        """Command bound to key k (bindings live in the command registry)."""
        return self.reg.find_key(k)

    def exec(mut self, cmd: Int) raises:
        var ai = self.active_editor()
        if cmd == CM_NEW:
            var name = String("NONAME")
            if self.untitled_n < 10:
                name += "0"
            name += String(self.untitled_n) + ".mojo"
            self.untitled_n += 1
            _ = self.new_editor(name, "")
        elif cmd == CM_OPEN:
            self.open_dialog(String(self.cwd))
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
            while i >= 0:
                if not (self.wins[i].kind == WK_EDITOR and self.wins[i].buf.modified):
                    self.remove_window(i)
                i -= 1
            if len(self.wins) > 0:
                self.say("Modified windows were kept open")
        elif cmd == CM_SHELL:
            self.term.leave()
            _ = run_system("printf '\\nType exit to return to TurboMojo...\\n\\n'; ${SHELL:-/bin/sh}")
            self.term.enter()
            self.scr.force = True
        elif cmd == CM_QUIT:
            self.quit()
        elif cmd == CM_UNDO:
            if ai >= 0:
                self.wins[ai].undo()
        elif cmd == CM_REDO:
            if ai >= 0:
                self.wins[ai].redo()
        elif cmd == CM_CUT or cmd == CM_COPY:
            var src = ai if ai >= 0 else self.top()
            if src >= 0 and self.wins[src].has_sel():
                self.clipboard = self.wins[src].selected_text()
                self.osc52(self.clipboard.copy())
                if cmd == CM_CUT and ai >= 0:
                    _ = self.wins[ai].delete_sel(self.wins[ai].new_group())
                    self.wins[ai].follow = True
                self.say(String(len(self.clipboard)) + " characters copied")
            elif src >= 0 and self.wins[src].kind == WK_MESSAGE:
                self.clipboard = self.wins[src].buf.lines[self.wins[src].cr].c.copy()
                self.osc52(self.clipboard.copy())
        elif cmd == CM_PASTE:
            if ai >= 0 and len(self.clipboard) > 0:
                self.wins[ai].insert_text(self.clipboard, ACT_OTHER)
                self.wins[ai].break_group()
        elif cmd == CM_CLEAR:
            if ai >= 0:
                _ = self.wins[ai].delete_sel(self.wins[ai].new_group())
        elif cmd == CM_SELALL:
            if ai >= 0:
                self.wins[ai].select_all()
        elif cmd == CM_COMMENT:
            if ai >= 0:
                self.wins[ai].toggle_comment()
        elif cmd == CM_DUPLINE:
            if ai >= 0:
                self.wins[ai].duplicate_line()
        elif cmd == CM_DELLINE:
            if ai >= 0:
                _ = self.wins[ai].delete_line()
        elif cmd == CM_COMPLETE:
            self.start_complete()
        elif cmd == CM_FIND or cmd == CM_REPLACE:
            if ai < 0:
                return
            var sel = self.wins[ai].selected_text()
            var seed = to_str(sel) if len(sel) > 0 and not (10 in sel) else to_str(self.find_text)
            var d = Dialog(D_FIND if cmd == CM_FIND else D_REPLACE, "Find" if cmd == CM_FIND else "Replace", 56, 11 if cmd == CM_FIND else 13)
            d.fields.append(Field("~T~ext to find", seed))
            if cmd == CM_REPLACE:
                d.fields.append(Field("~N~ew text", to_str(self.replace_text)))
                d.buttons.append("~R~eplace")
                d.buttons.append("Change ~a~ll")
            else:
                d.buttons.append("~O~K")
            d.buttons.append("~C~ancel")
            d.checks.append("~C~ase sensitive")
            d.check_vals.append(self.find_case)
            self.show(d^)
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
            self.palette_dialog()
        elif cmd == CM_RUN:
            self.run_program(False)
        elif cmd == CM_TEST:
            self.run_program(True)
        elif cmd == CM_USERSCREEN:
            self.term.leave()
            self.term.raw()
            self.term.wait_byte()
            self.term.enter()
            self.scr.force = True
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
        elif cmd == CM_NEXTERR:
            self.goto_error(1)
        elif cmd == CM_PREVERR:
            self.goto_error(-1)
        elif cmd == CM_LINENUM:
            self.line_numbers = not self.line_numbers
        elif cmd == CM_AUTOINDENT:
            self.auto_indent = not self.auto_indent
        elif cmd == CM_HLLINE:
            self.hl_line = not self.hl_line
        elif cmd == CM_CLOCK:
            self.show_clock = not self.show_clock
        elif cmd == CM_SHOWWS:
            self.show_ws = not self.show_ws
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
            self.cancel_job()
        elif cmd >= CM_THEME0 and cmd < CM_THEME0 + THEME_COUNT:
            self.theme_idx = cmd - CM_THEME0
            self.pal = theme(self.theme_idx)
            self.say("Theme: " + self.pal.name)
        elif cmd == CM_ZOOM:
            var t = self.top()
            if t >= 0:
                if self.wins[t].zoomed:
                    self.wins[t].zoomed = False
                    self.wins[t].x = self.wins[t].sx
                    self.wins[t].y = self.wins[t].sy
                    self.wins[t].w = self.wins[t].sw
                    self.wins[t].h = self.wins[t].sh
                else:
                    self.wins[t].sx = self.wins[t].x
                    self.wins[t].sy = self.wins[t].y
                    self.wins[t].sw = self.wins[t].w
                    self.wins[t].sh = self.wins[t].h
                    self.wins[t].zoomed = True
                self.fit_windows()
        elif cmd == CM_TILE or cmd == CM_CASCADE:
            self.arrange(cmd == CM_TILE)
        elif cmd == CM_NEXTWIN:
            if len(self.wins) > 1:
                self.focus(0)
        elif cmd == CM_PREVWIN:
            if len(self.wins) > 1:
                var w = self.wins.pop()
                self.wins.insert(0, w^)
        elif cmd == CM_MESSAGE:
            var mi = self.ensure_msg()
            self.focus(mi)
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
            self.help_dialog()
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
        elif cmd == CM_REFRESH:
            self.scr.force = True

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
                self.wins[i].x = (W * c) // cols
                self.wins[i].w = (W * (c + 1)) // cols - self.wins[i].x
                self.wins[i].y = 1 + (dh * r) // rows
                self.wins[i].h = 1 + (dh * (r + 1)) // rows - self.wins[i].y
        else:
            for k in range(n):
                var i = idx[k]
                var off = k % 8
                self.wins[i].zoomed = False
                self.wins[i].x = off
                self.wins[i].y = 1 + off
                self.wins[i].w = W - off
                self.wins[i].h = dh - off
        self.fit_windows()

    def find_again(mut self):
        var ai = self.active_editor()
        if ai < 0 or len(self.find_text) == 0:
            return
        if not self.wins[ai].find_next(self.find_text, self.find_case):
            self.info("Information", "Search string not found.")

    def palette_dialog(mut self):
        var d = Dialog(D_PALETTE, "Command Palette", min(66, self.scr.w - 4), min(20, self.desk_h()))
        d.fields.append(Field(">", ""))
        d.list_filter = True
        var items = List[String]()
        var data = List[Int]()
        var seen = List[Int]()
        for m in self.menus:
            var title = plain(m.title)
            if title == "≡":
                title = "System"
            for it in m.items:
                if it.cmd == CM_NONE or it.cmd in seen:
                    continue
                seen.append(it.cmd)
                items.append(pad_right(title + ": " + plain(it.label), 40) + self.reg.all_keys_label(it.cmd))
                data.append(it.cmd)
        d.set_items(items^, data^)
        d.buttons.append("~R~un")
        d.buttons.append("~C~ancel")
        self.show(d^)

    def symbol_dialog(mut self):
        var ai = self.active_editor()
        if ai < 0:
            return
        var d = Dialog(D_SYMBOL, "Go to Symbol", min(64, self.scr.w - 4), min(20, self.desk_h()))
        d.fields.append(Field("~S~ymbol", ""))
        d.list_filter = True
        var items = List[String]()
        var data = List[Int]()
        for r in range(self.wins[ai].buf.count()):
            var ind = self.wins[ai].indent_of(r)
            var line = self.wins[ai].buf.lines[r].c.copy()
            var rest = slice_str(line, ind, len(line))
            var kw = String("")
            for k in ["def ", "fn ", "struct ", "trait ", "comptime "]:
                if rest.startswith(k):
                    kw = String(k)
            if kw.byte_length() == 0:
                continue
            if kw == "comptime " and ind > 0:
                continue
            var s0 = ind + cp_len(kw)
            var e = s0
            while e < len(line) and is_ident(line[e]):
                e += 1
            if e == s0:
                continue
            var name = slice_str(line, s0, e)
            var pad = String("")
            for _ in range(self.wins[ai].vcol(r, ind) // 4):
                pad += "  "
            var tag = String("ƒ ") if kw == "def " or kw == "fn " else (String("◆ ") if kw == "struct " else (String("◇ ") if kw == "trait " else String("= ")))
            items.append(pad_right(pad + tag + name, 44) + ":" + String(r + 1))
            data.append(r)
        if len(items) == 0:
            self.say("No symbols found")
            return
        d.set_items(items^, data^)
        d.buttons.append("~G~o")
        d.buttons.append("~C~ancel")
        self.show(d^)

    def help_dialog(mut self):
        """Keyboard reference generated from the command registry."""
        var d = Dialog(D_HELP, "Keyboard Reference", min(72, self.scr.w - 4), min(24, self.desk_h()))
        var items = List[String]()
        for mi in range(1, len(self.reg.menu_titles)):
            var lines = List[String]()
            for p in self.reg.layout:
                if p.menu != mi or p.cmd == CM_NONE:
                    continue
                var keys = self.reg.all_keys_label(p.cmd)
                if keys.byte_length() == 0:
                    continue
                var ci = self.reg.index_of(p.cmd)
                var title = plain(self.reg.cmds[ci].title)
                if title.endswith("..."):
                    var tc = decode(title)
                    title = slice_str(tc, 0, len(tc) - 3)
                lines.append("  " + pad_right(keys, 24) + title)
            if len(lines) == 0:
                continue
            if len(items) > 0:
                items.append("")
            items.append(lower_to_upper(plain(self.reg.menu_titles[mi])))
            for l in lines:
                items.append(l)
        for l in [
            "",
            "MENUS",
            "  F10                     Open the menu bar",
            "  Alt-<letter>            Open the menu with that highlighted letter",
            "  Alt-1..9                Go to window number",
            "  Esc                     Close a menu or dialog",
            "",
            "EDITING",
            "  Arrows, Home, End       Move (Home toggles indent / column 1)",
            "  Ctrl-Left/Right         Move by word",
            "  Ctrl-Home/End           Start / end of file",
            "  PgUp/PgDn               Page; Ctrl-Up/Down scrolls the view",
            "  Shift + movement        Select",
            "  Tab / Shift-Tab         Indent / outdent (selection or line)",
            "  Ins                     Insert / overwrite mode",
            "",
            "MOUSE",
            "  Click, drag, wheel      Place cursor, select, scroll",
            "  Title bar / corner      Move / resize a window",
            "  [■] / [↑]               Close / zoom a window",
        ]:
            items.append(String(l))
        var data = List[Int]()
        for _ in range(len(items)):
            data.append(0)
        d.set_items(items^, data^)
        d.focus = 0
        d.buttons.append("~O~K")
        self.show(d^)

    # ============================================================ completion
    def collect_completions(self, ai: Int, prefix: String) -> List[String]:
        var seen = Dict[String, Int]()
        var out = List[String]()
        var pc = decode(prefix)
        var np = len(pc)
        for r in range(self.wins[ai].buf.count()):
            var line = self.wins[ai].buf.lines[r].c.copy()
            var i = 0
            var n = len(line)
            while i < n:
                if is_alpha(line[i]) and (i == 0 or not is_ident(line[i - 1])):
                    var j = i
                    while j < n and is_ident(line[j]):
                        j += 1
                    if j - i > np and j - i >= 2:
                        var ok = True
                        for k in range(np):
                            if line[i + k] != pc[k]:
                                ok = False
                                break
                        if ok and not (r == self.wins[ai].cr and j == self.wins[ai].cc):
                            var w = slice_str(line, i, j)
                            if w not in seen:
                                seen[w] = 1
                                out.append(w)
                    i = j
                else:
                    i += 1
            if len(out) > 200:
                break
        for lst in [self.hl.kws.copy(), self.hl.types.copy(), self.hl.builtins.copy()]:
            for w in lst:
                if w.startswith(prefix) and w != prefix and w not in seen:
                    seen[w] = 1
                    out.append(w)
        return out^

    def start_complete(mut self):
        var ai = self.active_editor()
        if ai < 0:
            return
        var start = self.wins[ai].word_start()
        var prefix = slice_str(self.wins[ai].buf.lines[self.wins[ai].cr].c, start, self.wins[ai].cc)
        if prefix.byte_length() == 0:
            self.say("Type the start of an identifier, then Ctrl-Space")
            return
        var items = self.collect_completions(ai, prefix)
        if len(items) == 0:
            self.say("No completions for '" + prefix + "'")
            self.mode = M_NORMAL
            return
        if len(items) == 1 and self.mode != M_COMPLETE:
            var cps = decode(items[0])
            var rest = List[Int]()
            for k in range(len(decode(prefix)), len(cps)):
                rest.append(cps[k])
            self.wins[ai].insert_text(rest, ACT_TYPE)
            return
        self.comp_items = items^
        self.comp_sel = 0
        self.comp_start = start
        self.mode = M_COMPLETE

    def complete_key(mut self, k: Int) -> Bool:
        var ai = self.active_editor()
        if ai < 0:
            self.mode = M_NORMAL
            return False
        var n = len(self.comp_items)
        if k == KEY_UP:
            self.comp_sel = (self.comp_sel - 1 + n) % n
            return True
        if k == KEY_DOWN:
            self.comp_sel = (self.comp_sel + 1) % n
            return True
        if k == KEY_PGUP:
            self.comp_sel = max(0, self.comp_sel - 8)
            return True
        if k == KEY_PGDN:
            self.comp_sel = min(n - 1, self.comp_sel + 8)
            return True
        if k == KEY_ESC:
            self.mode = M_NORMAL
            return True
        if k == KEY_ENTER or k == KEY_TAB:
            var cps = decode(self.comp_items[self.comp_sel])
            var plen = self.wins[ai].cc - self.comp_start
            var rest = List[Int]()
            for q in range(plen, len(cps)):
                rest.append(cps[q])
            self.wins[ai].insert_text(rest, ACT_TYPE)
            self.wins[ai].break_group()
            self.mode = M_NORMAL
            return True
        if k < K_BASE and is_ident(k):
            self.wins[ai].type_char(k, True)
            self.start_complete()
            return True
        if k == KEY_BACKSPACE:
            self.wins[ai].backspace()
            if self.wins[ai].cc <= self.comp_start:
                self.mode = M_NORMAL
            else:
                self.start_complete()
            return True
        self.mode = M_NORMAL
        return False

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
        var mi = self.ensure_msg()
        var all = decode_list(data)
        var text = decode(header)
        text.append(10)
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
        var errors = 0
        var warnings = 0
        var row = 1
        for l in lines:
            var s = to_str(l)
            var is_err = str_contains(s, "error:") and not s.startswith("mojo: ")
            var is_warn = str_contains(s, "warning:")
            if is_err:
                errors += 1
            if is_warn:
                warnings += 1
            if is_err or is_warn:
                var loc = self.parse_loc(l)
                if loc.row > 0:
                    loc.msg_line = row
                    loc.path = abs_path(self.cwd, loc.path)
                    self.errs.append(loc^)
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
        var c = "echo __PID__$$ && " + cmd
        var mode = String("r")
        var fp = external_call["popen", Int](c.as_c_string_span(), mode.as_c_string_span())
        if fp == 0:
            self.info("Error", "Could not start: " + cmd)
            return False
        var fd = Int(external_call["fileno", Int32](fp))
        var fl = external_call["fcntl", Int32](Int32(fd), Int32(3), Int32(0))
        _ = external_call["fcntl", Int32](Int32(fd), Int32(4), fl | Int32(2048))  # O_NONBLOCK
        self.job.active = True
        self.job.kind = kind
        self.job.fp = fp
        self.job.fd = fd
        self.job.pid = 0
        self.job.data.clear()
        self.job.t0 = Int(perf_counter_ns())
        self.job.path = path
        self.job.exe = exe
        self.job.cancelled = False
        var i = self.find_editor(path)
        self.job.version = self.wins[i].buf.version if i >= 0 else -1
        return True

    def find_editor(self, path: String) -> Int:
        for i in range(len(self.wins)):
            if self.wins[i].kind == WK_EDITOR and self.wins[i].path == path:
                return i
        return -1

    def job_busy(mut self) -> Bool:
        if self.job.active:
            self.say("Compiler is busy - Ctrl-F2 cancels it")
            return True
        return False

    def cancel_job(mut self):
        if not self.job.active:
            self.say("Nothing to cancel")
            return
        if self.job.pid > 0:
            _ = external_call["kill", Int32](Int32(self.job.pid), Int32(15))
        self.job.cancelled = True
        self.say("Cancelling...")

    def job_elapsed(self) -> Float64:
        return Float64(Int(perf_counter_ns()) - self.job.t0) / 1e9

    def job_header(self) -> String:
        if self.job.kind == JOB_BUILD:
            return "Building " + self.job.path + " ..."
        return "Formatting " + self.job.path + " ..."

    def poll_job(mut self) raises:
        if not self.job.active:
            return
        var buf = List[UInt8](length=16384, fill=0)
        var got = False
        var eof = False
        for _ in range(64):
            var n = external_call["read", Int](Int(self.job.fd), buf.unsafe_ptr(), Int(16384))
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
        if got and self.job.kind == JOB_BUILD and self.job.pid != 0:
            _ = self.fill_messages(self.job_header(), self.job.data.copy(), "Compiling...")
        if eof:
            self.finish_job()

    def finish_job(mut self) raises:
        var st = Int(external_call["pclose", Int32](self.job.fp))
        self.job.active = False
        var secs = self.job_elapsed()
        if self.job.kind == JOB_BUILD:
            self.finish_build(st, secs)
        else:
            self.finish_format(st)

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
        var cmd = "cd " + shell_quote(dir) + " && mkdir -p build && exec " + self.compiler + " build " + shell_quote(path) + " -o " + shell_quote(exe) + " 2>&1"
        if self.start_job(JOB_BUILD, cmd, path, exe):
            _ = self.fill_messages(self.job_header(), List[UInt8](), "Compiling...")
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
        var counts = self.fill_messages(self.job_header(), self.job.data.copy(), footer)
        var ei = self.find_editor(path)
        var nlines = self.wins[ei].buf.count() if ei >= 0 else 0
        var tstr = String(Int(secs * 10) // 10) + "." + String(Int(secs * 10) % 10) + " s"
        if self.job.cancelled:
            self.say("Build cancelled after " + tstr)
            return
        if self.mode == M_NORMAL:
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
            if self.mode == M_NORMAL or self.mode == M_DIALOG:
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
            self.open_path(e.path)
            var t = self.top()
            self.wins[t].goto(e.row - 1, max(0, e.col - 1))
            mi = self.msg_index()
            if mi >= 0 and e.msg_line < self.wins[mi].buf.count():
                self.say(to_str(self.wins[mi].buf.lines[e.msg_line].c))

    def format_file(mut self) raises:
        if self.job_busy():
            return
        var i = self.top_editor()
        if i < 0 or not self.ensure_saved(i):
            return
        var path = self.wins[i].path
        var cmd = "cd " + shell_quote(dirname(path)) + " && exec " + self.compiler + " format -q " + shell_quote(path) + " 2>&1"
        if self.start_job(JOB_FORMAT, cmd, path, ""):
            self.say("Formatting " + basename(path) + "...")

    def finish_format(mut self, status: Int) raises:
        var path = self.job.path
        if self.job.cancelled:
            self.say("Format cancelled")
            return
        if status != 0:
            _ = self.fill_messages(self.job_header(), self.job.data.copy(), "Format failed")
            self.say("mojo format failed - see the Message window")
            return
        var i = self.find_editor(path)
        if i < 0:
            self.say("Formatted " + basename(path))
            return
        if self.wins[i].buf.version != self.job.version:
            self.say("Edited while formatting - buffer not reloaded (file on disk is formatted)")
            return
        var txt: String
        with open(path, "r") as f:
            txt = f.read()
        var cr = self.wins[i].cr
        var cc = self.wins[i].cc
        var tmp = TextBuffer()
        tmp.load(decode(txt))
        self.wins[i].replace_all_text(tmp.all_text())
        self.wins[i].cr = cr
        self.wins[i].cc = cc
        self.wins[i].clamp()
        self.wins[i].buf.modified = False
        self.say("Formatted " + basename(path))

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
        var sub = " run "
        var cmd = (
            "cd " + shell_quote(dirname(path)) + " && clear && printf '\\033[1m$ mojo" + sub + "%s\\033[0m\\n' " + shell_quote(basename(path))
            + " && " + self.compiler + sub + shell_quote(path) + " " + self.run_args
            + "; printf '\\n\\033[7m Program exited with status %d - press any key to return to TurboMojo \\033[0m' $?"
        )
        self.term.leave()
        _ = run_system(cmd)
        self.term.raw()
        self.term.wait_byte()
        self.term.enter()
        self.scr.force = True

    # ================================================================ input
    def handle(mut self, e: Event) raises:
        if e.kind == EV_MOUSE:
            self.handle_mouse(e)
            return
        if e.kind == EV_PASTE:
            if self.mode == M_DIALOG:
                var fi = self.dlg.focus_field()
                if fi >= 0:
                    self.dlg.field_key_insert(fi, e.text)
                return
            self.mode = M_NORMAL
            var ai = self.active_editor()
            if ai >= 0:
                self.wins[ai].insert_text(e.text, ACT_OTHER)
                self.wins[ai].break_group()
            return
        self.handle_key(e.key)

    def handle_key(mut self, k: Int) raises:
        if self.mode == M_DIALOG:
            self.dialog_key(k)
            return
        if self.mode == M_MENU:
            self.menu_key(k)
            return
        if self.mode == M_COMPLETE:
            if self.complete_key(k):
                return
        if k == fkey(10):
            self.open_menu(1)
            return
        var cmd = self.shortcut(k)
        if cmd != CM_NONE:
            self.exec(cmd)
            return
        if (k & MOD_ALT) != 0 and (k & (MOD_CTRL | MOD_SHIFT)) == 0:
            var c = k & KEY_MASK
            if c >= 49 and c <= 57:
                for i in range(len(self.wins)):
                    if self.wins[i].number == c - 48:
                        self.focus(i)
                        return
                return
            var m = self.menu_for_letter(lower(c))
            if c == 32:
                m = 0
            if m >= 0:
                self.open_menu(m)
            return
        var t = self.top()
        if t < 0:
            return
        if self.wins[t].kind == WK_MESSAGE:
            self.message_key(k)
            return
        self.editor_key(k)

    def message_key(mut self, k: Int) raises:
        var t = self.top()
        var n = self.wins[t].buf.count()
        if k == KEY_UP:
            self.wins[t].cr = max(0, self.wins[t].cr - 1)
        elif k == KEY_DOWN:
            self.wins[t].cr = min(n - 1, self.wins[t].cr + 1)
        elif k == KEY_PGUP:
            self.wins[t].cr = max(0, self.wins[t].cr - self.wins[t].rows())
        elif k == KEY_PGDN:
            self.wins[t].cr = min(n - 1, self.wins[t].cr + self.wins[t].rows())
        elif k == KEY_HOME or k == (KEY_HOME | MOD_CTRL):
            self.wins[t].cr = 0
        elif k == KEY_END or k == (KEY_END | MOD_CTRL):
            self.wins[t].cr = n - 1
        elif k == KEY_ENTER or k == 32:
            var row = self.wins[t].cr
            var best = -1
            for j in range(len(self.errs)):
                if self.errs[j].msg_line <= row:
                    best = j
            if best >= 0 and row - self.errs[best].msg_line < 6:
                self.err_idx = best
                self.jump_to_error(best)
            return
        elif k == KEY_ESC:
            if len(self.wins) > 1:
                self.focus(0)
        self.wins[t].cc = 0
        self.wins[t].follow = True

    def editor_key(mut self, k: Int) raises:
        var t = self.top()
        var shift = (k & MOD_SHIFT) != 0
        var ctl = (k & MOD_CTRL) != 0
        var base = k & ~MOD_SHIFT
        if base == KEY_LEFT or base == (KEY_LEFT | MOD_CTRL) or base == (KEY_LEFT | MOD_ALT):
            self.wins[t].move_left(shift, ctl or (k & MOD_ALT) != 0)
        elif base == KEY_RIGHT or base == (KEY_RIGHT | MOD_CTRL) or base == (KEY_RIGHT | MOD_ALT):
            self.wins[t].move_right(shift, ctl or (k & MOD_ALT) != 0)
        elif base == KEY_UP:
            self.wins[t].move_vert(-1, shift)
        elif base == KEY_DOWN:
            self.wins[t].move_vert(1, shift)
        elif base == (KEY_UP | MOD_CTRL):
            self.wins[t].scroll(-1)
            return
        elif base == (KEY_DOWN | MOD_CTRL):
            self.wins[t].scroll(1)
            return
        elif base == KEY_PGUP:
            self.wins[t].page(-1, shift)
        elif base == KEY_PGDN:
            self.wins[t].page(1, shift)
        elif base == KEY_HOME or base == (KEY_HOME | MOD_CTRL):
            self.wins[t].home(shift, ctl)
        elif base == KEY_END or base == (KEY_END | MOD_CTRL):
            self.wins[t].end(shift, ctl)
        elif k == KEY_ENTER:
            self.wins[t].newline(self.auto_indent)
        elif k == KEY_BACKSPACE:
            self.wins[t].backspace()
        elif k == KEY_DELETE:
            self.wins[t].delete_fwd()
        elif k == KEY_TAB:
            self.wins[t].tab(False)
        elif k == (KEY_TAB | MOD_SHIFT):
            self.wins[t].tab(True)
        elif k == KEY_INSERT:
            self.insert_mode = not self.insert_mode
        elif k == KEY_ESC:
            self.wins[t].sel = False
        elif k < K_BASE and k >= 32:
            self.wins[t].type_char(k, self.insert_mode)
        self.wins[t].follow = True

    def window_at(self, x: Int, y: Int) -> Int:
        var i = len(self.wins) - 1
        while i >= 0:
            if self.wins[i].contains(x, y):
                return i
            i -= 1
        return -1

    def handle_mouse(mut self, e: Event) raises:
        var x = e.mx
        var y = e.my
        # ---- wheel
        if e.button == MB_WHEEL_UP or e.button == MB_WHEEL_DOWN:
            var d = -3 if e.button == MB_WHEEL_UP else 3
            if self.mode == M_DIALOG and self.dlg.has_list:
                self.dlg.list_move(d)
                return
            if self.mode == M_COMPLETE:
                self.comp_sel = max(0, min(len(self.comp_items) - 1, self.comp_sel + d))
                return
            if self.mode != M_NORMAL:
                return
            var i = self.window_at(x, y)
            if i >= 0:
                if self.wins[i].kind == WK_MESSAGE:
                    self.wins[i].cr = max(0, min(self.wins[i].buf.count() - 1, self.wins[i].cr + d))
                    self.wins[i].follow = True
                else:
                    self.wins[i].scroll(d)
            return
        # ---- release
        if not e.pressed:
            self.drag = 0
            return
        # ---- drag
        if e.drag:
            var t = self.top()
            if t < 0 or self.mode != M_NORMAL:
                return
            if self.drag == 1:
                self.wins[t].x = x - self.drag_dx
                self.wins[t].y = y - self.drag_dy
                self.wins[t].zoomed = False
                self.fit_windows()
            elif self.drag == 2:
                self.wins[t].w = max(16, x - self.wins[t].x + 1)
                self.wins[t].h = max(4, y - self.wins[t].y + 1)
                self.wins[t].zoomed = False
                self.fit_windows()
            elif self.drag == 3:
                var p = self.wins[t].screen_to_pos(x, y)
                if not self.wins[t].sel:
                    self.wins[t].sel = True
                    self.wins[t].ar = self.wins[t].cr
                    self.wins[t].ac = self.wins[t].cc
                self.wins[t].cr = p.r
                self.wins[t].cc = p.c
                self.wins[t].sync_want()
                self.wins[t].follow = True
            return
        if e.button != MB_LEFT:
            return
        # ---- dialogs
        if self.mode == M_DIALOG:
            if self.dlg.kind == D_RESULT:
                self.mode = M_NORMAL
                return
            var b = self.dlg.button_at(x, y)
            if b >= 0:
                self.dlg.focus = self.dlg.button_focus_index(b)
                self.dialog_button(b)
                return
            if x == self.dlg.dx + 3 and y == self.dlg.dy:
                self.mode = M_NORMAL
                return
            for i in range(len(self.dlg.field_y)):
                if y == self.dlg.field_y[i] and x >= self.dlg.field_x:
                    self.dlg.focus = i
                    self.dlg.fields[i].cur = max(0, min(len(self.dlg.fields[i].text), x - self.dlg.field_x - 1 + self.dlg.fields[i].scroll))
                    return
            for i in range(len(self.dlg.check_y)):
                if y == self.dlg.check_y[i]:
                    self.dlg.focus = len(self.dlg.fields) + i
                    self.dlg.check_vals[i] = not self.dlg.check_vals[i]
                    return
            if self.dlg.has_list and x >= self.dlg.list_x and x < self.dlg.list_x + self.dlg.list_w and y >= self.dlg.list_y and y < self.dlg.list_y + self.dlg.list_h:
                var k = self.dlg.list_top + (y - self.dlg.list_y)
                if k < len(self.dlg.shown):
                    if not self.dlg.list_filter:
                        self.dlg.focus = len(self.dlg.fields) + len(self.dlg.checks)
                    if k == self.dlg.list_sel and self.last_click_item == k:
                        self.last_click_item = -1
                        self.dialog_button(0)
                        return
                    self.dlg.list_move(k - self.dlg.list_sel)
                    self.last_click_item = k
            return
        # ---- completion popup: any click closes it
        if self.mode == M_COMPLETE:
            self.mode = M_NORMAL
        # ---- menu bar / dropdown
        if self.mode == M_MENU:
            var m = self.menus[self.menu_idx].copy()
            var mx = dropdown_rect_x(self.scr.w, m)
            var mw = m.width()
            if x > mx and x < mx + mw - 1 and y >= 2 and y < 2 + len(m.items):
                var it = y - 2
                if m.items[it].cmd != CM_NONE:
                    self.mode = M_NORMAL
                    self.exec(m.items[it].cmd)
                return
            if y != 0:
                self.mode = M_NORMAL
                return
        if y == 0:
            for i in range(len(self.menus)):
                var w = cp_len(self.menus[i].title)
                if x >= self.menus[i].x and x < self.menus[i].x + w:
                    if self.mode == M_MENU and self.menu_idx == i:
                        self.mode = M_NORMAL
                    else:
                        self.open_menu(i)
                    return
            self.mode = M_NORMAL
            return
        if y == self.scr.h - 1:
            for i in range(len(self.st_cmd)):
                if x >= self.st_x0[i] and x < self.st_x1[i]:
                    if self.st_cmd[i] == -1:
                        self.open_menu(1)
                    else:
                        self.exec(self.st_cmd[i])
                    return
            return
        # ---- windows
        var i = self.window_at(x, y)
        if i < 0:
            return
        self.focus(i)
        var t = self.top()
        var wx = self.wins[t].x
        var wy = self.wins[t].y
        var ww = self.wins[t].w
        var wh = self.wins[t].h
        if y == wy:
            if x >= wx + 2 and x <= wx + 4:
                self.close_window(t, NEXT_CLOSE)
                return
            if x >= wx + ww - 5 and x <= wx + ww - 3:
                self.exec(CM_ZOOM)
                return
            self.drag = 1
            self.drag_dx = x - wx
            self.drag_dy = y - wy
            return
        if x >= wx + ww - 2 and y >= wy + wh - 1:
            self.drag = 2
            return
        if x == wx + ww - 1:
            # vertical scrollbar
            if y == wy + 1:
                self.wins[t].scroll(-1)
            elif y == wy + wh - 2:
                self.wins[t].scroll(1)
            elif y < wy + wh // 2:
                self.wins[t].scroll(-self.wins[t].rows())
            else:
                self.wins[t].scroll(self.wins[t].rows())
            return
        if y == wy + wh - 1 or x == wx:
            return
        if self.wins[t].kind == WK_MESSAGE:
            var r = self.wins[t].top + (y - wy - 1)
            if r < self.wins[t].buf.count():
                if self.wins[t].cr == r:
                    self.message_key(KEY_ENTER)
                else:
                    self.wins[t].cr = r
            return
        var p = self.wins[t].screen_to_pos(x, y)
        self.wins[t].begin_move(False)
        self.wins[t].cr = p.r
        self.wins[t].cc = p.c
        self.wins[t].sync_want()
        self.drag = 3

    # ================================================================= draw
    def draw_status(mut self, items: List[String], cmds: List[Int]):
        var y = self.scr.h - 1
        var p = self.pal.copy()
        self.scr.fill(0, y, self.scr.w, 1, 32, p.status_fg, p.status_bg)
        self.st_x0.clear()
        self.st_x1.clear()
        self.st_cmd.clear()
        var x = 1
        for i in range(len(items)):
            var x0 = x
            x = self.scr.hot_text(x, y, items[i], p.status_fg, p.status_hot, p.status_bg)
            self.st_x0.append(x0)
            self.st_x1.append(x)
            self.st_cmd.append(cmds[i])
            x += 2
        var right = String("")
        if self.status_ttl > 0:
            right = self.status
        else:
            var ti = self.top_editor()
            if ti >= 0:
                right = ("CRLF" if self.wins[ti].buf.crlf else "LF") + "  " + ("Tabs" if self.wins[ti].buf.use_tabs else "Spaces") + "  "
            right += "INS" if self.insert_mode else "OVR"
        if self.job.active:
            var sp = decode(SPINNER)
            var b = List[UInt8]()
            encode_cp(sp[self.tick % len(sp)], b)
            var what = "Building " if self.job.kind == JOB_BUILD else "Formatting "
            var e = self.job_elapsed()
            right = bytes_to_str(b) + " " + what + basename(self.job.path) + " " + String(Int(e)) + "." + String(Int(e * 10) % 10) + "s  ^F2 cancel  " + right
        var rl = cp_len(right)
        var rx = self.scr.w - rl - 1
        if rx < x:
            rx = x
        if rx < self.scr.w:
            self.scr.clip(0, y, self.scr.w, 1)
            if rx > x:
                self.scr.put(rx - 2, y, 0x2502, p.status_fg, p.status_bg)
            _ = self.scr.text(rx, y, right, p.status_fg, p.status_bg)
            self.scr.no_clip()

    def draw(mut self):
        var p = self.pal.copy()
        self.scr.no_clip()
        self.scr.fill(0, 1, self.scr.w, self.scr.h - 2, p.desk_ch, p.desk_fg, p.desk_bg)
        var n = len(self.wins)
        for i in range(n):
            self.wins[i].gut = self.wins[i].gutter_for(self.line_numbers)
            if self.wins[i].follow:
                self.wins[i].ensure_visible()
                self.wins[i].follow = False
        for i in range(n):
            self.draw_window(i, i == n - 1)
            if i == n - 1 and self.wins[i].w < self.scr.w:
                self.scr.shadow(self.wins[i].x, self.wins[i].y, self.wins[i].w, self.wins[i].h, p.shadow_fg, p.shadow_bg)
        draw_menubar(self.scr, p, self.menus, self.menu_idx if self.mode == M_MENU else -1, clock_hm() if self.show_clock else "")
        # status line
        var items = List[String]()
        var cmds = List[Int]()
        if self.mode == M_MENU:
            items.append(self.menus[self.menu_idx].items[self.menu_item].hint)
            cmds.append(CM_NONE)
        elif self.mode == M_DIALOG:
            items.append("~Tab~ Next control")
            cmds.append(CM_NONE)
            items.append("~Enter~ Accept")
            cmds.append(CM_NONE)
            items.append("~Esc~ Cancel")
            cmds.append(CM_NONE)
        elif self.mode == M_COMPLETE:
            items.append("~Enter~ Insert")
            cmds.append(CM_NONE)
            items.append("~Esc~ Close")
            cmds.append(CM_NONE)
        else:
            var t = self.top()
            items.append("~F1~ Help")
            cmds.append(CM_HELP)
            if t >= 0 and self.wins[t].kind == WK_MESSAGE:
                items.append("~Enter~ Go to source")
                cmds.append(CM_NONE)
                items.append("~Alt-F8~ Next msg")
                cmds.append(CM_NEXTERR)
                items.append("~F6~ Next window")
                cmds.append(CM_NEXTWIN)
            else:
                items.append("~F2~ Save")
                cmds.append(CM_SAVE)
                items.append("~F3~ Open")
                cmds.append(CM_OPEN)
                items.append("~^P~ Commands")
                cmds.append(CM_PALETTE)
                items.append("~F9~ Build")
                cmds.append(CM_BUILD)
                items.append("~^F9~ Run")
                cmds.append(CM_RUN)
            items.append("~F10~ Menu")
            cmds.append(-1)
        self.draw_status(items, cmds)
        if self.mode == M_MENU:
            draw_dropdown(self.scr, p, self.menus[self.menu_idx], self.menu_item, self.checked())
        # cursor
        self.scr.cvis = False
        var t = self.top()
        if (self.mode == M_NORMAL or self.mode == M_COMPLETE) and t >= 0 and self.wins[t].kind == WK_EDITOR:
            var cx = self.wins[t].x + 1 + self.wins[t].gut + self.wins[t].vcol(self.wins[t].cr, self.wins[t].cc) - self.wins[t].left
            var cy = self.wins[t].y + 1 + self.wins[t].cr - self.wins[t].top
            if cx > self.wins[t].x and cx < self.wins[t].x + self.wins[t].w - 1 and cy > self.wins[t].y and cy < self.wins[t].y + self.wins[t].h - 1:
                self.scr.cx = cx
                self.scr.cy = cy
                self.scr.cvis = True
                self.scr.cblock = not self.insert_mode
            if self.mode == M_COMPLETE:
                self.draw_completion(cx, cy)
        if self.mode == M_DIALOG:
            var c = self.dlg.draw(self.scr, p)
            if c[0] >= 0:
                self.scr.cx = c[0]
                self.scr.cy = c[1]
                self.scr.cvis = True
                self.scr.cblock = False

    def draw_window(mut self, i: Int, active: Bool):
        var p = self.pal.copy()
        self.wins[i].draw(self.scr, p, self.hl, active, self.hl_line, self.insert_mode, self.show_ws)

    def draw_completion(mut self, cx: Int, cy: Int):
        var p = self.pal.copy()
        var n = len(self.comp_items)
        var h = min(8, n)
        var w = 12
        for s in self.comp_items:
            w = max(w, cp_len(s) + 2)
        w = min(w, 40)
        var ai = self.top()
        var plen = self.wins[ai].cc - self.comp_start
        var x = max(0, min(cx - plen - 1, self.scr.w - w - 2))
        var y = cy + 1
        if y + h > self.scr.h - 1:
            y = cy - h
        var topi = max(0, min(self.comp_sel - h + 1, n - h))
        if self.comp_sel < topi:
            topi = self.comp_sel
        for r in range(h):
            var k = topi + r
            var sel = k == self.comp_sel
            var fg = p.list_sel_fg if sel else p.list_fg
            var bg = p.list_sel_bg if sel else p.list_bg
            self.scr.fill(x, y + r, w, 1, 32, fg, bg)
            _ = self.scr.text(x + 1, y + r, self.comp_items[k], fg, bg)
        self.scr.shadow(x, y, w, h, p.shadow_fg, p.shadow_bg)

    # ================================================================= loop
    def run(mut self) raises:
        self.term.enter()
        while self.running:
            var sz = self.term.size()
            if sz[0] != self.scr.w or sz[1] != self.scr.h:
                self.scr.resize(sz[0], sz[1])
                self.fit_windows()
            self.draw()
            self.scr.render(self.term.out)
            self.term.flush()
            var evs = self.term.poll()
            for k in range(len(evs)):
                try:
                    self.handle(evs[k])
                except err:
                    self.mode = M_NORMAL
                    self.info("Error", String(err))
            try:
                self.poll_job()
            except err:
                self.info("Error", String(err))
            self.tick += 1
            if self.status_ttl > 0:
                self.status_ttl -= 1
        if self.job.active:
            self.cancel_job()
            _ = external_call["pclose", Int32](self.job.fp)
        self.term.leave()
