"""The vim interface's command line (P12-03; see vim_cmd.mojo): / and ? search, n N * #,
and `:` commands - :w :q :wq :x :e :N :s :%s :d :y :noh and the rest, and TurboMojo's own
commands by name (`:build`, `:run`, `:file.save`). The line is typed on the status row,
as in vim; Enter runs it, Esc drops it."""
from std.collections import List
from appstate import *
from util import *
from term import KEY_ESC, KEY_ENTER, KEY_BACKSPACE, KEY_TAB, KEY_UP, KEY_DOWN, MOD_SHIFT, MOD_ALT, MOD_CTRL, KEY_MASK, K_BASE
from window import WK_EDITOR, Range
from window_search import *
from search import Search, make_search
from dialog import NEXT_NONE, NEXT_CLOSE
from highlight import HL_JSON, HL_PYTHON
from ipynb import is_ipynb_path, percent_text_to_ipynb, IpynbCellOutput
from commands import CM_SAVEALL, CM_SPLIT_DOWN, CM_SPLIT_RIGHT, CM_NEXT_TAB, CM_PREV_TAB, CM_NEXTWIN, CM_PREVWIN, CM_EXPLORER, CM_RUN_CELL, CM_RUN_ALL_CELLS, CM_VIM_ZEN, CM_NEW_NOTEBOOK
from vim import *
from vim_motion import *
from vim_cmd import *
from grep import collect_search_files, MAX_FILE_BYTES, is_binary
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


def _parse_norm_keys(raw: List[Int]) -> List[Int]:
    """Decode key sequence after `:norm[al][!] `, translating `<Esc>`, `<CR>`, `<BS>`, `<Tab>`, `<C-x>`."""
    var out = List[Int]()
    var i = 1 if (len(raw) > 0 and raw[0] == 32) else 0
    var n = len(raw)
    while i < n:
        var ch = raw[i]
        if ch == 60:
            var close = -1
            var k = i + 1
            while k < min(n, i + 10):
                if raw[k] == 62:
                    close = k
                    break
                k += 1
            if close > i + 1:
                var tag_cps = List[Int]()
                for q in range(i + 1, close):
                    tag_cps.append(lower(raw[q]))
                var tag = to_str(tag_cps)
                if tag == "esc":
                    out.append(KEY_ESC)
                    i = close + 1
                    continue
                if tag == "cr" or tag == "enter" or tag == "return":
                    out.append(KEY_ENTER)
                    i = close + 1
                    continue
                if tag == "bs" or tag == "backspace":
                    out.append(KEY_BACKSPACE)
                    i = close + 1
                    continue
                if tag == "tab":
                    out.append(KEY_TAB)
                    i = close + 1
                    continue
                if tag == "space":
                    out.append(32)
                    i = close + 1
                    continue
                if tag.byte_length() == 3 and tag.startswith("c-"):
                    var cch = tag_cps[2]
                    if cch >= 97 and cch <= 122:
                        out.append(cch | MOD_CTRL)
                        i = close + 1
                        continue
        if ch == 27:
            out.append(KEY_ESC)
        elif ch == 10 or ch == 13:
            out.append(KEY_ENTER)
        elif ch >= 1 and ch <= 26:
            out.append((ch + 96) | MOD_CTRL)
        else:
            out.append(ch)
        i += 1
    return out^


__extension App:
    def vim_cmdline_start(mut self, t: Int, kind: Int):
        """/ ? : - the command line opens on the status row (a : typed in Visual mode
        starts with '<,'>, the selection's lines)."""
        self.vim.cl_on = True
        self.vim.cl_kind = kind
        self.vim.cl_text = List[Int]()
        self.vim.cl_hist_idx = -1
        self.vim.cl_draft = ""
        self.vim.cl_tab_cands.clear()
        self.vim.cl_tab_idx = -1
        self.vim.cl_v1 = -1
        self.vim.cl_v2 = -1
        self.vim.cl_orig_r = self.wins[t].cr
        self.vim.cl_orig_c = self.wins[t].cc
        if kind == 58 and (self.vim.mode == VM_VISUAL or self.vim.mode == VM_VLINE or self.vim.mode == VM_BLOCK):
            self.vim.cl_v1 = min(self.vim.ar, self.wins[t].cr)
            self.vim.cl_v2 = max(self.vim.ar, self.wins[t].cr)
            for c in decode("'<,'>"):
                self.vim.cl_text.append(c)

    def _vim_hist_push(mut self, is_cmd: Bool, entry: String):
        if entry.byte_length() == 0:
            return
        if is_cmd:
            if len(self.vim.cl_hist_cmd) > 0 and self.vim.cl_hist_cmd[len(self.vim.cl_hist_cmd) - 1] == entry:
                return
            self.vim.cl_hist_cmd.append(entry)
            if len(self.vim.cl_hist_cmd) > 64:
                _ = self.vim.cl_hist_cmd.pop(0)
        else:
            if len(self.vim.cl_hist_search) > 0 and self.vim.cl_hist_search[len(self.vim.cl_hist_search) - 1] == entry:
                return
            self.vim.cl_hist_search.append(entry)
            if len(self.vim.cl_hist_search) > 64:
                _ = self.vim.cl_hist_search.pop(0)

    def _vim_hist_step(mut self, t: Int, up: Bool):
        var is_cmd = self.vim.cl_kind == 58
        var hist = self.vim.cl_hist_cmd.copy() if is_cmd else self.vim.cl_hist_search.copy()
        if len(hist) == 0:
            return
        if self.vim.cl_hist_idx < 0:
            if not up:
                return
            self.vim.cl_draft = to_str(self.vim.cl_text)
            var idx = len(hist) - 1
            while idx >= 0:
                if self.vim.cl_draft.byte_length() == 0 or hist[idx].startswith(self.vim.cl_draft):
                    self.vim.cl_hist_idx = idx
                    self.vim.cl_text = decode(hist[idx])
                    self.vim_incsearch_preview(t)
                    return
                idx -= 1
            return
        if up:
            var idx2 = self.vim.cl_hist_idx - 1
            while idx2 >= 0:
                if self.vim.cl_draft.byte_length() == 0 or hist[idx2].startswith(self.vim.cl_draft):
                    self.vim.cl_hist_idx = idx2
                    self.vim.cl_text = decode(hist[idx2])
                    self.vim_incsearch_preview(t)
                    return
                idx2 -= 1
        else:
            var idx3 = self.vim.cl_hist_idx + 1
            while idx3 < len(hist):
                if self.vim.cl_draft.byte_length() == 0 or hist[idx3].startswith(self.vim.cl_draft):
                    self.vim.cl_hist_idx = idx3
                    self.vim.cl_text = decode(hist[idx3])
                    self.vim_incsearch_preview(t)
                    return
                idx3 += 1
            self.vim.cl_hist_idx = -1
            self.vim.cl_text = decode(self.vim.cl_draft)
            self.vim_incsearch_preview(t)

    def _vim_cmdline_complete(mut self, backwards: Bool):
        if self.vim.cl_kind != 58:
            return
        var cur = to_str(self.vim.cl_text)
        if len(self.vim.cl_tab_cands) > 0 and self.vim.cl_tab_idx >= 0 and self.vim.cl_tab_idx < len(self.vim.cl_tab_cands) and cur == self.vim.cl_tab_cands[self.vim.cl_tab_idx]:
            var n = len(self.vim.cl_tab_cands)
            self.vim.cl_tab_idx = (self.vim.cl_tab_idx + (-1 if backwards else 1) + n) % n
            self.vim.cl_text = decode(self.vim.cl_tab_cands[self.vim.cl_tab_idx])
            return
        self.vim.cl_tab_cands.clear()
        self.vim.cl_tab_idx = -1
        var sp = cur.find(" ")
        if sp > 0:
            var head = String(cur[byte=0:sp])
            var hclean = String(head.rstrip("!"))
            if (
                hclean == "e"
                or hclean == "edit"
                or hclean == "w"
                or hclean == "write"
                or hclean == "sp"
                or hclean == "split"
                or hclean == "vsp"
                or hclean == "vsplit"
            ):
                var raw_arg = String(cur[byte=sp + 1:].lstrip())
                var slash = raw_arg.rfind("/")
                var dir_rel = String(raw_arg[byte=0:slash + 1]) if slash >= 0 else String("")
                var leaf_pfx = String(raw_arg[byte=slash + 1:]) if slash >= 0 else raw_arg
                var search_dir = abs_path(String(self.cwd), dir_rel) if dir_rel.byte_length() > 0 else String(self.cwd)
                for entry in list_dir(search_dir):
                    if entry == "../" and not leaf_pfx.startswith("."):
                        continue
                    if entry.startswith(leaf_pfx):
                        self.vim.cl_tab_cands.append(head + " " + dir_rel + entry)
        else:
            var pfx = String(cur.lstrip())
            var builtins = [
                "write", "quit", "wq", "wall", "qall", "wqa", "edit", "split", "vsplit",
                "bnext", "bprev", "bdelete", "nohlsearch", "substitute", "delete", "yank",
                "set", "global", "vglobal", "normal", "vimgrep", "cdo", "cfdo",
                "Explore", "Ex", "notebook", "nb", "cell", "cells", "zen", "help",
            ]
            for b in builtins:
                var bs = String(b)
                if bs.startswith(pfx):
                    self.vim.cl_tab_cands.append(bs)
            for c in self.reg.cmds:
                var full = lower_str(c.name)
                var dot = full.rfind(".")
                var leaf = String(full[byte=dot + 1:]) if dot >= 0 else full
                if leaf.startswith(pfx) and not (leaf in self.vim.cl_tab_cands):
                    self.vim.cl_tab_cands.append(leaf)
                if full.startswith(pfx) and not (full in self.vim.cl_tab_cands):
                    self.vim.cl_tab_cands.append(full)
        if len(self.vim.cl_tab_cands) > 0:
            self.vim.cl_tab_idx = len(self.vim.cl_tab_cands) - 1 if backwards else 0
            self.vim.cl_text = decode(self.vim.cl_tab_cands[self.vim.cl_tab_idx])

    def vim_incsearch_preview(mut self, t: Int):
        """Live match highlighting while typing / or ? on the command line."""
        if self.vim.cl_kind != 47 and self.vim.cl_kind != 63:
            return
        if len(self.vim.cl_text) == 0:
            if len(self.vim.s_pat) > 0:
                var vp0 = vim_pattern(self.vim.s_pat)
                var s0 = make_search(vp0.pat, not vp0.icase, False, True)
                if s0.ok:
                    self.wins[t].set_highlight(s0)
            else:
                self.wins[t].clear_highlight()
            return
        var vp = vim_pattern(self.vim.cl_text)
        var s = make_search(vp.pat, not vp.icase, False, True)
        if s.ok and len(s.pat) > 0:
            self.wins[t].set_highlight(s)

    def vim_cmdline_key(mut self, t: Int, k: Int) raises:
        """A key while the command line is typed."""
        if k == KEY_ESC or k == (99 | MOD_CTRL) or k == (91 | MOD_CTRL):   # Esc, Ctrl-C, Ctrl-[: dropped
            self.vim.cl_on = False
            if self.vim.cl_kind == 47 or self.vim.cl_kind == 63:
                self.vim.cl_text.clear()
                self.vim_incsearch_preview(t)
            self.vim_cancel()
            return
        if k == KEY_ENTER:
            self.vim.cl_on = False
            var text = self.vim.cl_text.copy()
            self._vim_hist_push(self.vim.cl_kind == 58, to_str(text))
            if self.vim.cl_kind == 58:
                self.vim_ex(t, text)
            else:
                self.vim_search_typed(t, text, self.vim.cl_kind == 47)
            return
        if k == KEY_UP or k == KEY_DOWN:
            self.vim.cl_tab_cands.clear()
            self.vim.cl_tab_idx = -1
            self._vim_hist_step(t, k == KEY_UP)
            return
        if k == KEY_TAB or k == (KEY_TAB | MOD_SHIFT):
            self._vim_cmdline_complete((k & MOD_SHIFT) != 0)
            return
        self.vim.cl_tab_cands.clear()
        self.vim.cl_tab_idx = -1
        self.vim.cl_hist_idx = -1
        if k == KEY_BACKSPACE:
            if len(self.vim.cl_text) == 0:
                self.vim.cl_on = False                       # (as in vim: the line goes)
                self.vim_incsearch_preview(t)
                self.vim_cancel()
            else:
                _ = self.vim.cl_text.pop()
                self.vim_incsearch_preview(t)
            return
        if k == (117 | MOD_CTRL):                            # Ctrl-U: the line emptied
            self.vim.cl_text.clear()
            self.vim_incsearch_preview(t)
            return
        if (k & (MOD_CTRL | MOD_ALT)) != 0 or (k & KEY_MASK) >= K_BASE:
            return                                           # (nothing else on the line)
        self.vim.cl_text.append(k & KEY_MASK)
        self.vim_incsearch_preview(t)

    def vim_draw_cmdline(mut self):
        """The command line over the status row, with a bar cursor at its end."""
        var p = self.pal.copy()
        var y = self.scr.h - 1
        var fg = p.ed_fg if self.vim_zen else p.status_fg
        var bg = p.ed_bg if self.vim_zen else p.status_bg
        self.scr.fill(0, y, self.scr.w, 1, 32, fg, bg)
        var text = chr(self.vim.cl_kind) + to_str(self.vim.cl_text)
        var room = self.scr.w - 1
        var cps = decode(text)
        if len(cps) > room:
            # the end of a long line, as it is being typed
            var tail = List[Int]()
            for i in range(len(cps) - room, len(cps)):
                tail.append(cps[i])
            text = to_str(tail)
        _ = self.scr.text(0, y, text, fg, bg)
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
            self.vim_note_ctx(t)
            self.jump_mark()
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
        if self.vim.mode == VM_VISUAL or self.vim.mode == VM_VLINE or self.vim.mode == VM_BLOCK:
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
                self.vim_note_ctx(t)
                self.jump_mark()
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
                else:
                    var out_bytes: List[UInt8]
                    if is_ipynb_path(path) and self.wins[t].lang_override != HL_JSON:
                        var is_mj = (
                            self._workspace_prefers_mojo(path)
                            if self.wins[t].lang_override < 0
                            else (self.wins[t].lang_override != HL_PYTHON)
                        )
                        var prev_raw = bytes_to_str(read_file(path)) if path_exists(path) else String("")
                        var live_outs = self.collect_ipynb_outputs(t)
                        out_bytes = str_bytes(
                            percent_text_to_ipynb(bytes_to_str(self.wins[t].buf.to_bytes()), is_mj, prev_raw, live_outs)
                        )
                    else:
                        out_bytes = self.wins[t].buf.to_bytes()
                    if write_file(path, out_bytes):
                        if self.wins[t].path.byte_length() == 0:
                            self.wins[t].path = path
                            self.wins[t].title = basename(path)
                            if is_ipynb_path(path) and self.wins[t].lang_override < 0:
                                self._init_new_ipynb_window(t, path)
                            self.wins[t].buf.modified = False
                        self.say("Written: " + path)
                    else:
                        self.say("E212: Can't open file for writing: " + path)
        elif name == "wq" or ex_is(name, "xit", 1) or name == "exit":
            var need = name == "wq" or self.wins[t].buf.modified
            if need and not self.save_window(t, NEXT_NONE):
                return
            self.close_window(t, NEXT_CLOSE)
            if self.vim_zen and len(self.wins) == 0:
                self.running = False
        elif ex_is(name, "quit", 1):
            if x.bang:
                self.remove_window(t)
                if self.vim_zen and len(self.wins) == 0:
                    self.running = False
            elif self.wins[t].buf.modified and not self.has_shared_sibling(t):
                self.say("E37: No write since last change (add ! to override)")
            else:
                self.close_window(t, NEXT_CLOSE)
                if self.vim_zen and len(self.wins) == 0:
                    self.running = False
        elif ex_is(name, "wall", 2):
            self.exec(CM_SAVEALL)
        elif ex_is(name, "qall", 2) or name == "quitall":
            if x.bang:
                self.running = False
            else:
                self.quit()                                      # (it asks about unsaved files)
        elif name == "wqa" or name == "wqall" or ex_is(name, "xall", 2):
            self.exec(CM_SAVEALL)
            self.quit()
        elif ex_is(name, "edit", 1):
            if x.arg.byte_length() == 0:
                self.say("E32: No file name" if not x.bang else ":e! is not in TurboMojo's vim (File > Revert is not either: undo with u)")
            else:
                self.open_path(x.arg)
        elif name == "sp" or ex_is(name, "split", 2) or name == "vsp" or ex_is(name, "vsplit", 2):
            var right = name == "vsp" or ex_is(name, "vsplit", 2)
            if x.arg.byte_length() > 0:
                self.open_path(x.arg)
                if self.tiled:
                    self.exec(CM_SPLIT_RIGHT if right else CM_SPLIT_DOWN)
            else:
                self.clone_editor_view(right)
        elif name == "bn" or ex_is(name, "bnext", 2):
            self.exec(CM_NEXT_TAB if self.tiled else CM_NEXTWIN)
        elif name == "bp" or name == "bprev" or ex_is(name, "bprevious", 2):
            self.exec(CM_PREV_TAB if self.tiled else CM_PREVWIN)
        elif name == "bd" or ex_is(name, "bdelete", 2):
            if x.bang:
                self.remove_window(t)
                if self.vim_zen and len(self.wins) == 0:
                    self.running = False
            elif self.wins[t].buf.modified:
                self.say("E89: No write since last change for buffer (add ! to override)")
            else:
                self.close_window(t, NEXT_CLOSE)
                if self.vim_zen and len(self.wins) == 0:
                    self.running = False
        elif name == "Ex" or ex_is(name, "Explore", 2) or name == "Vex" or name == "Lex":
            if x.arg.byte_length() > 0:
                var dir_p = abs_path(String(self.cwd), x.arg)
                if is_dir(dir_p):
                    self.ex.set_root(dir_p)
            self.exec(CM_EXPLORER)
        elif name == "nb" or name == "notebook":
            if x.arg.byte_length() > 0:
                var nb_arg = x.arg
                if nb_arg.find(".") < 0:
                    nb_arg += ".ipynb"
                self.open_path(nb_arg)
            else:
                self.new_notebook_cmd()
        elif name == "cell" or name == "runcell":
            var ca = lower_str(x.arg)
            if ca == "add" or ca == "below" or ca == "b":
                self.exec(CM_CELL_INSERT_BELOW)
            elif ca == "above" or ca == "a":
                self.exec(CM_CELL_INSERT_ABOVE)
            elif ca == "del" or ca == "delete" or ca == "d":
                self.exec(CM_CELL_DELETE)
            elif ca == "md" or ca == "markdown" or ca == "m":
                self.cell_set_type(True)
            elif ca == "code" or ca == "y":
                self.cell_set_type(False)
            elif ca == "restart":
                self.exec(CM_CELL_RESTART)
            elif ca == "clear":
                self.exec(CM_CELL_CLEAR_OUT)
            else:
                self.exec(CM_RUN_CELL)
        elif name == "cells" or name == "runall":
            self.exec(CM_RUN_ALL_CELLS)
        elif name == "zen" or name == "vimzen":
            self.exec(CM_VIM_ZEN)
        elif ex_is(name, "help", 1):
            var ha = lower_str(x.arg)
            if ha.find("nb") >= 0 or ha.find("notebook") >= 0 or ha.find("ipynb") >= 0 or ha.find("jupyter") >= 0 or ha.find("cell") >= 0:
                self.help_page("notebooks.md")
            elif ha.find("py") >= 0:
                self.help_page("coming-from-python.md")
            elif ha.find("key") >= 0 or ha.find("cheat") >= 0 or ha.find("vim") >= 0:
                self.help_page("cheatsheet.md")
            else:
                self.help_page("guide.md")
        elif ex_is(name, "substitute", 1):
            self.vim_substitute(t, r1, r2, x.raw)
        elif ex_is(name, "nohlsearch", 3):
            self.wins[t].clear_highlight()
        elif ex_is(name, "delete", 1) or ex_is(name, "yank", 1):
            self.vim_apply(t, OP_D if name.startswith("d") else OP_Y, VimSpan(True, r1, 0, r2, 0, True))
        elif ex_is(name, "set", 2):
            self.vim_set(t, x.arg)
        elif ex_is(name, "global", 1) or ex_is(name, "vglobal", 1):
            var gr1 = x.r1 if x.has_range else 0
            var gr2 = x.r2 if x.has_range else max(0, self.wins[t].buf.count() - 1)
            var inv = x.bang or ex_is(name, "vglobal", 1)
            self.vim_global(t, gr1, gr2, x.raw, inv)
        elif ex_is(name, "normal", 4):
            self.vim_normal_cmd(t, r1, r2, x.raw)
        elif ex_is(name, "vimgrep", 3):
            self.vim_vimgrep(t, x.raw)
        elif name == "cdo" or ex_is(name, "cfdo", 3):
            self.vim_cdo(x.arg, ex_is(name, "cfdo", 3))
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

    def vim_set(mut self, t: Int, arg: String):
        """:set [option ...] - configure line numbers, wrap, ignorecase, whitespace, tabstop, shiftwidth."""
        if String(arg.strip()).byte_length() == 0:
            self.say(
                ("nu " if self.line_numbers else "nonu ")
                + ("rnu " if self.rel_numbers else "nornu ")
                + ("wrap " if self.soft_wrap else "nowrap ")
                + ("ic " if not self.find_case else "noic ")
                + ("list " if self.show_ws else "nolist ")
                + "ts=" + String(self.tab_width)
                + " sw=" + String(self.indent_size)
            )
            return
        var items = parse_set(arg)
        for it in items:
            if not it.ok:
                self.say(it.error)
                return
            if it.key == "number":
                var v = (not self.line_numbers) if it.toggle else it.bool_val
                self.line_numbers = v
                if not v:
                    self.rel_numbers = False
                for i in range(len(self.wins)):
                    if self.wins[i].kind == WK_EDITOR:
                        self.wins[i].gut = self.wins[i].gutter_for(self.line_numbers)
                        if not v:
                            self.wins[i].rel_nums = False
            elif it.key == "relativenumber":
                var v = (not self.rel_numbers) if it.toggle else it.bool_val
                self.rel_numbers = v
                if v and not self.line_numbers:
                    self.line_numbers = True
                for i in range(len(self.wins)):
                    if self.wins[i].kind == WK_EDITOR:
                        self.wins[i].rel_nums = self.rel_numbers
                        self.wins[i].gut = self.wins[i].gutter_for(self.line_numbers)
            elif it.key == "wrap":
                var v = (not self.soft_wrap) if it.toggle else it.bool_val
                self.soft_wrap = v
                for i in range(len(self.wins)):
                    if self.wins[i].kind == WK_EDITOR:
                        self.wins[i].set_wrap(v)
            elif it.key == "ignorecase":
                var v = self.find_case if it.toggle else it.bool_val
                self.find_case = not v
            elif it.key == "list":
                var v = (not self.show_ws) if it.toggle else it.bool_val
                self.show_ws = v
            elif it.key == "tabstop":
                self.tab_width = it.int_val
                if t >= 0 and t < len(self.wins):
                    self.wins[t].buf.tab_width = it.int_val
            elif it.key == "shiftwidth":
                self.indent_size = it.int_val
                if t >= 0 and t < len(self.wins):
                    self.wins[t].buf.indent_size = it.int_val

    def vim_global(mut self, t: Int, r1: Int, r2: Int, raw: List[Int], invert: Bool) raises:
        """:g/pat/cmd and :v/pat/cmd (:g!/pat/cmd) across rows r1..r2 under one undo group."""
        var g = parse_global(raw, invert)
        if not g.ok:
            self.say(g.error)
            return
        var pat = g.pat.copy()
        if len(pat) == 0:
            pat = self.vim.s_pat.copy()
        if len(pat) == 0:
            self.say("E35: No previous regular expression")
            return
        self.vim.s_pat = pat.copy()
        var vp = vim_pattern(pat)
        var s = make_search(vp.pat, not vp.icase, False, True)
        if not s.ok:
            self.say("E: bad pattern " + to_str(pat) + ": " + s.error)
            return
        var rows = List[Int]()
        var hi = min(r2, self.wins[t].buf.count() - 1)
        for r in range(max(0, r1), hi + 1):
            var hit = len(s.re.search(self.wins[t].buf.line(r), 0)) > 0
            if (not hit) if g.invert else hit:
                rows.append(r)
        if len(rows) == 0:
            if not g.invert:
                self.say("Pattern not found: " + to_str(pat))
            return
        if g.cmd.byte_length() == 0 or g.cmd == "p" or g.cmd == "print":
            var lr = rows[len(rows) - 1]
            self.wins[t].cr = lr
            self.wins[t].cc = first_nonblank(self.wins[t].buf.line(lr))
            self.wins[t].sync_want()
            self.vim_settle(t)
            self.say(String(len(rows)) + (" line" if len(rows) == 1 else " lines"))
            return
        var prev_fg = self.wins[t].forced_group
        if prev_fg == 0:
            self.wins[t].forced_group = self.wins[t].new_group()
        var cmd_cps = decode(g.cmd)
        var idx = 0
        while idx < len(rows):
            var cur_r = rows[idx]
            if cur_r >= 0 and cur_r < self.wins[t].buf.count():
                var old_n = self.wins[t].buf.count()
                self.wins[t].cr = cur_r
                self.wins[t].cc = first_nonblank(self.wins[t].buf.line(cur_r))
                self.wins[t].sync_want()
                self.vim_ex(t, cmd_cps)
                var delta = self.wins[t].buf.count() - old_n
                if delta != 0:
                    for j in range(idx + 1, len(rows)):
                        rows[j] += delta
            idx += 1
        self.wins[t].forced_group = prev_fg
        self.wins[t].break_group()
        self.sync_shared_buffers(t)
        self.vim_settle(t)

    def vim_normal_cmd(mut self, t: Int, r1: Int, r2: Int, raw: List[Int]) raises:
        """:[range]norm[al] <keys> - replay Normal-mode key sequence on each line in range."""
        var kseq = _parse_norm_keys(raw)
        if len(kseq) == 0:
            return
        var rows = List[Int]()
        var hi = min(r2, self.wins[t].buf.count() - 1)
        for r in range(max(0, r1), hi + 1):
            rows.append(r)
        var prev_fg = self.wins[t].forced_group
        if prev_fg == 0:
            self.wins[t].forced_group = self.wins[t].new_group()
        var prev_rep = self.vim.replaying
        self.vim.replaying = True
        var idx = 0
        while idx < len(rows):
            var cur_r = rows[idx]
            if cur_r >= 0 and cur_r < self.wins[t].buf.count():
                var old_n = self.wins[t].buf.count()
                self.wins[t].cr = cur_r
                self.wins[t].cc = 0
                self.wins[t].sync_want()
                self.vim.mode = VM_NORMAL
                self.vim_cancel()
                for kv in kseq:
                    self.handle_key(kv)
                if self.vim.cl_on:
                    self.handle_key(KEY_ENTER)
                if self.vim.mode != VM_NORMAL:
                    self.handle_key(KEY_ESC)
                self.vim_cancel()
                var delta = self.wins[t].buf.count() - old_n
                if delta != 0:
                    for j in range(idx + 1, len(rows)):
                        rows[j] += delta
            idx += 1
        self.vim.replaying = prev_rep
        self.wins[t].forced_group = prev_fg
        self.wins[t].break_group()
        self.sync_shared_buffers(t)
        self.vim_settle(t)

    def vim_vimgrep(mut self, t: Int, raw: List[Int]) raises:
        """:vimgrep /pat/[g][j] [files...] - populate quickfix / Search panel (`self.errs`)."""
        var vg = parse_vimgrep(raw)
        if not vg.ok:
            self.say(vg.error)
            return
        var vp = vim_pattern(vg.pat)
        var s = make_search(vp.pat, not vp.icase, False, True)
        if not s.ok:
            self.say("E: bad pattern " + to_str(vg.pat) + ": " + s.error)
            return
        self.vim.s_pat = vg.pat.copy()
        var root = String(self.cwd)
        var cur_path = String(self.wins[t].path) if (t >= 0 and t < len(self.wins)) else String("")
        var targets = List[String]()
        var search_cur_unnamed = False
        if len(vg.files) == 0:
            if root.byte_length() > 0:
                targets = collect_search_files(root, "")
            elif cur_path.byte_length() > 0:
                targets.append(cur_path)
            else:
                search_cur_unnamed = True
        else:
            for fp in vg.files:
                if fp == "%":
                    if cur_path.byte_length() > 0:
                        if not (cur_path in targets):
                            targets.append(cur_path)
                    else:
                        search_cur_unnamed = True
                elif fp.find("*") >= 0 or fp.find("?") >= 0:
                    var matched = collect_search_files(root, fp)
                    for mp in matched:
                        if not (mp in targets):
                            targets.append(mp)
                else:
                    var ap = abs_path(root, fp)
                    if path_exists(ap) and not (ap in targets):
                        targets.append(ap)

        var locs = List[ErrLoc]()
        var text = decode("vimgrep /" + to_str(vg.pat) + "/")
        text.append(10)
        var msg_row = 1
        var prefix = root + "/" if root.byte_length() > 0 else String("")

        if search_cur_unnamed and t >= 0 and t < len(self.wins):
            var n_ln = self.wins[t].buf.count()
            for r in range(n_ln):
                var ln = self.wins[t].buf.line(r)
                var col = 0
                while col <= len(ln):
                    var m = s.caps_in(ln, col)
                    if len(m) == 0:
                        break
                    var shown_ln = to_str(ln)
                    var entry = self.wins[t].title + ":" + String(r + 1) + ":" + String(m[0] + 1) + ": " + shown_ln
                    for c in decode(entry):
                        text.append(c)
                    text.append(10)
                    locs.append(ErrLoc("", r + 1, m[0] + 1, msg_row))
                    msg_row += 1
                    if not vg.all:
                        break
                    col = m[1] if m[1] > m[0] else m[0] + 1

        for p in targets:
            var wi = self.find_editor(p)
            var lines = List[List[Int]]()
            if wi >= 0:
                for r in range(self.wins[wi].buf.count()):
                    lines.append(self.wins[wi].buf.line(r))
            else:
                var raw_b = read_file(p)
                if len(raw_b) == 0 or len(raw_b) > MAX_FILE_BYTES or is_binary(raw_b):
                    continue
                var tmp_b = TextBuffer()
                tmp_b.load_bytes(raw_b)
                for r in range(tmp_b.count()):
                    lines.append(tmp_b.line(r))
            var shown_p = p
            if prefix.byte_length() > 0 and shown_p.startswith(prefix):
                var rel_p = String(shown_p[byte=prefix.byte_length():])
                shown_p = rel_p^
            for r in range(len(lines)):
                var ln = lines[r].copy()
                var col = 0
                while col <= len(ln):
                    var m = s.caps_in(ln, col)
                    if len(m) == 0:
                        break
                    var entry = shown_p + ":" + String(r + 1) + ":" + String(m[0] + 1) + ": " + to_str(ln)
                    for c in decode(entry):
                        text.append(c)
                    text.append(10)
                    locs.append(ErrLoc(p, r + 1, m[0] + 1, msg_row))
                    msg_row += 1
                    if not vg.all:
                        break
                    col = m[1] if m[1] > m[0] else m[0] + 1

        for c in decode(String(len(locs)) + (" match" if len(locs) == 1 else " matches")):
            text.append(c)
        self.panel_write(PG_SEARCH)
        var mi = self.ensure_msg()
        self.wins[mi].buf.load(text)
        self.wins[mi].cr = 0
        self.wins[mi].top = 0
        self.errs = locs^
        self.errs_from_search = True
        self.err_idx = 0 if len(self.errs) > 0 else -1
        if len(self.errs) == 0:
            self.say("E480: No match: " + to_str(vg.pat))
            return
        if not vg.nojump:
            var fp0 = String(self.errs[0].path)
            var r0 = self.errs[0].row
            var c0 = self.errs[0].col
            if fp0.byte_length() > 0:
                self.open_path(fp0)
            var te = self.top_editor()
            if te >= 0:
                self.wins[te].cr = max(0, min(r0 - 1, self.wins[te].buf.count() - 1))
                self.wins[te].cc = max(0, min(c0 - 1, self.wins[te].buf.llen(self.wins[te].cr)))
                self.wins[te].sync_want()
                self.vim_settle(te)
        self.say("(" + ("1" if not vg.nojump else "0") + " of " + String(len(self.errs)) + ") vimgrep matches")

    def vim_cdo(mut self, arg: String, per_file: Bool) raises:
        """:cdo / :cfdo <cmd> - execute Ex command across every quickfix entry (or file) in `self.errs`."""
        var locs = self.errs.copy()
        if len(locs) == 0:
            self.say("E42: No Errors")
            return
        if String(arg.strip()).byte_length() == 0:
            self.say("E471: Argument required")
            return
        var cmd_cps = decode(arg)
        var seen = List[String]()
        var ran = 0
        for i in range(len(locs)):
            var p = String(locs[i].path)
            if per_file:
                if p in seen:
                    continue
                seen.append(p)
            if p.byte_length() > 0:
                self.open_path(p)
            var te = self.top_editor()
            if te < 0:
                continue
            self.wins[te].cr = max(0, min(locs[i].row - 1, self.wins[te].buf.count() - 1))
            self.wins[te].cc = max(0, min(locs[i].col - 1, self.wins[te].buf.llen(self.wins[te].cr)))
            self.wins[te].sync_want()
            self.vim_ex(te, cmd_cps)
            ran += 1
        self.say(("cfdo: " if per_file else "cdo: ") + String(ran) + (" file" if per_file and ran == 1 else (" files" if per_file else (" entry" if ran == 1 else " entries"))))
