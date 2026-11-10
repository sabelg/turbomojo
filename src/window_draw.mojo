"""Window drawing: frame, gutter, highlighted text, selection, scrollbars."""
from std.collections import List
from buffer import TextBuffer, Pos, TAB_WIDTH
from screen import Screen
from palette import Palette
from highlight import Highlighter, C_TEXT
from util import is_ident, lower, decode, cp_len, to_str, str_contains, char_width
from grapheme import cluster_end
from window import *
from window_search import *
from window_multi import *


__extension Window:
    # --------------------------------------------------------------- draw
    def draw(
        self, mut scr: Screen, pal: Palette, hl: Highlighter, active: Bool, hl_line: Bool, insert_mode: Bool, show_ws: Bool
    ):
        var is_msg = self.kind == WK_MESSAGE
        var plain = is_msg or self.buf.large      # no syntax colours
        var bg = pal.msg_bg if is_msg else pal.ed_bg
        var fg = pal.msg_fg if is_msg else pal.ed_fg
        var ffg = (pal.msg_frame if is_msg else pal.frame_act) if active else pal.frame_inact
        scr.fill(self.x, self.y, self.w, self.h, 32, fg, bg)
        scr.frame(self.x, self.y, self.w, self.h, active, ffg, bg)
        # title
        var t = " " + self.title + (" (large file) " if self.buf.large else " ")
        var tl = cp_len(t)
        var tx = self.x + max(1, (self.w - tl) // 2)
        scr.clip(self.x + 1, self.y, self.w - 2, 1)
        _ = scr.text(tx, self.y, t, pal.title_fg if active else ffg, bg)
        scr.no_clip()
        if active and self.w > 12:
            _ = scr.text(self.x + 2, self.y, "[", ffg, bg)
            scr.put(self.x + 3, self.y, 0x25A0, pal.icon_fg, bg)
            _ = scr.text(self.x + 4, self.y, "]", ffg, bg)
            _ = scr.text(self.x + self.w - 5, self.y, "[", ffg, bg)
            scr.put(self.x + self.w - 4, self.y, 0x2195 if self.zoomed else 0x2191, pal.icon_fg, bg)
            _ = scr.text(self.x + self.w - 3, self.y, "]", ffg, bg)
        if self.number > 0 and self.number < 10 and self.w > 12:
            _ = scr.text(self.x + self.w - 7, self.y, String(self.number), ffg, bg)

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
        var sr = self.sel_range()
        # find highlighter state at the first visible line
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
                    st = hl.line(ln, st, classes)
                loaded = r
                seg = min(seg, len(starts) - 1)
            var s0 = starts[seg]
            var s1 = starts[seg + 1] if seg + 1 < len(starts) else len(ln)
            var v0 = vs[seg]
            var off = v0 if self.wrap else self.left     # visual column shown at the left edge
            var rowbg = bg
            var rowfg = fg
            if is_msg:
                var lt = to_str(ln)
                if str_contains(lt, "error:"):
                    rowfg = pal.msg_err
                elif str_contains(lt, "warning:"):
                    rowfg = pal.msg_warn
                elif str_contains(lt, "note:"):
                    rowfg = pal.msg_note
                if r == self.cr:
                    rowbg = pal.msg_sel_bg
                    rowfg = pal.msg_sel_fg
                    scr.fill(self.x + 1, yy, self.w - 2, 1, 32, rowfg, rowbg)
            elif hl_line and active and r == self.cr:
                rowbg = pal.curline_bg
                scr.fill(cx0, yy, cls, 1, 32, rowfg, rowbg)
            if self.gut > 0:
                var num = String(r + 1) if seg == 0 else String("")
                var pad = self.gut - 1 - cp_len(num)
                var s = String("")
                for _ in range(pad):
                    s += " "
                s += num + " "
                _ = scr.text(self.x + 1, yy, s, pal.frame_act if r == self.cr and active else pal.gutter_fg, pal.gutter_bg)
            var n = len(ln)
            scr.clip(cx0, self.y + 1, cls, self.h - 2)
            var v = v0
            var lastx = -1
            var lim = off + cls
            var nextc = s0
            # other matches of the current search on this row (skipped for huge lines)
            var ms = List[Int]()
            var mi = 0
            if self.hs_on and not is_msg and n > 0 and n <= 20000:
                var mcols = self.scope_cols(r, n)
                ms = self.hs.all_in(ln, mcols.c1, mcols.c2)
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
                if not plain:
                    cfg = pal.syn[classes[c]]
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
            scr.clip(self.x + 1, self.y + 1, self.w - 2, self.h - 2)
            seg += 1
            if seg >= len(starts):
                r += 1
                seg = 0
        scr.no_clip()

        # bottom: position + modified marker
        if not is_msg:
            var pos = " " + String(self.cr + 1) + ":" + String(self.vcol(self.cr, self.cc) + 1) + " "
            var px = self.x + 2
            if self.buf.modified:
                scr.put(px, self.y + self.h - 1, 0x263C, pal.icon_fg, bg)
                px += 1
            _ = scr.text(px, self.y + self.h - 1, pos, ffg, bg)
        if active and self.h > 4:
            # vertical scrollbar
            var sx = self.x + self.w - 1
            var y0 = self.y + 1
            var y1 = self.y + self.h - 2
            scr.put(sx, y0, 0x25B2, pal.scroll_fg, pal.scroll_bg)
            scr.put(sx, y1, 0x25BC, pal.scroll_fg, pal.scroll_bg)
            for yy in range(y0 + 1, y1):
                scr.put(sx, yy, 0x2592, pal.scroll_fg, pal.scroll_bg)
            var span = y1 - y0 - 1
            if span > 0:
                var tot = max(1, self.buf.count() - 1)
                var ty = y0 + 1 + (min(self.cr, tot) * (span - 1)) // tot
                scr.put(sx, ty, 0x25A0, pal.scroll_fg, pal.scroll_bg)
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

    def is_bracket(self, ch: Int) -> Bool:
        return ch == 40 or ch == 41 or ch == 91 or ch == 93 or ch == 123 or ch == 125
