"""The vim interface's keys (Phase 12; see vim.mojo): Normal, Insert and Visual modes in
front of TurboMojo's own bindings. handle_key asks vim_key first; what it does not take
goes on as before, so Ctrl and Alt keys, the F-keys and the menus work in every mode."""
from std.collections import List
from appstate import *
from util import *
from term import KEY_ESC, KEY_ENTER, KEY_BACKSPACE, KEY_TAB, KEY_UP, KEY_DOWN, KEY_LEFT, KEY_RIGHT, KEY_HOME, KEY_END, KEY_DELETE, KEY_INSERT, MOD_SHIFT, MOD_ALT, MOD_CTRL, KEY_MASK, K_BASE
from window import WK_EDITOR, Range
from vim import *


def first_nonblank(line: List[Int]) -> Int:
    """The column of the line's first character that is not a blank (its last one if
    the line is all blanks)."""
    var c = 0
    while c < len(line) and (line[c] == 32 or line[c] == 9):
        c += 1
    if c < len(line):
        return c
    return max(0, len(line) - 1)


__extension App:
    def vim_on(self) -> Bool:
        return self.keymap == KEYMAP_VIM

    def vim_reset(mut self):
        """A fresh start in Normal mode (the keymap was chosen, or left)."""
        self.vim = VimState()
        for i in range(len(self.wins)):
            if self.wins[i].vsel != 0:
                self.wins[i].vsel = 0
                self.wins[i].sel = False

    def vim_key(mut self, k: Int) raises -> Bool:
        """A key for vim? True when vim took it."""
        if self.keymap != KEYMAP_VIM or self.mode != M_NORMAL:
            return False
        var t = self.top()
        if t < 0 or self.wins[t].kind != WK_EDITOR:
            return False
        if self.vim.mode == VM_INSERT:
            if k == KEY_ESC:
                self.vim_normal(t, True)
                return True
            return False
        if (k & (MOD_CTRL | MOD_ALT)) != 0:
            return False                    # TurboMojo's
        var base = k & KEY_MASK
        if (k & MOD_SHIFT) != 0 and base >= K_BASE:
            return False                    # Shift and an arrow: TurboMojo's selection
        var ch = base
        if base >= K_BASE:
            # the keys that are not characters, as vim has them in Normal mode
            if k == KEY_ESC:
                if self.vim.mode != VM_NORMAL:
                    self.vim_normal(t, False)
                    return True
                self.vim.count = 0
                return False                # (Esc goes on: one cursor again, a tip away...)
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
                return True                 # (nothing in Normal mode)
            else:
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
        return True

    def vim_motion(mut self, t: Int, ch: Int) -> Bool:
        """The motions of this part (h j k l 0 $ +); False if `ch` is not one (its
        count is then left for the command)."""
        if not (ch == 104 or ch == 108 or ch == 106 or ch == 107 or ch == 43 or ch == 48 or ch == 36):
            return False
        var n = self.vim.take_count()
        var last = max(0, self.wins[t].buf.llen(self.wins[t].cr) - 1)
        if ch == 104:
            self.wins[t].cc = max(0, self.wins[t].cc - n)
            self.wins[t].sync_want()
        elif ch == 108:
            self.wins[t].cc = min(self.wins[t].cc + n, last)
            self.wins[t].sync_want()
        elif ch == 106 or ch == 107 or ch == 43:
            var sel = self.wins[t].sel
            self.wins[t].move_vert(n if ch != 107 else -n, False)
            self.wins[t].sel = sel
            if ch == 43:
                self.wins[t].cc = first_nonblank(self.wins[t].buf.line(self.wins[t].cr))
                self.wins[t].sync_want()
        elif ch == 48:
            self.wins[t].cc = 0
            self.wins[t].sync_want()
        elif ch == 36:
            if n > 1:
                var sel = self.wins[t].sel
                self.wins[t].move_vert(n - 1, False)
                self.wins[t].sel = sel
            self.wins[t].cc = max(0, self.wins[t].buf.llen(self.wins[t].cr) - 1)
            self.wins[t].want = 1 << 30         # (stays at the end on j and k)
        else:
            return False
        self.vim_settle(t)
        return True

    def vim_settle(mut self, t: Int):
        """After a motion: the cursor where vim may have it (on a character in Normal
        mode), the Visual selection from where it started, and the cursor shown."""
        var last = max(0, self.wins[t].buf.llen(self.wins[t].cr) - 1)
        if self.wins[t].cc > last:
            self.wins[t].cc = last
        if self.vim.mode == VM_VISUAL or self.vim.mode == VM_VLINE:
            self.wins[t].sel = True
            self.wins[t].ar = self.vim.ar
            self.wins[t].ac = self.vim.ac
            self.wins[t].vsel = 1 if self.vim.mode == VM_VISUAL else 2
        self.wins[t].extra.clear()
        self.wins[t].break_group()
        self.wins[t].follow = True

    def vim_normal_key(mut self, t: Int, ch: Int) raises:
        if self.vim_motion(t, ch):
            return
        if ch == 105 or ch == 97 or ch == 73 or ch == 65 or ch == 111 or ch == 79:
            self.vim_insert(t, ch)
        elif ch == 120:
            self.vim_delete_chars(t, self.vim.take_count())
        elif ch == 118 or ch == 86:
            self.vim_visual(t, VM_VISUAL if ch == 118 else VM_VLINE)
        else:
            self.vim.count = 0
            self.say("Not a vim command: " + chr(ch))

    def vim_insert(mut self, t: Int, how: Int):
        """i a I A o O: Insert mode, where the key says."""
        self.vim.count = 0
        var line = self.wins[t].buf.line(self.wins[t].cr)
        self.wins[t].sel = False
        self.wins[t].break_group()
        if how == 97 and len(line) > 0:                       # a
            self.wins[t].cc = min(self.wins[t].cc + 1, len(line))
        elif how == 73:                                       # I
            self.wins[t].cc = first_nonblank(line)
            if self.wins[t].cc == len(line) - 1 and (line[self.wins[t].cc] == 32 or line[self.wins[t].cc] == 9):
                self.wins[t].cc = len(line)
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
        self.wins[t].sync_want()
        self.vim.mode = VM_INSERT
        self.insert_mode = True             # (typing inserts; TurboMojo's Insert key can still overwrite)
        self.wins[t].follow = True

    def vim_normal(mut self, t: Int, from_insert: Bool):
        """Back to Normal mode: from Insert the cursor steps back onto the last character
        typed, as in vim; a Visual selection goes."""
        self.vim.mode = VM_NORMAL
        self.vim.count = 0
        self.wins[t].vsel = 0
        self.wins[t].sel = False
        if from_insert and self.wins[t].cc > 0:
            self.wins[t].cc -= 1
        self.wins[t].sync_want()
        self.vim_settle(t)

    def vim_delete_chars(mut self, t: Int, n: Int):
        """x: the characters under and after the cursor, not past the line's end."""
        var r = self.wins[t].cr
        var c = self.wins[t].cc
        var e = min(c + n, self.wins[t].buf.llen(r))
        if e <= c:
            return
        self.vim.reg = self.wins[t].buf.get_text(r, c, r, e)
        self.vim.reg_lines = False
        _ = self.wins[t].buf.delete(r, c, r, e, r, c, self.wins[t].new_group())
        self.vim_settle(t)

    def vim_visual(mut self, t: Int, mode: Int):
        self.vim.count = 0
        self.vim.mode = mode
        self.vim.ar = self.wins[t].cr
        self.vim.ac = self.wins[t].cc
        self.vim_settle(t)

    def vim_visual_key(mut self, t: Int, ch: Int):
        if self.vim_motion(t, ch):
            return
        if ch == 118 or ch == 86:                     # v V: the other kind, or back to Normal
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
        elif ch == 100 or ch == 120:                  # d x
            self.vim_cut_selection(t, True)
        elif ch == 121:                               # y
            self.vim_cut_selection(t, False)
        else:
            self.vim.count = 0
            self.say("Not a vim command in Visual mode: " + chr(ch))

    def vim_cut_selection(mut self, t: Int, delete: Bool):
        """d / y in Visual mode: the selection into vim's register (and TurboMojo's
        clipboard, so Ctrl-V pastes it too), deleted for d; then Normal mode."""
        var lines = self.wins[t].vsel == 2
        var s = self.wins[t].sel_range()
        var count = self.wins[t].buf.count()
        if lines and s.r2 == count - 1 and s.c2 == self.wins[t].buf.llen(s.r2) and s.r1 > 0 and delete:
            # the last line too: the line break before the first one goes with them
            s = Range(s.r1 - 1, self.wins[t].buf.llen(s.r1 - 1), s.r2, s.c2)
        var text = self.wins[t].buf.get_text(s.r1, s.c1, s.r2, s.c2)
        self.vim.reg = text.copy()
        self.vim.reg_lines = lines
        self.clipboard = text^
        var n_lines = s.r2 - s.r1 + (0 if s.c2 == 0 and s.r2 > s.r1 else 1)
        self.wins[t].vsel = 0
        self.wins[t].sel = False
        if delete:
            _ = self.wins[t].buf.delete(s.r1, s.c1, s.r2, s.c2, self.wins[t].cr, self.wins[t].cc, self.wins[t].new_group())
            self.wins[t].cr = min(s.r1 + (1 if lines and s.c1 > 0 else 0), self.wins[t].buf.count() - 1)
            self.wins[t].cc = first_nonblank(self.wins[t].buf.line(self.wins[t].cr)) if lines else s.c1
        else:
            self.wins[t].cr = s.r1
            self.wins[t].cc = s.c1 if not lines else self.wins[t].cc
        self.vim.mode = VM_NORMAL
        self.wins[t].sync_want()
        self.vim_settle(t)
        if n_lines > 1:
            self.say(String(n_lines) + (" fewer lines" if delete else " lines yanked"))
