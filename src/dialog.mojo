"""Modal Turbo Vision style dialogs: input lines, check boxes, list boxes, buttons."""
from std.collections import List
from screen import Screen
from palette import Palette
from contrast import text_muted, text_disabled
from util import cp_len, decode, to_str, fuzzy_score, char_width

comptime D_NONE = 0
comptime D_OPEN = 1
comptime D_SAVEAS = 2
comptime D_FIND = 3
comptime D_REPLACE = 4
comptime D_GOTO = 5
comptime D_ABOUT = 6
comptime D_CONFIRM_CLOSE = 7
comptime D_CONFIRM_QUIT = 8
comptime D_INFO = 9
comptime D_PALETTE = 10
comptime D_SYMBOL = 11
comptime D_WINLIST = 12
comptime D_ARGS = 13
comptime D_HELP = 14
comptime D_RESULT = 15
comptime D_BUSY = 16
comptime D_COMPILER = 17
comptime D_RECOVER = 18
comptime D_CHANGED = 19
comptime D_FINDFILES = 20
comptime D_RENAME = 21
comptime D_RENAME_APPLY = 22
comptime D_ACTIONS = 23
comptime D_WSYMBOL = 24
comptime D_EX_NAME = 25
comptime D_EX_DELETE = 26
comptime D_TASKS = 27
comptime D_RUNCFGS = 28
comptime D_RUNCFG = 29
comptime D_TRUST = 30
comptime D_DOCFETCH = 31
comptime D_DOCFIND = 32
comptime D_BREAKPOINT = 33      # condition, hit count, log message of one breakpoint
comptime D_BPFUNC = 34          # the name for a function breakpoint
comptime D_BREAKPOINTS = 35     # the list of all breakpoints
comptime D_SETVALUE = 36        # a new value for a variable of the program being debugged
comptime D_WATCH = 37           # the expression of a watch
comptime D_EVALUATE = 38        # evaluate an expression or run a debugger command
comptime D_MEMADDR = 39         # the CPU window's memory: an address or a variable
comptime D_GIT_COMMIT = 40      # the commit message
comptime D_GIT_BRANCH = 41      # switch to (or make) a branch
comptime D_PANEL_FILTER = 42    # the text the Problems or Message page's lines must contain
comptime D_THEME = 43           # Options > Colour theme
comptime D_NOTICES = 44         # Help > Notifications
comptime D_EXERCISES = 45       # Help > Exercises
comptime D_EX_FILTER = 46       # the explorer's filter (/ in the explorer)
comptime D_NEW_PROJECT = 47     # File > New project
comptime D_SETUP = 48           # Help > Check setup
comptime D_PRESETS = 49         # Options > Presets

comptime NEXT_NONE = 0
comptime NEXT_CLOSE = 1
comptime NEXT_QUIT = 2


struct Field(Copyable, Movable):
    var label: String
    var text: List[Int]
    var cur: Int
    var scroll: Int
    var fresh: Bool      # the pre-filled text is "selected": typing replaces it

    def __init__(out self, label: String, text: String):
        self.label = label
        self.text = decode(text)
        self.cur = len(self.text)
        self.scroll = 0
        self.fresh = False


struct Dialog(Copyable, Movable):
    var kind: Int
    var title: String
    var w: Int
    var h: Int
    var lines: List[String]
    var fields: List[Field]
    var checks: List[String]
    var check_vals: List[Bool]
    var has_list: Bool
    var list_filter: Bool
    var items: List[String]
    var item_data: List[Int]
    var shown: List[Int]
    var keys: List[String]   # if given (one per item): what typing is matched against instead of the item's text
    var boost: List[Int]     # if given (one per item): added to the score of items that match
    var muted_col: Int       # items: the text from this column on is secondary (muted); -1 none
    var off: List[Bool]      # if given (one per item): the item can do nothing now (disabled colour)
    var show_count: Bool     # the title says how many items the typing leaves: "Go to 12/340"
    var numbered: Bool       # screen-reader mode: buttons read "1 OK", "2 Cancel" - digits press them
    var use_pat: Bool        # the pattern is `pat` (set by the owner), not the whole field
    var pat: String
    var list_sel: Int
    var list_top: Int
    var buttons: List[String]
    var focus: Int
    var payload: Int
    var next: Int
    var dir: String
    # layout cache for mouse hit-testing
    var dx: Int
    var dy: Int
    var btn_x: List[Int]
    var btn_y: Int
    var list_x: Int
    var list_y: Int
    var list_w: Int
    var list_h: Int
    var field_y: List[Int]
    var field_x: Int
    var check_y: List[Int]
    var check_x: List[Int]
    var check_w: Int
    var check_cols: Int     # check boxes are laid out in this many columns
    var note: String        # a line of live information above the buttons
    var at_bottom: Bool     # sit at the bottom of the screen instead of the middle

    def __init__(out self, kind: Int, title: String, w: Int, h: Int):
        self.kind = kind
        self.title = title
        self.w = w
        self.h = h
        self.lines = List[String]()
        self.fields = List[Field]()
        self.checks = List[String]()
        self.check_vals = List[Bool]()
        self.has_list = False
        self.list_filter = False
        self.items = List[String]()
        self.item_data = List[Int]()
        self.shown = List[Int]()
        self.keys = List[String]()
        self.boost = List[Int]()
        self.muted_col = -1
        self.off = List[Bool]()
        self.show_count = False
        self.numbered = False
        self.use_pat = False
        self.pat = ""
        self.list_sel = 0
        self.list_top = 0
        self.buttons = List[String]()
        self.focus = 0
        self.payload = -1
        self.next = NEXT_NONE
        self.dir = ""
        self.dx = 0
        self.dy = 0
        self.btn_x = List[Int]()
        self.btn_y = 0
        self.list_x = 0
        self.list_y = 0
        self.list_w = 0
        self.list_h = 0
        self.field_y = List[Int]()
        self.field_x = 0
        self.check_y = List[Int]()
        self.check_x = List[Int]()
        self.check_w = 0
        self.check_cols = 1
        self.note = ""
        self.at_bottom = False

    # ------------------------------------------------------------ focus
    def n_focus(self) -> Int:
        return len(self.fields) + len(self.checks) + (1 if self.has_list else 0) + len(self.buttons)

    def focus_field(self) -> Int:
        return self.focus if self.focus < len(self.fields) else -1

    def focus_check(self) -> Int:
        var k = self.focus - len(self.fields)
        return k if k >= 0 and k < len(self.checks) else -1

    def list_focused(self) -> Bool:
        return self.has_list and self.focus == len(self.fields) + len(self.checks)

    def focus_button(self) -> Int:
        var k = self.focus - len(self.fields) - len(self.checks) - (1 if self.has_list else 0)
        return k if k >= 0 and k < len(self.buttons) else -1

    def focus_cell(self) -> Tuple[Int, Int]:
        """Where the focused check box, list row or button is (as last drawn; -1 if a
        field has the focus or nothing is drawn) - for the screen reader's cursor."""
        var c = self.focus_check()
        if c >= 0 and c < len(self.check_y):
            return (self.check_x[c], self.check_y[c])
        if self.list_focused() and self.list_h > 0:
            return (self.list_x, self.list_y + max(0, self.list_sel - self.list_top))
        var b = self.focus_button()
        if b >= 0 and b < len(self.btn_x):
            return (self.btn_x[b], self.btn_y)
        return (-1, -1)

    def button_focus_index(self, b: Int) -> Int:
        return len(self.fields) + len(self.checks) + (1 if self.has_list else 0) + b

    def field_text(self, i: Int) -> String:
        return to_str(self.fields[i].text)

    # ------------------------------------------------------------- list
    def set_items(mut self, var items: List[String], var data: List[Int]):
        self.items = items^
        self.item_data = data^
        self.muted_col = -1         # (the caller sets these again if it has them)
        self.off = List[Bool]()
        self.has_list = True
        self.refilter()

    def refilter(mut self):
        self.shown.clear()
        var pat = String("")
        if self.use_pat:
            pat = self.pat
        elif self.list_filter and len(self.fields) > 0:
            pat = self.field_text(0)
        var scores = List[Int]()
        for i in range(len(self.items)):
            var s = fuzzy_score(self.keys[i] if len(self.keys) == len(self.items) else self.items[i], pat)
            if s >= 0:
                if len(self.boost) == len(self.items):
                    s += self.boost[i]
                # stable insertion by score (desc)
                var pos = len(self.shown)
                while pos > 0 and scores[pos - 1] < s:
                    pos -= 1
                self.shown.insert(pos, i)
                scores.insert(pos, s)
        self.list_sel = 0
        self.list_top = 0

    def selected_item(self) -> Int:
        if self.list_sel >= 0 and self.list_sel < len(self.shown):
            return self.shown[self.list_sel]
        return -1

    def list_move(mut self, d: Int):
        if len(self.shown) == 0:
            return
        self.list_sel = max(0, min(len(self.shown) - 1, self.list_sel + d))
        var h = max(1, self.list_h)
        if self.list_sel < self.list_top:
            self.list_top = self.list_sel
        if self.list_sel >= self.list_top + h:
            self.list_top = self.list_sel - h + 1

    # ------------------------------------------------------------- edit
    def field_take_fresh(mut self, i: Int) -> Bool:
        """If the field still shows its pre-filled text as selected, remove that text.
        True if there was something to remove."""
        if not self.fields[i].fresh:
            return False
        self.fields[i].fresh = False
        if len(self.fields[i].text) == 0:
            return False
        self.fields[i].text.clear()
        self.fields[i].cur = 0
        self.fields[i].scroll = 0
        return True

    def field_key_insert(mut self, i: Int, cps: List[Int]):
        _ = self.field_take_fresh(i)
        for c in cps:
            if c >= 32:
                self.fields[i].text.insert(self.fields[i].cur, c)
                self.fields[i].cur += 1
        if self.list_filter and i == 0:
            self.refilter()

    def field_backspace(mut self, i: Int):
        if self.field_take_fresh(i):
            if self.list_filter and i == 0:
                self.refilter()
            return
        if self.fields[i].cur > 0:
            _ = self.fields[i].text.pop(self.fields[i].cur - 1)
            self.fields[i].cur -= 1
            if self.list_filter and i == 0:
                self.refilter()

    def field_delete(mut self, i: Int):
        if self.field_take_fresh(i):
            if self.list_filter and i == 0:
                self.refilter()
            return
        if self.fields[i].cur < len(self.fields[i].text):
            _ = self.fields[i].text.pop(self.fields[i].cur)
            if self.list_filter and i == 0:
                self.refilter()

    # ------------------------------------------------------------- draw
    def draw(mut self, mut scr: Screen, pal: Palette) -> Tuple[Int, Int]:
        """Draw the dialog. Returns the screen cursor position (-1 if hidden)."""
        var w = min(self.w, scr.w - 2)
        var h = min(self.h, scr.h - 2)
        var x = (scr.w - w) // 2
        var y = max(1, (scr.h - h) // 2)
        if self.at_bottom:
            y = max(1, scr.h - h - 1)
        self.dx = x
        self.dy = y
        var bg = pal.dlg_bg
        var fg = pal.dlg_fg
        scr.fill(x, y, w, h, 32, fg, bg)
        scr.frame(x, y, w, h, True, pal.dlg_frame, bg)
        _ = scr.text(x + 2, y, "[", pal.dlg_frame, bg)
        scr.put(x + 3, y, 0x25A0, pal.icon_fg, bg)
        _ = scr.text(x + 4, y, "]", pal.dlg_frame, bg)
        var t = " " + self.title + " "
        if self.show_count and self.has_list:
            t = " " + self.title + "  " + String(len(self.shown)) + "/" + String(len(self.items)) + " "
        _ = scr.text(x + max(5, (w - cp_len(t)) // 2), y, t, pal.dlg_title, bg)
        var cur_x = -1
        var cur_y = -1
        var yy = y + 2
        for l in self.lines:
            scr.clip(x + 1, y + 1, w - 2, h - 2)
            _ = scr.hot_text(x + 3, yy, l, fg, pal.dlg_hot, bg)
            scr.no_clip()
            yy += 1
        if len(self.lines) > 0 and (len(self.fields) > 0 or self.has_list):
            yy += 1
        # fields
        var labw = 0
        for f in self.fields:
            labw = max(labw, cp_len(f.label))
        self.field_y.clear()
        self.field_x = x + 3 + labw + 1
        var fw = max(4, w - (labw + 8))
        for i in range(len(self.fields)):
            var foc = self.focus == i
            _ = scr.hot_text(x + 3, yy, self.fields[i].label, pal.dlg_hot if foc else fg, pal.dlg_hot, bg)
            var fx = self.field_x
            scr.fill(fx, yy, fw, 1, 32, pal.in_fg, pal.in_bg)
            # keep cursor visible
            var cur = self.fields[i].cur
            if cur < self.fields[i].scroll:
                self.fields[i].scroll = cur
            # scroll right until the cursor fits (widths in columns)
            while self.span_width(i, self.fields[i].scroll, cur) >= fw - 2 and self.fields[i].scroll < cur:
                self.fields[i].scroll += 1
            var sc = self.fields[i].scroll
            scr.clip(fx + 1, yy, fw - 1, 1)
            var xx = fx + 1
            for k in range(sc, len(self.fields[i].text)):
                if xx >= fx + fw:
                    break
                # pre-filled text that typing would replace is shown as selected
                xx = scr.draw_cp(xx, yy, self.fields[i].text[k], pal.in_bg if self.fields[i].fresh else pal.in_fg, pal.in_fg if self.fields[i].fresh else pal.in_bg)
            scr.no_clip()
            if sc > 0:
                scr.put(fx, yy, 0x25C4, pal.dlg_hot, pal.in_bg)
            if foc:
                cur_x = fx + 1 + self.span_width(i, sc, cur)
                cur_y = yy
            self.field_y.append(yy)
            yy += 2
        # check boxes
        self.check_y.clear()
        self.check_x.clear()
        var ccols = max(1, self.check_cols)
        self.check_w = max(8, (w - 6) // ccols)
        for i in range(len(self.checks)):
            var foc = self.focus == len(self.fields) + i
            var mark = "[X] " if self.check_vals[i] else "[ ] "
            var chx = x + 3 + (i % ccols) * self.check_w
            var chy = yy + i // ccols
            _ = scr.hot_text(chx, chy, mark + self.checks[i], pal.dlg_hot if foc else fg, pal.dlg_hot, bg)
            self.check_y.append(chy)
            self.check_x.append(chx)
            if foc:
                cur_x = chx + 1
                cur_y = chy
        if len(self.checks) > 0:
            yy += (len(self.checks) + ccols - 1) // ccols + 1
        if self.note.byte_length() > 0 and h >= 7:
            scr.clip(x + 1, y + 1, w - 2, h - 2)
            _ = scr.text(x + 3, y + h - 5, self.note, pal.dlg_hot, bg)
            scr.no_clip()
        # list box
        if self.has_list:
            var lx = x + 2
            var lw = w - 4
            var lh = (y + h - (4 if len(self.buttons) > 0 else 1)) - yy
            lh = max(1, lh)
            self.list_x = lx
            self.list_y = yy
            self.list_w = lw
            self.list_h = lh
            scr.fill(lx, yy, lw, lh, 32, pal.list_fg, pal.list_bg)
            if self.list_sel >= self.list_top + lh:
                self.list_top = self.list_sel - lh + 1
            scr.clip(lx, yy, lw - 1, lh)
            for i in range(lh):
                var k = self.list_top + i
                if k >= len(self.shown):
                    break
                var sel = k == self.list_sel
                var ifg = pal.list_sel_fg if sel else pal.list_fg
                var ibg = pal.list_sel_bg if sel else pal.list_bg
                scr.fill(lx, yy + i, lw - 1, 1, 32, ifg, ibg)
                var it = self.shown[k]
                if not sel and it < len(self.off) and self.off[it]:
                    _ = scr.text(lx + 1, yy + i, self.items[it], text_disabled(pal, ifg, ibg), ibg)
                elif not sel and self.muted_col >= 0:
                    var cps = decode(self.items[it])
                    var cut = min(self.muted_col, len(cps))
                    var xx = scr.cps(lx + 1, yy + i, List[Int](cps[0:cut]), ifg, ibg)
                    _ = scr.cps(xx, yy + i, List[Int](cps[cut:]), text_muted(ifg, ibg), ibg)
                else:
                    _ = scr.text(lx + 1, yy + i, self.items[it], ifg, ibg)
            scr.no_clip()
            # scrollbar
            var sx = lx + lw - 1
            for i in range(lh):
                scr.put(sx, yy + i, 0x2592, pal.scroll_fg, pal.scroll_bg)
            if lh >= 3:
                scr.put(sx, yy, 0x25B2, pal.scroll_fg, pal.scroll_bg)
                scr.put(sx, yy + lh - 1, 0x25BC, pal.scroll_fg, pal.scroll_bg)
                if len(self.shown) > 1:
                    var ty = yy + 1 + (self.list_sel * (lh - 3)) // (len(self.shown) - 1)
                    scr.put(sx, ty, 0x25A0, pal.scroll_fg, pal.scroll_bg)
            if len(self.shown) == 0:
                _ = scr.text(lx + 1, yy, "(no matches)", pal.list_fg, pal.list_bg)
        # buttons
        self.btn_x.clear()
        if len(self.buttons) > 0:
            var total = 0
            for i in range(len(self.buttons)):
                total += cp_len(self.button_label(i)) - 2 + 4 + 2
            var bx = x + max(2, (w - total) // 2)
            var by = y + h - 3
            self.btn_y = by
            for i in range(len(self.buttons)):
                var bw = cp_len(self.button_label(i)) - 2 + 4
                var foc = self.focus_button() == i
                var dflt = i == 0 and self.focus_button() < 0
                var bfg = pal.btn_focus_fg if (foc or dflt) else pal.btn_fg
                scr.fill(bx, by, bw, 1, 32, bfg, pal.btn_bg)
                _ = scr.hot_text(bx + 2, by, self.button_label(i), bfg, pal.btn_hot, pal.btn_bg)
                if foc:
                    scr.put(bx, by, 0x25BA, bfg, pal.btn_bg)
                    scr.put(bx + bw - 1, by, 0x25C4, bfg, pal.btn_bg)
                # button shadow
                scr.put(bx + bw, by, 0x2584, pal.btn_shadow, bg)
                for k in range(bx + 1, bx + bw + 1):
                    scr.put(k, by + 1, 0x2580, pal.btn_shadow, bg)
                self.btn_x.append(bx)
                bx += bw + 2
        scr.shadow(x, y, w, h, pal.shadow_fg, pal.shadow_bg)
        return (cur_x, cur_y)

    def button_label(self, i: Int) -> String:
        """Button i as drawn: "1 ~O~K" when numbered (the first nine)."""
        if self.numbered and i < 9:
            return String(i + 1) + " " + self.buttons[i]
        return self.buttons[i]

    def span_width(self, i: Int, a: Int, b: Int) -> Int:
        var w = 0
        for k in range(a, min(b, len(self.fields[i].text))):
            w += char_width(self.fields[i].text[k])
        return w

    def button_at(self, px: Int, py: Int) -> Int:
        if len(self.buttons) == 0 or py != self.btn_y:
            return -1
        for i in range(len(self.buttons)):
            var bw = cp_len(self.button_label(i)) - 2 + 4
            if px >= self.btn_x[i] and px < self.btn_x[i] + bw:
                return i
        return -1
