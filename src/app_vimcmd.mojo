"""The vim interface's command line (P12-03; see vim_cmd.mojo): / and ? search, n N * #,
and `:` commands - :w :q :wq :x :e :N :s :%s :d :y :noh and the rest, and TurboMojo's own
commands by name (`:build`, `:run`, `:file.save`). The line is typed on the status row,
as in vim; Enter runs it, Esc drops it."""
from std.collections import List
from appstate import *
from util import *
from term import KEY_ESC, KEY_ENTER, KEY_BACKSPACE, MOD_ALT, MOD_CTRL, KEY_MASK, K_BASE
from window import WK_EDITOR, Range
from window_search import *
from search import Search, make_search
from dialog import NEXT_NONE, NEXT_CLOSE
from commands import CM_SAVEALL
from vim import *
from vim_motion import *
from vim_cmd import *
from app_vim import *
from app_files import *
from app_exec import *


def title_plain(t: String) -> String:
    """A menu title as one lower-case word: "~G~o to line number..." is "gotolinenumber"."""
    var out = String("")
    for c in decode(t):
        if c == 126 or c == 32 or c == 46 or c == 0x2026:
            continue
        out += chr(lower(c))
    return out^


__extension App:
    def vim_cmdline_start(mut self, t: Int, kind: Int):
        """/ ? : - the command line opens on the status row (a : typed in Visual mode
        starts with '<,'>, the selection's lines)."""
        self.vim.cl_on = True
        self.vim.cl_kind = kind
        self.vim.cl_text = List[Int]()
        self.vim.cl_v1 = -1
        self.vim.cl_v2 = -1
        if kind == 58 and (self.vim.mode == VM_VISUAL or self.vim.mode == VM_VLINE):
            self.vim.cl_v1 = min(self.vim.ar, self.wins[t].cr)
            self.vim.cl_v2 = max(self.vim.ar, self.wins[t].cr)
            for c in decode("'<,'>"):
                self.vim.cl_text.append(c)

    def vim_cmdline_key(mut self, t: Int, k: Int) raises:
        """A key while the command line is typed."""
        if k == KEY_ESC or k == (99 | MOD_CTRL):           # Esc, Ctrl-C: dropped
            self.vim.cl_on = False
            self.vim_cancel()
            return
        if k == KEY_ENTER:
            self.vim.cl_on = False
            var text = self.vim.cl_text.copy()
            if self.vim.cl_kind == 58:
                self.vim_ex(t, text)
            else:
                self.vim_search_typed(t, text, self.vim.cl_kind == 47)
            return
        if k == KEY_BACKSPACE:
            if len(self.vim.cl_text) == 0:
                self.vim.cl_on = False                       # (as in vim: the line goes)
                self.vim_cancel()
            else:
                _ = self.vim.cl_text.pop()
            return
        if k == (117 | MOD_CTRL):                            # Ctrl-U: the line emptied
            self.vim.cl_text.clear()
            return
        if (k & (MOD_CTRL | MOD_ALT)) != 0 or (k & KEY_MASK) >= K_BASE:
            return                                           # (nothing else on the line)
        self.vim.cl_text.append(k & KEY_MASK)

    def vim_draw_cmdline(mut self):
        """The command line over the status row, with a bar cursor at its end."""
        var p = self.pal.copy()
        var y = self.scr.h - 1
        self.scr.fill(0, y, self.scr.w, 1, 32, p.status_fg, p.status_bg)
        var text = chr(self.vim.cl_kind) + to_str(self.vim.cl_text)
        var room = self.scr.w - 1
        var cps = decode(text)
        if len(cps) > room:
            # the end of a long line, as it is being typed
            var tail = List[Int]()
            for i in range(len(cps) - room, len(cps)):
                tail.append(cps[i])
            text = to_str(tail)
        _ = self.scr.text(0, y, text, p.status_fg, p.status_bg)
        self.scr.cx = min(cp_len(text), self.scr.w - 1)
        self.scr.cy = y
        self.scr.cvis = True
        self.scr.cblock = False
        self.scr.cbar = True

    # ----------------------------------------------------------------- search
    def vim_make_search(mut self, pat: List[Int]) -> Search:
        var vp = vim_pattern(pat)
        var s = make_search(vp.pat, not vp.icase, False, True)
        if not s.ok:
            self.say("E: bad pattern " + to_str(pat) + ": " + s.error)
        return s^

    def vim_find(self, t: Int, s: Search, forward: Bool, r0: Int, c0: Int) -> Range:
        """The next match's start after (r0, c0) - before it, backwards - going round
        the text's end: Range(row, column, 1 if it went round, 0); row -1 if none."""
        var n = self.wins[t].buf.count()
        for k in range(n + 1):
            var r = (r0 + k) % n if forward else ((r0 - k) % n + n) % n
            var ln = self.wins[t].buf.line(r)
            if forward:
                var m = s.caps_in(ln, c0 + 1 if k == 0 else 0)
                if len(m) > 0:
                    return Range(r, m[0], 1 if (r < r0 or k == n) else 0, 0)
            else:
                var ms = s.all_in(ln, 0, len(ln))
                var best = -1
                var j = 0
                while j + 1 < len(ms):
                    if k != 0 or ms[j] < c0:
                        best = ms[j]
                    j += 2
                if best >= 0:
                    return Range(r, best, 1 if (r > r0 or k == n) else 0, 0)
        return Range(-1, 0, 0, 0)

    def vim_search_typed(mut self, t: Int, pat: List[Int], forward: Bool):
        """/pattern or ?pattern and Enter (an empty pattern: the last one again)."""
        if len(pat) > 0:
            self.vim.s_pat = pat.copy()
        elif len(self.vim.s_pat) == 0:
            self.vim_cancel()
            self.say("E35: No previous regular expression")
            return
        self.vim.s_fwd = forward
        self.vim_search_go(t, forward, self.wins[t].cr, self.wins[t].cc)

    def vim_search_go(mut self, t: Int, forward: Bool, r0: Int, c0: Int):
        """The last search pattern, `forward` or not, from (r0, c0), the count's number
        of times: the cursor goes to the match, or the waiting operator works up to it."""
        var op = self.vim.op
        var n = self.vim.total_count() if op != 0 else self.vim.take_count()
        self.vim.op = 0
        if len(self.vim.s_pat) == 0:
            self.vim_cancel()
            self.say("E35: No previous regular expression")
            return
        var pat = self.vim.s_pat.copy()
        var s = self.vim_make_search(pat)
        if not s.ok:
            self.vim_cancel()
            return
        var r = r0
        var c = c0
        var wrapped = False
        for _ in range(n):
            var m = self.vim_find(t, s, forward, r, c)
            if m.r1 < 0:
                self.vim_cancel()
                self.wins[t].set_highlight(s)
                self.say("E486: Pattern not found: " + to_str(self.vim.s_pat))
                return
            r = m.r1
            c = m.c1
            if m.r2 == 1:
                wrapped = True
        self.wins[t].set_highlight(s)
        if op != 0:
            var span = motion_span(self.wins[t].buf, self.wins[t].cr, self.wins[t].cc, VimMove(True, r, c, VK_EXCL))
            if span.ok:
                self.vim_apply(t, op, span)
        else:
            self.wins[t].cr = r
            self.wins[t].cc = c
            self.wins[t].sync_want()
            self.vim_settle(t)
        if wrapped:
            self.say("search hit BOTTOM, continuing at TOP" if forward else "search hit TOP, continuing at BOTTOM")
        else:
            self.say(("/" if forward else "?") + to_str(self.vim.s_pat))

    def vim_star(mut self, t: Int, forward: Bool):
        """* #: the word under the cursor (or the next one on the line), as a whole word."""
        var line = self.wins[t].buf.line(self.wins[t].cr)
        var c = self.wins[t].cc
        while c < len(line) and vcls(line[c], False) != 2:
            c += 1
        if c >= len(line):
            self.vim_cancel()
            self.say("E348: No string under cursor")
            return
        var s = c
        while s > 0 and vcls(line[s - 1], False) == 2:
            s -= 1
        var e = c
        while e < len(line) and vcls(line[e], False) == 2:
            e += 1
        var pat = decode("\\<")
        for i in range(s, e):
            pat.append(line[i])
        pat.append(92)
        pat.append(62)
        self.vim.s_pat = pat^
        self.vim.s_fwd = forward
        self.vim_search_go(t, forward, self.wins[t].cr, s)

    # -------------------------------------------------------------- : commands
    def vim_ex(mut self, t: Int, line: List[Int]) raises:
        """A `:` command line."""
        var last = self.wins[t].buf.count() - 1
        var x = parse_ex(line, self.wins[t].cr, last, self.vim.cl_v1, self.vim.cl_v2)
        if self.vim.mode == VM_VISUAL or self.vim.mode == VM_VLINE:
            self.vim_normal(t, False)
        self.vim_cancel()
        if not x.ok:
            self.say(x.error)
            return
        var r1 = x.r1 if x.has_range else self.wins[t].cr
        var r2 = x.r2 if x.has_range else self.wins[t].cr
        var name = x.name
        if name.byte_length() == 0:
            if x.has_range:                                  # :N - that line
                self.wins[t].cr = r2
                self.wins[t].cc = first_nonblank(self.wins[t].buf.line(r2))
                self.wins[t].sync_want()
                self.vim_settle(t)
            return
        if ex_is(name, "write", 1):
            if x.arg.byte_length() == 0:
                _ = self.save_window(t, NEXT_NONE)
            else:
                var path = abs_path(String(self.cwd), x.arg)
                if path_exists(path) and not x.bang:
                    self.say("E13: File exists (add ! to override): " + path)
                elif write_file(path, self.wins[t].buf.to_bytes()):
                    self.say("Written: " + path)
                else:
                    self.say("E212: Can't open file for writing: " + path)
        elif name == "wq" or ex_is(name, "xit", 1) or name == "exit":
            var need = name == "wq" or self.wins[t].buf.modified
            if need and not self.save_window(t, NEXT_NONE):
                return
            self.close_window(t, NEXT_CLOSE)
        elif ex_is(name, "quit", 1):
            if x.bang:
                self.remove_window(t)
            elif self.wins[t].buf.modified:
                self.say("E37: No write since last change (add ! to override)")
            else:
                self.close_window(t, NEXT_CLOSE)
        elif ex_is(name, "wall", 2):
            self.exec(CM_SAVEALL)
        elif ex_is(name, "qall", 2) or name == "quitall":
            self.quit()                                      # (it asks about unsaved files)
        elif name == "wqa" or name == "wqall" or ex_is(name, "xall", 2):
            self.exec(CM_SAVEALL)
            self.quit()
        elif ex_is(name, "edit", 1):
            if x.arg.byte_length() == 0:
                self.say("E32: No file name" if not x.bang else ":e! is not in TurboMojo's vim (File > Revert is not either: undo with u)")
            else:
                self.open_path(x.arg)
        elif ex_is(name, "substitute", 1):
            self.vim_substitute(t, r1, r2, x.raw)
        elif ex_is(name, "nohlsearch", 3):
            self.wins[t].clear_highlight()
        elif ex_is(name, "delete", 1) or ex_is(name, "yank", 1):
            self.vim_apply(t, OP_D if name.startswith("d") else OP_Y, VimSpan(True, r1, 0, r2, 0, True))
        elif ex_is(name, "set", 2):
            self.say(":set is not in TurboMojo's vim: the settings are in Options and the config file")
        else:
            self.vim_turbo_command(name, x.arg)
        self.vim.changed = False                             # (. does not repeat : commands)

    def vim_turbo_command(mut self, name: String, arg: String) raises:
        """`:name` for one of TurboMojo's commands: its name (compile.build), the last part
        of it (build) or its menu title in one word (gotolinenumber, "go to line number")."""
        var want = lower_str(name)
        var words = title_plain(name + arg)
        var found = List[Int]()
        var names = List[String]()
        for c in self.reg.cmds:
            var full = lower_str(c.name)
            var seg = full
            var dot = full.rfind(".")
            if dot >= 0:
                seg = String(full[byte = dot + 1 :])
            if full == want or seg == want or title_plain(c.title) == words:
                var seen = False
                for f in found:
                    if f == c.id:
                        seen = True
                if not seen:
                    found.append(c.id)
                    names.append(c.name)
        if len(found) == 0:
            self.say("E492: Not an editor command: " + name + ((" " + arg) if arg.byte_length() > 0 else ""))
            return
        if len(found) > 1:
            var all = String("")
            for i in range(len(names)):
                all += (", " if i > 0 else "") + ":" + names[i]
            self.say("Which one? " + all)
            return
        if self.cmd_unavailable(found[0]):
            self.say("Not now: :" + names[0])
            return
        self.exec(found[0])

    def vim_substitute(mut self, t: Int, r1: Int, r2: Int, raw: List[Int]):
        """:s/pattern/replacement/flags on rows r1 to r2 - one undo step."""
        var sub = parse_sub(raw)
        if not sub.ok:
            self.say(sub.error)
            return
        var pat = sub.pat.copy()
        if len(pat) == 0:
            pat = self.vim.s_pat.copy()
        if len(pat) == 0:
            self.say("E35: No previous regular expression")
            return
        self.vim.s_pat = pat.copy()
        var vp = vim_pattern(pat)
        var icase = (vp.icase or sub.icase) and not sub.noic
        var s = make_search(vp.pat, not icase, False, True)
        if not s.ok:
            self.say("E: bad pattern " + to_str(pat) + ": " + s.error)
            return
        var rep = vim_replacement(sub.rep)
        var g = self.wins[t].new_group()
        var count = 0
        var lines = 0
        var at = -1
        var r = r2
        while r >= r1:                      # bottom up: new line breaks move no row still to do
            var ln = self.wins[t].buf.line(r)
            var out = List[Int]()
            var upto = 0
            var c = 0
            var here = 0
            while c <= len(ln):
                var m = s.re.search(ln, c)
                if len(m) == 0:
                    break
                for i in range(upto, m[0]):
                    out.append(ln[i])
                for v in s.replacement(rep, ln, m):
                    out.append(v)
                upto = m[1]
                here += 1
                if not sub.all:
                    break
                c = m[1] if m[1] > m[0] else m[0] + 1
            if here > 0:
                for i in range(upto, len(ln)):
                    out.append(ln[i])
                _ = self.wins[t].buf.delete(r, 0, r, len(ln), self.wins[t].cr, self.wins[t].cc, g)
                _ = self.wins[t].buf.insert(r, 0, out, self.wins[t].cr, self.wins[t].cc, g)
                count += here
                lines += 1
                if at < 0:
                    at = r
            r -= 1
        self.wins[t].break_group()
        if count == 0:
            self.say("E486: Pattern not found: " + to_str(pat))
            return
        self.wins[t].cr = min(at, self.wins[t].buf.count() - 1)
        self.wins[t].cc = first_nonblank(self.wins[t].buf.line(self.wins[t].cr))
        self.wins[t].sync_want()
        self.vim_settle(t)
        self.say(String(count) + (" substitution" if count == 1 else " substitutions") + " on " + String(lines) + (" line" if lines == 1 else " lines"))
