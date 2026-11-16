"""Window drawing: frame, gutter, highlighted text, selection, scrollbars."""
from glyphs import GLYPHS_ASCII
from std.collections import List
from buffer import TextBuffer, Pos, TAB_WIDTH
from screen import Screen, UL_CURLY, UL_DASHED, UL_DOTTED
from palette import Palette, mix
from highlight import Highlighter, C_TEXT, C_STR, C_DEF, lang_for_path, HL_MOJO, HL_PYTHON
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
from cellimg import (
    CELL_IMG_MARK,
    CELL_NB_HDR_MARK,
    CELL_NB_SUB_MARK,
    CELL_NB_BOT_MARK,
    decode_cell_img_line,
)
from nb_widgets import (
    render_latex_inline,
    render_mermaid_diagram,
    parse_cell_widgets,
    format_widget_bar,
)
from window import *
from window_search import *
from window_multi import *
from window_lines import *



def wordish(c: Int) -> Bool:
    return (c >= 48 and c <= 57) or (c >= 65 and c <= 90) or (c >= 97 and c <= 122) or c == 95 or c >= 128


def _preprocess_md_math_mermaid(raw: String) -> String:
    """Convert inline `$...$` LaTeX math and fenced ```mermaid diagrams into rich Unicode blocks."""
    if raw.find("$") < 0 and raw.find("```mermaid") < 0:
        return raw
    var out_lines = List[String]()
    var in_fence = False
    var in_mermaid = False
    var m_lines = List[String]()
    for ln_slice in raw.split("\n"):
        var ln = String(ln_slice)
        var st = String(ln.strip())
        if st.startswith("```"):
            if not in_fence:
                in_fence = True
                if st.startswith("```mermaid"):
                    in_mermaid = True
                    m_lines = List[String]()
                    continue
                out_lines.append(ln)
                continue
            else:
                in_fence = False
                if in_mermaid:
                    in_mermaid = False
                    var diag = render_mermaid_diagram("\n".join(m_lines))
                    out_lines.append("```text")
                    for dl in diag:
                        out_lines.append(dl)
                    out_lines.append("```")
                    continue
                out_lines.append(ln)
                continue
        if in_mermaid:
            m_lines.append(ln)
        elif in_fence:
            out_lines.append(ln)
        else:
            out_lines.append(render_latex_inline(ln))
    if in_mermaid and len(m_lines) > 0:
        var diag2 = render_mermaid_diagram("\n".join(m_lines))
        for dl2 in diag2:
            out_lines.append(dl2)
    return "\n".join(out_lines)


def _draw_nb_inline_spans(
    mut scr: Screen,
    x0: Int,
    y: Int,
    x_lim: Int,
    text: String,
    base_fg: Int,
    rowbg: Int,
    pal: Palette,
    base_bold: Bool = False,
    base_italic: Bool = False,
) -> Int:
    """Render inline Markdown `**bold**`, `` `code` ``, and `$math$` spans cleanly without raw markup delimiters."""
    var rendered_txt = render_latex_inline(text) if text.find("$") >= 0 else text
    var cps = decode(rendered_txt)
    var n = len(cps)
    var i = 0
    var x = x0
    var code_bg = mix(pal.gutter_bg, rowbg, 75)
    while i < n and x < x_lim:
        # Inline `` `code` `` span
        if cps[i] == 96:
            var j = i + 1
            while j < n and cps[j] != 96:
                j += 1
            if j < n and j > i + 1:
                var code_txt = slice_str(cps, i + 1, j)
                var x1 = scr.text(x, y, code_txt, pal.syn[C_STR], code_bg)
                x = x1
                i = j + 1
                continue
        # Inline `**bold**` span
        if i + 1 < n and cps[i] == 42 and cps[i + 1] == 42:
            var j = i + 2
            while j + 1 < n and not (cps[j] == 42 and cps[j + 1] == 42):
                j += 1
            if j + 1 < n and j > i + 2:
                var bold_txt = slice_str(cps, i + 2, j)
                var bx0 = x
                x = scr.text(x, y, bold_txt, pal.title_fg if not base_bold else base_fg, rowbg)
                if x > bx0:
                    scr.bold(bx0, y, x - bx0)
                i = j + 2
                continue
        var at = x
        x = scr.draw_cp(x, y, cps[i], base_fg, rowbg)
        if x > at:
            if base_bold:
                scr.bold(at, y, x - at)
            elif base_italic:
                scr.italic(at, y, x - at)
        i += 1
    return x


def _draw_nb_markdown_line(
    mut scr: Screen,
    x0: Int,
    y: Int,
    cls: Int,
    md_raw: String,
    pal: Palette,
    rowbg: Int,
):
    """Render a single `.ipynb` Markdown cell body line with rich headings, rules, quotes, bullets & spans."""
    var x_lim = x0 + max(1, cls - 1)
    var trimmed = String(md_raw.strip())
    if trimmed == "---" or trimmed == "***" or trimmed == "___":
        var rule_ch = 45 if scr.glyphs == GLYPHS_ASCII else 0x2500
        var rule_w = max(8, min(cls - 4, 72))
        var rule_fg = mix(pal.gutter_fg, rowbg, 50)
        for rx in range(x0, min(x_lim, x0 + rule_w)):
            scr.put(rx, y, rule_ch, rule_fg, rowbg)
        return
    if md_raw.startswith("### "):
        _ = _draw_nb_inline_spans(scr, x0, y, x_lim, String(md_raw[byte=4:]), pal.msg_note, rowbg, pal, True, False)
        return
    if md_raw.startswith("## "):
        _ = _draw_nb_inline_spans(scr, x0, y, x_lim, String(md_raw[byte=3:]), pal.msg_note, rowbg, pal, True, False)
        return
    if md_raw.startswith("# "):
        _ = _draw_nb_inline_spans(scr, x0, y, x_lim, String(md_raw[byte=2:]), pal.syn[C_DEF], rowbg, pal, True, False)
        return
    if md_raw.startswith("- ") or md_raw.startswith("* "):
        var bx = scr.text(x0, y, "  • ", pal.frame_act, rowbg)
        _ = _draw_nb_inline_spans(scr, bx, y, x_lim, String(md_raw[byte=2:]), pal.ed_fg, rowbg, pal)
        return
    if md_raw.byte_length() >= 3 and Int(md_raw.as_bytes()[0]) >= 49 and Int(md_raw.as_bytes()[0]) <= 57 and Int(md_raw.as_bytes()[1]) == 46 and Int(md_raw.as_bytes()[2]) == 32:
        var nx = scr.text(x0, y, "  " + String(md_raw[byte=0:3]), pal.frame_act, rowbg)
        _ = _draw_nb_inline_spans(scr, nx, y, x_lim, String(md_raw[byte=3:]), pal.ed_fg, rowbg, pal)
        return
    if md_raw.startswith("> "):
        var qbar = "| " if scr.glyphs == GLYPHS_ASCII else "  ▎ "
        var qx = scr.text(x0, y, qbar, pal.msg_note, rowbg)
        _ = _draw_nb_inline_spans(scr, qx, y, x_lim, String(md_raw[byte=2:]), mix(pal.ed_fg, pal.gutter_fg, 72), rowbg, pal, False, True)
        return
    _ = _draw_nb_inline_spans(scr, x0, y, x_lim, md_raw, pal.ed_fg, rowbg, pal)


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
        var pd = self.pad()
        for i in range(len(self.sticky)):
            var r = self.sticky[i]
            if r < 0 or r >= self.buf.count() or i >= self.rows() - 1:
                break
            var yy = self.y + pd + i
            scr.fill(self.x + pd, yy, self.gut + cls, 1, 32, pal.ed_fg, pal.curline_bg)
            if self.gut > 0:
                var num = String(r + 1)
                _ = scr.text(self.x + max(pd, self.gut - cp_len(num)), yy, num, pal.gutter_fg, pal.curline_bg)
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
                for ux in range(self.x + pd, self.x + pd + self.gut + cls):
                    scr.underline(ux, yy, False, pal.frame_inact)

    def draw_minimap(self, mut scr: Screen, pal: Palette, rws: Int):
        """The whole file at the right edge in braille dots: each dot a few columns of a
        line that has text; the rows the window shows on a lighter background. In half
        blocks (editor.minimap_style = "blocks") a cell has an upper and a lower half
        only, each for two dot rows and both dot columns."""
        var pd = self.pad()
        var sep_w = 1 if (self.chromeless and self.split_sep) else 0
        var n = self.buf.count()
        var x0 = self.x + self.w - pd - sep_w - MINIMAP_W
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
                    scr.put(x0 + cx, self.y + pd + cy, hb, pal.gutter_fg, bg)
                    continue
                var bits = 0
                for dy in range(4):
                    for dx in range(2):
                        if masks[dy] & (1 << (cx * 2 + dx)) != 0:
                            bits |= braille_dot(dx, dy)
                scr.put(x0 + cx, self.y + pd + cy, braille(bits) if bits != 0 else 32, pal.gutter_fg, bg)

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
        var md_src = _preprocess_md_math_mermaid(to_str(self.buf.all_text()))
        var lines = md_render_rich(md_src, md_w, hl, md_links, True)
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

    def _nb_status_pill(self, r: Int) -> String:
        var use_buf_cb = len(self.buf.cell_badge_rows) > 0
        var cb_rows_n = len(self.buf.cell_badge_rows) if use_buf_cb else len(self.cell_badge_rows)
        for cbi in range(cb_rows_n):
            var cbr = self.buf.cell_badge_rows[cbi] if use_buf_cb else self.cell_badge_rows[cbi]
            var cbn = len(self.buf.cell_badges) if use_buf_cb else len(self.cell_badges)
            if cbr == r and cbi < cbn:
                var cb = String(self.buf.cell_badges[cbi] if use_buf_cb else self.cell_badges[cbi])
                if str_contains(cb, "running"):
                    return " ⟳ running "
                if str_contains(cb, "queued"):
                    return " ⋯ queued "
                if str_contains(cb, "✗"):
                    return " ✗ error "
                if str_contains(cb, "✓"):
                    var inner = cb
                    if inner.startswith("[") and inner.endswith("]") and inner.byte_length() >= 2:
                        var unbr = String(inner[byte=1 : inner.byte_length() - 1])
                        inner = unbr
                    var dot_i = inner.find("·")
                    if dot_i >= 0:
                        var pre_dot = String(inner[byte=0:dot_i].strip())
                        inner = pre_dot
                    if inner == "✓ 0 ms" or inner == "✓":
                        return " ✓ "
                    if cp_len(inner) <= 14:
                        return " " + inner + " "
                    return " ✓ "
        return ""

    def nb_card_action_spans(self, r: Int) -> Tuple[Int, Int, Int, Int, String, String, String]:
        """Return `(fold_x0, fold_x1, run_x0, run_x1, fold_pill, run_pill, stat_pill)` in screen x coords."""
        var pd = self.pad()
        var cx0 = self.x + pd + self.gut
        var cls = self.cols()
        var card_x1 = cx0 + max(12, cls - 1) - 1
        var stat_pill = self._nb_status_pill(r)
        var rx = card_x1 - 1
        if stat_pill.byte_length() > 0 and rx - cp_len(stat_pill) > cx0 + 18:
            rx -= cp_len(stat_pill)
        else:
            stat_pill = ""
        var run_pill = String(" [▶ Run] ")
        var run_x1 = rx
        var run_x0 = rx - cp_len(run_pill)
        rx = run_x0
        var fi = self.buf.fold_index(r)
        var fold_pill = String("")
        var fold_x0 = -1
        var fold_x1 = -1
        if fi >= 0 and fi < len(self.buf.fold_ends):
            var hidden = max(1, self.buf.fold_ends[fi] - r)
            fold_pill = " [▸ +" + String(hidden) + (" line] " if hidden == 1 else " lines] ")
        elif self.buf.foldable(r):
            fold_pill = " [▾ Hide code] "
        if fold_pill.byte_length() > 0 and rx - cp_len(fold_pill) > cx0 + 14:
            fold_x1 = rx
            fold_x0 = rx - cp_len(fold_pill)
        else:
            fold_pill = ""
        return (fold_x0, fold_x1, run_x0, run_x1, fold_pill, run_pill, stat_pill)

    def imgview_bar_hit(self, px: Int, py: Int) -> Int:
        """Hit-test interactive controls on `WK_IMGVIEW`:
        1=zoom out, 2=zoom in, 3=fit 100%, 4=prev/step-, 5=next/step+, 6=OS viewer,
        7=close, 8=play/pause, 9=Save GIF, >=1000=(1000 + scrubbed frame index)."""
        if self.kind != WK_IMGVIEW or self.chromeless or self.w < 32:
            return 0
        if len(self.img_paths) > 1 and self.h >= 6 and py == self.y + self.h - 2:
            var sx0 = self.x + 3
            var bar_w = max(8, min(44, self.w - 18))
            if px >= sx0 and px < sx0 + bar_w:
                var fidx = ((px - sx0) * len(self.img_paths)) // max(1, bar_w)
                return 1000 + max(0, min(len(self.img_paths) - 1, fidx))
            return 0
        if py != self.y + self.h - 1:
            return 0
        var zstr = " " + String(self.img_zoom_pct) + "% "
        var x = self.x + 2
        if self.img_anim_fps > 0 and len(self.img_paths) > 1:
            var play_lbl = " [⏸ Pause] " if self.img_anim_playing else " [▶ Play]  "
            var pw = cp_len(play_lbl)
            if px >= x and px < x + pw:
                return 8
            x += pw
        var w_minus = 4  # " [-]"
        if px >= x and px < x + w_minus:
            return 1
        x += w_minus + cp_len(zstr)
        var w_plus = 4   # "[+] "
        if px >= x and px < x + w_plus:
            return 2
        x += w_plus + 1
        var w_fit = 7    # "[0 Fit]"
        if px >= x and px < x + w_fit:
            return 3
        x += w_fit + 2
        if len(self.img_paths) > 1 and x + 16 < self.x + self.w - 2:
            if px >= x and px < x + 8:
                return 4
            x += 9
            if px >= x and px < x + 8:
                return 5
            x += 10
        if len(self.img_paths) > 1 and x + 9 < self.x + self.w - 2:
            if px >= x and px < x + 7:
                return 9
            x += 9
        if x + 10 < self.x + self.w - 2:
            if px >= x and px < x + 10:
                return 6
            x += 12
        if x + 11 < self.x + self.w - 2:
            if px >= x and px < x + 11:
                return 7
        return 0

    def draw_imgview(self, mut scr: Screen, pal: Palette, active: Bool):
        """Render dedicated image-only zoom window (`WK_IMGVIEW`) with centered image, scrubber & bottom controls."""
        var pd = self.pad()
        var ix = self.x + pd
        var iy = self.y + pd
        var iw = max(1, self.w - 2 * pd)
        var has_scrub = not self.chromeless and len(self.img_paths) > 1 and self.h >= 6 and self.w >= 32 and not scr.plain
        var ih = max(1, self.h - 2 * pd - (1 if has_scrub else 0))
        var matte_bg = (
            mix(0x090B10, pal.ed_bg, 38)
            if (pal.ed_bg >= 0 and pal.ed_bg <= 0xFFFFFF)
            else pal.ed_bg
        )
        scr.clip(ix, iy, iw, ih)
        scr.fill(ix, iy, iw, ih, 32, pal.ed_fg, matte_bg)
        var p = self.imgview_current_path()
        if p.byte_length() > 0:
            self.img_cache[].draw_zoomed_view(
                scr,
                ix,
                iy,
                iw,
                ih,
                matte_bg,
                p,
                self.img_zoom_pct,
                self.img_pan_x,
                self.img_pan_y,
                self.gfx_mode,
                self.gfx_tmux,
                self.gfx_cell_w,
                self.gfx_cell_h,
            )
        scr.no_clip()
        if has_scrub:
            var sy = self.y + self.h - 2
            var sbg = mix(pal.gutter_bg, pal.ed_bg, 65)
            scr.fill(ix, sy, iw, 1, 32, pal.ed_fg, sbg)
            var bar_w = max(8, min(44, self.w - 18))
            var sx0 = self.x + 3
            var n_fr = len(self.img_paths)
            var cur_f = max(0, min(n_fr - 1, self.img_idx))
            var knob = (cur_f * max(0, bar_w - 1)) // max(1, n_fr - 1)
            for bx in range(bar_w):
                var ch_s = 0x25CF if bx == knob else (0x2501 if bx < knob else 0x2500)
                var fg_s = pal.msg_ok if bx <= knob else pal.gutter_fg
                scr.put(sx0 + bx, sy, ch_s, fg_s, sbg)
            var f_info = "  Frame " + String(cur_f + 1) + "/" + String(n_fr) + (
                (" · " + String(self.img_anim_fps) + " fps") if self.img_anim_fps > 0 else String("")
            )
            if sx0 + bar_w + cp_len(f_info) < self.x + self.w - 1:
                _ = scr.text(sx0 + bar_w, sy, f_info, pal.msg_note, sbg)
        if not self.chromeless and self.w >= 32 and not scr.plain:
            var by = self.y + self.h - 1
            var ffg = pal.frame_act if active else pal.frame_inact
            var bg = pal.ed_bg
            var x = self.x + 2
            if self.img_anim_fps > 0 and len(self.img_paths) > 1:
                var plbl = " [⏸ Pause] " if self.img_anim_playing else " [▶ Play]  "
                var pcol = pal.msg_warn if not self.img_anim_playing else pal.msg_ok
                var px1 = scr.text(x, by, plbl, pcol, bg)
                if px1 > x:
                    scr.bold(x, by, px1 - x)
                x = px1
            x = scr.text(x, by, " [-]", pal.title_fg if active else ffg, bg)
            var z0 = x
            x = scr.text(x, by, " " + String(self.img_zoom_pct) + "% ", pal.msg_ok, bg)
            if active and x > z0:
                scr.bold(z0, by, x - z0)
            x = scr.text(x, by, "[+] ", pal.title_fg if active else ffg, bg)
            x += 1
            x = scr.text(x, by, "[0 Fit]", pal.msg_note if self.img_zoom_pct > 100 else ffg, bg)
            x += 2
            if len(self.img_paths) > 1 and x + 18 < self.x + self.w - 2:
                var prev_l = "[◀ Step]" if self.img_anim_fps > 0 else "[◀ Prev]"
                var next_l = "[Step ▶]" if self.img_anim_fps > 0 else "[Next ▶]"
                x = scr.text(x, by, prev_l, pal.title_fg if active else ffg, bg)
                x += 1
                x = scr.text(x, by, next_l, pal.title_fg if active else ffg, bg)
                x += 2
            if len(self.img_paths) > 1 and x + 9 < self.x + self.w - 2:
                x = scr.text(x, by, "[g GIF]", pal.msg_ok, bg)
                x += 2
            if x + 12 < self.x + self.w - 2:
                x = scr.text(x, by, "[o Viewer]", pal.msg_note, bg)
                x += 2
            if x + 13 < self.x + self.w - 2:
                _ = scr.text(x, by, "[Esc Close]", ffg, bg)

    # --------------------------------------------------------------- draw
    def draw(
        self, mut scr: Screen, pal: Palette, hl: Highlighter, active: Bool, hl_line: Bool, insert_mode: Bool, show_ws: Bool
    ):
        if self.kind == WK_EDITOR or self.kind == WK_IMGVIEW:
            self.img_cache[].begin_frame()
        var is_special_ed = self.kind == WK_HEX or self.kind == WK_MDPREVIEW or self.kind == WK_IMGVIEW
        var is_msg = self.kind != WK_EDITOR and not is_special_ed       # the Message and Outline windows are lists
        var plain = is_msg or self.buf.large      # no syntax colours
        var bg = pal.msg_bg if is_msg else pal.ed_bg
        var fg = pal.msg_fg if is_msg else pal.ed_fg
        var ffg = (pal.msg_frame if is_msg else pal.frame_act) if active else pal.frame_inact
        var pd = self.pad()
        scr.fill(self.x, self.y, self.w, self.h, 32, fg, bg)
        if not self.chromeless:
            scr.frame(self.x, self.y, self.w, self.h, active, ffg, bg)
            # title
            var ro_tag = (
                String(" [HEX READ-ONLY] ")
                if self.kind == WK_HEX
                else (String(" [READ-ONLY] ") if (self.read_only and self.kind != WK_IMGVIEW) else String(""))
            )
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
        elif self.split_sep and self.w > 2:
            var sep_ch = 124 if scr.glyphs == GLYPHS_ASCII else 0x2502
            for sy in range(self.y, self.y + self.h):
                scr.put(self.x + self.w - 1, sy, sep_ch, pal.frame_inact, bg)

        if self.kind == WK_HEX:
            self.draw_hex(scr, pal, active)
            return
        if self.kind == WK_MDPREVIEW:
            self.draw_mdpreview(scr, pal, hl, active)
            return
        if self.kind == WK_IMGVIEW:
            self.draw_imgview(scr, pal, active)
            return

        var rws = self.rows()
        var cls = self.cols()
        var cx0 = self.x + pd + self.gut
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
        var lang = self.effective_lang()
        var st = self.lex_state_at(self.top)
        var inner_w = self.w - 2 * pd - (1 if (self.chromeless and self.split_sep) else 0)
        var inner_h = self.h - 2 * pd
        scr.clip(self.x + pd, self.y + pd, max(1, inner_w), max(1, inner_h))
        var classes = List[Int]()
        # with soft wrap a line can take several screen rows ("segments")
        var r = self.top
        var seg = self.top_seg if self.rowwise() else 0
        var loaded = -1
        var ln = List[Int]()
        var starts = List[Int]()
        var vs = List[Int]()
        var v_lines = List[String]()
        var v_is_err = False
        var is_nb = self.is_notebook()
        var cur_cell_hdr = self.cell_header_for_row(self.cr) if is_nb else -1
        var row_cell_hdr = -1
        for i in range(rws):
            var yy = self.y + pd + i
            if r >= self.buf.count():
                if self.chromeless and not is_msg:
                    for rem_i in range(i, rws):
                        var ryy = self.y + pd + rem_i
                        if self.gut > 0:
                            scr.fill(self.x + pd, ryy, self.gut, 1, 32, pal.gutter_fg, pal.gutter_bg)
                        _ = scr.text(self.x + pd, ryy, "~", pal.gutter_fg, pal.gutter_bg if self.gut > 0 else bg)
                break
            if loaded != r:
                ln = self.buf.line(r)
                self.wrap_layout(ln, starts, vs)
                var vres = self.virtual_out_lines_at(r)
                v_lines = vres[0].copy()
                v_is_err = vres[1]
                row_cell_hdr = self.cell_header_for_row(r) if is_nb else -1
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
                seg = max(0, min(seg, len(starts) + len(v_lines) - 1))
            if seg >= len(starts):
                var vi = seg - len(starts)
                var vline = v_lines[vi] if vi < len(v_lines) else String("")
                var card_x0 = (cx0 - 1) if self.gut > 0 else cx0
                var card_x1 = cx0 + max(12, cls - 1) - 1
                var is_cur_out = is_nb and active and row_cell_hdr >= 0 and row_cell_hdr == cur_cell_hdr
                var out_bcol = (
                    pal.diag_err
                    if v_is_err
                    else (
                        (pal.msg_note if self.nb_cmd_mode else pal.frame_act)
                        if is_cur_out
                        else mix(pal.gutter_fg, bg, 65)
                    )
                )
                if self.gut > 0:
                    scr.fill(self.x + pd, yy, self.gut, 1, 32, pal.gutter_fg, pal.gutter_bg)
                    if not is_nb:
                        if vi == 0 and self.gut >= 5 and not scr.plain:
                            var out_ec = self.cell_exec_count_for_end(r)
                            var out_lbl = ("[" + String(out_ec) + "]") if out_ec > 0 else String("Out")
                            if cp_len(out_lbl) < self.gut:
                                _ = scr.text(self.x + pd, yy, out_lbl, pal.diag_err if v_is_err else pal.msg_note, pal.gutter_bg)
                        var rail_ch = 124 if scr.glyphs == GLYPHS_ASCII else 0x2502
                        var rail_fg = pal.diag_err if v_is_err else pal.msg_ok
                        scr.put(self.x + pd + self.gut - 1, yy, rail_ch, rail_fg, pal.gutter_bg)

                var vbg = mix(pal.diag_err if v_is_err else pal.curline_bg, bg, 16 if v_is_err else (35 if is_nb else 55))
                if is_nb and not scr.plain:
                    var hz = 45 if scr.glyphs == GLYPHS_ASCII else 0x2500
                    var vt = 124 if scr.glyphs == GLYPHS_ASCII else 0x2502
                    scr.clip(self.x + pd, yy, max(1, inner_w), 1)
                    if vline.startswith(String(CELL_NB_HDR_MARK)):
                        var rest_h = String(vline[byte=String(CELL_NB_HDR_MARK).byte_length() :])
                        var hp = rest_h.split("\t")
                        var out_tag = String(hp[0]) if len(hp) > 0 else String("Out")
                        var cap_tag = String(hp[1]) if len(hp) > 1 else String("")
                        scr.fill(cx0, yy, cls, 1, 32, pal.ed_fg, bg)
                        for bx in range(card_x0, card_x1 + 1):
                            scr.put(bx, yy, hz, out_bcol, vbg)
                        scr.put(card_x0, yy, 43 if scr.glyphs == GLYPHS_ASCII else 0x251C, out_bcol, vbg)
                        scr.put(card_x1, yy, 43 if scr.glyphs == GLYPHS_ASCII else 0x2524, out_bcol, vbg)
                        var ox = scr.text(cx0 + 1, yy, " " + out_tag + " ", pal.diag_err if v_is_err else pal.msg_ok, vbg)
                        if ox > cx0 + 1:
                            scr.bold(cx0 + 1, yy, ox - (cx0 + 1))
                        if cap_tag.byte_length() > 0:
                            var cap_disp = " " + cap_tag + " "
                            var cap_x = max(ox + 2, card_x1 - 1 - cp_len(cap_disp))
                            if cap_x + cp_len(cap_disp) <= card_x1:
                                _ = scr.text(cap_x, yy, cap_disp, pal.msg_note, vbg)
                    elif vline.startswith(String(CELL_NB_SUB_MARK)):
                        var sub_cap = String(vline[byte=String(CELL_NB_SUB_MARK).byte_length() :])
                        var sub_hz = 45 if scr.glyphs == GLYPHS_ASCII else 0x254C
                        scr.fill(cx0, yy, cls, 1, 32, pal.ed_fg, bg)
                        for bx in range(card_x0, card_x1 + 1):
                            scr.put(bx, yy, sub_hz, mix(out_bcol, vbg, 55), vbg)
                        scr.put(card_x0, yy, 43 if scr.glyphs == GLYPHS_ASCII else 0x251C, out_bcol, vbg)
                        scr.put(card_x1, yy, 43 if scr.glyphs == GLYPHS_ASCII else 0x2524, out_bcol, vbg)
                        if cx0 + 2 + cp_len(sub_cap) < card_x1:
                            _ = scr.text(cx0 + 1, yy, " " + sub_cap + " ", pal.msg_note, vbg)
                    elif vline == String(CELL_NB_BOT_MARK):
                        scr.fill(cx0, yy, cls, 1, 32, pal.ed_fg, bg)
                        for bx in range(card_x0, card_x1 + 1):
                            scr.put(bx, yy, hz, out_bcol, bg)
                        scr.put(card_x0, yy, 43 if scr.glyphs == GLYPHS_ASCII else 0x2570, out_bcol, bg)
                        scr.put(card_x1, yy, 43 if scr.glyphs == GLYPHS_ASCII else 0x256F, out_bcol, bg)
                    else:
                        var vfg = pal.ed_fg
                        if v_is_err:
                            vfg = pal.diag_err
                        elif str_contains(vline, "⚠ "):
                            vfg = pal.msg_warn
                        elif vline.startswith("[") or str_contains(vline, "[Tensor ") or str_contains(vline, "[Array ") or str_contains(vline, "[SIMD ") or str_contains(vline, "[DataFrame ") or str_contains(vline, "[Polars ") or str_contains(vline, "[📊"):
                            vfg = pal.msg_note
                        elif vline.startswith("… (+"):
                            vfg = pal.gutter_fg
                        scr.fill(cx0, yy, cls, 1, 32, pal.ed_fg, bg)
                        var inner_card_w = max(1, card_x1 - cx0)
                        scr.fill(cx0, yy, inner_card_w, 1, 32, vfg, vbg)
                        scr.put(card_x0, yy, vt, out_bcol, vbg)
                        scr.put(card_x1, yy, vt, out_bcol, vbg)
                        scr.clip(cx0, yy, inner_card_w, 1)
                        if vline.startswith(String(CELL_IMG_MARK)):
                            var dec_img = decode_cell_img_line(vline)
                            if dec_img[0]:
                                self.img_cache[].draw_image_row(
                                    scr,
                                    cx0 + 2,
                                    yy,
                                    max(0, inner_card_w - 3),
                                    vbg,
                                    dec_img[1],
                                    dec_img[2],
                                    dec_img[3],
                                    dec_img[4],
                                    self.gfx_mode,
                                    self.gfx_tmux,
                                    self.gfx_cell_w,
                                    self.gfx_cell_h,
                                    r * 64 + max(0, vi - dec_img[2]),
                                    self.y + pd,
                                    self.y + pd + rws,
                                )
                        else:
                            _ = scr.text(cx0 + 1, yy, " " + vline, vfg, vbg)
                    scr.clip(self.x + pd, self.y + pd, max(1, inner_w), max(1, inner_h))
                else:
                    var vfg = pal.ed_fg
                    if v_is_err:
                        vfg = pal.diag_err
                    elif str_contains(vline, "⚠ "):
                        vfg = pal.msg_warn
                    elif vline.startswith("[") or str_contains(vline, "[Tensor ") or str_contains(vline, "[Array ") or str_contains(vline, "[SIMD ") or str_contains(vline, "[DataFrame ") or str_contains(vline, "[Polars ") or str_contains(vline, "[📊"):
                        vfg = pal.msg_note
                    elif vline.startswith("… (+"):
                        vfg = pal.gutter_fg
                    scr.clip(cx0, yy, cls, 1)
                    scr.fill(cx0, yy, cls, 1, 32, vfg, vbg)
                    if vline.startswith(String(CELL_IMG_MARK)):
                        var dec_img = decode_cell_img_line(vline)
                        if dec_img[0]:
                            self.img_cache[].draw_image_row(
                                scr,
                                cx0 + 2,
                                yy,
                                max(0, cls - 2),
                                vbg,
                                dec_img[1],
                                dec_img[2],
                                dec_img[3],
                                dec_img[4],
                                self.gfx_mode,
                                self.gfx_tmux,
                                self.gfx_cell_w,
                                self.gfx_cell_h,
                                r * 64 + max(0, vi - dec_img[2]),
                                self.y + pd,
                                self.y + pd + rws,
                            )
                    else:
                        _ = scr.text(cx0, yy, "  " + vline, vfg, vbg)
                    scr.clip(self.x + pd, self.y + pd, max(1, inner_w), max(1, inner_h))
                seg += 1
                if seg >= len(starts) + len(v_lines):
                    var nr_v = self.buf.next_row(r)
                    if nr_v != r + 1 and nr_v < self.buf.count():
                        st = self.lex_state_at(nr_v)
                    r = nr_v
                    seg = 0
                continue
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
                    scr.fill(self.x + pd, yy, max(1, inner_w), 1, 32, rowfg, rowbg)
                elif r == self.cr:
                    # the row stays visible in a window without the focus, muted
                    rowbg = mix(pal.msg_sel_bg, bg, 35)
                    scr.fill(self.x + pd, yy, max(1, inner_w), 1, 32, rowfg, rowbg)
            elif r == self.buf.exec_row:
                # the line the program being debugged is stopped at
                rowbg = pal.msg_sel_bg
                rowfg = pal.msg_sel_fg
                scr.fill(cx0, yy, cls, 1, 32, rowfg, rowbg)
            elif len(ln) >= 7 and ((ln[0] == 60 and ln[1] == 60 and ln[2] == 60 and ln[3] == 60 and ln[4] == 60 and ln[5] == 60 and ln[6] == 60) or (ln[0] == 61 and ln[1] == 61 and ln[2] == 61 and ln[3] == 61 and ln[4] == 61 and ln[5] == 61 and ln[6] == 61) or (ln[0] == 62 and ln[1] == 62 and ln[2] == 62 and ln[3] == 62 and ln[4] == 62 and ln[5] == 62 and ln[6] == 62)):
                # merge conflict delimiter banner
                rowbg = mix(pal.diag_err if ln[0] != 61 else pal.diag_warn, bg, 22)
                scr.fill(cx0, yy, cls, 1, 32, rowfg, rowbg)
            elif is_nb and self.buf.is_cell_header(r) and not scr.plain:
                var is_cur_hdr = active and r == cur_cell_hdr
                if self.is_markdown_header(r) and (not active or self.nb_cmd_mode or row_cell_hdr != cur_cell_hdr):
                    rowbg = bg
                else:
                    rowbg = mix(pal.msg_note if self.nb_cmd_mode else pal.frame_act, bg, 18 if is_cur_hdr else 0)
                    if not is_cur_hdr:
                        rowbg = mix(pal.gutter_bg, bg, 52)
                scr.fill(cx0, yy, cls, 1, 32, rowfg, rowbg)
            elif is_nb and row_cell_hdr >= 0 and r > row_cell_hdr and not self.is_markdown_header(row_cell_hdr) and not scr.plain:
                rowbg = (
                    pal.curline_bg
                    if (hl_line and active and r == self.cr and not self.nb_cmd_mode)
                    else mix(pal.gutter_bg, bg, 40)
                )
                scr.fill(cx0, yy, cls, 1, 32, rowfg, rowbg)
            elif hl_line and active and r == self.cr and not (is_nb and self.nb_cmd_mode):
                rowbg = pal.curline_bg
                scr.fill(cx0, yy, cls, 1, 32, rowfg, rowbg)
            var render_md_cell = (
                is_nb
                and not scr.plain
                and seg == 0
                and off == 0
                and not self.has_sel()
                and row_cell_hdr >= 0
                and r > row_cell_hdr
                and self.is_markdown_header(row_cell_hdr)
                and (not active or self.nb_cmd_mode or row_cell_hdr != cur_cell_hdr or (self.cr == row_cell_hdr and self.cc == 0))
            )
            var render_md_hdr = (
                is_nb
                and not scr.plain
                and seg == 0
                and off == 0
                and not self.has_sel()
                and self.buf.is_cell_header(r)
                and self.is_markdown_header(r)
                and (not active or self.nb_cmd_mode or row_cell_hdr != cur_cell_hdr or (self.cr == row_cell_hdr and self.cc == 0))
            )
            var render_code_hdr = (
                is_nb
                and not scr.plain
                and seg == 0
                and off == 0
                and not self.has_sel()
                and self.buf.is_cell_header(r)
                and not self.is_markdown_header(r)
                and not (active and not self.nb_cmd_mode and r == self.cr and self.cc > 0)
            )
            if self.gut > 0:
                if render_md_cell or render_md_hdr:
                    scr.fill(self.x + pd, yy, self.gut, 1, 32, pal.gutter_fg, pal.gutter_bg)
                    if active and row_cell_hdr >= 0 and row_cell_hdr == cur_cell_hdr and self.nb_cmd_mode:
                        var crail_m = 124 if scr.glyphs == GLYPHS_ASCII else 0x2503
                        scr.put(self.x + pd + self.gut - 1, yy, crail_m, pal.msg_note, pal.gutter_bg)
                else:
                    var num = String(r + 1) if seg == 0 else String("")
                    if seg == 0 and self.rel_nums and r != self.cr and not is_msg:
                        num = String(r - self.cr if r > self.cr else self.cr - r)
                    var fold_mark = 32
                    if seg == 0 and not is_msg:
                        if self.buf.fold_index(r) >= 0:
                            fold_mark = 0x25B8
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
                        num_fg = pal.diag_err
                    elif sev == 2:
                        num_fg = pal.diag_warn
                    elif sev > 2:
                        num_fg = pal.diag_note
                    _ = scr.text(self.x + pd, yy, s, num_fg, pal.gutter_bg)
                    if seg == 0 and sev > 0 and pad >= 1:
                        scr.put(self.x + pd, yy, 69 if sev == 1 else (87 if sev == 2 else 105), num_fg, pal.gutter_bg)
                    elif seg == 0 and not is_msg and pad >= 1 and len(self.test_lens_rows) > 0:
                        for tli in range(len(self.test_lens_rows)):
                            if self.test_lens_rows[tli] == r and tli < len(self.test_lens_states):
                                var ts = self.test_lens_states[tli]
                                var tch = 0x2713 if ts == 2 else (0x2717 if ts == 3 else 0x25B7)
                                var tfg = pal.msg_ok if ts == 2 else (pal.diag_err if ts == 3 else pal.gutter_fg)
                                scr.put(self.x + pd, yy, tch, tfg, pal.gutter_bg)
                                break
                    elif seg == 0 and not is_msg and pad >= 1 and len(self.cov_rows) > 0:
                        for cvi in range(len(self.cov_rows)):
                            if self.cov_rows[cvi] == r:
                                var cs = self.cov_states[cvi] if cvi < len(self.cov_states) else 0
                                var cch = 0x2713 if cs > 0 else 0x00B7
                                var cfg_cov = pal.msg_ok if cs > 0 else pal.diag_err
                                scr.put(self.x + pd, yy, cch, cfg_cov, pal.gutter_bg)
                                break
                    if seg == 0 and not is_msg and len(self.buf.bps) > 0:
                        var look = self.buf.bp_look(r)
                        if look == 1 or look == 3:
                            _ = scr.text(self.x + pd, yy, s, pal.gutter_bg, pal.diag_err)
                            if pad >= 1:
                                scr.put(self.x + pd, yy, 0x25CF if look == 1 else 0x25C6, pal.gutter_bg, pal.diag_err)
                        elif look > 0:
                            _ = scr.text(self.x + pd, yy, s, pal.diag_err, pal.gutter_bg)
                            if pad >= 1:
                                scr.put(self.x + pd, yy, 0x25CB if look == 2 else 0x25CC, pal.diag_err, pal.gutter_bg)
                    if git_col and seg == 0 and r < len(self.buf.git_marks) and self.buf.git_marks[r] != LM_NONE:
                        var gm = Int(self.buf.git_marks[r])
                        var gch = 0x2B if gm == LM_ADDED else (0x7E if gm == LM_CHANGED else (0x203E if gm == LM_DELETED_ABOVE else 0x5F))
                        var gfg = pal.git_add if gm == LM_ADDED else (pal.git_mod if gm == LM_CHANGED else pal.git_del)
                        scr.put(self.x + pd + self.gut - 2, yy, gch, gfg, pal.gutter_bg)
                    if seg == 0 and r == self.buf.exec_row:
                        scr.put(self.x + pd + self.gut - 1, yy, 0x25BA, pal.msg_sel_bg, pal.gutter_bg)
                    elif is_nb and seg == 0 and self.buf.is_cell_header(r) and self.gut >= 5 and not scr.plain:
                        if render_code_hdr:
                            scr.fill(self.x + pd, yy, self.gut - 1, 1, 32, pal.gutter_fg, pal.gutter_bg)
                            if fold_mark != 32:
                                scr.put(self.x + pd + self.gut - 2, yy, fold_mark, pal.frame_act if fold_mark == 0x25B8 else pal.gutter_fg, pal.gutter_bg)
                        else:
                            var prompt_lbl: String
                            var prompt_fg: Int
                            if self.is_markdown_header(r):
                                prompt_lbl = " MD "
                                prompt_fg = pal.msg_note
                            else:
                                var is_running_cell = False
                                for cbi in range(len(self.buf.cell_badge_rows)):
                                    if self.buf.cell_badge_rows[cbi] == r and cbi < len(self.buf.cell_badges) and (str_contains(self.buf.cell_badges[cbi], "running") or str_contains(self.buf.cell_badges[cbi], "queued")):
                                        is_running_cell = True
                                        break
                                var ec_h = self.cell_exec_count_at_header(r)
                                if is_running_cell:
                                    prompt_lbl = "[*]"
                                    prompt_fg = pal.msg_warn
                                elif ec_h > 0:
                                    prompt_lbl = "[" + String(ec_h) + "]"
                                    prompt_fg = pal.msg_ok
                                else:
                                    prompt_lbl = "[ ]"
                                    prompt_fg = pal.frame_act
                            scr.fill(self.x + pd, yy, self.gut - 1, 1, 32, prompt_fg, pal.gutter_bg)
                            var px1 = scr.text(self.x + pd, yy, prompt_lbl, prompt_fg, pal.gutter_bg)
                            if px1 > self.x + pd:
                                scr.bold(self.x + pd, yy, px1 - (self.x + pd))
                    elif fold_mark != 32:
                        scr.put(self.x + pd + self.gut - 1, yy, fold_mark, pal.frame_act if fold_mark == 0x25B8 else pal.gutter_fg, pal.gutter_bg)
                    if is_nb and active and row_cell_hdr >= 0 and row_cell_hdr == cur_cell_hdr and not scr.plain and not render_code_hdr:
                        var crail = 124 if scr.glyphs == GLYPHS_ASCII else 0x2503
                        var crail_fg = pal.msg_note if self.nb_cmd_mode else pal.msg_ok
                        scr.put(self.x + pd + self.gut - 1, yy, crail, crail_fg, pal.gutter_bg)
            var n = len(ln)
            scr.clip(cx0, self.y + pd, cls, max(1, inner_h))
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
            if render_md_hdr:
                var md_title = self.clean_cell_title(r)
                var mx_end = cx0
                if md_title.byte_length() > 0:
                    mx_end = scr.text(cx0, yy, md_title, pal.msg_note, rowbg)
                    if mx_end > cx0:
                        scr.bold(cx0, yy, mx_end - cx0)
                if active and row_cell_hdr == cur_cell_hdr and self.nb_cmd_mode:
                    var m_pill = "[Markdown · Enter to edit]"
                    var m_px = max(mx_end + 2, cx0 + max(0, cls - 2 - cp_len(m_pill)))
                    if m_px + cp_len(m_pill) < cx0 + cls:
                        _ = scr.text(m_px, yy, m_pill, pal.gutter_fg, rowbg)
            elif render_code_hdr:
                var card_x0 = (cx0 - 1) if self.gut > 0 else cx0
                var card_x1 = cx0 + max(12, cls - 1) - 1
                var is_cur_c = active and r == cur_cell_hdr
                var cbcol = (
                    (pal.msg_note if self.nb_cmd_mode else pal.frame_act)
                    if is_cur_c
                    else mix(pal.gutter_fg, bg, 68)
                )
                var hz_c = 45 if scr.glyphs == GLYPHS_ASCII else 0x2500
                var is_fold_hdr = self.buf.fold_index(r) >= 0 and len(v_lines) == 0
                scr.clip(self.x + pd, yy, max(1, inner_w), 1)
                scr.fill(cx0, yy, cls, 1, 32, pal.ed_fg, bg)
                for bx in range(card_x0, card_x1 + 1):
                    scr.put(bx, yy, hz_c, cbcol, rowbg)
                scr.put(card_x0, yy, 43 if scr.glyphs == GLYPHS_ASCII else (0x2550 if is_fold_hdr else 0x256D), cbcol, rowbg)
                scr.put(card_x1, yy, 43 if scr.glyphs == GLYPHS_ASCII else (0x2550 if is_fold_hdr else 0x256E), cbcol, rowbg)
                var is_run_hdr = False
                for cbi in range(len(self.buf.cell_badge_rows)):
                    if self.buf.cell_badge_rows[cbi] == r and cbi < len(self.buf.cell_badges) and (
                        str_contains(self.buf.cell_badges[cbi], "running")
                        or str_contains(self.buf.cell_badges[cbi], "queued")
                    ):
                        is_run_hdr = True
                        break
                var ec_c = self.cell_exec_count_at_header(r)
                var in_lbl = " In [*] " if is_run_hdr else ((" In [" + String(ec_c) + "] ") if ec_c > 0 else String(" In [ ] "))
                var in_fg = pal.msg_warn if is_run_hdr else (pal.msg_ok if ec_c > 0 else pal.frame_act)
                var lx = scr.text(cx0 + 1, yy, in_lbl, in_fg, rowbg)
                if lx > cx0 + 1:
                    scr.bold(cx0 + 1, yy, lx - (cx0 + 1))
                var spans_c = self.nb_card_action_spans(r)
                var fold_x0 = spans_c[0]
                var run_x0 = spans_c[2]
                var run_x1 = spans_c[3]
                var fold_pill = spans_c[4]
                var run_pill = spans_c[5]
                var stat_pill = spans_c[6]
                var right_stop = fold_x0 if fold_x0 >= 0 else run_x0
                var ctitle = self.clean_cell_title(r)
                if ctitle.byte_length() > 0 and lx + 3 < right_stop:
                    var max_t = max(1, right_stop - (lx + 3))
                    var tcps = decode(ctitle)
                    if len(tcps) > max_t:
                        ctitle = slice_str(tcps, 0, max(1, max_t - 1)) + "…"
                    var tx0 = lx + 1
                    var tx1 = scr.text(tx0, yy, " " + ctitle + " ", pal.title_fg, rowbg)
                    if tx1 > tx0:
                        scr.bold(tx0, yy, tx1 - tx0)
                if fold_x0 >= 0 and fold_pill.byte_length() > 0:
                    var fp_fg = pal.msg_note if self.buf.fold_index(r) >= 0 else pal.gutter_fg
                    var fx1 = scr.text(fold_x0, yy, fold_pill, fp_fg, rowbg)
                    if self.buf.fold_index(r) >= 0 and fx1 > fold_x0:
                        scr.bold(fold_x0, yy, fx1 - fold_x0)
                var rx1 = scr.text(run_x0, yy, run_pill, pal.frame_act, rowbg)
                if is_cur_c and rx1 > run_x0:
                    scr.bold(run_x0, yy, rx1 - run_x0)
                if stat_pill.byte_length() > 0 and run_x1 + cp_len(stat_pill) <= card_x1:
                    var sfg = (
                        pal.msg_ok
                        if str_contains(stat_pill, "✓")
                        else (pal.diag_err if str_contains(stat_pill, "✗") else pal.msg_warn)
                    )
                    _ = scr.text(run_x1, yy, stat_pill, sfg, rowbg)
                scr.clip(cx0, self.y + pd, cls, max(1, inner_h))
            elif render_md_cell:
                var md_raw_ln = to_str(ln)
                var md_raw = md_raw_ln
                if md_raw_ln.startswith("# "):
                    md_raw = String(md_raw_ln[byte=2:])
                elif md_raw_ln == "#":
                    md_raw = ""
                _draw_nb_markdown_line(scr, cx0, yy, cls, md_raw, pal, rowbg)
            for c in range(s0, 0 if (render_md_cell or render_md_hdr or render_code_hdr) else s1):
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
            if render_code_hdr or render_md_hdr:
                pass
            elif fi >= 0 and s1 == n and fi < len(self.buf.fold_ends) and v + 2 >= off and v + 2 < lim:
                var hidden = self.buf.fold_ends[fi] - r
                _ = scr.text(cx0 + v + 1 - off, yy, " ⋯ " + String(hidden) + (" line " if hidden == 1 else " lines "), pal.gutter_fg, pal.gutter_bg)
            elif s1 == n and not is_msg and v + 2 >= off and v + 4 < lim:
                var eol_x = cx0 + v + 2 - off
                if active and r == self.cr and r == self.ghost_row and self.cc == n and self.ghost_text.byte_length() > 0 and not scr.plain:
                    var gline = String(self.ghost_text.split("\n")[0])
                    if gline.byte_length() > 0:
                        var gx0 = max(cx0, cx0 + v - off)
                        var gend = scr.text(gx0, yy, gline, pal.gutter_fg, rowbg)
                        if gend > gx0:
                            scr.italic(gx0, yy, gend - gx0)
                            scr.dim(gx0, yy, gend - gx0)
                            eol_x = max(eol_x, gend + 2)
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
                var use_buf_cb = len(self.buf.cell_badge_rows) > 0
                var cb_rows_n = len(self.buf.cell_badge_rows) if use_buf_cb else len(self.cell_badge_rows)
                if cb_rows_n > 0 and not scr.plain and eol_x + 8 < cx0 + cls:
                    for cbi in range(cb_rows_n):
                        var cbr = self.buf.cell_badge_rows[cbi] if use_buf_cb else self.cell_badge_rows[cbi]
                        var cbn = len(self.buf.cell_badges) if use_buf_cb else len(self.cell_badges)
                        if cbr == r and cbi < cbn:
                            if use_buf_cb and r > 0 and not self.buf.is_cell_header(r):
                                break
                            var cb = String(self.buf.cell_badges[cbi] if use_buf_cb else self.cell_badges[cbi])
                            if cb.byte_length() > 0:
                                var cbfg = (
                                    pal.msg_ok
                                    if str_contains(cb, "✓")
                                    else (pal.diag_err if str_contains(cb, "✗") else pal.msg_note)
                                )
                                if is_nb and not self.is_markdown_header(r) and eol_x + 9 < cx0 + cls:
                                    eol_x = scr.text(eol_x, yy, "  [▶ Run]", pal.frame_act, rowbg)
                                if eol_x + 6 < cx0 + cls:
                                    eol_x = scr.text(eol_x, yy, (" " + cb) if is_nb else ("  " + cb), cbfg, rowbg)
                                drew_cell = True
                            break
                if not drew_cell and (lang == HL_MOJO or lang == HL_PYTHON) and self.buf.is_cell_header(r) and not scr.plain and eol_x + 18 < cx0 + cls:
                    if is_nb:
                        if self.is_markdown_header(r):
                            var md_hint = "  [Markdown · Enter to edit]" if (self.nb_cmd_mode or row_cell_hdr != cur_cell_hdr) else "  [Markdown · Shift-Enter renders]"
                            eol_x = scr.text(eol_x, yy, md_hint, pal.gutter_fg, rowbg)
                        else:
                            eol_x = scr.text(eol_x, yy, "  [▶ Run · Shift-Enter]", pal.frame_act, rowbg)
                    else:
                        eol_x = scr.text(eol_x, yy, "  [Ctrl-Enter: Run Cell]", pal.msg_note, rowbg)
                if len(self.bench_badge_rows) > 0 and not scr.plain and eol_x + 8 < cx0 + cls:
                    for bbi in range(len(self.bench_badge_rows)):
                        if self.bench_badge_rows[bbi] == r and bbi < len(self.bench_badges):
                            var bb = String(self.bench_badges[bbi])
                            if bb.byte_length() > 0:
                                var bbfg = (
                                    pal.diag_err
                                    if str_contains(bb, "▓")
                                    else (pal.msg_warn if str_contains(bb, "▒") else pal.msg_ok)
                                )
                                eol_x = scr.text(eol_x, yy, "  " + bb, bbfg, rowbg)
                            break
                if (lang == HL_MOJO or lang == HL_PYTHON) and not scr.plain and eol_x + 16 < cx0 + cls:
                    var raw_wln = to_str(ln)
                    if str_contains(raw_wln, "@param") or str_contains(raw_wln, "@interact"):
                        var wlist = parse_cell_widgets(self.buf, r, r)
                        if len(wlist) > 0:
                            var wbar = format_widget_bar(wlist[0], 12)
                            if eol_x + cp_len(wbar) + 2 < cx0 + cls:
                                eol_x = scr.text(eol_x, yy, "  " + wbar, pal.msg_note, rowbg)
                if active and r == self.cr and r == self.inline_blame_row and self.inline_blame.byte_length() > 0 and not scr.plain and eol_x + 4 < cx0 + cls:
                    var bx0 = eol_x
                    var bend = scr.text(eol_x, yy, "  " + self.inline_blame, pal.gutter_fg, rowbg)
                    if bend > bx0:
                        scr.italic(bx0, yy, bend - bx0)
                        scr.dim(bx0, yy, bend - bx0)
            scr.clip(self.x + pd, self.y + pd, max(1, inner_w), max(1, inner_h))
            if (
                is_nb
                and not scr.plain
                and off == 0
                and row_cell_hdr >= 0
                and r > row_cell_hdr
                and not self.is_markdown_header(row_cell_hdr)
            ):
                var card_x0 = (cx0 - 1) if self.gut > 0 else cx0
                var card_x1 = cx0 + max(12, cls - 1) - 1
                var is_cur_b = active and row_cell_hdr == cur_cell_hdr
                var bbcol = (
                    (pal.msg_note if self.nb_cmd_mode else pal.frame_act)
                    if is_cur_b
                    else mix(pal.gutter_fg, bg, 68)
                )
                var nr_chk = self.buf.next_row(r)
                var is_cell_last = (
                    len(v_lines) == 0
                    and seg == len(starts) - 1
                    and (nr_chk >= self.buf.count() or self.buf.is_cell_header(nr_chk))
                )
                if card_x1 + 1 < cx0 + cls:
                    scr.fill(card_x1 + 1, yy, (cx0 + cls) - (card_x1 + 1), 1, 32, pal.ed_fg, bg)
                if is_cell_last and n == 0 and not (active and r == self.cr and not self.nb_cmd_mode):
                    var hz_b = 45 if scr.glyphs == GLYPHS_ASCII else 0x2500
                    for bx in range(card_x0, card_x1 + 1):
                        scr.put(bx, yy, hz_b, bbcol, bg)
                    scr.put(card_x0, yy, 43 if scr.glyphs == GLYPHS_ASCII else 0x2570, bbcol, bg)
                    scr.put(card_x1, yy, 43 if scr.glyphs == GLYPHS_ASCII else 0x256F, bbcol, bg)
                elif is_cell_last:
                    scr.put(card_x0, yy, 43 if scr.glyphs == GLYPHS_ASCII else 0x2570, bbcol, rowbg)
                    scr.put(card_x1, yy, 43 if scr.glyphs == GLYPHS_ASCII else 0x256F, bbcol, rowbg)
                else:
                    var vt_b = 124 if scr.glyphs == GLYPHS_ASCII else 0x2502
                    scr.put(card_x0, yy, vt_b, bbcol, rowbg)
                    scr.put(card_x1, yy, vt_b, bbcol, rowbg)
            seg += 1
            if seg >= len(starts) + len(v_lines):
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
            if cell.c >= self.x + pd + self.gut and cell.c < self.x + self.w - pd and cell.r >= self.y + pd and cell.r < self.y + self.h - pd:
                scr.set_bg(cell.c, cell.r, mix(fg, bg, 40))
        if not is_msg and len(self.sticky) > 0:
            self.draw_sticky(scr, pal, cx0, cls)
        if not is_msg and self.minimap and not scr.plain:
            self.draw_minimap(scr, pal, rws)

        if self.chromeless:
            return
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
