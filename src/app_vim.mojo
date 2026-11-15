"""The vim interface's keys (Phase 12; see vim.mojo and vim_motion.mojo): Normal, Insert
and Visual modes in front of TurboMojo's own bindings. handle_key asks vim_key first;
what it does not take goes on as before, so Ctrl and Alt keys, the F-keys and the menus
work in every mode.

A command is typed in parts - a count, an operator (d c y > <), its own count, then a
motion, a text object (i / a and one more key) or the operator again (dd) - kept in
VimState until it is whole. The keys of the last change are kept too, and `.` types
them again."""
from std.collections import List
from appstate import *
from util import *
from term import KEY_ESC, KEY_ENTER, KEY_BACKSPACE, KEY_TAB, KEY_UP, KEY_DOWN, KEY_LEFT, KEY_RIGHT, KEY_HOME, KEY_END, KEY_DELETE, KEY_INSERT, MOD_SHIFT, MOD_ALT, MOD_CTRL, KEY_MASK, K_BASE
from window import WK_EDITOR, Range
from layout import L_GROUP, L_ROW, L_COL, RATIO_MIN, RATIO_MAX
from vim import *
from vim_motion import *
from app_input import *
from app_vimcmd import *

comptime CH_G = 103
comptime CH_I = 105
comptime CH_A = 97
comptime OP_D = 100
comptime OP_C = 99
comptime OP_Y = 121
comptime OP_GT = 62
comptime OP_LT = 60
comptime OP_GC = 999

comptime PEND_DS = 1001
comptime PEND_CS1 = 1002
comptime PEND_CS2 = 1003
comptime PEND_VS = 1004


def is_find(ch: Int) -> Bool:
    return ch == 102 or ch == 116 or ch == 70 or ch == 84


def is_operator(ch: Int) -> Bool:
    return ch == OP_D or ch == OP_C or ch == OP_Y or ch == OP_GT or ch == OP_LT


def find_reversed(kind: Int) -> Int:
    """, : the last f t F T the other way."""
    if kind == 102:
        return 70
    if kind == 70:
        return 102
    if kind == 116:
        return 84
    return 116


def surround_pair(ch: Int) -> Tuple[Int, Int]:
    """Opening and closing delimiter for `ch` (e.g. '(' or ')' or 'b' -> (40, 41))."""
    if ch == 40 or ch == 41 or ch == 98:
        return (40, 41)
    if ch == 91 or ch == 93:
        return (91, 93)
    if ch == 123 or ch == 125 or ch == 66:
        return (123, 125)
    if ch == 60 or ch == 62:
        return (60, 62)
    return (ch, ch)


def surround_kind(ch: Int) -> Int:
    """0 if not a bracket/quote surround target; 1 for quotes; else bracket opener."""
    if ch == 34 or ch == 39 or ch == 96:
        return 1
    if ch == 40 or ch == 41 or ch == 98:
        return 40
    if ch == 91 or ch == 93:
        return 91
    if ch == 123 or ch == 125 or ch == 66:
        return 123
    if ch == 60 or ch == 62:
        return 60
    return 0


def is_toplevel_decl(ln: List[Int]) -> Bool:
    """True when `ln` begins at column 0 with def / struct / trait / __extension."""
    var s = to_str(ln)
    return s.startswith("def ") or s.startswith("struct ") or s.startswith("trait ") or s.startswith("__extension ")


def insert_key_kept(k: Int) -> Bool:
    """A key typed in Insert mode that . types again: text, Enter, Backspace, Tab,
    Delete, Ctrl-W - not other Ctrl or Alt keys, the arrows or the F-keys."""
    if k == (119 | MOD_CTRL):
        return True
    if (k & (MOD_CTRL | MOD_ALT)) != 0:
        return False
    if (k & KEY_MASK) < K_BASE:
        return True
    return k == KEY_ENTER or k == KEY_BACKSPACE or k == KEY_TAB or k == KEY_DELETE


__extension App:
    def vim_on(self) -> Bool:
        return self.keymap == KEYMAP_VIM

    def vim_reset(mut self):
        """A fresh start in Normal mode (the keymap was chosen, or left)."""
        self.vim_end_insert_group()
        self.vim = VimState()
        for i in range(len(self.wins)):
            if self.wins[i].vsel != 0:
                self.wins[i].vsel = 0
                self.wins[i].sel = False

    def vim_cancel(mut self):
        """A half-typed command goes (Esc, or a key that does not fit)."""
        self.vim.op = 0
        self.vim.op_n = 0
        self.vim.pend = 0
        self.vim.cs_old = 0
        self.vim.count = 0
        self.vim.regname = 0

    def vim_save_gv(mut self, t: Int):
        if self.vim.mode == VM_VISUAL or self.vim.mode == VM_VLINE or self.vim.mode == VM_BLOCK:
            self.vim.gv_mode = self.vim.mode
            self.vim.gv_ar = self.vim.ar
            self.vim.gv_ac = self.vim.ac
            self.vim.gv_cr = self.wins[t].cr
            self.vim.gv_cc = self.wins[t].cc

    def vim_done(mut self):
        """After a key: when the command is whole (Normal mode, nothing waiting), its
        keys are kept for . if it changed the text."""
        if self.vim.reg_wait:
            self.vim.reg_wait = False                   # ("x: its command comes next)
            return
        if self.vim.mode == VM_NORMAL and self.vim.op == 0 and self.vim.pend == 0 and not self.vim.cl_on:
            self.vim.regname = 0                        # (a register nothing used)
        if self.vim.mode != VM_NORMAL or self.vim.op != 0 or self.vim.pend != 0 or self.vim.count != 0 or self.vim.cl_on:
            return
        if self.vim.changed and not self.vim.replaying:
            self.vim.dot = self.vim.cur.copy()
        self.vim.cur.clear()
        self.vim.changed = False

    def vim_ctrl_w(mut self, t: Int, wb: Int, wn: Int) raises:
        """Ctrl-W <key> window / split management."""
        if wb == 119:
            self.exec(CM_NEXT_PANE if self.tiled else CM_NEXTWIN)
        elif wb == 104 or wb == KEY_LEFT:
            self.vim_pane_dir(-1, 0)
        elif wb == 108 or wb == KEY_RIGHT:
            self.vim_pane_dir(1, 0)
        elif wb == 107 or wb == KEY_UP:
            self.vim_pane_dir(0, -1)
        elif wb == 106 or wb == KEY_DOWN:
            self.vim_pane_dir(0, 1)
        elif wb == 115:
            self.exec(CM_SPLIT_DOWN)
        elif wb == 118:
            self.exec(CM_SPLIT_RIGHT)
        elif wb == 113 or wb == 99:
            self.exec(CM_CLOSE)
        elif wb == 111:
            self.exec(CM_ZOOM)
        elif wb == 61:                                  # Ctrl-W =: equalize split ratios
            for ri in range(len(self.lay.ratio)):
                self.lay.ratio[ri] = 500
            for wi in range(len(self.wins)):
                self.wins[wi].half = False
            if self.tiled:
                self.layout_sync()
            else:
                self.fit_windows()
        elif wb == 62 or wb == 60 or wb == 43 or wb == 45:  # Ctrl-W > < + -: grow/shrink pane
            var want_kind = L_ROW if (wb == 62 or wb == 60) else L_COL
            var grow = wb == 62 or wb == 43
            var delta = (50 if grow else -50) * max(1, wn)
            if self.tiled:
                var node = self.lay.cur
                var adjusted = False
                while node >= 0 and self.lay.parent[node] >= 0:
                    var par = self.lay.parent[node]
                    if self.lay.kind[par] == want_kind:
                        var nr = self.lay.ratio[par] + (delta if self.lay.first[par] == node else -delta)
                        self.lay.ratio[par] = max(RATIO_MIN, min(RATIO_MAX, nr))
                        adjusted = True
                        break
                    node = par
                if not adjusted:
                    _ = self.lay.resize(delta)
                self.layout_sync()
            elif t >= 0:
                if wb == 62 or wb == 60:
                    self.wins[t].w = max(16, min(self.scr.w - self.wins[t].x, self.wins[t].w + (4 if grow else -4) * max(1, wn)))
                else:
                    self.wins[t].h = max(5, min(self.desk_h() + 1 - self.wins[t].y, self.wins[t].h + (2 if grow else -2) * max(1, wn)))
        elif wb == 72 or wb == 74 or wb == 75 or wb == 76:  # Ctrl-W H J K L: move tab/split
            if self.tiled:
                self.layout_sync()
                var all_ids = self.lay.ids()
                if len(all_ids) >= 2 and len(self.lay.tabs[self.lay.cur]) > 0:
                    var id = self.lay.shown(self.lay.cur)
                    self.lay.remove(id)
                    var old_root = self.lay.root
                    var split_kind = L_ROW if (wb == 72 or wb == 76) else L_COL
                    var s = self.lay.new_node(split_kind, -1)
                    var ng = self.lay.new_node(L_GROUP, s)
                    self.lay.tabs[ng].append(id)
                    self.lay.parent[old_root] = s
                    if wb == 72 or wb == 75:
                        self.lay.first[s] = ng
                        self.lay.second[s] = old_root
                    else:
                        self.lay.first[s] = old_root
                        self.lay.second[s] = ng
                    self.lay.root = s
                    self.lay.cur = ng
                    self.layout_sync()
            elif t >= 0:
                var dh = self.desk_h()
                if wb == 72:
                    self.wins[t].x = 0
                    self.wins[t].y = 1
                    self.wins[t].w = max(16, self.scr.w // 2)
                    self.wins[t].h = dh
                elif wb == 76:
                    var rw = max(16, self.scr.w // 2)
                    self.wins[t].x = max(0, self.scr.w - rw)
                    self.wins[t].y = 1
                    self.wins[t].w = rw
                    self.wins[t].h = dh
                elif wb == 75:
                    self.wins[t].x = 0
                    self.wins[t].y = 1
                    self.wins[t].w = self.scr.w
                    self.wins[t].h = max(5, dh // 2)
                else:
                    var bh = max(5, dh // 2)
                    self.wins[t].x = 0
                    self.wins[t].y = 1 + max(0, dh - bh)
                    self.wins[t].w = self.scr.w
                    self.wins[t].h = bh
        else:
            self.vim_cancel()

    def vim_pane_dir(mut self, dx: Int, dy: Int) raises:
        """Focus the visible window in direction (dx, dy) from the active window."""
        var t = self.top()
        if t < 0:
            return
        var cx = self.wins[t].x + self.wins[t].w // 2
        var cy = self.wins[t].y + self.wins[t].h // 2
        var best = -1
        var best_score = 1 << 30
        for i in range(len(self.wins)):
            if i == t or self.wins[i].hidden:
                continue
            var wx = self.wins[i].x + self.wins[i].w // 2
            var wy = self.wins[i].y + self.wins[i].h // 2
            var ox = wx - cx
            var oy = wy - cy
            if dx < 0 and ox >= 0:
                continue
            if dx > 0 and ox <= 0:
                continue
            if dy < 0 and oy >= 0:
                continue
            if dy > 0 and oy <= 0:
                continue
            var primary = abs(ox) if dx != 0 else abs(oy)
            var secondary = abs(oy) if dx != 0 else abs(ox)
            var score = primary + secondary * 3
            if score < best_score:
                best_score = score
                best = i
        if best >= 0:
            self.focus(best)
            if self.tiled:
                self.layout_sync()
        else:
            self.exec(CM_NEXT_PANE if self.tiled else CM_NEXTWIN)

    def vim_insert_ctrl_w(mut self, t: Int):
        """Insert-mode Ctrl-W: delete word backwards on the cursor line."""
        var r = self.wins[t].cr
        var c = self.wins[t].cc
        if c <= 0:
            self.wins[t].backspace()
            return
        var ln = self.wins[t].buf.line(r)
        var s = min(c, len(ln))
        while s > 0 and is_blank(ln[s - 1]):
            s -= 1
        if s > 0:
            var cl = vcls(ln[s - 1], False)
            while s > 0 and vcls(ln[s - 1], False) == cl:
                s -= 1
        var g = self.wins[t].group_for(ACT_BACK)
        _ = self.wins[t].buf.delete(r, s, r, c, r, c, g)
        self.wins[t].cc = s
        self.wins[t].sync_want()
        self.wins[t].follow = True

    def vim_inc_number(mut self, t: Int, delta: Int):
        """Ctrl-A / Ctrl-X: add `delta` to the signed decimal integer at or after cursor."""
        var r = self.wins[t].cr
        var ln = self.wins[t].buf.line(r)
        var n = len(ln)
        if n == 0:
            return
        var c = min(self.wins[t].cc, n - 1)
        var s = -1
        var e = -1
        # if cursor is on digits (or on '-' immediately before digits), expand around it
        if ln[c] >= 48 and ln[c] <= 57:
            s = c
            while s > 0 and ln[s - 1] >= 48 and ln[s - 1] <= 57:
                s -= 1
            if s > 0 and ln[s - 1] == 45:
                s -= 1
            e = c + 1
            while e < n and ln[e] >= 48 and ln[e] <= 57:
                e += 1
        else:
            var i = c
            while i < n:
                if ln[i] >= 48 and ln[i] <= 57:
                    s = i
                    if s > 0 and ln[s - 1] == 45:
                        s -= 1
                    e = i + 1
                    while e < n and ln[e] >= 48 and ln[e] <= 57:
                        e += 1
                    break
                i += 1
        if s < 0:
            return
        var neg = ln[s] == 45
        var val = 0
        for j in range(s + (1 if neg else 0), e):
            val = val * 10 + (ln[j] - 48)
        if neg:
            val = -val
        var next_val = val + delta
        var rep = decode(String(next_val))
        var g = self.wins[t].new_group()
        _ = self.wins[t].buf.delete(r, s, r, e, r, self.wins[t].cc, g)
        _ = self.wins[t].buf.insert(r, s, rep, r, s, g)
        self.wins[t].cc = s + max(0, len(rep) - 1)
        self.wins[t].sync_want()
        self.vim.changed = True
        self.vim_settle(t)

    def vim_key(mut self, k: Int) raises -> Bool:
        """A key for vim? True when vim took it."""
        if self.keymap != KEYMAP_VIM or self.mode != M_NORMAL:
            return False
        var t = self.top()
        if t < 0 or self.wins[t].kind != WK_EDITOR:
            return False
        # Macro recording: stop on plain Normal-mode `q`, else capture every key
        if self.vim.rec_reg != 0 and not self.vim.replaying and self.vim.macro_depth == 0:
            if self.vim.mode == VM_NORMAL and not self.vim.cl_on and self.vim.op == 0 and self.vim.pend == 0 and k == 113:
                var reg = self.vim.rec_reg
                self.vim.rec_reg = 0
                var idx = (reg - 97) if reg >= 97 else (reg - 65)
                if reg >= 65 and reg <= 90:
                    for mk in self.vim.rec_keys:
                        self.vim.macros[idx].append(mk)
                else:
                    self.vim.macros[idx] = self.vim.rec_keys.copy()
                self.vim.rec_keys.clear()
                self.vim.count = 0
                self.vim.cur.clear()
                self.say("Recorded @" + chr(idx + 97))
                return True
            self.vim.rec_keys.append(k)
        if self.vim.mode == VM_INSERT:
            var ins_esc = k == KEY_ESC or k == (91 | MOD_CTRL) or k == (99 | MOD_CTRL)
            if not self.vim.replaying and (ins_esc or insert_key_kept(k)):
                self.vim.cur.append(KEY_ESC if ins_esc else k)
            if ins_esc:
                if self.wins[t].has_multi():
                    self.wins[t].collapse()
                elif self.vim.ins_count > 1 and self.wins[t].cr == self.vim.ins_r and self.wins[t].cc > self.vim.ins_c:
                    var typed = self.wins[t].buf.get_text(self.vim.ins_r, self.vim.ins_c, self.wins[t].cr, self.wins[t].cc)
                    for _ in range(self.vim.ins_count - 1):
                        self.wins[t].insert_text(typed, ACT_OTHER)
                self.vim.ins_count = 1
                self.vim_normal(t, True)
                self.vim_done()
                return True
            if k == (119 | MOD_CTRL):               # Insert Ctrl-W: delete word back
                if self.wins[t].has_multi():
                    self.wins[t].multi(OP_BACK, 0, False, False, List[Int]())
                else:
                    self.vim_insert_ctrl_w(t)
                return True
            if k == (110 | MOD_CTRL) or k == (112 | MOD_CTRL):   # Ctrl-N / Ctrl-P: complete
                self.start_complete()
                return True
            return False
        if self.vim.cl_on:                          # the command line takes every key
            if not self.vim.replaying:
                self.vim.cur.append(k)
            self.vim_cmdline_key(t, k)
            self.vim_done()
            return True
        if self.vim.pend == 23:                     # Ctrl-W <key>: window commands
            var wn = self.vim.take_count()
            self.vim.pend = 0
            self.vim.count = 0
            self.vim.cur.clear()
            var wb = k & KEY_MASK
            self.vim_ctrl_w(t, wb, wn)
            return True
        if (k & MOD_CTRL) != 0 and (k & MOD_ALT) == 0:
            var cb = k & KEY_MASK
            if cb == 114 and self.vim.mode == VM_NORMAL:        # Ctrl-R: redo
                var n = self.vim.take_count()
                self.vim_cancel()
                for _ in range(n):
                    self.wins[t].redo()
                self.vim_settle(t)
                return True
            if cb == 91 or cb == 99:                            # Ctrl-[ / Ctrl-C: Esc
                if self.vim.mode != VM_NORMAL:
                    self.vim_normal(t, False)
                    self.vim_done()
                else:
                    self.vim_cancel()
                    self.vim.cur.clear()
                return True
            if cb == 119:                                       # Ctrl-W: window prefix
                self.vim.pend = 23
                return True
            if cb == 118:                                       # Ctrl-V: Visual Block
                if self.vim.mode == VM_BLOCK:
                    self.vim_normal(t, False)
                elif self.vim.mode == VM_VISUAL or self.vim.mode == VM_VLINE:
                    self.vim.mode = VM_BLOCK
                    self.vim_settle(t)
                else:
                    self.vim_visual(t, VM_BLOCK)
                self.vim_done()
                return True
            if cb == 100 or cb == 117 or cb == 102 or cb == 98: # Ctrl-D/U/F/B scroll
                var rows = self.wins[t].rows()
                var step = max(1, rows // 2) if (cb == 100 or cb == 117) else max(1, rows - 2)
                var dir = 1 if (cb == 100 or cb == 102) else -1
                var n2 = self.vim.take_count()
                var delta = dir * step * n2
                self.wins[t].scroll(delta)
                var sel = self.wins[t].sel
                self.wins[t].move_vert(delta, False)
                self.wins[t].sel = sel
                self.vim_settle(t)
                return True
            if cb == 111 and self.vim.mode == VM_NORMAL:        # Ctrl-O: jump back
                self.vim_cancel()
                self.vim.cur.clear()
                self.jump_back()
                return True
            if cb == 105 and self.vim.mode == VM_NORMAL:        # Ctrl-I: jump forward
                self.vim_cancel()
                self.vim.cur.clear()
                self.jump_forward()
                return True
            if (cb == 97 or cb == 120) and self.vim.mode == VM_NORMAL:  # Ctrl-A / Ctrl-X
                if not self.vim.replaying:
                    self.vim.cur.append(k)
                var n3 = self.vim.take_count()
                self.vim_inc_number(t, n3 if cb == 97 else -n3)
                self.vim_done()
                return True
        if (k & (MOD_CTRL | MOD_ALT)) != 0:
            return False                    # TurboMojo's
        var base = k & KEY_MASK
        if (k & MOD_SHIFT) != 0 and base >= K_BASE:
            return False                    # Shift and an arrow: TurboMojo's selection
        if not self.vim.replaying:
            self.vim.cur.append(k)
        var p = self.vim.pend
        if p == 113:                        # q<reg>: start recording macro
            self.vim.pend = 0
            self.vim.cur.clear()
            if (base >= 97 and base <= 122) or (base >= 65 and base <= 90):
                self.vim.rec_reg = base
                self.vim.rec_keys = List[Int]()
                self.say("recording @" + chr(base))
            else:
                self.vim_cancel()
                if base < K_BASE:
                    self.say("Not a register: " + chr(base))
            return True
        if p == 64:                         # @<reg> / @@: replay macro
            self.vim.pend = 0
            var n_rep = self.vim.take_count()
            self.vim_cancel()
            self.vim.cur.clear()
            var mreg = 0
            if base == 64:
                mreg = self.vim.last_macro
            elif base >= 97 and base <= 122:
                mreg = base
            elif base >= 65 and base <= 90:
                mreg = base + 32
            if mreg < 97 or mreg > 122:
                self.say("No previously used register" if base == 64 else "Not a register")
                return True
            if self.vim.macro_depth >= 16:
                self.say("Macro recursion limit reached")
                return True
            self.vim.last_macro = mreg
            var mkeys = self.vim.macros[mreg - 97].copy()
            if len(mkeys) == 0:
                return True
            var had_g = self.wins[t].forced_group
            if had_g == 0:
                self.wins[t].forced_group = self.wins[t].new_group()
            self.vim.macro_depth += 1
            try:
                for _ in range(n_rep):
                    for mk in mkeys:
                        self.handle_key(mk)
            except err:
                self.vim.macro_depth -= 1
                var top_e = self.top()
                if top_e >= 0 and top_e < len(self.wins):
                    self.wins[top_e].forced_group = had_g
                raise err
            self.vim.macro_depth -= 1
            var top_now = self.top()
            if top_now >= 0 and top_now < len(self.wins):
                self.wins[top_now].forced_group = had_g
                self.wins[top_now].break_group()
            return True
        if p == 109:                        # m<a-z> / m<A-Z>: set local or global mark
            self.vim.pend = 0
            self.vim.cur.clear()
            if base >= 97 and base <= 122:
                var mi = base - 97
                self.vim.mark_paths[mi] = self.wins[t].path
                self.vim.mark_rows[mi] = self.wins[t].cr
                self.vim.mark_cols[mi] = self.wins[t].cc
            elif base >= 65 and base <= 90:
                var gi = base - 65
                self.vim.gmark_paths[gi] = self.wins[t].path
                self.vim.gmark_rows[gi] = self.wins[t].cr
                self.vim.gmark_cols[gi] = self.wins[t].cc
                self.say("Global mark '" + chr(base) + " set")
            else:
                self.vim_cancel()
                self.say("Marks are a..z or A..Z")
            return True
        if p == PEND_DS or p == PEND_CS1 or p == PEND_CS2 or p == PEND_VS:
            self.vim.pend = 0
            if base >= K_BASE:
                self.vim_cancel()
            elif p == PEND_DS:
                self.vim_surround_del(t, base)
            elif p == PEND_CS1:
                self.vim.cs_old = base
                self.vim.pend = PEND_CS2
                return True
            elif p == PEND_CS2:
                self.vim_surround_change(t, self.vim.cs_old, base)
            elif p == PEND_VS:
                self.vim_surround_visual(t, base)
            self.vim_done()
            return True
        if is_find(p) or p == 114 or p == 34:
            # f t F T r ": the next key is the character itself
            self.vim.pend = 0
            if base >= K_BASE:
                self.vim_cancel()
            elif p == 34:
                if (base >= 97 and base <= 122) or (base >= 65 and base <= 90) or base == 48 or base == 43 or base == 42 or base == 95 or base == 34:
                    self.vim.regname = base     # ("" is the unnamed one)
                    self.vim.reg_wait = True
                else:
                    self.vim_cancel()
                    self.say("Not a register: \"" + chr(base))
            elif p == 114:
                if self.vim.mode == VM_BLOCK:
                    self.vim_block_replace(t, base)
                else:
                    self.vim_replace(t, base)
            else:
                self.vim.f_kind = p
                self.vim.f_ch = base
                self.vim_do_motion(t, p, base, False)
            self.vim_done()
            return True
        var ch = base
        if base >= K_BASE:
            # the keys that are not characters, as vim has them in Normal mode
            if k == KEY_ESC:
                if self.vim.mode != VM_NORMAL:
                    self.vim_normal(t, False)
                    self.vim_done()
                    return True
                self.vim_cancel()           # (a half-typed command goes)
                self.vim.cur.clear()
                return False                # Esc goes on: one cursor again, a tip away...
            elif k == KEY_LEFT or k == KEY_BACKSPACE:
                ch = 104                    # h
            elif k == KEY_RIGHT:
                ch = 108                    # l
            elif k == KEY_UP:
                ch = 107                    # k
            elif k == KEY_DOWN:
                ch = 106                    # j
            elif k == KEY_ENTER:
                ch = 43                     # +
            elif k == KEY_HOME:
                ch = 48                     # 0
            elif k == KEY_END:
                ch = 36                     # $
            elif k == KEY_DELETE:
                ch = 120                    # x
            elif k == KEY_INSERT:
                ch = 105                    # i
            elif k == KEY_TAB:
                self.vim.cur.clear()
                if self.vim.mode == VM_NORMAL and self.jump_at + 1 < len(self.jumps):
                    self.jump_forward()
                return True
            else:
                self.vim.cur.clear()
                return False                # PgUp, PgDn, the F-keys...: TurboMojo's
        elif ch == 32:
            ch = 108                        # Space: l
        # a count
        if (ch >= 49 and ch <= 57) or (ch == 48 and self.vim.count > 0):
            self.vim.count = min(self.vim.count * 10 + (ch - 48), 99999)
            self.say(String(self.vim.count))
            return True
        if self.vim.mode == VM_NORMAL:
            self.vim_normal_key(t, ch)
        else:
            self.vim_visual_key(t, ch)
        self.vim_done()
        return True

    def vim_note_ctx(mut self, t: Int):
        """Record the cursor position before a non-linear jump so `''` / ``` ``` toggles back."""
        if t >= 0 and t < len(self.wins):
            self.vim.ctx_path = self.wins[t].path
            self.vim.ctx_row = self.wins[t].cr
            self.vim.ctx_col = self.wins[t].cc

    # ------------------------------------------------------------------ motions
    def vim_motion_key(mut self, t: Int, ch: Int) raises -> Bool:
        """The keys that move (or begin a motion: g, f t F T, ', `); False for any other."""
        if self.vim.pend == 39 or self.vim.pend == 96:      # 'a `a 'A `A '' ``
            var linewise = self.vim.pend == 39
            self.vim.pend = 0
            if ch == 39 or ch == 96:
                if self.vim.op == 0:
                    self.vim.count = 0
                    if self.vim.ctx_row >= 0:
                        var prev_p = self.wins[t].path
                        var prev_r = self.wins[t].cr
                        var prev_c = self.wins[t].cc
                        var cp_path = self.vim.ctx_path
                        var cp_row = self.vim.ctx_row
                        var cp_col = self.vim.ctx_col
                        var target_t = t
                        if cp_path.byte_length() > 0 and cp_path != self.wins[t].path and path_exists(cp_path):
                            self.open_path(cp_path)
                            target_t = self.top()
                            if target_t < 0 or self.wins[target_t].kind != WK_EDITOR:
                                return True
                        var tr0 = max(0, min(cp_row, self.wins[target_t].buf.count() - 1))
                        self.wins[target_t].cr = tr0
                        self.wins[target_t].cc = first_nonblank(self.wins[target_t].buf.line(tr0)) if linewise else min(cp_col, self.wins[target_t].buf.llen(tr0))
                        self.wins[target_t].sync_want()
                        self.vim_settle(target_t)
                        self.vim.ctx_path = prev_p
                        self.vim.ctx_row = prev_r
                        self.vim.ctx_col = prev_c
                    else:
                        self.jump_back()
                else:
                    self.vim_cancel()
                return True
            var is_lower = ch >= 97 and ch <= 122
            var is_upper = ch >= 65 and ch <= 90
            if not is_lower and not is_upper:
                self.vim_cancel()
                self.say("Marks are a..z or A..Z")
                return True
            var mr: Int
            var mpath: String
            var mc: Int
            if is_lower:
                var mi = ch - 97
                mr = self.vim.mark_rows[mi]
                mpath = self.vim.mark_paths[mi]
                mc = self.vim.mark_cols[mi]
            else:
                var gi = ch - 65
                mr = self.vim.gmark_rows[gi]
                mpath = self.vim.gmark_paths[gi]
                mc = self.vim.gmark_cols[gi]
            if mr < 0:
                self.vim_cancel()
                self.say("E20: Mark not set")
                return True
            if self.vim.op != 0:
                var op = self.vim.op
                self.vim.op = 0
                self.vim.count = 0
                self.vim.op_n = 0
                if mpath != self.wins[t].path:
                    self.vim_cancel()
                    self.say("Mark is in another file")
                    return True
                var tr = min(mr, self.wins[t].buf.count() - 1)
                var tc = first_nonblank(self.wins[t].buf.line(tr)) if linewise else min(mc, self.wins[t].buf.llen(tr))
                var span = motion_span(self.wins[t].buf, self.wins[t].cr, self.wins[t].cc, VimMove(True, tr, tc, VK_LINE if linewise else VK_EXCL))
                if span.ok:
                    self.vim_apply(t, op, span)
                return True
            self.vim.count = 0
            self.vim_note_ctx(t)
            self.jump_mark()
            var target_t = t
            if mpath.byte_length() > 0 and mpath != self.wins[t].path:
                self.open_path(mpath)
                target_t = self.top()
                if target_t < 0 or self.wins[target_t].kind != WK_EDITOR:
                    return True
            var tr2 = max(0, min(mr, self.wins[target_t].buf.count() - 1))
            self.wins[target_t].cr = tr2
            self.wins[target_t].cc = first_nonblank(self.wins[target_t].buf.line(tr2)) if linewise else min(mc, self.wins[target_t].buf.llen(tr2))
            self.wins[target_t].sync_want()
            self.vim_settle(target_t)
            return True
        if self.vim.pend == CH_G:
            self.vim.pend = 0
            if ch == CH_G:
                self.vim_do_motion(t, CH_G, 0, False)
            elif (ch == 45 or ch == 43) and self.vim.op == 0 and self.vim.mode == VM_NORMAL:   # g- / g+
                var n_u = self.vim.take_count()
                self.vim_cancel()
                if self.wins[t].read_only:
                    self.say("Buffer is read-only")
                    return True
                var moved = False
                var last_p = Pos(-1, -1)
                for _ in range(n_u):
                    var step = self.wins[t].buf.undo_earlier() if ch == 45 else self.wins[t].buf.undo_later()
                    if not step[0]:
                        break
                    moved = True
                    last_p = step[1].copy()
                if moved:
                    self.wins[t].sel = False
                    self.wins[t].extra.clear()
                    if last_p.r >= 0:
                        self.wins[t].cr = last_p.r
                        self.wins[t].cc = last_p.c
                    self.wins[t].clamp()
                    self.wins[t].sync_want()
                    self.vim_settle(t)
                    self.sync_shared_buffers(t)
                else:
                    self.say("Already at oldest change" if ch == 45 else "Already at newest change")
            elif ch == 100 and self.vim.op == 0 and self.vim.mode == VM_NORMAL:     # gd
                self.vim_cancel()
                self.exec(CM_DEFINITION)
            elif ch == 114 and self.vim.op == 0 and self.vim.mode == VM_NORMAL:     # gr
                self.vim_cancel()
                self.exec(CM_REFERENCES)
            elif ch == 121 and self.vim.op == 0 and self.vim.mode == VM_NORMAL:     # gy
                self.vim_cancel()
                self.exec(CM_TYPEDEF)
            elif ch == 118 and self.vim.op == 0 and self.vim.mode == VM_NORMAL:     # gv
                self.vim.count = 0
                if self.vim.gv_mode != 0:
                    self.vim.mode = self.vim.gv_mode
                    self.vim.ar = min(self.vim.gv_ar, self.wins[t].buf.count() - 1)
                    self.vim.ac = self.vim.gv_ac
                    self.wins[t].cr = min(self.vim.gv_cr, self.wins[t].buf.count() - 1)
                    self.wins[t].cc = self.vim.gv_cc
                    self.wins[t].sync_want()
                    self.vim_settle(t)
            elif ch == 99 and self.vim.op == 0:                                     # gc
                if self.vim.mode == VM_NORMAL:
                    self.vim.op = OP_GC
                    self.vim.op_n = self.vim.count
                    self.vim.count = 0
                else:
                    var sr = self.wins[t].sel_range()
                    var r2 = sr.r2 - (1 if self.wins[t].vsel == 2 and sr.c2 == 0 and sr.r2 > sr.r1 else 0)
                    if self.vim.mode == VM_BLOCK:
                        sr = Range(min(self.vim.ar, self.wins[t].cr), 0, max(self.vim.ar, self.wins[t].cr), 0)
                        r2 = sr.r2
                    self.vim_save_gv(t)
                    self.vim.count = 0
                    self.vim.mode = VM_NORMAL
                    self.wins[t].vsel = 0
                    self.wins[t].sel = False
                    self.wins[t].extra.clear()
                    self.vim_apply(t, OP_GC, VimSpan(True, sr.r1, 0, r2, 0, True))
            else:
                self.vim_cancel()
                self.say("Not a vim command: g" + chr(ch))
            return True
        if ch == CH_G or is_find(ch) or ch == 39 or ch == 96:
            self.vim.pend = ch
            return True
        if ch == 59 or ch == 44:                    # ; ,
            if self.vim.f_kind == 0:
                self.vim_cancel()
                return True
            var kind = self.vim.f_kind if ch == 59 else find_reversed(self.vim.f_kind)
            self.vim_do_motion(t, kind, self.vim.f_ch, True)
            return True
        if is_motion(ch):
            self.vim_do_motion(t, ch, 0, False)
            return True
        if ch == 47 or ch == 63:                    # / ?: the command line
            self.vim_cmdline_start(t, ch)
            return True
        if ch == 110 or ch == 78:                   # n N: the last search again (N: the other way)
            var fwd = self.vim.s_fwd if ch == 110 else not self.vim.s_fwd
            self.vim_search_go(t, fwd, self.wins[t].cr, self.wins[t].cc)
            return True
        if ch == 42 or ch == 35:                    # * #: the word under the cursor
            self.vim_star(t, ch == 42)
            return True
        return False

    def vim_do_motion(mut self, t: Int, ch: Int, arg: Int, again: Bool):
        """Motion `ch`: the cursor goes there, or the waiting operator works on the
        span from the cursor to there."""
        var r = self.wins[t].cr
        var c = self.wins[t].cc
        if self.vim.op != 0:
            var counted = self.vim.counted()
            var n = self.vim.total_count()
            var op = self.vim.op
            self.vim.op = 0
            var m: VimMove
            var line = self.wins[t].buf.line(r)
            if op == OP_C and (ch == 119 or ch == 87) and c < len(line) and not is_blank(line[c]):
                # cw is ce (vim's exception): the blanks after the word stay
                var big = ch == 87
                var q = Pos(r, c)
                for i in range(n):
                    if i == 0 and at_word_end(line, c, big):
                        continue
                    q = word_end(self.wins[t].buf, q.r, q.c, big)
                m = VimMove(True, q.r, q.c, VK_INCL)
            else:
                m = vim_move(self.wins[t].buf, r, c, ch, n, counted, arg, again, True)
            var span = motion_span(self.wins[t].buf, r, c, m)
            if not span.ok:
                self.vim_cancel()
                return
            self.vim_apply(t, op, span)
            return
        var counted2 = self.vim.count > 0
        var n2 = self.vim.take_count()
        if ch == 106 or ch == 107:
            var sel = self.wins[t].sel
            self.wins[t].move_vert(n2 if ch == 106 else -n2, False)
            self.wins[t].sel = sel
        else:
            var m2 = vim_move(self.wins[t].buf, r, c, ch, n2, counted2, arg, again, False)
            if m2.ok:
                if ch == CH_G or ch == 71 or ch == 37 or ch == 123 or ch == 125:
                    self.vim_note_ctx(t)
                    self.jump_mark()
                self.wins[t].cr = m2.r
                self.wins[t].cc = m2.c
                if ch == 36:
                    self.wins[t].want = 1 << 30         # (stays at the end on j and k)
                else:
                    self.wins[t].sync_want()
        self.vim_settle(t)

    def vim_settle(mut self, t: Int):
        """After a command: the cursor where vim may have it (on a character in Normal
        and Visual mode), the Visual selection from where it started, and the cursor
        shown."""
        if self.wins[t].cr >= self.wins[t].buf.count():
            self.wins[t].cr = self.wins[t].buf.count() - 1
        var last = max(0, self.wins[t].buf.llen(self.wins[t].cr) - 1)
        if self.vim.mode != VM_INSERT and self.wins[t].cc > last:
            self.wins[t].cc = last
        self.wins[t].extra.clear()
        if self.vim.mode == VM_VISUAL or self.vim.mode == VM_VLINE:
            self.wins[t].sel = True
            self.wins[t].ar = self.vim.ar
            self.wins[t].ac = self.vim.ac
            self.wins[t].vsel = 1 if self.vim.mode == VM_VISUAL else 2
        elif self.vim.mode == VM_BLOCK:
            var lo = min(self.vim.ar, self.wins[t].cr)
            var hi = max(self.vim.ar, self.wins[t].cr)
            var c1 = min(self.vim.ac, self.wins[t].cc)
            var c2 = max(self.vim.ac, self.wins[t].cc)
            self.wins[t].sel = True
            self.wins[t].vsel = 1
            self.wins[t].ar = self.wins[t].cr
            self.wins[t].ac = min(self.vim.ac, self.wins[t].buf.llen(self.wins[t].cr))
            for row in range(lo, hi + 1):
                if row == self.wins[t].cr:
                    continue
                var rl = self.wins[t].buf.llen(row)
                var rs = min(c1, rl)
                var re = min(c2 + 1, rl)
                self.wins[t].extra.append(Cur(row, re, rs < re, row, rs, self.wins[t].want))
        self.wins[t].break_group()
        self.wins[t].follow = True

    # ----------------------------------------------------------------- Normal
    def vim_normal_key(mut self, t: Int, ch: Int) raises:
        var p = self.vim.pend
        if p == 91 or p == 93:                      # [d ]d [c ]c [[ ]]
            self.vim.pend = 0
            var fwd = p == 93
            var n_sq = self.vim.take_count()
            if ch == 100:
                for _ in range(n_sq):
                    self.exec(CM_NEXTERR if fwd else CM_PREVERR)
            elif ch == 99:
                for _ in range(n_sq):
                    self.exec(CM_GIT_NEXT if fwd else CM_GIT_PREV)
            elif (p == 91 and ch == 91) or (p == 93 and ch == 93):
                self.jump_mark()
                var cur_r = self.wins[t].cr
                var cnt = self.wins[t].buf.count()
                for _ in range(n_sq):
                    var step = 1 if fwd else -1
                    var r = cur_r + step
                    while r >= 0 and r < cnt:
                        if is_toplevel_decl(self.wins[t].buf.line(r)):
                            cur_r = r
                            break
                        r += step
                self.wins[t].cr = cur_r
                self.wins[t].cc = 0
                self.wins[t].sync_want()
                self.vim_settle(t)
            else:
                self.vim_cancel()
                self.say("Not a vim command: " + chr(p) + chr(ch))
            return
        if p == 122:                                # za zo zc zM zR zz zt zb
            self.vim.pend = 0
            self.vim.count = 0
            if ch == 97:
                self.exec(CM_FOLD)
            elif ch == 111:
                _ = self.wins[t].buf.set_fold(self.wins[t].cr, False)
                self.wins[t].follow = True
            elif ch == 99:
                if self.wins[t].buf.fold_index(self.wins[t].cr) < 0:
                    _ = self.wins[t].toggle_fold(self.wins[t].cr)
            elif ch == 77:
                self.exec(CM_FOLDALL)
            elif ch == 82:
                self.exec(CM_UNFOLDALL)
            elif ch == 122:
                self.wins[t].top = max(0, self.wins[t].cr - self.wins[t].rows() // 2)
                self.wins[t].top_seg = 0
                self.wins[t].follow = False
            elif ch == 116:
                self.wins[t].top = self.wins[t].cr
                self.wins[t].top_seg = 0
                self.wins[t].follow = False
            elif ch == 98:
                self.wins[t].top = max(0, self.wins[t].cr - self.wins[t].rows() + 1)
                self.wins[t].top_seg = 0
                self.wins[t].follow = False
            else:
                self.vim_cancel()
                self.say("Not a vim command: z" + chr(ch))
            return
        if p == CH_I or p == CH_A:
            # a text object after an operator
            self.vim.pend = 0
            var span = vim_object(self.wins[t].buf, self.wins[t].cr, self.wins[t].cc, p == CH_I, ch)
            var op = self.vim.op
            var name = self.vim.regname
            self.vim_cancel()
            if not span.ok:
                return
            self.vim.regname = name                 # ("adiw)
            self.vim_apply(t, op, span)
            return
        if self.vim.op != 0:
            if (self.vim.op == OP_D or self.vim.op == OP_C) and ch == 115:
                # ds<ch> / cs<old><new>: surround delete or change
                var sop = self.vim.op
                self.vim.op = 0
                self.vim.op_n = 0
                self.vim.count = 0
                self.vim.pend = PEND_DS if sop == OP_D else PEND_CS1
                return
            if ch == CH_I or ch == CH_A:
                self.vim.pend = ch
                return
            if ch == self.vim.op or (self.vim.op == OP_GC and ch == 99):
                self.vim_lines_op(t, self.vim.op)   # dd cc yy >> << gcc
                return
            if self.vim_motion_key(t, ch):
                return
            self.vim_cancel()
            self.say("Not a vim command: " + chr(ch))
            return
        if self.vim_motion_key(t, ch):
            return
        if ch == 58:                                # :
            self.vim.count = 0
            self.vim_cmdline_start(t, ch)
        elif ch == 34:                              # ": a register's name follows
            self.vim.pend = 34
        elif ch == 109:                             # m<a-z>: set mark
            self.vim.pend = 109
        elif ch == 113:                             # q<a-z>: record macro
            self.vim.pend = 113
        elif ch == 64:                              # @<a-z> / @@: replay macro
            self.vim.pend = 64
        elif ch == 91 or ch == 93 or ch == 122:     # [ ] z prefixes
            self.vim.pend = ch
        elif ch == 75:                              # K: hover documentation
            self.vim.count = 0
            self.exec(CM_HOVER)
        elif is_operator(ch):
            self.vim.op = ch
            self.vim.op_n = self.vim.count
            self.vim.count = 0
        elif ch == 105 or ch == 97 or ch == 73 or ch == 65 or ch == 111 or ch == 79:
            self.vim_insert(t, ch)
        elif ch == 120 or ch == 88:                 # x X
            var n = self.vim.take_count()
            var r = self.wins[t].cr
            var c = self.wins[t].cc
            var len_ = self.wins[t].buf.llen(r)
            if ch == 120 and c < len_:
                self.vim_apply(t, OP_D, VimSpan(True, r, c, r, min(c + n, len_), False))
            elif ch == 88 and c > 0:
                self.vim_apply(t, OP_D, VimSpan(True, r, max(0, c - n), r, c, False))
        elif ch == 68 or ch == 67:                  # D C: d$ c$
            self.vim.op = OP_D if ch == 68 else OP_C
            self.vim.op_n = self.vim.count
            self.vim.count = 0
            self.vim_do_motion(t, 36, 0, False)
        elif ch == 89:                              # Y: yy
            self.vim.op_n = self.vim.count
            self.vim.count = 0
            self.vim_lines_op(t, OP_Y)
        elif ch == 115:                             # s: cl
            if self.wins[t].buf.llen(self.wins[t].cr) == 0:
                self.vim.count = 0
                self.vim_insert(t, 105)
            else:
                self.vim.op = OP_C
                self.vim.op_n = self.vim.count
                self.vim.count = 0
                self.vim_do_motion(t, 108, 0, False)
        elif ch == 83:                              # S: cc
            self.vim.op_n = self.vim.count
            self.vim.count = 0
            self.vim_lines_op(t, OP_C)
        elif ch == 114:                             # r: one more key
            self.vim.pend = 114
        elif ch == 74:                              # J
            self.vim_join(t, max(2, self.vim.take_count()))
        elif ch == 112 or ch == 80:                 # p P
            self.vim_put(t, ch == 112)
        elif ch == 117:                             # u
            var n2 = self.vim.take_count()
            for _ in range(n2):
                self.wins[t].undo()
            self.vim_settle(t)
        elif ch == 46:                              # .
            self.vim_repeat()
        elif ch == 118 or ch == 86:
            self.vim_visual(t, VM_VISUAL if ch == 118 else VM_VLINE)
        else:
            self.vim.count = 0
            self.say("Not a vim command: " + chr(ch))

    def vim_lines_op(mut self, t: Int, op: Int):
        """dd cc yy >> << gcc (and Y, S): the operator on this line and the count - 1
        after it."""
        var n = self.vim.total_count()
        self.vim.op = 0
        var r = self.wins[t].cr
        var r2 = min(r + n - 1, self.wins[t].buf.count() - 1)
        self.vim_apply(t, op, VimSpan(True, r, 0, r2, 0, True))

    def vim_insert(mut self, t: Int, how: Int):
        """i a I A o O: Insert mode, where the key says. Everything typed until Esc is
        one undo step, the command's own change included."""
        var cnt = self.vim.take_count()
        self.vim_begin_insert_group(t)
        var line = self.wins[t].buf.line(self.wins[t].cr)
        self.wins[t].sel = False
        self.wins[t].break_group()
        if how == 97 and len(line) > 0:                       # a
            self.wins[t].cc = min(self.wins[t].cc + 1, len(line))
        elif how == 73:                                       # I
            self.wins[t].cc = indent_end(line)
        elif how == 65:                                       # A
            self.wins[t].cc = len(line)
        elif how == 111:                                      # o
            self.wins[t].cc = len(line)
            self.wins[t].newline(self.auto_indent)
            cnt = 1
        elif how == 79:                                       # O
            var indent = List[Int]()
            if self.auto_indent:
                for c in line:
                    if c != 32 and c != 9:
                        break
                    indent.append(c)
            self.wins[t].cc = 0
            var nl = List[Int]()
            for c in indent:
                nl.append(c)
            nl.append(10)
            self.wins[t].insert_text(nl, ACT_OTHER)
            self.wins[t].cr -= 1
            self.wins[t].cc = len(indent)
            cnt = 1
        self.vim.ins_count = cnt
        self.vim.ins_r = self.wins[t].cr
        self.vim.ins_c = self.wins[t].cc
        self.vim_enter_insert(t)

    def vim_enter_insert(mut self, t: Int):
        self.wins[t].sync_want()
        self.vim.mode = VM_INSERT
        self.vim.changed = True
        self.insert_mode = True             # (typing inserts; TurboMojo's Insert key can still overwrite)
        self.wins[t].follow = True

    def vim_begin_insert_group(mut self, t: Int):
        self.vim_end_insert_group()
        if self.wins[t].forced_group == 0:
            self.wins[t].forced_group = self.wins[t].new_group()
            self.vim.ins_group = self.wins[t].forced_group

    def vim_end_insert_group(mut self):
        if self.vim.ins_group == 0:
            return
        for i in range(len(self.wins)):
            if self.wins[i].forced_group == self.vim.ins_group:
                self.wins[i].forced_group = 0
                self.wins[i].break_group()
        self.vim.ins_group = 0

    def vim_normal(mut self, t: Int, from_insert: Bool):
        """Back to Normal mode: from Insert the cursor steps back onto the last character
        typed, as in vim; a Visual selection goes."""
        self.vim_save_gv(t)
        self.vim.mode = VM_NORMAL
        self.vim_cancel()
        self.vim_end_insert_group()
        self.wins[t].vsel = 0
        self.wins[t].sel = False
        self.wins[t].extra.clear()
        if from_insert and self.wins[t].cc > 0:
            self.wins[t].cc -= 1
        self.wins[t].sync_want()
        self.vim_settle(t)

    # ------------------------------------------------------------ the changes
    def vim_store(mut self, text: List[Int], lines: Bool, yank: Bool):
        """What was deleted or copied (`yank`): into the register "x named before the
        command - "a to "z, "A to "Z adding to it, "+ and "* the clipboard (and the
        terminal's, with OSC 52), "_ nowhere - and the unnamed one, which TurboMojo's
        clipboard follows (Ctrl-V pastes it too); a copy also goes to "0."""
        var name = self.vim.regname
        self.vim.regname = 0
        if name == 95:                                  # "_: the black hole
            return
        var t = text.copy()
        var l = lines
        if name >= 97 and name <= 122:
            self.vim.regs[name - 97] = text.copy()
            self.vim.regs_lines[name - 97] = lines
        elif name >= 65 and name <= 90:
            var i = name - 65
            if self.vim.regs_lines[i] and not lines:
                for c in text:
                    self.vim.regs[i].append(c)
                self.vim.regs[i].append(10)             # (whole lines stay whole lines)
            else:
                if lines and not self.vim.regs_lines[i] and len(self.vim.regs[i]) > 0:
                    self.vim.regs[i].append(10)
                for c in text:
                    self.vim.regs[i].append(c)
            self.vim.regs_lines[i] = self.vim.regs_lines[i] or lines
            t = self.vim.regs[i].copy()
            l = self.vim.regs_lines[i]
        elif name == 43 or name == 42:                  # "+ "*
            self.osc52(text.copy())
            self.vim.clip_sent += 1
        if yank and (name == 0 or name == 34):
            self.vim.reg0 = text.copy()
            self.vim.reg0_lines = lines
        self.vim.reg = t.copy()
        self.vim.reg_lines = l
        self.clipboard = t^

    def vim_span_text(self, t: Int, s: VimSpan) -> List[Int]:
        if not s.lines:
            return self.wins[t].buf.get_text(s.r1, s.c1, s.r2, s.c2)
        var out = List[Int]()
        for r in range(s.r1, s.r2 + 1):
            for ch in self.wins[t].buf.line(r):
                out.append(ch)
            out.append(10)
        return out^

    def toggle_comment_multi(mut self, t: Int):
        """Toggle comments on window `t` across all cursors using language-aware prefix."""
        if t >= 0 and t < len(self.wins):
            self.wins[t].toggle_comment_multi()

    def vim_apply(mut self, t: Int, op: Int, s: VimSpan):
        """Operator `op` on span `s`."""
        var n_lines = s.r2 - s.r1 + 1
        if op == OP_GC:
            self.wins[t].sel = True
            self.wins[t].vsel = 2
            self.wins[t].ar = s.r1
            self.wins[t].ac = 0
            self.wins[t].cr = s.r2
            self.wins[t].cc = max(1, self.wins[t].buf.llen(s.r2))
            self.toggle_comment_multi(t)
            self.wins[t].sel = False
            self.wins[t].vsel = 0
            self.wins[t].cr = s.r1
            self.wins[t].cc = first_nonblank(self.wins[t].buf.line(s.r1))
            self.wins[t].sync_want()
            self.vim.changed = True
            self.vim_settle(t)
            return
        if op == OP_GT or op == OP_LT:
            self.vim_indent(t, s.r1, s.r2, 1 if op == OP_GT else -1)
            self.vim.changed = True
            if n_lines > 2:
                self.say(String(n_lines) + " lines " + (">" if op == OP_GT else "<") + "ed 1 time")
            return
        var text = self.vim_span_text(t, s)
        self.vim_store(text, s.lines, op == OP_Y)
        if op == OP_Y:
            if s.lines:
                self.wins[t].cr = s.r1
            else:
                self.wins[t].cr = s.r1
                self.wins[t].cc = s.c1
            self.wins[t].sync_want()
            self.vim_settle(t)
            if s.lines and n_lines > 2:
                self.say(String(n_lines) + " lines yanked")
            return
        self.vim.changed = True
        if op == OP_C:
            self.vim_begin_insert_group(t)
            var g = self.wins[t].new_group()
            if s.lines:
                # the lines go, one stays for the new text - with the first one's indentation
                var ind = indent_end(self.wins[t].buf.line(s.r1)) if self.auto_indent else 0
                _ = self.wins[t].buf.delete(s.r1, ind, s.r2, self.wins[t].buf.llen(s.r2), self.wins[t].cr, self.wins[t].cc, g)
                self.wins[t].cr = s.r1
                self.wins[t].cc = ind
            else:
                _ = self.wins[t].buf.delete(s.r1, s.c1, s.r2, s.c2, self.wins[t].cr, self.wins[t].cc, g)
                self.wins[t].cr = s.r1
                self.wins[t].cc = s.c1
            self.wins[t].sel = False
            self.vim_enter_insert(t)
            return
        # d
        var g2 = self.wins[t].new_group()
        if s.lines:
            var count = self.wins[t].buf.count()
            if s.r2 + 1 < count:
                _ = self.wins[t].buf.delete(s.r1, 0, s.r2 + 1, 0, self.wins[t].cr, self.wins[t].cc, g2)
            elif s.r1 > 0:
                _ = self.wins[t].buf.delete(s.r1 - 1, self.wins[t].buf.llen(s.r1 - 1), s.r2, self.wins[t].buf.llen(s.r2), self.wins[t].cr, self.wins[t].cc, g2)
            else:
                _ = self.wins[t].buf.delete(0, 0, s.r2, self.wins[t].buf.llen(s.r2), self.wins[t].cr, self.wins[t].cc, g2)
            self.wins[t].cr = min(s.r1, self.wins[t].buf.count() - 1)
            self.wins[t].cc = first_nonblank(self.wins[t].buf.line(self.wins[t].cr))
            if n_lines > 2:
                self.say(String(n_lines) + " fewer lines")
        else:
            _ = self.wins[t].buf.delete(s.r1, s.c1, s.r2, s.c2, self.wins[t].cr, self.wins[t].cc, g2)
            self.wins[t].cr = s.r1
            self.wins[t].cc = s.c1
        self.wins[t].sel = False
        self.wins[t].sync_want()
        self.vim_settle(t)

    def vim_surround_bounds(self, t: Int, old: Int) -> VimSpan:
        """Span covering `(open_pos, close_pos + 1)` of surrounding delimiter `old`."""
        var r = self.wins[t].cr
        var c = self.wins[t].cc
        var kind = surround_kind(old)
        if kind == 1:
            var q = obj_quote(self.wins[t].buf.line(r), r, c, True, old)
            if not q.ok or q.c1 <= 0:
                return VimSpan(False, 0, 0, 0, 0, False)
            return VimSpan(True, r, q.c1 - 1, r, q.c2 + 1, False)
        if kind > 0:
            return obj_bracket(self.wins[t].buf, r, c, False, kind)
        # arbitrary symmetric delimiter on the current line
        var ln = self.wins[t].buf.line(r)
        var a = -1
        var b = -1
        var i = c
        while i >= 0:
            if i < len(ln) and ln[i] == old:
                a = i
                break
            i -= 1
        var j = max(c, a + 1)
        while j < len(ln):
            if j != a and ln[j] == old:
                b = j
                break
            j += 1
        if a < 0 or b < 0:
            return VimSpan(False, 0, 0, 0, 0, False)
        return VimSpan(True, r, a, r, b + 1, False)

    def vim_surround_del(mut self, t: Int, old: Int):
        var s = self.vim_surround_bounds(t, old)
        if not s.ok:
            return
        var g = self.wins[t].new_group()
        _ = self.wins[t].buf.delete(s.r2, s.c2 - 1, s.r2, s.c2, self.wins[t].cr, self.wins[t].cc, g)
        _ = self.wins[t].buf.delete(s.r1, s.c1, s.r1, s.c1 + 1, self.wins[t].cr, self.wins[t].cc, g)
        self.wins[t].cr = s.r1
        self.wins[t].cc = s.c1
        self.wins[t].sync_want()
        self.vim.changed = True
        self.vim_settle(t)

    def vim_surround_change(mut self, t: Int, old: Int, new_ch: Int):
        var s = self.vim_surround_bounds(t, old)
        if not s.ok:
            return
        var pair = surround_pair(new_ch)
        var op_l = List[Int]()
        op_l.append(pair[0])
        var cl_l = List[Int]()
        cl_l.append(pair[1])
        var g = self.wins[t].new_group()
        _ = self.wins[t].buf.delete(s.r2, s.c2 - 1, s.r2, s.c2, self.wins[t].cr, self.wins[t].cc, g)
        _ = self.wins[t].buf.insert(s.r2, s.c2 - 1, cl_l, self.wins[t].cr, self.wins[t].cc, g)
        _ = self.wins[t].buf.delete(s.r1, s.c1, s.r1, s.c1 + 1, self.wins[t].cr, self.wins[t].cc, g)
        _ = self.wins[t].buf.insert(s.r1, s.c1, op_l, self.wins[t].cr, self.wins[t].cc, g)
        self.wins[t].cr = s.r1
        self.wins[t].cc = s.c1
        self.wins[t].sync_want()
        self.vim.changed = True
        self.vim_settle(t)

    def vim_surround_visual(mut self, t: Int, ch: Int):
        """Visual `S<ch>`: wrap the selection with `<open>...<close>`."""
        var pair = surround_pair(ch)
        var sr = self.wins[t].sel_range()
        var linewise = self.vim.mode == VM_VLINE
        self.vim_save_gv(t)
        self.vim.mode = VM_NORMAL
        self.wins[t].vsel = 0
        self.wins[t].sel = False
        self.wins[t].extra.clear()
        var g = self.wins[t].new_group()
        var op_l = List[Int]()
        op_l.append(pair[0])
        var cl_l = List[Int]()
        cl_l.append(pair[1])
        if linewise:
            var r2 = sr.r2 - (1 if sr.c2 == 0 and sr.r2 > sr.r1 else 0)
            cl_l.insert(0, 10)
            op_l.append(10)
            _ = self.wins[t].buf.insert(r2, self.wins[t].buf.llen(r2), cl_l, self.wins[t].cr, self.wins[t].cc, g)
            _ = self.wins[t].buf.insert(sr.r1, 0, op_l, self.wins[t].cr, self.wins[t].cc, g)
            self.wins[t].cr = sr.r1
            self.wins[t].cc = 0
        else:
            _ = self.wins[t].buf.insert(sr.r2, sr.c2, cl_l, self.wins[t].cr, self.wins[t].cc, g)
            _ = self.wins[t].buf.insert(sr.r1, sr.c1, op_l, self.wins[t].cr, self.wins[t].cc, g)
            self.wins[t].cr = sr.r1
            self.wins[t].cc = sr.c1
        self.wins[t].sync_want()
        self.vim.changed = True
        self.vim_settle(t)

    def vim_indent(mut self, t: Int, r1: Int, r2: Int, dir: Int):
        """> <: TurboMojo's indent of lines r1 to r2 (by the file's indentation)."""
        self.wins[t].sel = True
        self.wins[t].vsel = 2
        self.wins[t].ar = r1
        self.wins[t].ac = 0
        self.wins[t].cr = r2
        self.wins[t].cc = 0
        self.wins[t].indent_lines(dir)
        self.wins[t].sel = False
        self.wins[t].vsel = 0
        self.wins[t].cr = r1
        self.wins[t].cc = first_nonblank(self.wins[t].buf.line(r1))
        self.wins[t].sync_want()
        self.vim_settle(t)

    def vim_replace(mut self, t: Int, ch: Int):
        """r: the character under the cursor (and the count - 1 after it) becomes `ch`."""
        var n = self.vim.take_count()
        var r = self.wins[t].cr
        var c = self.wins[t].cc
        if c + n > self.wins[t].buf.llen(r) or ch == 10 or ch == 13:
            return
        var g = self.wins[t].new_group()
        _ = self.wins[t].buf.delete(r, c, r, c + n, r, c, g)
        var text = List[Int]()
        for _ in range(n):
            text.append(ch)
        _ = self.wins[t].buf.insert(r, c, text, r, c, g)
        self.wins[t].cc = c + n - 1
        self.vim.changed = True
        self.vim_settle(t)

    def vim_block_replace(mut self, t: Int, ch: Int):
        """V-BLOCK `r<ch>`: replace every cell in the rectangular block with `ch`."""
        if ch == 10 or ch == 13:
            return
        var lo = min(self.vim.ar, self.wins[t].cr)
        var hi = max(self.vim.ar, self.wins[t].cr)
        var c1 = min(self.vim.ac, self.wins[t].cc)
        var c2 = max(self.vim.ac, self.wins[t].cc)
        self.vim_save_gv(t)
        self.vim.mode = VM_NORMAL
        self.wins[t].vsel = 0
        self.wins[t].sel = False
        self.wins[t].extra.clear()
        var g = self.wins[t].new_group()
        for row in range(lo, hi + 1):
            var rl = self.wins[t].buf.llen(row)
            var rs = min(c1, rl)
            var re = min(c2 + 1, rl)
            if re > rs:
                var rep = List[Int]()
                for _ in range(re - rs):
                    rep.append(ch)
                _ = self.wins[t].buf.delete(row, rs, row, re, lo, c1, g)
                _ = self.wins[t].buf.insert(row, rs, rep, lo, c1, g)
        self.wins[t].cr = lo
        self.wins[t].cc = c1
        self.wins[t].sync_want()
        self.vim.changed = True
        self.vim_settle(t)

    def vim_join(mut self, t: Int, n: Int):
        """J: `n` lines into one (TurboMojo's join: the line break and the next line's
        indentation become one blank); one undo step."""
        var had = self.wins[t].forced_group
        if had == 0:
            self.wins[t].forced_group = self.wins[t].new_group()
        var joined = False
        for _ in range(n - 1):
            self.wins[t].sel = False
            if not self.wins[t].join_lines():           # (the cursor stays on the line)
                break
            joined = True
        self.wins[t].forced_group = had
        if joined:
            self.vim.changed = True
        self.vim_settle(t)

    def vim_reg_contents(mut self) -> Tuple[List[Int], Bool, Int]:
        """Read the active register (consuming `regname`), returning `(text, lines, name)`."""
        var name = self.vim.regname
        self.vim.regname = 0
        var src = self.vim.reg.copy()
        var src_lines = self.vim.reg_lines
        if name == 48:                                  # "0
            src = self.vim.reg0.copy()
            src_lines = self.vim.reg0_lines
        elif name >= 97 and name <= 122:
            src = self.vim.regs[name - 97].copy()
            src_lines = self.vim.regs_lines[name - 97]
        elif name >= 65 and name <= 90:
            src = self.vim.regs[name - 65].copy()
            src_lines = self.vim.regs_lines[name - 65]
        elif name == 43 or name == 42:                  # "+ "*: TurboMojo's clipboard
            src = self.clipboard.copy()
            src_lines = len(src) > 0 and src[len(src) - 1] == 10
        elif name == 95:
            return (List[Int](), False, 95)
        return (src^, src_lines, name)

    def vim_put(mut self, t: Int, after: Bool):
        """p P: the register after / before the cursor - whole lines below / above."""
        var n = self.vim.take_count()
        var rc = self.vim_reg_contents()
        var src = rc[0].copy()
        var src_lines = rc[1]
        var name = rc[2]
        if name == 95:
            return
        if len(src) == 0:
            if name == 0:
                self.say("Nothing to put yet")
            else:
                self.say("E353: Nothing in register " + chr(name))
            return
        var text = List[Int]()
        for _ in range(n):
            for ch in src:
                text.append(ch)
        var g = self.wins[t].new_group()
        var r = self.wins[t].cr
        self.vim.changed = True
        if src_lines:
            var row = r
            if not after:
                _ = self.wins[t].buf.insert(r, 0, text, r, self.wins[t].cc, g)
            elif r + 1 < self.wins[t].buf.count():
                _ = self.wins[t].buf.insert(r + 1, 0, text, r, self.wins[t].cc, g)
                row = r + 1
            else:
                # below the last line: the line break goes first
                var t2 = List[Int]()
                t2.append(10)
                for i in range(len(text) - 1):
                    t2.append(text[i])
                _ = self.wins[t].buf.insert(r, self.wins[t].buf.llen(r), t2, r, self.wins[t].cc, g)
                row = r + 1
            self.wins[t].cr = row
            self.wins[t].cc = first_nonblank(self.wins[t].buf.line(row))
        else:
            var col = self.wins[t].cc
            if after and self.wins[t].buf.llen(r) > 0:
                col = min(col + 1, self.wins[t].buf.llen(r))
            var e = self.wins[t].buf.insert(r, col, text, r, self.wins[t].cc, g)
            var multi = False
            for ch in text:
                if ch == 10:
                    multi = True
            if multi:
                self.wins[t].cr = r
                self.wins[t].cc = col
            else:
                self.wins[t].cr = e.r
                self.wins[t].cc = max(0, e.c - 1)
        self.wins[t].sync_want()
        self.vim_settle(t)

    def vim_repeat(mut self) raises:
        """.: the last change's keys typed again (the count: that many times)."""
        var n = self.vim.take_count()
        if len(self.vim.dot) == 0:
            return
        var keys = self.vim.dot.copy()
        var t = self.top()
        var had = 0
        var wrapped = False
        if n > 1 and t >= 0 and self.wins[t].kind == WK_EDITOR and self.wins[t].forced_group == 0:
            had = self.wins[t].forced_group
            self.wins[t].forced_group = self.wins[t].new_group()
            wrapped = True
        self.vim.replaying = True
        try:
            for _ in range(n):
                for k in keys:
                    self.handle_key(k)
        except err:
            self.vim.replaying = False
            if wrapped and t >= 0 and t < len(self.wins):
                self.wins[t].forced_group = had
            raise err
        self.vim.replaying = False
        if wrapped and t >= 0 and t < len(self.wins):
            self.wins[t].forced_group = had
            self.wins[t].break_group()
        self.vim.dot = keys^
        self.vim.cur.clear()
        self.vim.changed = False

    # ----------------------------------------------------------------- Visual
    def vim_visual(mut self, t: Int, mode: Int):
        self.vim.count = 0
        self.vim.mode = mode
        self.vim.ar = self.wins[t].cr
        self.vim.ac = self.wins[t].cc
        self.vim_settle(t)

    def vim_block_op(mut self, t: Int, ch: Int):
        """d x y c I A > < J on a `VM_BLOCK` rectangular selection."""
        var lo = min(self.vim.ar, self.wins[t].cr)
        var hi = max(self.vim.ar, self.wins[t].cr)
        var c1 = min(self.vim.ac, self.wins[t].cc)
        var c2 = max(self.vim.ac, self.wins[t].cc)
        self.vim_save_gv(t)
        self.vim.count = 0
        self.vim.mode = VM_NORMAL
        self.wins[t].vsel = 0
        self.wins[t].sel = False
        self.wins[t].extra.clear()
        if ch == 62 or ch == 60:
            self.vim_apply(t, ch, VimSpan(True, lo, 0, hi, 0, True))
            return
        if ch == 74:
            self.wins[t].cr = lo
            self.vim_join(t, max(2, hi - lo + 1))
            return
        if ch == 73 or ch == 65:                    # I / A: multi-cursor column insert
            var cs = List[Cur]()
            for row in range(lo, hi + 1):
                var rl = self.wins[t].buf.llen(row)
                var col = min(c1, rl) if ch == 73 else min(c2 + 1, rl)
                cs.append(Cur(row, col, False, row, 0, col))
            self.wins[t].set_cursors(cs^, 0)
            self.vim.ins_count = 1
            self.vim_begin_insert_group(t)
            self.vim_enter_insert(t)
            return
        # Collect block text (one line per row)
        var yanked = List[Int]()
        for row in range(lo, hi + 1):
            if row > lo:
                yanked.append(10)
            var rl = self.wins[t].buf.llen(row)
            var rs = min(c1, rl)
            var re = min(c2 + 1, rl)
            if re > rs:
                for cp in self.wins[t].buf.get_text(row, rs, row, re):
                    yanked.append(cp)
        self.vim_store(yanked, False, ch == OP_Y)
        if ch == OP_Y:
            self.wins[t].cr = lo
            self.wins[t].cc = c1
            self.wins[t].sync_want()
            self.vim_settle(t)
            return
        self.vim.changed = True
        if ch == OP_C:
            self.vim_begin_insert_group(t)
        var g = self.wins[t].new_group()
        var i_row = hi
        while i_row >= lo:
            var rl = self.wins[t].buf.llen(i_row)
            var rs = min(c1, rl)
            var re = min(c2 + 1, rl)
            if re > rs:
                _ = self.wins[t].buf.delete(i_row, rs, i_row, re, lo, c1, g)
            i_row -= 1
        if ch == OP_C:
            var cs2 = List[Cur]()
            for row in range(lo, hi + 1):
                var col = min(c1, self.wins[t].buf.llen(row))
                cs2.append(Cur(row, col, False, row, 0, col))
            self.wins[t].set_cursors(cs2^, 0)
            self.vim.ins_count = 1
            self.vim_enter_insert(t)
            return
        self.wins[t].cr = lo
        self.wins[t].cc = c1
        self.wins[t].sync_want()
        self.vim_settle(t)

    def vim_visual_key(mut self, t: Int, ch: Int) raises:
        if self.vim.pend == CH_I or self.vim.pend == CH_A:
            var inner = self.vim.pend == CH_I
            self.vim.pend = 0
            var span = vim_object(self.wins[t].buf, self.wins[t].cr, self.wins[t].cc, inner, ch)
            self.vim.count = 0
            if span.ok:
                if span.lines:
                    self.vim.mode = VM_VLINE
                    self.vim.ar = span.r1
                    self.vim.ac = 0
                    self.wins[t].cr = span.r2
                    self.wins[t].cc = 0
                else:
                    self.vim.mode = VM_VISUAL
                    self.vim.ar = span.r1
                    self.vim.ac = span.c1
                    self.wins[t].cr = span.r2
                    self.wins[t].cc = max(0, span.c2 - 1)
                self.wins[t].sync_want()
                self.vim_settle(t)
            return
        if self.vim_motion_key(t, ch):
            return
        if ch == CH_I or ch == CH_A:                  # viw, va", vi(...
            self.vim.pend = ch
            return
        if ch == 58:                                  # : - with '<,'> for the selection's lines
            self.vim.count = 0
            self.vim_cmdline_start(t, ch)
        elif ch == 34:                                # "x
            self.vim.pend = 34
        elif ch == 114 and self.vim.mode == VM_BLOCK: # r<ch> on block
            self.vim.pend = 114
        elif ch == 83:                                # S<ch>: surround visual selection
            self.vim.pend = PEND_VS
        elif ch == 118 or ch == 86:                   # v V: the other kind, or back to Normal
            var want = VM_VISUAL if ch == 118 else VM_VLINE
            if self.vim.mode == want:
                self.vim_normal(t, False)
            else:
                self.vim.mode = want
                self.vim_settle(t)
        elif ch == 111:                               # o: the other end
            var r = self.wins[t].cr
            var c = self.wins[t].cc
            self.wins[t].cr = self.vim.ar
            self.wins[t].cc = self.vim.ac
            self.vim.ar = r
            self.vim.ac = c
            self.wins[t].sync_want()
            self.vim_settle(t)
        elif self.vim.mode == VM_BLOCK and (ch == 73 or ch == 65 or ch == 100 or ch == 120 or ch == 121 or ch == 99 or ch == 62 or ch == 60 or ch == 74):
            self.vim_block_op(t, OP_D if ch == 120 else ch)
        elif ch == 112 or ch == 80:                   # p / P: replace visual selection
            var rc = self.vim_reg_contents()
            var src = rc[0].copy()
            var name = rc[2]
            if name == 95 or len(src) == 0:
                self.vim_normal(t, False)
                return
            var lines = self.wins[t].vsel == 2
            var sr = self.wins[t].sel_range()
            var r2 = sr.r2 - (1 if lines and sr.c2 == 0 and sr.r2 > sr.r1 else 0)
            var s = VimSpan(True, sr.r1, 0, r2, 0, True) if lines else VimSpan(True, sr.r1, sr.c1, sr.r2, sr.c2, False)
            var old_text = self.vim_span_text(t, s)
            self.vim_save_gv(t)
            self.vim.count = 0
            self.vim.mode = VM_NORMAL
            self.wins[t].vsel = 0
            self.wins[t].sel = False
            var g = self.wins[t].new_group()
            if s.lines:
                var ins = src.copy()
                if len(ins) > 0 and ins[len(ins) - 1] == 10:
                    _ = ins.pop()
                _ = self.wins[t].buf.delete(s.r1, 0, s.r2, self.wins[t].buf.llen(s.r2), self.wins[t].cr, self.wins[t].cc, g)
                _ = self.wins[t].buf.insert(s.r1, 0, ins, s.r1, 0, g)
                self.wins[t].cr = s.r1
                self.wins[t].cc = first_nonblank(self.wins[t].buf.line(s.r1))
            else:
                var ins2 = src.copy()
                if rc[1] and len(ins2) > 0 and ins2[len(ins2) - 1] == 10:
                    _ = ins2.pop()
                _ = self.wins[t].buf.delete(s.r1, s.c1, s.r2, s.c2, self.wins[t].cr, self.wins[t].cc, g)
                var e = self.wins[t].buf.insert(s.r1, s.c1, ins2, s.r1, s.c1, g)
                self.wins[t].cr = e.r
                self.wins[t].cc = max(0, e.c - 1)
            if ch == 112:
                self.vim.reg = old_text.copy()
                self.vim.reg_lines = s.lines
                self.clipboard = old_text^
            self.wins[t].sync_want()
            self.vim.changed = True
            self.vim_settle(t)
        elif ch == 100 or ch == 120 or ch == 121 or ch == 99 or ch == 62 or ch == 60 or ch == 74:
            # d x y c > < J on the selection
            var lines2 = self.wins[t].vsel == 2
            var sr2 = self.wins[t].sel_range()
            var s2: VimSpan
            if lines2:
                var r2_ = sr2.r2 - (1 if sr2.c2 == 0 and sr2.r2 > sr2.r1 else 0)
                s2 = VimSpan(True, sr2.r1, 0, r2_, 0, True)
            else:
                s2 = VimSpan(True, sr2.r1, sr2.c1, sr2.r2, sr2.c2, False)
            self.vim_save_gv(t)
            self.vim.count = 0
            self.vim.mode = VM_NORMAL
            self.wins[t].vsel = 0
            self.wins[t].sel = False
            if ch == 74:
                self.wins[t].cr = s2.r1
                self.vim_join(t, max(2, s2.r2 - s2.r1 + 1))
            else:
                self.vim_apply(t, OP_D if ch == 120 else ch, s2)
        else:
            self.vim.count = 0
            self.say("Not a vim command in Visual mode: " + chr(ch))
