"""Multi-cursor editing (extends Window).

The window keeps its ordinary cursor and selection (cr/cc/sel/ar/ac/want); additional
cursors live in `extra`. An editing or movement step is carried out once per cursor by
loading each one into the ordinary fields and calling the single-cursor operation.
Cursors are handled from the end of the text towards the start; the ones already done
lie after the place being edited, so they are remembered by their distance from the end
of the text and of their line, which an edit before them does not change. All edits of
one step share one undo group."""
from std.collections import List
from buffer import TextBuffer, Pos
from search import Search, make_search
from util import is_ident
from window import *
from window_search import *
from window_lines import *

comptime OP_TYPE = 1
comptime OP_BACK = 2
comptime OP_DEL = 3
comptime OP_NEWLINE = 4
comptime OP_INSERT = 5
comptime OP_LEFT = 6
comptime OP_RIGHT = 7
comptime OP_VERT = 8
comptime OP_HOME = 9
comptime OP_END = 10
comptime OP_DELSEL = 11
comptime OP_LINE_START = 12       # column 0 (Home toggles with the indentation instead)

comptime MAX_CURSORS = 2000


def cur_start(c: Cur) -> Pos:
    """Where a cursor's selection begins (the cursor itself if nothing is selected)."""
    if c.sel and (c.ar < c.r or (c.ar == c.r and c.ac < c.c)):
        return Pos(c.ar, c.ac)
    return Pos(c.r, c.c)


def cur_end(c: Cur) -> Pos:
    if c.sel and (c.ar > c.r or (c.ar == c.r and c.ac > c.c)):
        return Pos(c.ar, c.ac)
    return Pos(c.r, c.c)


def pos_lt(a: Pos, b: Pos) -> Bool:
    return a.r < b.r or (a.r == b.r and a.c < b.c)


__extension Window:
    def has_multi(self) -> Bool:
        return len(self.extra) > 0

    def cursor_count(self) -> Int:
        return 1 + len(self.extra)

    def collapse(mut self):
        """Back to one cursor: the main one stays."""
        self.extra.clear()
        self.box_on = False

    def main_cur(self) -> Cur:
        return Cur(self.cr, self.cc, self.sel, self.ar, self.ac, self.want)

    def set_main(mut self, c: Cur):
        self.cr = c.r
        self.cc = c.c
        self.sel = c.sel
        self.ar = c.ar
        self.ac = c.ac
        self.want = c.want

    def clamp_cur(self, c: Cur) -> Cur:
        var last = self.buf.count() - 1
        var r = max(0, min(c.r, last))
        var ar = max(0, min(c.ar, last))
        return Cur(r, max(0, min(c.c, self.buf.llen(r))), c.sel, ar, max(0, min(c.ac, self.buf.llen(ar))), c.want)

    def all_cursors(self) -> List[Cur]:
        """Every cursor, the main one last."""
        var out = List[Cur]()
        for e in self.extra:
            out.append(self.clamp_cur(e))
        out.append(self.clamp_cur(self.main_cur()))
        return out^

    def set_cursors(mut self, var cs: List[Cur], main: Int):
        """Install a set of cursors: sorted, without duplicates or overlapping
        selections; `main` is the index (in `cs`) of the one to become the main cursor."""
        # insertion sort by start position, carrying the main index along
        var order = List[Int]()
        for i in range(len(cs)):
            var k = len(order)
            order.append(i)
            while k > 0 and pos_lt(cur_start(cs[order[k]]), cur_start(cs[order[k - 1]])):
                var t = order[k - 1]
                order[k - 1] = order[k]
                order[k] = t
                k -= 1
        var kept = List[Cur]()
        var kept_main = -1
        for oi in order:
            var c = cs[oi].copy()
            var n = len(kept)
            if n > 0:
                var prev_end = cur_end(kept[n - 1])
                var prev_start = cur_start(kept[n - 1])
                var st = cur_start(c)
                if pos_lt(st, prev_end) or (st.r == prev_start.r and st.c == prev_start.c):
                    # same place as, or inside, the one before: they become one cursor
                    if oi == main:
                        kept_main = n - 1
                    continue
            if oi == main:
                kept_main = n
            kept.append(c^)
        if kept_main < 0:
            kept_main = len(kept) - 1
        self.extra.clear()
        for i in range(len(kept)):
            if i == kept_main:
                self.set_main(kept[i])
            else:
                self.extra.append(kept[i].copy())

    def do_op(mut self, op: Int, a: Int, flag: Bool, flag2: Bool, text: List[Int]):
        """One single-cursor operation on the main cursor."""
        if op == OP_TYPE:
            if self.auto_pairs and flag:
                self.type_smart(a)
            else:
                self.type_char(a, flag)
        elif op == OP_BACK:
            if self.auto_pairs:
                self.backspace_smart()
            else:
                self.backspace()
        elif op == OP_DEL:
            self.delete_fwd()
        elif op == OP_NEWLINE:
            self.newline(flag)
        elif op == OP_INSERT:
            self.insert_text(text, ACT_OTHER)
        elif op == OP_LEFT:
            self.move_left(flag, flag2)
        elif op == OP_RIGHT:
            self.move_right(flag, flag2)
        elif op == OP_VERT:
            self.move_vert(a, flag)
        elif op == OP_HOME:
            self.home(flag, False)
        elif op == OP_END:
            self.end(flag, False)
        elif op == OP_DELSEL:
            _ = self.delete_sel(self.new_group())
        elif op == OP_LINE_START:
            self.begin_move(flag)
            self.cc = 0
            self.sync_want()

    def multi(mut self, op: Int, a: Int, flag: Bool, flag2: Bool, text: List[Int]):
        """Carry out `op` at every cursor as one undo step."""
        self.multi_texts(op, a, flag, flag2, text, List[List[Int]]())

    def multi_texts(mut self, op: Int, a: Int, flag: Bool, flag2: Bool, text: List[Int], texts: List[List[Int]]):
        """Like multi(); for OP_INSERT a non-empty `texts` gives each cursor its own text
        (in the order of the cursors in the document)."""
        self.box_on = False
        if not self.has_multi():
            self.do_op(op, a, flag, flag2, text)
            return
        var cs = self.all_cursors()
        var main = len(cs) - 1
        # work in document order
        var order = List[Int]()
        for i in range(len(cs)):
            var k = len(order)
            order.append(i)
            while k > 0 and pos_lt(cur_start(cs[order[k]]), cur_start(cs[order[k - 1]])):
                var t = order[k - 1]
                order[k - 1] = order[k]
                order[k] = t
                k -= 1
        var sorted = List[Cur]()
        var smain = 0
        for k in range(len(order)):
            if order[k] == main:
                smain = k
            sorted.append(cs[order[k]].copy())
        var edits = op <= OP_INSERT or op == OP_DELSEL
        if edits:
            var g: Int
            self.set_main(sorted[len(sorted) - 1])
            if op == OP_TYPE:
                g = self.group_for(ACT_TYPE)
            elif op == OP_BACK:
                g = self.group_for(ACT_BACK)
            elif op == OP_DEL:
                g = self.group_for(ACT_DEL)
            else:
                g = self.new_group()
            self.forced_group = g
        var n = len(sorted)
        var i = n - 1
        while i >= 0:
            # the cursors after this one, as distances from the end of text and line
            var rel = List[Int]()
            if edits:
                var count = self.buf.count()
                for j in range(i + 1, n):
                    rel.append(count - sorted[j].r)
                    rel.append(self.buf.llen(sorted[j].r) - sorted[j].c)
                    rel.append(count - sorted[j].ar)
                    rel.append(self.buf.llen(sorted[j].ar) - sorted[j].ac)
            self.set_main(sorted[i])
            if op == OP_INSERT and len(texts) == n:
                self.do_op(op, a, flag, flag2, texts[i])
            else:
                self.do_op(op, a, flag, flag2, text)
            sorted[i] = self.main_cur()
            if edits:
                var count = self.buf.count()
                var q = 0
                for j in range(i + 1, n):
                    var r = max(0, min(count - 1, count - rel[q]))
                    var c = max(0, self.buf.llen(r) - rel[q + 1])
                    var ar = max(0, min(count - 1, count - rel[q + 2]))
                    var ac = max(0, self.buf.llen(ar) - rel[q + 3])
                    sorted[j] = Cur(r, c, sorted[j].sel, ar, ac, sorted[j].want)
                    q += 4
            i -= 1
        self.forced_group = 0
        if edits:
            # typing went through other columns: each cursor keeps its own
            for j in range(n):
                var keep = sorted[j].copy()
                self.set_main(keep)
                self.sync_want()
                sorted[j] = self.main_cur()
        self.set_cursors(sorted^, smain)
        self.follow = True

    # ------------------------------------------------------- adding cursors
    def add_cursor(mut self, c: Cur):
        """Add a cursor and make it the main one (the view follows it)."""
        if self.cursor_count() >= MAX_CURSORS:
            return
        self.box_on = False
        var cs = self.all_cursors()
        cs.append(self.clamp_cur(c))
        self.set_cursors(cs^, len(self.extra) + 1)
        self.break_group()
        self.follow = True

    def toggle_cursor_at(mut self, r: Int, c: Int):
        """Alt-click: a cursor here is removed, an empty place gets one."""
        var cs = self.all_cursors()
        for i in range(len(cs)):
            if cs[i].r == r and cs[i].c == c:
                if len(cs) == 1:
                    return
                var rest = List[Cur]()
                for j in range(len(cs)):
                    if j != i:
                        rest.append(cs[j].copy())
                self.set_cursors(rest^, len(cs) - 2)
                return
        self.add_cursor(Cur(r, c, False, r, c, self.vcol(r, c)))

    def add_cursor_vert(mut self, d: Int) -> Bool:
        """A new cursor on the line above (d = -1) or below (d = 1) the outermost one, in
        the same screen column. False at the edge of the text."""
        var cs = self.all_cursors()
        var edge = cs[0].copy()
        for c in cs:
            if (d < 0 and c.r < edge.r) or (d > 0 and c.r > edge.r):
                edge = c.copy()
        var r = edge.r + d
        if r < 0 or r >= self.buf.count():
            return False
        var col = self.col_at_vcol(r, edge.want)
        self.add_cursor(Cur(r, col, False, r, col, edge.want))
        return True

    def select_word_here(mut self) -> Bool:
        var ln = self.buf.line(self.cr)
        var a = min(self.cc, len(ln))
        var b = a
        while a > 0 and is_ident(ln[a - 1]):
            a -= 1
        while b < len(ln) and is_ident(ln[b]):
            b += 1
        if a == b:
            return False
        self.sel = True
        self.ar = self.cr
        self.ac = a
        self.cc = b
        self.sync_want()
        self.follow = True
        return True

    def add_next_occurrence(mut self) -> Bool:
        """Nothing selected: select the word at the cursor. Otherwise add a cursor that
        selects the next occurrence of the selected text (exact case, wrapping around).
        False when there is nothing (more) to select."""
        if not self.has_sel():
            return self.select_word_here()
        var q = self.sel_range()
        if q.r1 != q.r2:
            return False
        var text = self.selected_text()
        var s = make_search(text, True, False, False)
        var cs = self.all_cursors()
        var n = self.buf.count()
        for k in range(n + 1):
            var r = (q.r2 + k) % n
            var ln = self.buf.line(r)
            var c = q.c2 if k == 0 else 0
            while True:
                var m = s.caps_in(ln, c)
                if len(m) == 0:
                    break
                var taken = False
                for cur in cs:
                    var st = cur_start(cur)
                    if st.r == r and st.c == m[0]:
                        taken = True
                if not taken:
                    self.add_cursor(Cur(r, m[1], True, r, m[0], self.vcol(r, m[1])))
                    return True
                c = m[1]
        return False

    def skip_next_occurrence(mut self) -> Bool:
        """Advance the main cursor's selection to the next unselected match without
        keeping the current occurrence."""
        if not self.has_sel():
            return self.select_word_here()
        var q = self.sel_range()
        if q.r1 != q.r2:
            return False
        var text = self.selected_text()
        var s = make_search(text, True, False, False)
        var cs = self.all_cursors()
        var n = self.buf.count()
        for k in range(n + 1):
            var r = (q.r2 + k) % n
            var ln = self.buf.line(r)
            var c = q.c2 if k == 0 else 0
            while True:
                var m = s.caps_in(ln, c)
                if len(m) == 0:
                    break
                var taken = False
                for cur in cs:
                    var st = cur_start(cur)
                    if st.r == r and st.c == m[0]:
                        taken = True
                if not taken:
                    var kept = List[Cur]()
                    for e in self.extra:
                        kept.append(self.clamp_cur(e))
                    var main_idx = len(kept)
                    kept.append(self.clamp_cur(Cur(r, m[1], True, r, m[0], self.vcol(r, m[1]))))
                    self.set_cursors(kept^, main_idx)
                    self.break_group()
                    self.follow = True
                    return True
                c = m[1]
        return False

    # ------------------------------------------------------- structural selection
    def _try_candidate(self, cur: Range, cand: Range, mut best: Range, mut found: Bool):
        if cand.r1 == cand.r2 and cand.c1 == cand.c2:
            return
        var starts_le = cand.r1 < cur.r1 or (cand.r1 == cur.r1 and cand.c1 <= cur.c1)
        var ends_ge = cand.r2 > cur.r2 or (cand.r2 == cur.r2 and cand.c2 >= cur.c2)
        var same = cand.r1 == cur.r1 and cand.c1 == cur.c1 and cand.r2 == cur.r2 and cand.c2 == cur.c2
        if not (starts_le and ends_ge) or same:
            return
        if not found:
            best = cand.copy()
            found = True
            return
        var cand_in_best = (best.r1 < cand.r1 or (best.r1 == cand.r1 and best.c1 <= cand.c1)) and (
            best.r2 > cand.r2 or (best.r2 == cand.r2 and best.c2 >= cand.c2)
        )
        var best_in_cand = (cand.r1 < best.r1 or (cand.r1 == best.r1 and cand.c1 <= best.c1)) and (
            cand.r2 > best.r2 or (cand.r2 == best.r2 and cand.c2 >= best.c2)
        )
        if cand_in_best and not best_in_cand:
            best = cand.copy()
        elif not best_in_cand:
            var cand_rows = cand.r2 - cand.r1
            var best_rows = best.r2 - best.r1
            if cand_rows < best_rows or (cand_rows == 0 and best_rows == 0 and (cand.c2 - cand.c1) < (best.c2 - best.c1)):
                best = cand.copy()

    def _line_indent_spaces(self, r: Int) -> Int:
        var ln = self.buf.line(r)
        var cols = 0
        for ch in ln:
            if ch == 32:
                cols += 1
            elif ch == 9:
                cols += self.buf.tab_width - cols % self.buf.tab_width
            else:
                return cols
        return -1

    def _line_ends_colon(self, r: Int) -> Bool:
        var ln = self.buf.line(r)
        var last = -1
        for ch in ln:
            if ch == 35:   # '#'
                break
            if ch != 32 and ch != 9:
                last = ch
        return last == 58  # ':'

    def _block_end_from(self, hr: Int, h_ind: Int) -> Int:
        var n = self.buf.count()
        var last_body = hr
        for r in range(hr + 1, min(n, hr + 2000)):
            var ind = self._line_indent_spaces(r)
            if ind < 0:
                continue
            if ind <= h_ind:
                break
            last_body = r
        return last_body

    def _find_matching_close(self, orow: Int, ocol: Int, open_ch: Int, close_ch: Int) -> Pos:
        var depth = 1
        var n = self.buf.count()
        var limit = min(n, orow + 400)
        for r in range(orow, limit):
            var ln = self.buf.line(r)
            var c0 = ocol + 1 if r == orow else 0
            var in_str = 0
            var esc = False
            for c in range(c0, len(ln)):
                var ch = ln[c]
                if in_str != 0:
                    if esc:
                        esc = False
                    elif ch == 92:
                        esc = True
                    elif ch == in_str:
                        in_str = 0
                    continue
                if ch == 35:
                    break
                if ch == 34 or ch == 39:
                    in_str = ch
                    continue
                if ch == open_ch:
                    depth += 1
                elif ch == close_ch:
                    depth -= 1
                    if depth == 0:
                        return Pos(r, c)
        return Pos(-1, -1)

    def expand_selection(mut self) -> Bool:
        """Grow the selection concentrically: word -> dotted name -> quotes ->
        brackets -> trimmed line -> full line -> indentation block -> buffer."""
        self.collapse()
        var had_sel = self.has_sel()
        if not had_sel:
            self.sel_hist.clear()
        var cur = self.sel_range() if had_sel else Range(self.cr, self.cc, self.cr, self.cc)
        var best = Range(0, 0, 0, 0)
        var found = False

        if cur.r1 == cur.r2:
            var r = cur.r1
            var ln = self.buf.line(r)
            var n = len(ln)
            # 1. identifier & dotted chain
            var a = min(cur.c1, n)
            var b = min(cur.c2, n)
            while a > 0 and is_ident(ln[a - 1]):
                a -= 1
            while b < n and is_ident(ln[b]):
                b += 1
            if a < b:
                self._try_candidate(cur, Range(r, a, r, b), best, found)
            var da = min(cur.c1, n)
            var db = min(cur.c2, n)
            while da > 0 and (is_ident(ln[da - 1]) or ln[da - 1] == 46):
                da -= 1
            while db < n and (is_ident(ln[db]) or ln[db] == 46):
                db += 1
            if da < db:
                self._try_candidate(cur, Range(r, da, r, db), best, found)

            # 2. single-line quoted strings
            var i = 0
            while i < n:
                var ch = ln[i]
                if ch == 35:
                    break
                if ch == 34 or ch == 39:
                    var j = i + 1
                    var esc = False
                    while j < n:
                        if esc:
                            esc = False
                        elif ln[j] == 92:
                            esc = True
                        elif ln[j] == ch:
                            break
                        j += 1
                    if j < n and i <= cur.c1 and cur.c2 <= j + 1:
                        self._try_candidate(cur, Range(r, i + 1, r, j), best, found)
                        self._try_candidate(cur, Range(r, i, r, j + 1), best, found)
                    i = j + 1
                    continue
                i += 1

            # 3. trimmed line and full line
            var first_ns = 0
            while first_ns < n and (ln[first_ns] == 32 or ln[first_ns] == 9):
                first_ns += 1
            var last_ns = n
            while last_ns > first_ns and (ln[last_ns - 1] == 32 or ln[last_ns - 1] == 9):
                last_ns -= 1
            if first_ns < last_ns:
                self._try_candidate(cur, Range(r, first_ns, r, last_ns), best, found)
            if n > 0:
                self._try_candidate(cur, Range(r, 0, r, n), best, found)

        # 4. enclosing balanced brackets (), [], {}
        var d_paren = 0
        var d_brack = 0
        var d_brace = 0
        var min_r = max(0, cur.r1 - 400)
        var r_scan = cur.r1
        while r_scan >= min_r:
            var ln = self.buf.line(r_scan)
            var c_scan = (min(cur.c1, len(ln) - 1) if not had_sel else cur.c1 - 1) if r_scan == cur.r1 else len(ln) - 1
            while c_scan >= 0:
                var ch = ln[c_scan]
                if ch == 41:
                    d_paren += 1
                elif ch == 40:
                    if d_paren > 0:
                        d_paren -= 1
                    else:
                        var cl = self._find_matching_close(r_scan, c_scan, 40, 41)
                        if cl.r >= 0:
                            self._try_candidate(cur, Range(r_scan, c_scan + 1, cl.r, cl.c), best, found)
                            self._try_candidate(cur, Range(r_scan, c_scan, cl.r, cl.c + 1), best, found)
                elif ch == 93:
                    d_brack += 1
                elif ch == 91:
                    if d_brack > 0:
                        d_brack -= 1
                    else:
                        var cl = self._find_matching_close(r_scan, c_scan, 91, 93)
                        if cl.r >= 0:
                            self._try_candidate(cur, Range(r_scan, c_scan + 1, cl.r, cl.c), best, found)
                            self._try_candidate(cur, Range(r_scan, c_scan, cl.r, cl.c + 1), best, found)
                elif ch == 125:
                    d_brace += 1
                elif ch == 123:
                    if d_brace > 0:
                        d_brace -= 1
                    else:
                        var cl = self._find_matching_close(r_scan, c_scan, 123, 125)
                        if cl.r >= 0:
                            self._try_candidate(cur, Range(r_scan, c_scan + 1, cl.r, cl.c), best, found)
                            self._try_candidate(cur, Range(r_scan, c_scan, cl.r, cl.c + 1), best, found)
                c_scan -= 1
            r_scan -= 1

        # 5. enclosing indentation block (header + body)
        var start_ind = self._line_indent_spaces(cur.r1)
        if start_ind >= 0 and self._line_ends_colon(cur.r1):
            var bend = self._block_end_from(cur.r1, start_ind)
            if bend > cur.r1:
                self._try_candidate(cur, Range(cur.r1, 0, bend, self.buf.llen(bend)), best, found)
        var ref_ind = start_ind
        if ref_ind < 0:
            for rr in range(cur.r1, cur.r2 + 1):
                var ri = self._line_indent_spaces(rr)
                if ri >= 0 and (ref_ind < 0 or ri < ref_ind):
                    ref_ind = ri
        if ref_ind > 0:
            var up_r = cur.r1 - 1
            var target_ind = ref_ind
            while up_r >= max(0, cur.r1 - 2000):
                var ui = self._line_indent_spaces(up_r)
                if ui >= 0 and ui < target_ind:
                    if self._line_ends_colon(up_r):
                        var bend = self._block_end_from(up_r, ui)
                        if bend >= cur.r2:
                            # body only first, then header + body
                            var body_start = up_r + 1
                            while body_start < bend and self._line_indent_spaces(body_start) < 0:
                                body_start += 1
                            if body_start <= bend:
                                var bs_ln = self.buf.line(body_start)
                                var bs_c = 0
                                while bs_c < len(bs_ln) and (bs_ln[bs_c] == 32 or bs_ln[bs_c] == 9):
                                    bs_c += 1
                                self._try_candidate(cur, Range(body_start, bs_c, bend, self.buf.llen(bend)), best, found)
                            self._try_candidate(cur, Range(up_r, 0, bend, self.buf.llen(bend)), best, found)
                    target_ind = ui
                    if target_ind == 0:
                        break
                up_r -= 1

        # 6. full buffer
        var last_row = self.buf.count() - 1
        self._try_candidate(cur, Range(0, 0, last_row, self.buf.llen(last_row)), best, found)

        if not found:
            return False
        self.sel_hist.append(cur^)
        self.sel = True
        self.ar = best.r1
        self.ac = best.c1
        self.cr = best.r2
        self.cc = best.c2
        self.sync_want()
        self.break_group()
        self.follow = True
        return True

    def shrink_selection(mut self) -> Bool:
        """Step back through previous `expand_selection` ranges, or collapse selection."""
        if len(self.sel_hist) > 0:
            var prev = self.sel_hist.pop()
            if prev.r1 == prev.r2 and prev.c1 == prev.c2:
                self.sel = False
                self.ar = prev.r1
                self.ac = prev.c1
                self.cr = prev.r1
                self.cc = prev.c1
            else:
                self.sel = True
                self.ar = prev.r1
                self.ac = prev.c1
                self.cr = prev.r2
                self.cc = prev.c2
            self.sync_want()
            self.break_group()
            self.follow = True
            return True
        if self.has_sel():
            var sr = self.sel_range()
            self.sel = False
            self.cr = sr.r1
            self.cc = sr.c1
            self.sync_want()
            self.break_group()
            self.follow = True
            return True
        return False

    # ------------------------------------------------------- column selection
    def box_select(mut self, ar: Int, av: Int, r: Int, v: Int):
        """Select the rectangle between two corners given as (row, screen column): one
        cursor per row, each selecting the part of its line inside the columns. A line
        that ends before the rectangle gets a cursor at its end. The cursor of the moving
        corner's row becomes the main one."""
        var last = self.buf.count() - 1
        var a_row = max(0, min(ar, last))
        var m_row = max(0, min(r, last))
        if m_row - a_row >= MAX_CURSORS:
            m_row = a_row + MAX_CURSORS - 1
        elif a_row - m_row >= MAX_CURSORS:
            m_row = a_row - MAX_CURSORS + 1
        var a_v = max(0, av)
        var m_v = max(0, v)
        var cs = List[Cur]()
        var main = 0
        var lo = min(a_row, m_row)
        var hi = max(a_row, m_row)
        for row in range(lo, hi + 1):
            var ac = self.col_at_vcol(row, a_v)
            var cc = self.col_at_vcol(row, m_v)
            if row == m_row:
                main = len(cs)
            cs.append(Cur(row, cc, ac != cc, row, ac, m_v))
        self.set_cursors(cs^, main)
        self.box_on = True
        self.box_ar = a_row
        self.box_av = a_v
        self.box_r = m_row
        self.box_v = m_v
        self.break_group()
        self.follow = True

    def box_active(self) -> Bool:
        """Do the cursors still form the box that box_select made?"""
        return self.box_on and self.cr == self.box_r and self.cursor_count() == abs(self.box_r - self.box_ar) + 1

    def box_extend(mut self, dr: Int, dv: Int):
        """Move the moving corner of the column selection by rows / screen columns,
        starting a new one at the cursor if there is none."""
        if not self.box_active():
            var v0 = self.vcol(self.cr, self.cc)
            var a0 = v0
            var ar0 = self.cr
            if self.has_sel() and not self.has_multi():
                # grow from an ordinary selection: its anchor is the fixed corner
                ar0 = self.ar
                a0 = self.vcol(self.ar, self.ac)
            self.box_ar = ar0
            self.box_av = a0
            self.box_r = self.cr
            self.box_v = v0
        self.box_select(self.box_ar, self.box_av, self.box_r + dr, self.box_v + dv)

    def in_extra_sel(self, r: Int, c: Int) -> Bool:
        for e in self.extra:
            if not e.sel:
                continue
            var a = cur_start(e)
            var b = cur_end(e)
            if r < a.r or r > b.r:
                continue
            if r == a.r and c < a.c:
                continue
            if r == b.r and c >= b.c:
                continue
            return True
        return False

    def selections_text(self) -> List[Int]:
        """The selected text of every cursor in document order, one per line."""
        var out = List[Int]()
        var cs = self.all_cursors()
        var order = List[Int]()
        for i in range(len(cs)):
            var k = len(order)
            order.append(i)
            while k > 0 and pos_lt(cur_start(cs[order[k]]), cur_start(cs[order[k - 1]])):
                var t = order[k - 1]
                order[k - 1] = order[k]
                order[k] = t
                k -= 1
        var first = True
        for oi in order:
            var a = cur_start(cs[oi])
            var b = cur_end(cs[oi])
            if a.r == b.r and a.c == b.c:
                continue
            if not first:
                out.append(10)
            first = False
            for v in self.buf.get_text(a.r, a.c, b.r, b.c):
                out.append(v)
        return out^

    def paste_multi(mut self, clip: List[Int]):
        """Paste at every cursor. A clipboard with exactly one line per cursor is dealt
        out line by line; anything else is inserted whole at each cursor."""
        var lines = List[List[Int]]()
        var cur = List[Int]()
        for v in clip:
            if v == 10:
                lines.append(cur.copy())
                cur.clear()
            else:
                cur.append(v)
        lines.append(cur.copy())
        if self.has_multi() and len(lines) == self.cursor_count():
            self.multi_texts(OP_INSERT, 0, False, False, clip, lines)
        else:
            self.multi(OP_INSERT, 0, False, False, clip)
        self.break_group()
