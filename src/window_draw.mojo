"""Window drawing: frame, gutter, highlighted text, selection, scrollbars."""
from glyphs import GLYPHS_ASCII
from std.collections import List
from buffer import TextBuffer, Pos, TAB_WIDTH
from screen import Screen, UL_CURLY, UL_DASHED, UL_DOTTED
from palette import Palette, mix
from highlight import Highlighter, C_TEXT, C_DEF, lang_for_path, HL_MOJO, HL_PYTHON
from util import is_ident, lower, decode, cp_len, to_str, str_contains, char_width, slice_str
from grapheme import cluster_end
from git import GB_KNOWN, GS_NONE, GS_CONFLICT, GS_DELETED, GS_UNTRACKED, GS_ADDED
from linediff import LM_NONE, LM_ADDED, LM_CHANGED, LM_DELETED_ABOVE
from hexview import render_hex_rows
from markdown import (
    md_render, md_render_rich, MdLine, MD_TEXT, MD_BOLD, MD_ITALIC, MD_CODE, MD_HEAD, MD_LINK, MD_DIM, MD_STRIKE, MD_BLOCK,
)
from vim_motion import is_code_mask, active_scope_range, ScopeRange
from search import MatchSpan
from window import *
from window_search import *
from window_multi import *
from window_lines import *



def wordish(c: Int) -> Bool:
    return (c >= 48 and c <= 57) or (c >= 65 and c <= 90) or (c >= 97 and c <= 122) or c == 95 or c >= 128


def word_at(line: List[Int], col: Int) -> List[Int]:
    """The identifier at column `col` of a line (the cursor on it or right after it);
    empty if there is none, or it is a single character, a number, or very long."""
    var a = max(0, min(col, len(line)))
    var b = a
    while a > 0 and wordish(line[a - 1]):
        a -= 1
    while b < len(line) and wordish(line[b]):
        b += 1
    var w = List[Int]()
    if b - a < 2 or b - a > 80 or (line[a] >= 48 and line[a] <= 57):
        return w^
    for q in range(a, b):
        w.append(line[q])
    return w^


def word_spans(line: List[Int], word: List[Int]) -> List[Int]:
    """Where `word` stands as a whole word in a line: start, end, start, end, ..."""
    var out = List[Int]()
    var n = len(line)
    var m = len(word)
    if m == 0:
        return out^
    var i = 0
    while i + m <= n:
        if line[i] == word[0] and (i == 0 or not wordish(line[i - 1])) and (i + m == n or not wordish(line[i + m])):
            var same = True
            for k in range(1, m):
                if line[i + k] != word[k]:
                    same = False
                    break
            if same:
                out.append(i)
                out.append(i + m)
                i += m
                continue
        i += 1
    return out^

def braille(bits: Int) -> Int:
    """The braille character with these dots (bit 0 = dot 1 ... bit 7 = dot 8)."""
    return 0x2800 + (bits & 255)


def braille_dot(col: Int, row: Int) -> Int:
    """The bit of the braille dot in column 0-1, row 0-3 of a cell."""
    if row == 3:
        return 0x40 if col == 0 else 0x80
    return (1 << row) if col == 0 else (8 << row)


__extension Window:
    def _indent_vcol_row(self, r: Int) -> Int:
        var ln = self.buf.line(r)
        var v = 0
        for ch in ln:
            if ch == 32:
                v += 1
            elif ch == 9:
                v += self.buf.tab_width - v % self.buf.tab_width
            else:
                return v
        return -1

    def _indent_guide_vcol(self, r: Int) -> Int:
        var v = self._indent_vcol_row(r)
        if v >= 0:
            return v
        var n = self.buf.count()
        var up = -1
        var up_colon = False
        var rr = r - 1
        while rr >= max(0, r - 24):
            up = self._indent_vcol_row(rr)
            if up >= 0:
                var uln = self.buf.line(rr)
                var last = -1
                for ch in uln:
                    if ch == 35:
                        break
                    if ch != 32 and ch != 9:
                        last = ch
                up_colon = last == 58
                break
            rr -= 1
        var dn = -1
        for dr in range(r + 1, min(n, r + 25)):
            dn = self._indent_vcol_row(dr)
            if dn >= 0:
                break
        if up_colon and dn > up:
            return dn
        if up >= 0 and dn >= 0:
            return min(up, dn)
        return 0

    def draw_sticky(self, mut scr: Screen, pal: Palette, cx0: Int, cls: Int):
        """The headers of the scopes the view is in, pinned on the top rows."""
        for i in range(len(self.sticky)):
            var r = self.sticky[i]
            if r < 0 or r >= self.buf.count() or i >= self.rows() - 1:
                break
            var yy = self.y + 1 + i
            scr.fill(self.x + 1, yy, self.gut + cls, 1, 32, pal.ed_fg, pal.curline_bg)
            if self.gut > 0:
                var num = String(r + 1)
                _ = scr.text(self.x + max(1, self.gut - cp_len(num)), yy, num, pal.gutter_fg, pal.curline_bg)
            var ln = self.buf.line(r)
            scr.clip(cx0, yy, cls, 1)
            var xx = cx0
            for c in ln:
                if xx >= cx0 + cls:
                    break
                if c == 9:
                    xx += self.buf.tab_width - (xx - cx0) % self.buf.tab_width
                    continue
                xx = scr.draw_cp(xx, yy, c, pal.syn[C_DEF] if not scr.plain else pal.ed_fg, pal.curline_bg)
            scr.no_clip()
            if i == len(self.sticky) - 1:
                # the last pinned line is underlined: the code goes on below it
                for ux in range(self.x + 1, self.x + 1 + self.gut + cls):
                    scr.underline(ux, yy, False, pal.frame_inact)

    def draw_minimap(self, mut scr: Screen, pal: Palette, rws: Int):
        """The whole file at the right edge in braille dots: each dot a few columns of a
        line that has text; the rows the window shows on a lighter background. In half
        blocks (editor.minimap_style = "blocks") a cell has an upper and a lower half
        only, each for two dot rows and both dot columns."""
        var n = self.buf.count()
        var x0 = self.x + self.w - 1 - MINIMAP_W
        var per = max(1, (n + rws * 4 - 1) // (rws * 4))     # lines per dot row
        var colw = 4                                          # text columns per dot
        for cy in range(rws):
            var masks = List[Int]()                          # per dot row: the dot columns with text
            var first = cy * 4 * per
            for dy in range(4):
                var li = (cy * 4 + dy) * per
                var m = 0
                if li < n:
                    var ln = self.buf.line(li)
                    var col = 0
                    for c in ln:
                        if c == 9:
                            col += self.buf.tab_width - col % self.buf.tab_width
                            continue
                        if c != 32:
                            var d = col // colw
                            if d < MINIMAP_W * 2:
                                m |= 1 << d
                        col += 1
                        if col >= MINIMAP_W * 2 * colw:
                            break
                masks.append(m)
            var shown = first < self.top + rws and first + 4 * per > self.top
            var bg = pal.curline_bg if shown else pal.ed_bg
            for cx in range(MINIMAP_W):
                if self.minimap_blocks and scr.glyphs != GLYPHS_ASCII:   # (ascii: braille -> . : #)
                    # half blocks: the upper and the lower two dot rows of the cell
                    var cols = 3 << (cx * 2)
                    var up = (masks[0] | masks[1]) & cols != 0
                    var dn = (masks[2] | masks[3]) & cols != 0
                    var hb = 0x2588 if up and dn else (0x2580 if up else (0x2584 if dn else 32))
                    scr.put(x0 + cx, self.y + 1 + cy, hb, pal.gutter_fg, bg)
                    continue
                var bits = 0
                for dy in range(4):
                    for dx in range(2):
                        if masks[dy] & (1 << (cx * 2 + dx)) != 0:
                            bits |= braille_dot(dx, dy)
                scr.put(x0 + cx, self.y + 1 + cy, braille(bits) if bits != 0 else 32, pal.gutter_fg, bg)

    def draw_hex(self, mut scr: Screen, pal: Palette, active: Bool):
        """Render virtualized 16-byte/row hex + ASCII inspector (`WK_HEX`)."""
        var rws = self.rows()
        var bg = pal.ed_bg
        scr.fill(self.x + 1, self.y + 1, self.w - 2, self.h - 2, 32, pal.ed_fg, bg)
        var lines = List[String]()
        var total_rows = 0
        if len(self.hex_bytes) > 0:
            total_rows = (len(self.hex_bytes) + 15) // 16
            lines = render_hex_rows(self.hex_bytes, self.top, rws)
        else:
            var raw = self.buf.lsp_bytes()
            var looks_formatted = (
                self.buf.llen(0) >= 10 and self.buf.at(0, 8) == 32 and self.buf.at(0, 9) == 32
            )
            if looks_formatted:
                total_rows = self.buf.count()
                var r0 = max(0, self.top)
                var r1 = min(total_rows, r0 + rws)
                for rr in range(r0, r1):
                    lines.append(to_str(self.buf.line(rr)))
            elif len(raw) > 0:
                total_rows = (len(raw) + 15) // 16
                lines = render_hex_rows(raw, self.top, rws)
        scr.clip(self.x + 1, self.y + 1, self.w - 2, self.h - 2)
        for i in range(len(lines)):
            var r = self.top + i
            var yy = self.y + 1 + i
            var rbg = pal.curline_bg if r == self.cr and active else (mix(pal.curline_bg, bg, 50) if r == self.cr else bg)
            if r == self.cr:
                scr.fill(self.x + 1, yy, self.w - 2, 1, 32, pal.ed_fg, rbg)
            var cps = decode(lines[i])
            var xx = self.x + 2
            for k in range(len(cps)):
                if xx >= self.x + self.w - 1:
                    break
                var ch = cps[k]
                var cfg = pal.ed_fg
                if k < 10:
                    cfg = pal.gutter_fg
                elif k >= 60:
                    cfg = pal.gutter_fg if ch == 124 else pal.msg_note
                xx = scr.draw_cp(xx, yy, ch, cfg, rbg)
        scr.no_clip()
        if self.w > 20:
            _ = scr.text(self.x + 2, self.y + self.h - 1, " [HEX READ-ONLY] ", pal.msg_warn, bg)
        if active and self.h > 4 and not scr.plain:
            var sx = self.x + self.w - 1
            var y0 = self.y + 1
            var y1 = self.y + self.h - 2
            scr.put(sx, y0, 0x25B2, pal.scroll_fg, pal.scroll_bg)
            scr.put(sx, y1, 0x25BC, pal.scroll_fg, pal.scroll_bg)
            for yy in range(y0 + 1, y1):
                scr.put(sx, yy, 0x2592, pal.scroll_fg, pal.scroll_bg)
            var span = y1 - y0 - 1
            if span > 0:
                var tot = max(1, total_rows - 1)
                var ty = y0 + 1 + (min(self.cr, tot) * (span - 1)) // tot
                scr.put(sx, ty, 0x25A0, pal.scroll_fg, pal.scroll_bg)

    def draw_mdpreview(self, mut scr: Screen, pal: Palette, hl: Highlighter, active: Bool):
        """Render live Markdown preview (`WK_MDPREVIEW`) with SGR styling, tables, and code blocks."""
        var rws = self.rows()
        var bg = pal.ed_bg
        scr.fill(self.x + 1, self.y + 1, self.w - 2, self.h - 2, 32, pal.ed_fg, bg)
        var md_w = max(8, self.w - 4)
        var md_links = List[String]()
        var lines = md_render_rich(to_str(self.buf.all_text()), md_w, hl, md_links, True)
        var total_rows = len(lines)
        var r0 = max(0, min(self.top, max(0, total_rows - 1)))
        scr.clip(self.x + 1, self.y + 1, self.w - 2, self.h - 2)
        var show_n = min(rws, max(0, total_rows - r0))
        for i in range(show_n):
            var yy = self.y + 1 + i
            var xx = self.x + 2
            var n_cp = len(lines[r0 + i].cps)
            for k in range(n_cp):
                if xx >= self.x + self.w - 1:
                    break
                var cp = lines[r0 + i].cps[k]
                var st = lines[r0 + i].st[k]
                var cfg = pal.ed_fg
                var cbg = bg
                if st == MD_HEAD:
                    cfg = pal.syn[C_DEF]
                elif st == MD_CODE:
                    cfg = pal.syn[4]
                    cbg = pal.curline_bg
                elif st == MD_LINK or st < 0:
                    cfg = pal.frame_act
                elif st == MD_DIM or st == MD_STRIKE:
                    cfg = pal.gutter_fg
                elif st >= MD_BLOCK:
                    var sc = min(st - MD_BLOCK, len(pal.syn) - 1)
                    cfg = pal.syn[sc]
                    cbg = pal.curline_bg
                var nx = scr.draw_cp(xx, yy, cp, cfg, cbg)
                var wcell = max(1, nx - xx)
                if st == MD_BOLD or st == MD_HEAD:
                    scr.bold(xx, yy, wcell)
                elif st == MD_ITALIC:
                    scr.italic(xx, yy, wcell)
                elif st == MD_DIM:
                    scr.dim(xx, yy, wcell)
                elif st == MD_STRIKE:
                    scr.strikethrough(xx, yy, wcell)
                elif st == MD_LINK or st < 0:
                    scr.underline(xx, yy, False, pal.frame_act)
                xx = nx
        scr.no_clip()
        if active and self.h > 4 and not scr.plain:
            var sx = self.x + self.w - 1
            var y0 = self.y + 1
            var y1 = self.y + self.h - 2
            scr.put(sx, y0, 0x25B2, pal.scroll_fg, pal.scroll_bg)
            scr.put(sx, y1, 0x25BC, pal.scroll_fg, pal.scroll_bg)
            for yy in range(y0 + 1, y1):
                scr.put(sx, yy, 0x2592, pal.scroll_fg, pal.scroll_bg)
            var span = y1 - y0 - 1
            if span > 0:
                var tot = max(1, total_rows - 1)
                var ty = y0 + 1 + (min(r0, tot) * (span - 1)) // tot
                scr.put(sx, ty, 0x25A0, pal.scroll_fg, pal.scroll_bg)

    def draw_overview_ruler(
        self, mut scr: Screen, pal: Palette, sx: Int, y0: Int, y1: Int, ty: Int, ml_spans: List[MatchSpan]
    ):
        """Draw overview ruler ticks on vertical scrollbar for diagnostics, search hits, Git hunks, and extra cursors."""
        var span = y1 - y0 - 1
        if span <= 0:
            return
        var has_any = (
            len(self.buf.marks) > 0
            or self.hs_on
            or len(self.buf.git_marks) > 0
            or len(self.extra) > 0
        )
        if not has_any:
            return
        var tot = max(1, self.buf.count() - 1)
        var tick_pri = List[Int](length=span, fill=0)
        var tick_col = List[Int](length=span, fill=0)

        # 1. Extra cursors
        for ec in self.extra:
            var idx = (max(0, min(ec.r, tot)) * (span - 1)) // tot
            if tick_pri[idx] < 1:
                tick_pri[idx] = 1
                tick_col[idx] = pal.frame_act

        # 2. Git changed / added lines
        var gm_lim = min(len(self.buf.git_marks), self.buf.count())
        for gr in range(gm_lim):
            var gm = Int(self.buf.git_marks[gr])
            if gm != LM_NONE:
                var idx = (min(gr, tot) * (span - 1)) // tot
                if tick_pri[idx] < 2:
                    tick_pri[idx] = 2
                    tick_col[idx] = pal.git_add if gm == LM_ADDED else pal.git_mod

        # 3. Search hits
        if self.hs_on and self.hs.ok:
            var scol = pal.match_bg if pal.match_bg != pal.scroll_bg else pal.match_fg
            if self.hs.is_multiline():
                for sp in ml_spans:
                    var idx = (max(0, min(sp.r1, tot)) * (span - 1)) // tot
                    if tick_pri[idx] < 3:
                        tick_pri[idx] = 3
                        tick_col[idx] = scol
            elif self.buf.count() <= 5000:
                for sr_r in range(self.buf.count()):
                    var ln_s = self.buf.line(sr_r)
                    if len(ln_s) > 0 and len(ln_s) <= 4000 and len(self.hs.caps_in(ln_s, 0)) > 0:
                        var idx = (min(sr_r, tot) * (span - 1)) // tot
                        if tick_pri[idx] < 3:
                            tick_pri[idx] = 3
                            tick_col[idx] = scol

        # 4 & 5. Diagnostic warnings & errors
        for m in self.buf.marks:
            var pri = 5 if m.severity == 1 else (4 if m.severity == 2 else 0)
            if pri > 0:
                var idx = (max(0, min(m.l1, tot)) * (span - 1)) // tot
                if tick_pri[idx] < pri:
                    tick_pri[idx] = pri
                    tick_col[idx] = pal.diag_err if m.severity == 1 else pal.diag_warn

        var tick_ch = 61 if scr.glyphs == GLYPHS_ASCII else 0x25AC
        for k in range(span):
            if tick_pri[k] > 0:
                var yy = y0 + 1 + k
                var g = 0x25A0 if yy == ty else tick_ch
                scr.put(sx, yy, g, tick_col[k], pal.scroll_bg)

    # --------------------------------------------------------------- draw
    def draw(
        self, mut scr: Screen, pal: Palette, hl: Highlighter, active: Bool, hl_line: Bool, insert_mode: Bool, show_ws: Bool
    ):
        var is_special_ed = self.kind == WK_HEX or self.kind == WK_MDPREVIEW
        var is_msg = self.kind != WK_EDITOR and not is_special_ed       # the Message and Outline windows are lists
        var plain = is_msg or self.buf.large      # no syntax colours
        var bg = pal.msg_bg if is_msg else pal.ed_bg
        var fg = pal.msg_fg if is_msg else pal.ed_fg
        var ffg = (pal.msg_frame if is_msg else pal.frame_act) if active else pal.frame_inact
        scr.fill(self.x, self.y, self.w, self.h, 32, fg, bg)
        scr.frame(self.x, self.y, self.w, self.h, active, ffg, bg)
        # title
        var ro_tag = String(" [HEX READ-ONLY] ") if self.kind == WK_HEX else (String(" [READ-ONLY] ") if self.read_only else String(""))
        var t = " " + self.title + self.crumbs + ro_tag + (" (large file) " if self.buf.large else (" " if ro_tag.byte_length() == 0 else ""))
        var tl = cp_len(t)
        var tx = self.x + max(1, (self.w - tl) // 2)
        if self.w > 12:
            # keep clear of the close icon and "[■]" on the left, the number and the
            # zoom icon on the right: a longer title is cut short
            var lo = self.x + (5 if active else 1)
            var hi = self.x + self.w - (7 if self.number > 0 and self.number < 10 else (5 if active else 1))
            if tx < lo or tx + tl > hi:
                var room = hi - lo
                if tl > room and tl - 2 <= room:
                    var bare = String(t[byte=1:t.byte_length() - 1])     # without its padding it fits
                    t = bare
                    tl -= 2
                if tl > room and room > 3:
                    var tc = decode(t)
                    t = slice_str(tc, 0, room - 2) + "… "
                    tl = cp_len(t)
                tx = max(lo, min(tx, hi - tl))
        scr.clip(self.x + 1, self.y, self.w - 2, 1)
        var tend = scr.text(tx, self.y, t, pal.title_fg if active else ffg, bg)
        if active:
            scr.bold(tx, self.y, tend - tx)     # (focus is shown more than one way: frame, title, cursor)
        scr.no_clip()
        if active and self.w > 12 and not scr.plain:     # (no icons for a screen reader)
            _ = scr.text(self.x + 2, self.y, "[", ffg, bg)
            scr.put(self.x + 3, self.y, 0x25A0, pal.icon_fg, bg)
            _ = scr.text(self.x + 4, self.y, "]", ffg, bg)
            _ = scr.text(self.x + self.w - 5, self.y, "[", ffg, bg)
            scr.put(self.x + self.w - 4, self.y, 0x2195 if self.zoomed or self.half else 0x2191, pal.icon_fg, bg)
            _ = scr.text(self.x + self.w - 3, self.y, "]", ffg, bg)
        if self.number > 0 and self.number < 10 and self.w > 12:
            _ = scr.text(self.x + self.w - 7, self.y, String(self.number), ffg, bg)

        if self.kind == WK_HEX:
            self.draw_hex(scr, pal, active)
            return
        if self.kind == WK_MDPREVIEW:
            self.draw_mdpreview(scr, pal, hl, active)
            return

        var rws = self.rows()
        var cls = self.cols()
        var cx0 = self.x + 1 + self.gut
        var brk = Pos(-1, -1)
        if active and not is_msg:
            brk = self.match_bracket()
        var bc = -1
        if brk.r >= 0:
            bc = self.cc if self.is_bracket(self.buf.at(self.cr, self.cc)) else self.cc - 1
        var has_sel = self.has_sel()
        var n_extra = len(self.extra)
        # the word the cursor is on: its other uses on screen get a quiet background
        # (not while the matches of a search are shown: one kind of marking at a time)
        var wword = List[Int]()
        if active and not is_msg and self.word_hl and not self.hs_on and not has_sel and n_extra == 0 and not self.buf.large:
            wword = word_at(self.buf.line(self.cr), self.cc)
        var sr = self.sel_range()
        var hs_ml = self.hs_on and not is_msg and self.hs.is_multiline() and not self.buf.large
        var ml_spans = List[MatchSpan]()
        if hs_ml:
            ml_spans = self._multiline_spans(self.hs)
        var ascope = ScopeRange(-1, -1, -1)
        var ascope_vcol = -1
        if self.indent_guides and not is_msg and not plain and not scr.plain:
            ascope = active_scope_range(self.buf, self.cr)
            if ascope.r1 >= 0:
                ascope_vcol = self._indent_vcol_row(ascope.r1)
        var rb_on = self.rainbow_brackets and not is_msg and not plain and not scr.plain
        var rb_depth = 0
        if rb_on:
            var scan_start = max(0, self.top - 300)
            for rr in range(scan_start, min(self.top, self.buf.count())):
                var rln = self.buf.line(rr)
                var rmask = is_code_mask(rln)
                for rc in range(len(rln)):
                    if rc < len(rmask) and rmask[rc]:
                        var rch = rln[rc]
                        if rch == 40 or rch == 91 or rch == 123:
                            rb_depth += 1
                        elif rch == 41 or rch == 93 or rch == 125:
                            rb_depth = max(0, rb_depth - 1)
        var rb_colors = List[Int]()
        # find highlighter state at the first visible line
        var lang = lang_for_path(self.path, self.title)
        var st = self.lex_state_at(self.top)
        scr.clip(self.x + 1, self.y + 1, self.w - 2, self.h - 2)
        var classes = List[Int]()
        # with soft wrap a line can take several screen rows ("segments")
        var r = self.top
        var seg = self.top_seg if self.wrap else 0
        var loaded = -1
        var ln = List[Int]()
        var starts = List[Int]()
        var vs = List[Int]()
        for i in range(rws):
            var yy = self.y + 1 + i
            if r >= self.buf.count():
                break
            if loaded != r:
                ln = self.buf.line(r)
                self.wrap_layout(ln, starts, vs)
                if not plain:
                    st = hl.line(ln, st, classes, lang)
                    if len(self.buf.sem) > 0:
                        self.buf.sem_apply(r, classes)
                rb_colors.clear()
                if rb_on:
                    var rmask = is_code_mask(ln)
                    for rc in range(len(ln)):
                        if rc < len(rmask) and rmask[rc]:
                            var rch = ln[rc]
                            if rch == 40 or rch == 91 or rch == 123:
                                rb_colors.append(pal.rainbow_color(rb_depth))
                                rb_depth += 1
                            elif rch == 41 or rch == 93 or rch == 125:
                                rb_depth = max(0, rb_depth - 1)
                                rb_colors.append(pal.rainbow_color(rb_depth))
                            else:
                                rb_colors.append(-1)
                        else:
                            rb_colors.append(-1)
                loaded = r
                seg = max(0, min(seg, len(starts) - 1))
            var s0 = starts[seg]
            var s1 = starts[seg + 1] if seg + 1 < len(starts) else len(ln)
            var v0 = vs[seg]
            var off = v0 if self.wrap else self.left     # visual column shown at the left edge
            var rowbg = bg
            var rowfg = fg
            if is_msg:
                var lt = to_str(ln) if self.kind == WK_MESSAGE else String("")
                if str_contains(lt, "error:"):
                    rowfg = pal.msg_err
                elif str_contains(lt, "warning:"):
                    rowfg = pal.msg_warn
                elif str_contains(lt, "note:"):
                    rowfg = pal.msg_note
                if self.kind == WK_DIFF and len(ln) > 0:
                    if ln[0] == 43:             # +
                        rowfg = pal.msg_ok
                    elif ln[0] == 45:           # -
                        rowfg = pal.msg_err
                    elif ln[0] == 64:           # @@
                        rowfg = pal.msg_note
                if r < len(self.git_rows) and self.git_rows[r] != GS_NONE:
                    var gc = self.git_rows[r]
                    if gc == GS_CONFLICT or gc == GS_DELETED:
                        rowfg = pal.msg_err
                    elif gc == GS_UNTRACKED or gc == GS_ADDED:
                        rowfg = pal.msg_ok
                    else:
                        rowfg = pal.msg_warn
                if r < len(self.row_marks) and self.row_marks[r] != RM_NONE:
                    var rm = self.row_marks[r]
                    rowfg = pal.msg_err if rm == RM_ERROR else (pal.msg_warn if rm == RM_WARN else (pal.msg_ok if rm == RM_OK else pal.msg_note))
                if r == self.cr and active:
                    rowbg = pal.msg_sel_bg
                    rowfg = pal.msg_sel_fg
                    scr.fill(self.x + 1, yy, self.w - 2, 1, 32, rowfg, rowbg)
                elif r == self.cr:
                    # the row stays visible in a window without the focus, muted
                    rowbg = mix(pal.msg_sel_bg, bg, 35)
                    scr.fill(self.x + 1, yy, self.w - 2, 1, 32, rowfg, rowbg)
            elif r == self.buf.exec_row:
                # the line the program being debugged is stopped at
                rowbg = pal.msg_sel_bg
                rowfg = pal.msg_sel_fg
                scr.fill(cx0, yy, cls, 1, 32, rowfg, rowbg)
            elif len(ln) >= 7 and ((ln[0] == 60 and ln[1] == 60 and ln[2] == 60 and ln[3] == 60 and ln[4] == 60 and ln[5] == 60 and ln[6] == 60) or (ln[0] == 61 and ln[1] == 61 and ln[2] == 61 and ln[3] == 61 and ln[4] == 61 and ln[5] == 61 and ln[6] == 61) or (ln[0] == 62 and ln[1] == 62 and ln[2] == 62 and ln[3] == 62 and ln[4] == 62 and ln[5] == 62 and ln[6] == 62)):
                # merge conflict delimiter banner
                rowbg = mix(pal.diag_err if ln[0] != 61 else pal.diag_warn, bg, 22)
                scr.fill(cx0, yy, cls, 1, 32, rowfg, rowbg)
            elif hl_line and active and r == self.cr:
                rowbg = pal.curline_bg
                scr.fill(cx0, yy, cls, 1, 32, rowfg, rowbg)
            if self.gut > 0:
                var num = String(r + 1) if seg == 0 else String("")
                if seg == 0 and self.rel_nums and r != self.cr and not is_msg:
                    num = String(r - self.cr if r > self.cr else self.cr - r)   # (vim: its own number on the cursor's line)
                var fold_mark = 32
                if seg == 0 and not is_msg:
                    if self.buf.fold_index(r) >= 0:
                        fold_mark = 0x25B8          # folded: points at the hidden block
                    elif self.buf.foldable(r):
                        fold_mark = 0x25BE
                var git_col = self.buf.git_state == GB_KNOWN
                var pad = self.gut - (2 if git_col else 1) - cp_len(num)
                var s = String("")
                for _ in range(pad):
                    s += " "
                s += num + ("  " if git_col else " ")
                var num_fg = pal.frame_act if r == self.cr and active else pal.gutter_fg
                var sev = self.buf.mark_severity(r) if len(self.buf.marks) > 0 else 0
                if sev == 1:
                    num_fg = pal.diag_err           # a problem on this line
                elif sev == 2:
                    num_fg = pal.diag_warn
                elif sev > 2:
                    num_fg = pal.diag_note
                _ = scr.text(self.x + 1, yy, s, num_fg, pal.gutter_bg)
                if seg == 0 and sev > 0 and pad >= 1:
                    # and a letter before the number: the colour is not the only sign
                    scr.put(self.x + 1, yy, 69 if sev == 1 else (87 if sev == 2 else 105), num_fg, pal.gutter_bg)   # E W i
                elif seg == 0 and not is_msg and pad >= 1 and len(self.test_lens_rows) > 0:
                    for tli in range(len(self.test_lens_rows)):
                        if self.test_lens_rows[tli] == r and tli < len(self.test_lens_states):
                            var ts = self.test_lens_states[tli]
                            var tch = 0x2713 if ts == 2 else (0x2717 if ts == 3 else 0x25B7)
                            var tfg = pal.msg_ok if ts == 2 else (pal.diag_err if ts == 3 else pal.gutter_fg)
                            scr.put(self.x + 1, yy, tch, tfg, pal.gutter_bg)
                            break
                elif seg == 0 and not is_msg and pad >= 1 and len(self.cov_rows) > 0:
                    for cvi in range(len(self.cov_rows)):
                        if self.cov_rows[cvi] == r:
                            var cs = self.cov_states[cvi] if cvi < len(self.cov_states) else 0
                            var cch = 0x2713 if cs > 0 else 0x00B7
                            var cfg_cov = pal.msg_ok if cs > 0 else pal.diag_err
                            scr.put(self.x + 1, yy, cch, cfg_cov, pal.gutter_bg)
                            break
                if seg == 0 and not is_msg and len(self.buf.bps) > 0:
                    var look = self.buf.bp_look(r)
                    if look == 1 or look == 3:
                        # a breakpoint: the line number in the alarm colour, with its sign
                        _ = scr.text(self.x + 1, yy, s, pal.gutter_bg, pal.diag_err)
                        if pad >= 1:
                            scr.put(self.x + 1, yy, 0x25CF if look == 1 else 0x25C6, pal.gutter_bg, pal.diag_err)
                    elif look > 0:
                        # switched off, or not placed by the debugger: only an outline
                        _ = scr.text(self.x + 1, yy, s, pal.diag_err, pal.gutter_bg)
                        if pad >= 1:
                            scr.put(self.x + 1, yy, 0x25CB if look == 2 else 0x25CC, pal.diag_err, pal.gutter_bg)
                if git_col and seg == 0 and r < len(self.buf.git_marks) and self.buf.git_marks[r] != LM_NONE:
                    # since the index: + added, ~ changed, ‾ removed above, _ removed below
                    var gm = Int(self.buf.git_marks[r])
                    var gch = 0x2B if gm == LM_ADDED else (0x7E if gm == LM_CHANGED else (0x203E if gm == LM_DELETED_ABOVE else 0x5F))
                    var gfg = pal.git_add if gm == LM_ADDED else (pal.git_mod if gm == LM_CHANGED else pal.git_del)
                    scr.put(self.x + self.gut - 1, yy, gch, gfg, pal.gutter_bg)
                if seg == 0 and r == self.buf.exec_row:
                    scr.put(self.x + self.gut, yy, 0x25BA, pal.msg_sel_bg, pal.gutter_bg)   # ►
                elif fold_mark != 32:
                    scr.put(self.x + self.gut, yy, fold_mark, pal.frame_act if fold_mark == 0x25B8 else pal.gutter_fg, pal.gutter_bg)
            var n = len(ln)
            scr.clip(cx0, self.y + 1, cls, self.h - 2)
            var v = v0
            var lastx = -1
            var lim = off + cls
            var nextc = s0
            # other matches of the current search on this row (skipped for huge lines)
            var ms = List[Int]()
            var mi = 0
            var ml_eol_hit = False
            if hs_ml:
                for sp in ml_spans:
                    if r >= sp.r1 and r <= sp.r2:
                        var mc1 = sp.c1 if r == sp.r1 else 0
                        var mc2 = sp.c2 if r == sp.r2 else n
                        if mc2 > mc1:
                            ms.append(mc1)
                            ms.append(mc2)
                        if r < sp.r2:
                            ml_eol_hit = True
            elif self.hs_on and not is_msg and n > 0 and n <= 20000:
                var mcols = self.scope_cols(r, n)
                ms = self.hs.all_in(ln, mcols.c1, mcols.c2)
            var ws = List[Int]()
            var wi = 0
            if len(wword) > 0 and n >= len(wword) and n <= 20000:
                ws = word_spans(ln, wword)
            for c in range(s0, s1):
                if v >= lim:
                    break
                if c < nextc:
                    continue       # drawn as part of the cluster that began earlier
                var ch = ln[c]
                var ce = c + 1
                if self.clustered:
                    ce = cluster_end(ln, c)
                    nextc = ce
                var a = self.span(ln, c, ce, v)
                if a == 0:
                    if lastx >= 0:
                        scr.combine(lastx, yy, ch)
                    continue
                if v + a <= off:
                    v += a
                    lastx = -1
                    continue
                var cfg = rowfg
                var cbg = rowbg
                if self.kind == WK_DIFF and not (r == self.cr and active) and len(ln) > 0 and ln[0] == 0xB1:
                    var bar_idx = -1
                    for bi in range(len(ln)):
                        if ln[bi] == 0x2502:
                            bar_idx = bi
                            break
                    if bar_idx >= 0:
                        if c == bar_idx:
                            cfg = pal.gutter_fg
                        elif c < bar_idx:
                            cfg = pal.msg_err
                        else:
                            cfg = pal.msg_ok
                if not plain:
                    cfg = pal.syn[classes[c]]
                    if c < len(rb_colors) and rb_colors[c] >= 0:
                        cfg = rb_colors[c]
                while wi + 1 < len(ws) and c >= ws[wi + 1]:
                    wi += 2
                if wi < len(ws) and c >= ws[wi]:
                    cbg = pal.word_bg
                while mi + 1 < len(ms) and c >= ms[mi + 1]:
                    mi += 2
                if mi < len(ms) and c >= ms[mi]:
                    cfg = pal.match_fg
                    cbg = pal.match_bg
                if self.in_sel(r, c) or (n_extra > 0 and self.in_extra_sel(r, c)):
                    cfg = pal.sel_fg
                    cbg = pal.sel_bg
                if (r == brk.r and c == brk.c) or (r == self.cr and c == bc):
                    cfg = pal.bracket_fg
                    cbg = pal.bracket_bg
                var sx = cx0 + v - off
                if ch == 9 or v < off:
                    # tab (or a wide char cut by the left edge): blank cells
                    for k in range(max(v, off), v + a):
                        scr.put(cx0 + k - off, yy, 32, cfg, cbg)
                    if ch == 9 and show_ws:
                        scr.put(max(sx, cx0), yy, 0x2192, pal.gutter_fg, cbg)
                    lastx = -1
                elif ce - c > 1:
                    scr.put_cluster(sx, yy, ln, c, ce, a, cfg, cbg)
                    lastx = -1
                else:
                    scr.put(sx, yy, ch, cfg, cbg)
                    lastx = sx
                v += a
            # vertical indentation scope guides across leading spaces and blank lines inside blocks
            if self.indent_guides and not is_msg and not plain and seg == 0 and not scr.plain:
                var step = max(2, self.buf.indent_size)
                var glim = self._indent_guide_vcol(r)
                var gch = 124 if scr.glyphs == GLYPHS_ASCII else 0x2506
                var gv = 0
                while gv < glim:
                    if gv >= off and gv < lim:
                        var gx = cx0 + gv - off
                        if scr.bg_at(gx, yy) == rowbg:
                            var gfg_ind = (
                                pal.frame_act
                                if ascope.r1 >= 0 and r >= ascope.r1 and r <= ascope.r2 and gv == ascope_vcol
                                else pal.gutter_fg
                            )
                            scr.put(gx, yy, gch, gfg_ind, rowbg)
                    gv += step
            # the additional cursors: the terminal has one real cursor, these are drawn
            for e in self.extra:
                if e.r != r:
                    continue
                if self.seg_of(starts, e.c) != seg:
                    continue
                var ev = self.vcol(r, e.c)
                if ev >= off and ev < lim:
                    scr.set_bg(cx0 + ev - off, yy, pal.match_fg if pal.match_fg != rowbg else pal.sel_fg)
                    scr.set_fg(cx0 + ev - off, yy, rowbg)
            # selection past end of line shows the newline
            if has_sel and sr.r1 <= r and r < sr.r2 and s1 == n and v >= off and v < lim:
                scr.put(cx0 + v - off, yy, 32, pal.sel_fg, pal.sel_bg)
            elif ml_eol_hit and s1 == n and v >= off and v < lim:
                scr.put(cx0 + v - off, yy, 32, pal.match_fg, pal.match_bg)
            # problems reported for this line: underline the range (at least one cell)
            for m in self.buf.marks:
                if r < m.l1 or r > m.l2 or is_msg:
                    continue
                var a_c = m.c1 if r == m.l1 else 0
                var b_c = m.c2 if r == m.l2 else n
                a_c = max(s0, min(a_c, n))
                b_c = max(a_c, min(b_c, s1))
                if a_c > s1 or (a_c == s1 and s1 < n):
                    continue                    # on another screen row of this line
                var va = self.vcol(r, a_c)
                var vb = max(va + 1, self.vcol(r, b_c))
                var ucol = pal.diag_err if m.severity == 1 else (pal.diag_warn if m.severity == 2 else pal.diag_note)
                # the kind of problem by the line's shape too, not only its colour
                var ukind = UL_CURLY if m.severity == 1 else (UL_DASHED if m.severity == 2 else UL_DOTTED)
                for uv in range(max(va, off), min(vb, lim)):
                    scr.underline_kind(cx0 + uv - off, yy, ukind, ucol)
                    if m.deprecated and not scr.plain:
                        scr.strikethrough(cx0 + uv - off, yy, 1)
            # column guides: only where nothing else colours the cell
            if not is_msg and not self.wrap:
                for rc in self.rulers:
                    var rx = cx0 + rc - off
                    if rc >= off and rc < lim and scr.bg_at(rx, yy) == rowbg:
                        scr.set_bg(rx, yy, pal.ruler_bg)
            # a folded block: say how much is hidden behind its header
            var fi = self.buf.fold_index(r) if not is_msg else -1
            if fi >= 0 and s1 == n and fi < len(self.buf.fold_ends) and v + 2 >= off and v + 2 < lim:
                var hidden = self.buf.fold_ends[fi] - r
                _ = scr.text(cx0 + v + 1 - off, yy, " ⋯ " + String(hidden) + (" line " if hidden == 1 else " lines "), pal.gutter_fg, pal.gutter_bg)
            elif s1 == n and not is_msg and v + 2 >= off and v + 4 < lim:
                var eol_x = cx0 + v + 2 - off
                if len(self.buf.hints) > 0:
                    # inlay hints are shown after the end of the line, not inside it
                    var note = self.buf.hints_text(r)
                    if note.byte_length() > 0:
                        var hx0 = eol_x
                        eol_x = scr.text(eol_x, yy, "◂ " + note + "  ", pal.syn[3], rowbg)
                        if not scr.plain and eol_x > hx0:
                            scr.italic(hx0, yy, eol_x - hx0)
                            scr.dim(hx0, yy, eol_x - hx0)
                if len(self.dbg_inline_rows) > 0 and eol_x + 4 < cx0 + cls:
                    for dli in range(len(self.dbg_inline_rows)):
                        if self.dbg_inline_rows[dli] == r and dli < len(self.dbg_inline_vals):
                            eol_x = scr.text(eol_x, yy, "⟨" + self.dbg_inline_vals[dli] + "⟩  ", pal.msg_note, rowbg)
                            break
                var drew_cell = False
                if len(self.cell_badge_rows) > 0 and not scr.plain and eol_x + 8 < cx0 + cls:
                    for cbi in range(len(self.cell_badge_rows)):
                        if self.cell_badge_rows[cbi] == r and cbi < len(self.cell_badges):
                            var cb = String(self.cell_badges[cbi])
                            if cb.byte_length() > 0:
                                var cbfg = (
                                    pal.msg_ok
                                    if str_contains(cb, "✓")
                                    else (pal.diag_err if str_contains(cb, "✗") else pal.msg_note)
                                )
                                eol_x = scr.text(eol_x, yy, "  " + cb, cbfg, rowbg)
                                drew_cell = True
                            break
                if not drew_cell and (lang == HL_MOJO or lang == HL_PYTHON) and len(ln) >= 4 and ln[0] == 35 and ln[1] == 32 and ln[2] == 37 and ln[3] == 37 and not scr.plain and eol_x + 18 < cx0 + cls:
                    eol_x = scr.text(eol_x, yy, "  [Ctrl-Enter: Run Cell]", pal.msg_note, rowbg)
                if len(self.bench_badge_rows) > 0 and not scr.plain and eol_x + 8 < cx0 + cls:
                    for bbi in range(len(self.bench_badge_rows)):
                        if self.bench_badge_rows[bbi] == r and bbi < len(self.bench_badges):
                            var bb = String(self.bench_badges[bbi])
                            if bb.byte_length() > 0:
                                eol_x = scr.text(eol_x, yy, "  " + bb, pal.msg_ok, rowbg)
                            break
                if active and r == self.cr and r == self.inline_blame_row and self.inline_blame.byte_length() > 0 and not scr.plain and eol_x + 4 < cx0 + cls:
                    var bx0 = eol_x
                    var bend = scr.text(eol_x, yy, "  " + self.inline_blame, pal.gutter_fg, rowbg)
                    if bend > bx0:
                        scr.italic(bx0, yy, bend - bx0)
                        scr.dim(bx0, yy, bend - bx0)
            scr.clip(self.x + 1, self.y + 1, self.w - 2, self.h - 2)
            seg += 1
            if seg >= len(starts):
                var nr = self.buf.next_row(r)
                if nr != r + 1 and nr < self.buf.count():
                    st = self.lex_state_at(nr)      # lines were skipped: pick up the state there
                    if rb_on:
                        for srr in range(r + 1, min(nr, r + 300)):
                            var sln = self.buf.line(srr)
                            var smask = is_code_mask(sln)
                            for src in range(len(sln)):
                                if src < len(smask) and smask[src]:
                                    var sch = sln[src]
                                    if sch == 40 or sch == 91 or sch == 123:
                                        rb_depth += 1
                                    elif sch == 41 or sch == 93 or sch == 125:
                                        rb_depth = max(0, rb_depth - 1)
                r = nr
                seg = 0
        scr.no_clip()
        if not is_msg and not active and self.kind == WK_EDITOR:
            # where the cursor is in an editor without the focus: a muted cell (the
            # terminal's one cursor belongs to the window that has the focus)
            var cell = self.cursor_cell()
            if cell.c > self.x + self.gut and cell.c < self.x + self.w - 1 and cell.r > self.y and cell.r < self.y + self.h - 1:
                scr.set_bg(cell.c, cell.r, mix(fg, bg, 40))
        if not is_msg and len(self.sticky) > 0:
            self.draw_sticky(scr, pal, cx0, cls)
        if not is_msg and self.minimap and not scr.plain:
            self.draw_minimap(scr, pal, rws)

        # bottom: position + modified marker
        if not is_msg:
            var pos = " " + String(self.cr + 1) + ":" + String(self.vcol(self.cr, self.cc) + 1) + " "
            var px = self.x + 2
            if self.buf.modified:
                scr.put(px, self.y + self.h - 1, 0x263C, pal.icon_fg, bg)
                px += 1
            _ = scr.text(px, self.y + self.h - 1, pos, ffg, bg)
        if active and self.h > 4 and not scr.plain:
            # vertical scrollbar
            var sx = self.x + self.w - 1
            var y0 = self.y + 1
            var y1 = self.y + self.h - 2
            scr.put(sx, y0, 0x25B2, pal.scroll_fg, pal.scroll_bg)
            scr.put(sx, y1, 0x25BC, pal.scroll_fg, pal.scroll_bg)
            for yy in range(y0 + 1, y1):
                scr.put(sx, yy, 0x2592, pal.scroll_fg, pal.scroll_bg)
            var span = y1 - y0 - 1
            var ty = -1
            if span > 0:
                var tot = max(1, self.buf.count() - 1)
                ty = y0 + 1 + (min(self.cr, tot) * (span - 1)) // tot
                scr.put(sx, ty, 0x25A0, pal.scroll_fg, pal.scroll_bg)
            if not is_msg:
                self.draw_overview_ruler(scr, pal, sx, y0, y1, ty, ml_spans)
            if not is_msg and self.w > 30:
                # horizontal scrollbar
                var hx0 = self.x + 18
                var hx1 = self.x + self.w - 2
                var by = self.y + self.h - 1
                scr.put(hx0, by, 0x25C4, pal.scroll_fg, pal.scroll_bg)
                scr.put(hx1, by, 0x25BA, pal.scroll_fg, pal.scroll_bg)
                for xx in range(hx0 + 1, hx1):
                    scr.put(xx, by, 0x2592, pal.scroll_fg, pal.scroll_bg)
                var hs = hx1 - hx0 - 1
                if hs > 0:
                    var maxw = 1
                    for r in range(self.top, min(self.buf.count(), self.top + rws)):
                        maxw = max(maxw, self.buf.llen(r))
                    var tx2 = hx0 + 1 + (min(self.vcol(self.cr, self.cc), maxw) * (hs - 1)) // maxw
                    scr.put(tx2, by, 0x25A0, pal.scroll_fg, pal.scroll_bg)
        elif not active and self.minimap and not is_msg and self.h > 4 and not scr.plain:
            self.draw_overview_ruler(scr, pal, self.x + self.w - 1, self.y + 1, self.y + self.h - 2, -1, ml_spans)

    def is_bracket(self, ch: Int) -> Bool:
        return ch == 40 or ch == 41 or ch == 91 or ch == 93 or ch == 123 or ch == 125
