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


def insert_key_kept(k: Int) -> Bool:
    """A key typed in Insert mode that . types again: text, Enter, Backspace, Tab,
    Delete - not Ctrl or Alt keys, the arrows or the F-keys."""
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
        self.vim.count = 0

    def vim_done(mut self):
        """After a key: when the command is whole (Normal mode, nothing waiting), its
        keys are kept for . if it changed the text."""
        if self.vim.mode != VM_NORMAL or self.vim.op != 0 or self.vim.pend != 0 or self.vim.count != 0 or self.vim.cl_on:
            return
        if self.vim.changed and not self.vim.replaying:
            self.vim.dot = self.vim.cur.copy()
        self.vim.cur.clear()
        self.vim.changed = False

    def vim_key(mut self, k: Int) raises -> Bool:
        """A key for vim? True when vim took it."""
        if self.keymap != KEYMAP_VIM or self.mode != M_NORMAL:
            return False
        var t = self.top()
        if t < 0 or self.wins[t].kind != WK_EDITOR:
            return False
        if self.vim.mode == VM_INSERT:
            if not self.vim.replaying and (k == KEY_ESC or insert_key_kept(k)):
                self.vim.cur.append(k)
            if k == KEY_ESC:
                self.vim_normal(t, True)
                self.vim_done()
                return True
            return False
        if self.vim.cl_on:                          # the command line takes every key
            if not self.vim.replaying:
                self.vim.cur.append(k)
            self.vim_cmdline_key(t, k)
            self.vim_done()
            return True
        if k == (114 | MOD_CTRL):                   # Ctrl-R: redo
            var n = self.vim.take_count()
            self.vim_cancel()
            for _ in range(n):
                self.wins[t].redo()
            self.vim_settle(t)
            return True
        if (k & (MOD_CTRL | MOD_ALT)) != 0:
            return False                    # TurboMojo's
        var base = k & KEY_MASK
        if (k & MOD_SHIFT) != 0 and base >= K_BASE:
            return False                    # Shift and an arrow: TurboMojo's selection
        if not self.vim.replaying:
            self.vim.cur.append(k)
        var p = self.vim.pend
        if is_find(p) or p == 114:
            # f t F T r: the next key is the character itself
            self.vim.pend = 0
            if base >= K_BASE:
                self.vim_cancel()
            elif p == 114:
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
                return True                 # (nothing in Normal mode)
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

    # ------------------------------------------------------------------ motions
    def vim_motion_key(mut self, t: Int, ch: Int) -> Bool:
        """The keys that move (or begin a motion: g, f t F T); False for any other."""
        if self.vim.pend == CH_G:
            self.vim.pend = 0
            if ch == CH_G:
                self.vim_do_motion(t, CH_G, 0, False)
            else:
                self.vim_cancel()
                self.say("Not a vim command: g" + chr(ch))
            return True
        if ch == CH_G or is_find(ch):
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
        if self.vim.mode == VM_VISUAL or self.vim.mode == VM_VLINE:
            self.wins[t].sel = True
            self.wins[t].ar = self.vim.ar
            self.wins[t].ac = self.vim.ac
            self.wins[t].vsel = 1 if self.vim.mode == VM_VISUAL else 2
        self.wins[t].extra.clear()
        self.wins[t].break_group()
        self.wins[t].follow = True

    # ----------------------------------------------------------------- Normal
    def vim_normal_key(mut self, t: Int, ch: Int) raises:
        var p = self.vim.pend
        if p == CH_I or p == CH_A:
            # a text object after an operator
            self.vim.pend = 0
            var span = vim_object(self.wins[t].buf, self.wins[t].cr, self.wins[t].cc, p == CH_I, ch)
            var op = self.vim.op
            self.vim_cancel()
            if not span.ok:
                return
            self.vim_apply(t, op, span)
            return
        if self.vim.op != 0:
            if ch == CH_I or ch == CH_A:
                self.vim.pend = ch
                return
            if ch == self.vim.op:
                self.vim_lines_op(t, ch)            # dd cc yy >> <<
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
        """dd cc yy >> << (and Y, S): the operator on this line and the count - 1
        after it."""
        var n = self.vim.total_count()
        self.vim.op = 0
        var r = self.wins[t].cr
        var r2 = min(r + n - 1, self.wins[t].buf.count() - 1)
        self.vim_apply(t, op, VimSpan(True, r, 0, r2, 0, True))

    def vim_insert(mut self, t: Int, how: Int):
        """i a I A o O: Insert mode, where the key says. Everything typed until Esc is
        one undo step, the command's own change included."""
        self.vim.count = 0
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
        self.vim.mode = VM_NORMAL
        self.vim_cancel()
        self.vim_end_insert_group()
        self.wins[t].vsel = 0
        self.wins[t].sel = False
        if from_insert and self.wins[t].cc > 0:
            self.wins[t].cc -= 1
        self.wins[t].sync_want()
        self.vim_settle(t)

    # ------------------------------------------------------------ the changes
    def vim_store(mut self, text: List[Int], lines: Bool):
        """What was deleted or copied: vim's register, and TurboMojo's clipboard (Ctrl-V
        pastes it too)."""
        self.vim.reg = text.copy()
        self.vim.reg_lines = lines
        self.clipboard = text.copy()

    def vim_span_text(self, t: Int, s: VimSpan) -> List[Int]:
        if not s.lines:
            return self.wins[t].buf.get_text(s.r1, s.c1, s.r2, s.c2)
        var out = List[Int]()
        for r in range(s.r1, s.r2 + 1):
            for ch in self.wins[t].buf.line(r):
                out.append(ch)
            out.append(10)
        return out^

    def vim_apply(mut self, t: Int, op: Int, s: VimSpan):
        """Operator `op` on span `s`."""
        var n_lines = s.r2 - s.r1 + 1
        if op == OP_GT or op == OP_LT:
            self.vim_indent(t, s.r1, s.r2, 1 if op == OP_GT else -1)
            self.vim.changed = True
            if n_lines > 2:
                self.say(String(n_lines) + " lines " + (">" if op == OP_GT else "<") + "ed 1 time")
            return
        var text = self.vim_span_text(t, s)
        self.vim_store(text, s.lines)
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

    def vim_put(mut self, t: Int, after: Bool):
        """p P: the register after / before the cursor - whole lines below / above."""
        var n = self.vim.take_count()
        if len(self.vim.reg) == 0:
            self.say("Nothing to put yet")
            return
        var text = List[Int]()
        for _ in range(n):
            for ch in self.vim.reg:
                text.append(ch)
        var g = self.wins[t].new_group()
        var r = self.wins[t].cr
        self.vim.changed = True
        if self.vim.reg_lines:
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
        self.vim.replaying = True
        for _ in range(n):
            for k in keys:
                self.handle_key(k)
        self.vim.replaying = False
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

    def vim_visual_key(mut self, t: Int, ch: Int):
        if self.vim_motion_key(t, ch):
            return
        if ch == 58:                                  # : - with '<,'> for the selection's lines
            self.vim.count = 0
            self.vim_cmdline_start(t, ch)
        elif ch == 118 or ch == 86:                     # v V: the other kind, or back to Normal
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
        elif ch == 100 or ch == 120 or ch == 121 or ch == 99 or ch == 62 or ch == 60 or ch == 74:
            # d x y c > < J on the selection
            var lines = self.wins[t].vsel == 2
            var sr = self.wins[t].sel_range()
            var s: VimSpan
            if lines:
                var r2 = sr.r2 - (1 if sr.c2 == 0 and sr.r2 > sr.r1 else 0)
                s = VimSpan(True, sr.r1, 0, r2, 0, True)
            else:
                s = VimSpan(True, sr.r1, sr.c1, sr.r2, sr.c2, False)
            self.vim.count = 0
            self.vim.mode = VM_NORMAL
            self.wins[t].vsel = 0
            self.wins[t].sel = False
            if ch == 74:
                self.wins[t].cr = s.r1
                self.vim_join(t, max(2, s.r2 - s.r1 + 1))
            else:
                self.vim_apply(t, OP_D if ch == 120 else ch, s)
        else:
            self.vim.count = 0
            self.say("Not a vim command in Visual mode: " + chr(ch))
