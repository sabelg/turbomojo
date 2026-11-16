"""Phase 21–25 IDE integration (`v3.1` → `v4.0.0`).

Provides:
- Interactive `# @param` / `@interact` notebook widgets, virtualized `WK_DATAGRID` table & heatmap
  window, pure-Mojo GIF89a animation export, and external Jupyter `ipykernel` connection
- 2-char Flash / Leap cross-pane jump beacons, Harpoon `1..4` quick-marks, `g;`/`g,` change-list,
  and live Vim register preview popup
- Interactive `WK_PROFILE` Flamegraph & Multi-Stream GPU Timeline window, per-line stall badges,
  and `LayoutTensor` 32-lane coalescing / XOR-swizzle + MAX `Graph` fusion inspector
- Multimodal Notebook AI vision context, isolated `git worktree` verified task runner, and local
  hybrid `mojocst` AST + BM25 semantic codebase search
- Standalone self-contained HTML5 notebook export and zero-server `AF_UNIX` collaborative Live Share
"""
from std.collections import List
from appstate import *
from buffer import TextBuffer, Pos
from cellimg import is_anim_spec, parse_anim_spec
from cells import parse_cells, cell_at_row
from commands import *
from dialog import (
    Dialog,
    Field,
    NEXT_CLOSE,
    D_HARPOON,
    D_SEMANTIC_SEARCH,
    D_WORKTREE_TASK,
    D_LIVE_SHARE,
    D_EXPORT_HTML,
    D_CONNECT_KERNEL,
    D_SAVE_GIF,
)
from grep import collect_search_files, is_binary, MAX_FILE_BYTES
from highlight import HL_MOJO, HL_PYTHON
from ipynb import is_ipynb_path
from lsp import WorkspaceEdit, FileEdits, LspEdit, col_to_utf16
from palette import mix
from term import (
    KEY_ESC,
    KEY_ENTER,
    KEY_BACKSPACE,
    KEY_TAB,
    KEY_UP,
    KEY_DOWN,
    KEY_LEFT,
    KEY_RIGHT,
    KEY_PGUP,
    KEY_PGDN,
    KEY_HOME,
    KEY_END,
    MOD_CTRL,
    MOD_ALT,
    KEY_MASK,
    K_BASE,
)
from util import *
from app_dialogs import *
from app_files import *
from app_jobs import *
from app_layout import *
from app_menus import *
from app_nav import *
from app_outline import *
from app_vim import *
from vim import VM_NORMAL, VM_VISUAL, VM_VLINE, VM_BLOCK, KEYMAP_VIM
from vim_motion import motion_span, VimMove, VK_EXCL
from window import (
    Window,
    WK_EDITOR,
    WK_IMGVIEW,
    WK_DATAGRID,
    WK_PROFILE,
    WK_CODEGEN,
    RM_NONE,
    RM_OK,
    RM_WARN,
    RM_ERROR,
    RM_DIM,
)
from nb_widgets import (
    parse_cell_widgets,
    step_widget_value,
    set_widget_ratio,
    rewrite_widget_line,
    format_widget_bar,
    parse_delimited_grid,
    save_png_frames_as_gif,
)
from vim_cst import (
    FlashTarget,
    find_flash_targets_in_lines,
    assign_flash_labels,
    HarpoonList,
)
from gpu_profiler import (
    LineStallAnnotation,
    parse_ncu_source_csv,
    parse_rocprof_trace_lines,
    analyze_static_asm_stalls,
    parse_chrome_trace_json,
    parse_folded_stacks,
    parse_layout_from_mojo_source,
    render_max_graph_fusion,
)
from nb_ai_rag import (
    NotebookAiContext,
    build_notebook_ai_context,
    create_isolated_worktree,
    collect_worktree_patches,
    verify_worktree_mojo_file,
    cleanup_isolated_worktree,
    SemanticCodeIndex,
)
from nb_export_share import (
    HtmlCellView,
    render_notebook_cells_html,
    export_ipynb_file_to_html,
    LiveShareEvent,
    LS_OFF,
    LS_HOST,
    LS_CLIENT,
)


def stem_without_ext(path: String) -> String:
    if path.byte_length() == 0:
        return "notebook"
    var dot = path.rfind(".")
    var slash = path.rfind("/")
    if dot > slash and dot > 0:
        return String(path[byte=0:dot])
    return path


def extract_matrix_or_csv_from_output(out_txt: String, fallback_title: String) -> Tuple[String, String]:
    """Extract tabular CSV/TSV/JSON/2D-array lines from a notebook cell output or synthesize
    an inspectable numeric slice from a `[Tensor ...]` / `[DataFrame ...]` summary card."""
    var trimmed = String(out_txt.strip())
    if trimmed.byte_length() == 0:
        return (fallback_title, "col_0,col_1,col_2,col_3\n0.0,1.0,2.0,3.0\n4.0,5.0,6.0,7.0")
    if trimmed.startswith("[[") or trimmed.startswith("[{") or (trimmed.find(",") > 0 and trimmed.find("\n") > 0 and not trimmed.startswith("[Tensor") and not trimmed.startswith("[DataFrame")):
        return (fallback_title, trimmed)
    var csv_lines = List[String]()
    var card_line = String("")
    for raw_ln in trimmed.split("\n"):
        var ln = String(raw_ln.strip())
        if ln.byte_length() == 0:
            continue
        if ln.startswith("[Tensor") or ln.startswith("[Array") or ln.startswith("[DataFrame") or ln.startswith("[Polars") or ln.startswith("[SIMD") or (ln.find(": [Tensor") > 0) or (ln.find(": [DataFrame") > 0):
            if card_line.byte_length() == 0:
                card_line = ln
        elif ln.find(",") > 0 or ln.find("\t") > 0:
            csv_lines.append(ln)
    if len(csv_lines) >= 2:
        return (fallback_title, "\n".join(csv_lines))
    if card_line.byte_length() > 0:
        # Build an inspectable summary + synthetic distribution grid from card metadata
        var min_v: Float64 = -1.0
        var max_v: Float64 = 1.0
        var mean_v: Float64 = 0.0
        var has_nan = card_line.find("NaN") >= 0
        for part_s in card_line.split(" "):
            var ps = String(part_s.strip())
            if ps.startswith("min="):
                var vs = String(ps[byte=4:].rstrip(",]"))
                try:
                    min_v = atof(vs)
                except:
                    pass
            elif ps.startswith("max="):
                var vs2 = String(ps[byte=4:].rstrip(",]"))
                try:
                    max_v = atof(vs2)
                except:
                    pass
            elif ps.startswith("mean="):
                var vs3 = String(ps[byte=5:].rstrip(",]"))
                try:
                    mean_v = atof(vs3)
                except:
                    pass
        var rows_s = List[String]()
        rows_s.append("row,c0,c1,c2,c3,c4,c5,c6,c7")
        var span = max_v - min_v
        if span == 0.0:
            span = 1.0
        for r in range(16):
            var cells_r = List[String]()
            cells_r.append("r" + String(r))
            for c in range(8):
                if has_nan and r == 3 and c == 4:
                    cells_r.append("NaN")
                else:
                    var t = Float64((r * 8 + c) % 64) / 63.0
                    var v = min_v + span * (0.65 * t + 0.35 * Float64((r + c) % 7) / 6.0)
                    if r == 0 and c == 0:
                        v = min_v
                    elif r == 15 and c == 7:
                        v = max_v
                    elif r == 7 and c == 3:
                        v = mean_v
                    var iv = Int(v * 1000.0)
                    var whole = iv // 1000
                    var frac = abs(iv % 1000)
                    var fpad = ("00" if frac < 10 else ("0" if frac < 100 else "")) + String(frac)
                    cells_r.append(String(whole) + "." + fpad)
            rows_s.append(",".join(cells_r))
        return (card_line, "\n".join(rows_s))
    return (fallback_title, trimmed)


__extension App:
    # ========================================================================
    # Phase 21: Interactive Widgets, WK_DATAGRID, GIF89a & External ipykernel
    # ========================================================================
    def step_notebook_widget_at(mut self, wi: Int, row: Int, delta: Int, ratio: Float64 = -1.0, rerun: Bool = True) raises -> Bool:
        """Adjust `# @param` / `@interact` widget on `row` by `delta` steps (or `[0..1]` `ratio`),
        rewrite the literal in place, and optionally re-execute the cell live."""
        if wi < 0 or wi >= len(self.wins) or self.wins[wi].kind != WK_EDITOR or self.wins[wi].read_only:
            return False
        if row < 0 or row >= self.wins[wi].buf.count():
            return False
        var wlist = parse_cell_widgets(self.wins[wi].buf, row, row)
        if len(wlist) == 0:
            return False
        var w = wlist[0].copy()
        if ratio >= 0.0:
            set_widget_ratio(w, ratio)
        else:
            step_widget_value(w, delta)
        var orig_ln = to_str(self.wins[wi].buf.line(row))
        var new_ln = rewrite_widget_line(orig_ln, w)
        if new_ln != orig_ln:
            var g = self.wins[wi].new_group()
            _ = self.wins[wi].buf.delete(row, 0, row, self.wins[wi].buf.llen(row), self.wins[wi].cr, self.wins[wi].cc, g)
            _ = self.wins[wi].buf.insert(row, 0, decode(new_ln), self.wins[wi].cr, self.wins[wi].cc, g)
            self.wins[wi].break_group()
            self.wins[wi].cc = min(self.wins[wi].cc, self.wins[wi].buf.llen(row))
            self.sync_shared_buffers(wi)
        self.say(format_widget_bar(w, 16))
        if rerun and (self.wins[wi].is_notebook() or self.wins[wi].has_cells()) and self.trust_ok():
            var prev_cr = self.wins[wi].cr
            self.wins[wi].cr = row
            self.run_code_cell(False)
            self.wins[wi].cr = min(prev_cr, self.wins[wi].buf.count() - 1)
        return True

    def datagrid_index(self) -> Int:
        for i in range(len(self.wins)):
            if self.wins[i].kind == WK_DATAGRID:
                return i
        return -1

    def datagrid_refresh_buffer(mut self):
        var di = self.datagrid_index()
        if di < 0:
            return
        var cols_w = max(40, self.wins[di].w - 4)
        var rows_h = max(8, self.wins[di].h - 2)
        var lines = self.datagrid.render_summary_lines(cols_w, rows_h)
        var cps = List[Int]()
        var marks = List[Int]()
        for k in range(len(lines)):
            if k > 0:
                cps.append(10)
            for c in decode(lines[k]):
                cps.append(c)
            if k == 0:
                marks.append(RM_OK)
            elif k == 1:
                marks.append(RM_DIM)
            else:
                marks.append(RM_NONE)
        self.wins[di].buf.load(cps)
        self.wins[di].row_marks = marks^
        self.wins[di].buf.modified = False
        self.wins[di].read_only = True
        self.wins[di].top = 0
        self.wins[di].cr = min(max(0, 2 + (self.datagrid.cursor_row - self.datagrid.scroll_row)), max(0, self.wins[di].buf.count() - 1))
        var hm_lbl = " [Heatmap ON]" if self.datagrid.heatmap_mode else ""
        self.wins[di].title = "DataGrid · " + self.datagrid.title + hm_lbl

    def open_datagrid_window(mut self, custom_title: String = "", custom_data: String = ""):
        """Open or focus the virtualized `WK_DATAGRID` table & 2D heatmap window."""
        var title = custom_title
        var payload = custom_data
        var sep = String(",")
        if payload.byte_length() == 0:
            var ei = self.top_editor()
            if ei >= 0:
                var p = self.wins[ei].path
                var low_p = lower_str(p)
                if self.wins[ei].has_sel():
                    payload = to_str(self.wins[ei].selected_text())
                    title = basename(p) if p.byte_length() > 0 else self.wins[ei].title
                elif low_p.endswith(".csv") or low_p.endswith(".tsv"):
                    payload = to_str(self.wins[ei].buf.all_text())
                    title = basename(p)
                    if low_p.endswith(".tsv"):
                        sep = "\t"
                else:
                    var cells = parse_cells(self.wins[ei].buf)
                    var ci = cell_at_row(cells, self.wins[ei].cr)
                    var out_txt = String("")
                    if ci >= 0 and ci < len(cells):
                        var hrow = cells[ci].header_row if cells[ci].header_row >= 0 else 0
                        for oi in range(len(self.wins[ei].buf.cell_out_rows)):
                            if self.wins[ei].buf.cell_out_rows[oi] == hrow and oi < len(self.wins[ei].buf.cell_out_texts):
                                out_txt = self.wins[ei].buf.cell_out_texts[oi]
                                break
                        title = cells[ci].title if cells[ci].title.byte_length() > 0 else ("Cell " + String(ci + 1))
                    var extracted = extract_matrix_or_csv_from_output(out_txt, title if title.byte_length() > 0 else String("Tensor Slice"))
                    title = extracted[0]
                    payload = extracted[1]
            else:
                title = "Demo Tensor [16x4]"
                payload = "idx,loss,grad_norm,throughput\n0,1.842,0.92,118.4\n1,1.215,0.61,124.1\n2,0.743,0.38,129.8\n3,0.412,0.19,131.2"
        if payload.find("\t") > 0 and payload.find(",") < 0:
            sep = "\t"
        self.datagrid = parse_delimited_grid(title if title.byte_length() > 0 else String("DataGrid"), payload, sep)
        self.datagrid.heatmap_mode = True
        var di = self.datagrid_index()
        if di < 0:
            var ww = max(48, min(self.scr.w - 6, (self.scr.w * 84) // 100))
            var wh = max(14, min(self.desk_h() - 2, (self.desk_h() * 82) // 100))
            var wx = max(1, (self.scr.w - ww) // 2)
            var wy = max(1, 1 + (self.desk_h() - wh) // 2)
            var w = Window(WK_DATAGRID, "DataGrid", "", wx, wy, ww, wh, 0)
            w.read_only = True
            self.wins.append(w^)
            di = len(self.wins) - 1
        self.focus(di)
        self.datagrid_refresh_buffer()
        self.say("DataGrid: ↑↓←→ move, s/Enter sort column, m toggle heatmap, e export CSV, Esc close")

    def datagrid_draw(mut self, wi: Int, active: Bool):
        """Overlay Viridis-style truecolor numeric heatmap shading & active cell cursor in `WK_DATAGRID`."""
        if wi < 0 or wi >= len(self.wins) or self.scr.plain:
            return
        var wx = self.wins[wi].x + 1
        var wy = self.wins[wi].y + 1
        var ww = max(1, self.wins[wi].w - 2)
        var wh = max(1, self.wins[wi].h - 2)
        var n_cols = len(self.datagrid.headers)
        var n_vis_rows = len(self.datagrid.filtered_indices)
        if n_cols == 0 or n_vis_rows == 0:
            return
        self.datagrid_refresh_buffer()
        self.wins[wi].draw(self.scr, self.pal, self.hl, active, False, False, False)
        if not self.datagrid.heatmap_mode:
            return
        # Shade visible numeric cells rows starting after header + sparkline + separator rows
        var data_y0 = wy + 3
        var max_data_rows = max(0, wh - 4)
        for vr in range(min(max_data_rows, max(0, n_vis_rows - self.datagrid.scroll_row))):
            var view_row = self.datagrid.scroll_row + vr
            var sy = data_y0 + vr
            if sy >= wy + wh - 1:
                break
            var sx = wx + 1
            # Skip row-index prefix column up to first `│`
            while sx < wx + ww - 1 and self.scr.ch[sy * self.scr.w + sx] != 0x2502 and self.scr.ch[sy * self.scr.w + sx] != 124:
                sx += 1
            if sx < wx + ww - 1:
                sx += 1
            for c in range(self.datagrid.scroll_col, n_cols):
                var cw = self.datagrid.col_widths[c] if c < len(self.datagrid.col_widths) else 10
                var cell_span = min(cw + 2, max(0, (wx + ww - 1) - sx))
                if cell_span <= 0:
                    break
                var hm = self.datagrid.heatmap_cell_rgb(view_row, c)
                var is_cur = view_row == self.datagrid.cursor_row and c == self.datagrid.cursor_col
                if hm[0]:
                    var rgb_bg = (hm[1] << 16) | (hm[2] << 8) | hm[3]
                    if is_cur:
                        rgb_bg = mix(0xFFFFFF, rgb_bg, 28)
                    for cx in range(sx, sx + cell_span):
                        if self.scr.ch[sy * self.scr.w + cx] != 0x2502 and self.scr.ch[sy * self.scr.w + cx] != 124:
                            self.scr.set_bg(cx, sy, rgb_bg)
                            self.scr.set_fg(cx, sy, 0xF4F7FA)
                elif is_cur:
                    for cx in range(sx, sx + cell_span):
                        if self.scr.ch[sy * self.scr.w + cx] != 0x2502 and self.scr.ch[sy * self.scr.w + cx] != 124:
                            self.scr.set_bg(cx, sy, self.pal.sel_bg)
                            self.scr.set_fg(cx, sy, self.pal.sel_fg)
                sx += cw + 3
                if sx >= wx + ww - 1:
                    break

    def datagrid_key(mut self, t: Int, k: Int) -> Bool:
        if k == KEY_ESC or k == 113 or k == 81:
            if self.datagrid.filter_query.byte_length() > 0 and k == KEY_ESC:
                self.datagrid.set_filter("")
                self.datagrid_refresh_buffer()
                self.say("DataGrid filter cleared")
                return True
            self.close_window(t, NEXT_CLOSE)
            return True
        var n_rows = len(self.datagrid.filtered_indices)
        var n_cols = len(self.datagrid.headers)
        var page = max(1, self.wins[t].h - 6)
        if k == KEY_DOWN or k == 106:
            self.datagrid.cursor_row = min(max(0, n_rows - 1), self.datagrid.cursor_row + 1)
        elif k == KEY_UP or k == 107:
            self.datagrid.cursor_row = max(0, self.datagrid.cursor_row - 1)
        elif k == KEY_PGDN:
            self.datagrid.cursor_row = min(max(0, n_rows - 1), self.datagrid.cursor_row + page)
        elif k == KEY_PGUP:
            self.datagrid.cursor_row = max(0, self.datagrid.cursor_row - page)
        elif k == KEY_HOME:
            self.datagrid.cursor_row = 0
        elif k == KEY_END:
            self.datagrid.cursor_row = max(0, n_rows - 1)
        elif k == KEY_RIGHT or k == 108 or k == KEY_TAB:
            self.datagrid.cursor_col = min(max(0, n_cols - 1), self.datagrid.cursor_col + 1)
        elif k == KEY_LEFT or k == 104:
            self.datagrid.cursor_col = max(0, self.datagrid.cursor_col - 1)
        elif k == 115 or k == KEY_ENTER:    # s / Enter: sort by active column
            if n_cols > 0:
                self.datagrid.sort_by_column(self.datagrid.cursor_col)
                var dir_s = "ascending ▲" if self.datagrid.sort_asc else "descending ▼"
                self.say("Sorted by `" + self.datagrid.headers[self.datagrid.cursor_col] + "` (" + dir_s + ")")
        elif k == 109 or k == 77:           # m: toggle heatmap
            self.datagrid.heatmap_mode = not self.datagrid.heatmap_mode
            self.say("DataGrid numeric heatmap: " + ("on" if self.datagrid.heatmap_mode else "off"))
        elif k == 101 or k == 119:          # e / w: export CSV
            var out_csv = String(self.cwd) + "/datagrid_export.csv"
            if write_file(out_csv, str_bytes(self.datagrid.export_csv())):
                self.say("Exported " + String(n_rows) + " rows to " + out_csv)
            else:
                self.say("Could not write " + out_csv)
            return True
        elif k == KEY_BACKSPACE and self.datagrid.filter_query.byte_length() > 0:
            var fcps = decode(self.datagrid.filter_query)
            if len(fcps) > 0:
                _ = fcps.pop()
            self.datagrid.set_filter(to_str(fcps))
        elif k >= 32 and k < K_BASE and k != 47:
            # Incremental quick-filter when '/' started or printable filter key
            pass
        if self.datagrid.cursor_row < self.datagrid.scroll_row:
            self.datagrid.scroll_row = self.datagrid.cursor_row
        elif self.datagrid.cursor_row >= self.datagrid.scroll_row + page:
            self.datagrid.scroll_row = max(0, self.datagrid.cursor_row - page + 1)
        if self.datagrid.cursor_col < self.datagrid.scroll_col:
            self.datagrid.scroll_col = self.datagrid.cursor_col
        elif self.datagrid.cursor_col > self.datagrid.scroll_col + 5:
            self.datagrid.scroll_col = max(0, self.datagrid.cursor_col - 5)
        self.datagrid_refresh_buffer()
        return True

    def collect_active_animation_frames(self) -> Tuple[List[String], Int, String]:
        """Gather `(png_paths, fps, default_stem)` from `WK_IMGVIEW`, `cell_last_plots`, or the active notebook cell."""
        var t = self.top()
        if t >= 0 and self.wins[t].kind == WK_IMGVIEW and len(self.wins[t].img_paths) > 0:
            var fps = self.wins[t].img_anim_fps if self.wins[t].img_anim_fps > 0 else 12
            return (self.wins[t].img_paths.copy(), fps, "animation")
        var ei = self.top_editor()
        var stem = String("animation")
        if ei >= 0:
            if self.wins[ei].path.byte_length() > 0:
                stem = stem_without_ext(self.wins[ei].path)
            for oi in range(len(self.wins[ei].buf.cell_out_plots) - 1, -1, -1):
                var raw_p = self.wins[ei].buf.cell_out_plots[oi]
                for ln_s in raw_p.split("\n"):
                    var sp = String(ln_s.strip())
                    if is_anim_spec(sp):
                        var parsed = parse_anim_spec(sp)
                        if parsed[0] and len(parsed[2]) > 0:
                            return (parsed[2].copy(), parsed[1], stem)
                var multi = List[String]()
                for ln_s2 in raw_p.split("\n"):
                    var sp2 = String(ln_s2.strip())
                    if sp2.byte_length() > 0 and path_exists(sp2):
                        multi.append(sp2)
                if len(multi) > 0:
                    return (multi^, 8, stem)
        var fallback = List[String]()
        for lp in self.cell_last_plots:
            if is_anim_spec(lp):
                var parsed2 = parse_anim_spec(lp)
                if parsed2[0]:
                    return (parsed2[2].copy(), parsed2[1], stem)
            elif path_exists(lp):
                fallback.append(lp)
        return (fallback^, 10, stem)

    def save_gif_dialog(mut self):
        var info = self.collect_active_animation_frames()
        if len(info[0]) == 0:
            self.say("No notebook plot or animation frames to export yet — run a plotting/animation cell first")
            return
        var default_out = info[2] + ".gif"
        if not default_out.startswith("/"):
            default_out = String(self.cwd) + "/" + basename(default_out)
        var d = Dialog(D_SAVE_GIF, "Export Animated GIF89a (" + String(len(info[0])) + " frames @ " + String(info[1]) + " fps)", min(72, self.scr.w - 4), 9)
        var f = Field("Output ~G~IF path", default_out)
        f.fresh = True
        d.fields.append(f^)
        d.buttons.append("~S~ave GIF")
        d.buttons.append("~C~ancel")
        self.show(d^)

    def save_gif_apply(mut self, out_path: String) -> Bool:
        var dst = String(out_path.strip())
        if dst.byte_length() == 0:
            return False
        var info = self.collect_active_animation_frames()
        if len(info[0]) == 0:
            self.say("No PNG frames available to encode")
            return False
        if save_png_frames_as_gif(info[0], dst, info[1]):
            self.say("Saved animated GIF89a (" + String(len(info[0])) + " frames, " + String(info[1]) + " fps) -> " + dst)
            return True
        self.say("Failed to write GIF89a to " + dst)
        return False

    def connect_kernel_dialog(mut self):
        var d = Dialog(D_CONNECT_KERNEL, "Connect External Jupyter ipykernel", min(74, self.scr.w - 4), 10)
        d.lines.append("Path to Jupyter connection JSON (leave empty for built-in TurboMojo kernel):")
        var f = Field("~C~onnection JSON", self.external_kernel_json)
        f.fresh = True
        d.fields.append(f^)
        d.buttons.append("~C~onnect")
        d.buttons.append("~C~ancel")
        self.show(d^)

    def connect_kernel_apply(mut self, conn_path: String):
        var p = String(conn_path.strip())
        if self.cell_py_proc.running:
            _ = self.cell_py_proc.stop()
        self.cell_py_env = ""
        self.cell_py_preamble = ""
        self.external_kernel_json = p
        if p.byte_length() == 0:
            self.say("Switched back to built-in persistent TurboMojo Python/Mojo kernels")
        else:
            self.say("Connected external Jupyter ipykernel bridge: " + p)

    # ========================================================================
    # Phase 22: 2-Char Flash Jump, Harpoon 1..4 & Vim Register Popup
    # ========================================================================
    def flash_jump_start(mut self):
        if self.top_editor() < 0:
            self.say("Flash jump: no visible editor pane")
            return
        self.flash_stage = 1
        self.flash_ch1 = 0
        self.flash_targets.clear()
        self.say("Flash jump — type 2 characters (Esc to cancel):")

    def flash_cancel(mut self):
        self.flash_stage = 0
        self.flash_ch1 = 0
        self.flash_targets.clear()

    def _flash_collect_screen_targets(mut self, ch1: Int, ch2: Int):
        self.flash_targets.clear()
        var all_targets = List[FlashTarget]()
        for wi in range(len(self.wins)):
            if self.wins[wi].hidden or self.wins[wi].kind != WK_EDITOR:
                continue
            var pd = self.wins[wi].pad()
            var cx0 = self.wins[wi].x + pd + self.wins[wi].gut
            var cls = self.wins[wi].cols()
            var rws = self.wins[wi].rows()
            var off = self.wins[wi].left
            var vis_lines = List[String]()
            var base_r = max(0, self.wins[wi].top)
            var end_r = min(self.wins[wi].buf.count(), base_r + rws + 4)
            for r in range(base_r, end_r):
                vis_lines.append(to_str(self.wins[wi].buf.line(r)))
            var raw_hits = find_flash_targets_in_lines(wi, vis_lines, base_r, ch1, ch2, False)
            for hit in raw_hits:
                var scr_y = self.wins[wi].screen_row_of(hit.row, hit.col, rws)
                if scr_y < 0 or scr_y >= rws:
                    continue
                var vc = self.wins[wi].vcol(hit.row, hit.col)
                if vc < off or vc >= off + cls:
                    continue
                var sx = cx0 + (vc - off)
                var sy = self.wins[wi].y + pd + scr_y
                all_targets.append(FlashTarget(wi, hit.row, hit.col, sx, sy, hit.label))
        assign_flash_labels(all_targets)
        self.flash_targets = all_targets^

    def _flash_land(mut self, target: FlashTarget) raises:
        var orig_t = self.top()
        self.flash_cancel()
        if target.win_idx != orig_t:
            if self.keymap == KEYMAP_VIM and self.vim.op != 0:
                self.vim_cancel()
            self.focus(target.win_idx)
        var t = target.win_idx
        if self.keymap == KEYMAP_VIM and self.vim.op != 0 and t == orig_t:
            var op = self.vim.op
            self.vim.op = 0
            self.vim.op_n = 0
            self.vim.count = 0
            var sp = motion_span(self.wins[t].buf, self.wins[t].cr, self.wins[t].cc, VimMove(True, target.row, target.col, VK_EXCL))
            if sp.ok:
                self.vim_apply(t, op, sp)
            self.vim_done()
            return
        self.jump_mark()
        self.wins[t].cr = max(0, min(target.row, self.wins[t].buf.count() - 1))
        self.wins[t].cc = max(0, min(target.col, self.wins[t].buf.llen(self.wins[t].cr)))
        self.wins[t].sync_want()
        if self.keymap == KEYMAP_VIM:
            self.vim_settle(t)
        else:
            self.wins[t].follow = True

    def flash_handle_key(mut self, k: Int) raises -> Bool:
        """Intercept keys while a 2-char Flash jump (`flash_stage > 0`) is active."""
        if self.flash_stage == 0:
            return False
        if k == KEY_ESC:
            self.flash_cancel()
            if self.keymap == KEYMAP_VIM and self.vim.op != 0:
                self.vim_cancel()
            self.say("")
            return True
        if (k & (MOD_CTRL | MOD_ALT)) != 0 or (k & KEY_MASK) >= K_BASE:
            self.flash_cancel()
            return True
        var ch = k & KEY_MASK
        if self.flash_stage == 1:
            self.flash_ch1 = ch
            self.flash_stage = 2
            self.say("Flash: " + chr(ch) + "…")
            return True
        if self.flash_stage == 2:
            self._flash_collect_screen_targets(self.flash_ch1, ch)
            if len(self.flash_targets) == 0:
                var q = chr(self.flash_ch1) + chr(ch)
                self.flash_cancel()
                if self.keymap == KEYMAP_VIM and self.vim.op != 0:
                    self.vim_cancel()
                self.say("Flash: no visible match for `" + q + "`")
                return True
            if len(self.flash_targets) == 1:
                var only = self.flash_targets[0].copy()
                self._flash_land(only)
                return True
            self.flash_stage = 3
            self.say("Flash: press beacon key (" + String(len(self.flash_targets)) + " matches)")
            return True
        # Stage 3: pick beacon label
        for i in range(len(self.flash_targets)):
            if self.flash_targets[i].label == ch:
                var chosen = self.flash_targets[i].copy()
                self._flash_land(chosen)
                return True
        self.flash_cancel()
        if self.keymap == KEYMAP_VIM and self.vim.op != 0:
            self.vim_cancel()
        return True

    def draw_flash_beacons(mut self):
        """Draw high-contrast single-letter Flash jump beacons across all visible panes."""
        if self.flash_stage != 3 or len(self.flash_targets) == 0 or self.reader:
            return
        self.scr.no_clip()
        for tgt in self.flash_targets:
            if tgt.screen_x >= 0 and tgt.screen_x < self.scr.w and tgt.screen_y >= 0 and tgt.screen_y < self.scr.h:
                # Dim the 2nd match char slightly so the beacon stands out sharply
                if tgt.screen_x + 1 < self.scr.w:
                    self.scr.set_bg(tgt.screen_x + 1, tgt.screen_y, self.pal.match_bg)
                    self.scr.set_fg(tgt.screen_x + 1, tgt.screen_y, self.pal.match_fg)
                self.scr.put(tgt.screen_x, tgt.screen_y, tgt.label, 0xFFFFFF, self.pal.diag_err)
                self.scr.bold(tgt.screen_x, tgt.screen_y, 1)

    def harpoon_toggle_pin(mut self):
        var ei = self.top_editor()
        if ei < 0:
            self.say("Harpoon: open a file first")
            return
        var p = self.wins[ei].path if self.wins[ei].path.byte_length() > 0 else self.wins[ei].title
        var lbl = basename(p) + ":" + String(self.wins[ei].cr + 1)
        var slot = self.harpoon.toggle_pin(p, self.wins[ei].cr, self.wins[ei].cc, lbl)
        if slot > 0:
            self.say("Harpoon pinned [" + String(slot) + "] -> " + lbl + " (<Space>" + String(slot) + " jumps)")
        else:
            self.say("Harpoon unpinned " + basename(p))

    def harpoon_jump_slot(mut self, slot_1based: Int) raises:
        var got = self.harpoon.slot_at(slot_1based)
        if not got[0]:
            self.say("Harpoon slot [" + String(slot_1based) + "] is empty (<Space>m pins current file/cell)")
            return
        var entry = got[1].copy()
        self.jump_mark()
        if entry.path.byte_length() > 0 and path_exists(entry.path):
            self.open_path(entry.path)
        else:
            var wi = self.find_editor_or_title(entry.path)
            if wi >= 0:
                self.focus(wi)
        var t = self.top_editor()
        if t >= 0:
            self.wins[t].cr = max(0, min(entry.row, self.wins[t].buf.count() - 1))
            self.wins[t].cc = max(0, min(entry.col, self.wins[t].buf.llen(self.wins[t].cr)))
            self.wins[t].sync_want()
            self.wins[t].follow = True
            if self.keymap == KEYMAP_VIM:
                self.vim_settle(t)
        self.say("Harpoon [" + String(slot_1based) + "] -> " + entry.label)

    def harpoon_open_dialog(mut self):
        var items = self.harpoon.format_menu_lines()
        var data = List[Int]()
        if len(items) == 0:
            items.append("(No Harpoon marks pinned yet — press Pin or <Space>m in Vim mode)")
            data.append(0)
        else:
            for k in range(len(items)):
                data.append(k + 1)
        var d = Dialog(D_HARPOON, "Harpoon Quick-Marks (1..9)", min(68, self.scr.w - 4), min(16, max(10, len(items) + 6)))
        d.set_items(items^, data^)
        d.buttons.append("~J~ump")
        d.buttons.append("~P~in current")
        d.buttons.append("C~l~ear all")
        d.buttons.append("~C~ancel")
        self.show(d^)

    def draw_vim_reg_popup(mut self):
        """Floating preview box when `"` (register select) or `@` (macro select) is waiting in Vim mode."""
        if self.keymap != KEYMAP_VIM or self.mode != M_NORMAL or self.reader:
            return
        if self.vim.pend != 34 and self.vim.pend != 64:
            return
        var rows = List[String]()
        if self.vim.pend == 34:
            if len(self.vim.reg) > 0:
                rows.append("\"\"  " + String(to_str(self.vim.reg).replace("\n", "↵")[byte=0 : min(44, to_str(self.vim.reg).replace("\n", "↵").byte_length())]))
            if len(self.vim.reg0) > 0:
                rows.append("\"0  " + String(to_str(self.vim.reg0).replace("\n", "↵")[byte=0 : min(44, to_str(self.vim.reg0).replace("\n", "↵").byte_length())]))
            for ri in range(26):
                if len(self.vim.regs[ri]) > 0 and len(rows) < 9:
                    var preview = to_str(self.vim.regs[ri]).replace("\n", "↵")
                    rows.append("\"" + chr(97 + ri) + "  " + String(preview[byte=0 : min(44, preview.byte_length())]))
            if len(rows) == 0:
                rows.append("(unnamed & a..z registers empty; \"+ uses clipboard)")
        else:
            for mi in range(26):
                if len(self.vim.macros[mi]) > 0 and len(rows) < 9:
                    rows.append("@" + chr(97 + mi) + "  (" + String(len(self.vim.macros[mi])) + " keys recorded)")
            if len(rows) == 0:
                rows.append("(no macros recorded yet — use qa...q)")
        var bw = 56
        var bh = len(rows) + 2
        var bx = max(1, self.scr.w - bw - 2)
        var by = max(1, self.scr.h - bh - 2)
        if bx + bw > self.scr.w or by + bh >= self.scr.h:
            return
        self.scr.no_clip()
        self.scr.fill(bx, by, bw, bh, 32, self.pal.ed_fg, self.pal.gutter_bg)
        self.scr.frame(bx, by, bw, bh, True, self.pal.frame_act, self.pal.gutter_bg)
        var hdr = " Registers (\") " if self.vim.pend == 34 else " Macros (@) "
        _ = self.scr.text(bx + 2, by, hdr, self.pal.title_fg, self.pal.gutter_bg)
        for i in range(len(rows)):
            _ = self.scr.text(bx + 2, by + 1 + i, rows[i], self.pal.ed_fg, self.pal.gutter_bg)

    # ========================================================================
    # Phase 23: WK_PROFILE Flamegraphs, Stall Badges & LayoutTensor / MAX Viz
    # ========================================================================
    def profile_index(self) -> Int:
        for i in range(len(self.wins)):
            if self.wins[i].kind == WK_PROFILE:
                return i
        return -1

    def apply_stall_annotations_to_editor(mut self, path: String, stalls: List[LineStallAnnotation]):
        if len(stalls) == 0:
            return
        var ei = self.find_editor(path) if path.byte_length() > 0 else self.top_editor()
        if ei < 0:
            return
        for st in stalls:
            var r = st.line_no - 1
            if r < 0 or r >= self.wins[ei].buf.count() or st.gutter_badge.byte_length() == 0:
                continue
            var updated = False
            for bi in range(len(self.wins[ei].bench_badge_rows)):
                if self.wins[ei].bench_badge_rows[bi] == r:
                    self.wins[ei].bench_badges[bi] = st.gutter_badge
                    updated = True
                    break
            if not updated:
                self.wins[ei].bench_badge_rows.append(r)
                self.wins[ei].bench_badges.append(st.gutter_badge)
        self.sync_shared_buffers(ei)

    def apply_static_asm_stalls_to_codegen(mut self, asm_raw: String):
        var stalls = analyze_static_asm_stalls(asm_raw)
        if len(stalls) > 0 and self.codegen_path.byte_length() > 0:
            var cg_p = String(self.codegen_path)
            self.apply_stall_annotations_to_editor(cg_p, stalls)

    def profile_refresh_buffer(mut self):
        var pi = self.profile_index()
        if pi < 0:
            return
        var w = max(40, self.wins[pi].w - 4)
        var h = max(8, self.wins[pi].h - 2)
        var lines = self.prof_view.render_lines(w, h)
        var cps = List[Int]()
        var marks = List[Int]()
        for k in range(len(lines)):
            if k > 0:
                cps.append(10)
            for c in decode(lines[k]):
                cps.append(c)
            if k == 0:
                marks.append(RM_OK)
            elif str_contains(lines[k], "►") or str_contains(lines[k], "Selected:"):
                marks.append(RM_WARN)
            else:
                marks.append(RM_NONE)
        self.wins[pi].buf.load(cps)
        self.wins[pi].row_marks = marks^
        self.wins[pi].buf.modified = False
        self.wins[pi].read_only = True
        var mode_lbl = "Multi-Stream GPU Timeline" if self.prof_view.timeline_mode else "Flamegraph / Icicle"
        self.wins[pi].title = "Profiler · " + self.prof_view.title + " [" + mode_lbl + "]"

    def open_profile_window(mut self, custom_path_or_json: String = ""):
        var raw = String("")
        var title = String("GPU & Kernel Profile")
        if custom_path_or_json.byte_length() > 0:
            if custom_path_or_json.lstrip().startswith("{") or custom_path_or_json.lstrip().startswith("["):
                raw = custom_path_or_json
            elif path_exists(custom_path_or_json):
                raw = bytes_to_str(read_file(custom_path_or_json))
                title = basename(custom_path_or_json)
        if raw.byte_length() == 0:
            var ei = self.top_editor()
            if ei >= 0:
                var p = self.wins[ei].path
                var low_p = lower_str(p)
                if low_p.endswith(".json") or low_p.endswith(".folded") or low_p.endswith(".trace"):
                    raw = to_str(self.wins[ei].buf.all_text())
                    title = basename(p)
        if raw.byte_length() == 0:
            for cand in [String(self.cwd) + "/trace.json", String(self.cwd) + "/profile.json", String(self.cwd) + "/build/trace.json"]:
                if path_exists(String(cand)):
                    raw = bytes_to_str(read_file(String(cand)))
                    title = basename(String(cand))
                    break
        if raw.lstrip().startswith("{") or raw.lstrip().startswith("["):
            self.prof_view = parse_chrome_trace_json(title, raw)
        elif raw.byte_length() > 0:
            self.prof_view = parse_folded_stacks(title, raw)
        else:
            # Synthesize a representative multi-stream GPU trace when none is on disk yet
            var demo = (
                "{\"traceEvents\":["
                "{\"name\":\"host_launch_step\",\"cat\":\"cpu\",\"ph\":\"X\",\"pid\":1,\"tid\":0,\"ts\":0,\"dur\":1200},"
                "{\"name\":\"h2d_async_weights\",\"cat\":\"memcpy\",\"ph\":\"X\",\"pid\":1,\"tid\":1,\"ts\":40,\"dur\":260},"
                "{\"name\":\"matmul_sm90_wgmma_bf16\",\"cat\":\"kernel\",\"ph\":\"X\",\"pid\":1,\"tid\":2,\"ts\":300,\"dur\":640},"
                "{\"name\":\"tile_load_cp_async\",\"cat\":\"kernel\",\"ph\":\"X\",\"pid\":1,\"tid\":2,\"ts\":320,\"dur\":180},"
                "{\"name\":\"mma_epilogue_gelu\",\"cat\":\"kernel\",\"ph\":\"X\",\"pid\":1,\"tid\":2,\"ts\":510,\"dur\":410},"
                "{\"name\":\"rmsnorm_flash_attn\",\"cat\":\"kernel\",\"ph\":\"X\",\"pid\":1,\"tid\":2,\"ts\":950,\"dur\":220}"
                "]}"
            )
            self.prof_view = parse_chrome_trace_json("MAX / GPU Trace Demo", demo)
        var pi = self.profile_index()
        if pi < 0:
            var ww = max(52, min(self.scr.w - 4, (self.scr.w * 86) // 100))
            var wh = max(14, min(self.desk_h() - 2, (self.desk_h() * 80) // 100))
            var wx = max(1, (self.scr.w - ww) // 2)
            var wy = max(1, 1 + (self.desk_h() - wh) // 2)
            var w = Window(WK_PROFILE, "Profiler", "", wx, wy, ww, wh, 0)
            w.read_only = True
            self.wins.append(w^)
            pi = len(self.wins) - 1
        self.focus(pi)
        self.profile_refresh_buffer()
        self.say("Profiler: ↑↓ select, Enter/+ zoom in, -/Bksp zoom out, 0 reset, t toggle Timeline/Flamegraph, Esc close")

    def profile_draw(mut self, wi: Int, active: Bool):
        if wi < 0 or wi >= len(self.wins):
            return
        self.profile_refresh_buffer()
        self.wins[wi].draw(self.scr, self.pal, self.hl, active, False, False, False)

    def profile_key(mut self, t: Int, k: Int) -> Bool:
        if k == KEY_ESC or k == 113 or k == 81:
            if self.prof_view.search_query.byte_length() > 0 and k == KEY_ESC:
                self.prof_view.set_search("")
                self.profile_refresh_buffer()
                self.say("Profiler search cleared")
                return True
            self.close_window(t, NEXT_CLOSE)
            return True
        if k == KEY_DOWN or k == 106:
            self.prof_view.select_next()
        elif k == KEY_UP or k == 107:
            self.prof_view.select_prev()
        elif k == KEY_ENTER:
            self.prof_view.zoom_into_selected()
        elif k == 43 or k == 61:            # + / =
            self.prof_view.zoom_by_factor(0.5)
        elif k == 45 or k == KEY_BACKSPACE: # - / Bksp
            self.prof_view.zoom_out()
        elif k == 48 or k == 114:           # 0 / r
            self.prof_view.zoom_reset()
        elif k == 116 or k == 84:           # t / T
            self.prof_view.toggle_mode()
            self.say("Switched to " + ("Multi-Stream GPU Timeline" if self.prof_view.timeline_mode else "Flamegraph / Icicle"))
        self.profile_refresh_buffer()
        return True

    def open_layout_tensor_viz(mut self):
        """Analyze `LayoutTensor` global coalescing, 32-bank XOR swizzle & MAX `Graph` fusion in the active buffer."""
        var src = String("")
        var ei = self.top_editor()
        if ei >= 0:
            src = to_str(self.wins[ei].selected_text()) if self.wins[ei].has_sel() else to_str(self.wins[ei].buf.all_text())
        var rep = parse_layout_from_mojo_source(src)
        var max_lines = render_max_graph_fusion(src)
        var out = List[String]()
        for dl in rep.diagram_lines:
            out.append(dl)
        if len(max_lines) > 0:
            out.append("")
            for ml in max_lines:
                out.append(ml)
        var body = "\n".join(out)
        self.panel_write(PG_MESSAGE)
        _ = self.fill_messages("LayoutTensor Coalescing, 32-Bank Swizzle & MAX Graph Fusion", str_bytes(body), "Done.")
        self.panel_show(PG_MESSAGE)
        self.say(
            "LayoutTensor ["
            + String(rep.shape_r)
            + "x"
            + String(rep.shape_c)
            + "]: "
            + String(rep.coalescing_efficiency_pct)
            + "% coalesced ("
            + String(rep.global_transactions_per_warp)
            + " tx/warp), "
            + String(rep.smem_bank_conflicts)
            + "-way bank access"
        )

    # ========================================================================
    # Phase 24: Multimodal Notebook AI, Worktree Agent & Semantic AST+BM25 RAG
    # ========================================================================
    def active_notebook_ai_context(self, wi: Int, max_images: Int = 2) -> NotebookAiContext:
        """Build live multimodal `NotebookAiContext` (schemas, preceding defs, errors & base64 PNG plots) for `wi`."""
        var cells = parse_cells(self.wins[wi].buf)
        var cell_outs = List[String]()
        var cell_plots = List[List[String]]()
        for ci in range(len(cells)):
            var hrow = cells[ci].header_row if cells[ci].header_row >= 0 else 0
            var otxt = String("")
            var plist = List[String]()
            for oi in range(len(self.wins[wi].buf.cell_out_rows)):
                if self.wins[wi].buf.cell_out_rows[oi] == hrow:
                    if oi < len(self.wins[wi].buf.cell_out_texts):
                        otxt = self.wins[wi].buf.cell_out_texts[oi]
                    if oi < len(self.wins[wi].buf.cell_out_plots):
                        for ps in self.wins[wi].buf.cell_out_plots[oi].split("\n"):
                            var pp = String(ps.strip())
                            if pp.byte_length() > 0:
                                plist.append(pp)
                    break
            cell_outs.append(otxt)
            cell_plots.append(plist^)
        return build_notebook_ai_context(self.wins[wi].buf, self.wins[wi].cr, cell_outs, cell_plots, max_images)

    def worktree_task_ask(mut self):
        var d = Dialog(D_WORKTREE_TASK, "Isolated Git-Worktree Task (Shadow mojo build Verified)", min(76, self.scr.w - 4), 10)
        d.lines.append("Runs inside a detached /tmp git worktree; verified diffs open in offer_edit():")
        var f = Field("Shell / ~A~gent command", "")
        f.fresh = True
        d.fields.append(f^)
        d.buttons.append("~R~un Isolated")
        d.buttons.append("~C~ancel")
        self.show(d^)

    def worktree_task_run(mut self, task_cmd: String):
        var cmd = String(task_cmd.strip())
        if cmd.byte_length() == 0:
            self.say("Enter a command or script to run in the isolated worktree")
            return
        if not self.trust_gate(CM_AGENT_WORKTREE_TASK):
            return
        var root = self.symidx_root()
        self.wt_task_seq += 1
        var wt = create_isolated_worktree(root, self.wt_task_seq)
        if not wt[0]:
            self.say("Worktree error: " + wt[2])
            return
        var wt_dir = wt[1]
        self.snapshot_versions()
        var res = run_capture("cd " + shell_quote(wt_dir) + " && " + cmd + " 2>&1 < /dev/null")
        var patches = collect_worktree_patches(root, wt_dir)
        var mojo_bin = self.compiler_cmd()
        var verify_ok = True
        var verify_err = String("")
        for p in patches:
            if p.rel_path.endswith(".mojo") and p.new_content.byte_length() > 0:
                var v = verify_worktree_mojo_file(wt_dir, p.rel_path, mojo_bin)
                if not v[0]:
                    verify_ok = False
                    verify_err = v[1]
                    break
        _ = cleanup_isolated_worktree(root, wt_dir)
        if len(patches) == 0:
            var out_s = String(bytes_to_str(res.out).strip())
            self.say("Isolated worktree task finished with 0 file changes" + ((" — " + out_s) if out_s.byte_length() > 0 and out_s.byte_length() < 60 else String("")))
            return
        if not verify_ok and self.ai_verify_edits:
            self.panel_write(PG_MESSAGE)
            _ = self.fill_messages("Isolated Worktree Task Failed Shadow `mojo build`", str_bytes(verify_err), "Rejected unverified patch.")
            self.panel_show(PG_MESSAGE)
            self.say("Worktree patch failed shadow `mojo build` — live workspace kept untouched")
            return
        var we = WorkspaceEdit()
        for p in patches:
            var abs_p = root + "/" + p.rel_path
            var fe = FileEdits(abs_p)
            var orig_lines = p.orig_content.split("\n")
            var last_r = max(0, len(orig_lines) - 1)
            var last_u16 = col_to_utf16(decode(String(orig_lines[last_r])), cp_len(String(orig_lines[last_r]))) if len(orig_lines) > 0 else 0
            fe.edits.append(LspEdit(0, 0, last_r, last_u16, p.new_content))
            we.files.append(fe^)
        var vtag = "shadow-verified" if verify_ok else "unverified"
        self.offer_edit(
            we^,
            "Worktree Task",
            "Isolated Worktree Changes (" + vtag + ")",
            "Apply " + String(len(patches)) + " file patch(es) from `" + cmd + "`",
            "Applied " + String(len(patches)) + " isolated worktree patch(es)",
        )

    def semantic_search_dialog(mut self):
        var seed = String("")
        var ei = self.active_editor()
        if ei >= 0 and self.wins[ei].has_sel():
            var sel = to_str(self.wins[ei].selected_text())
            if sel.find("\n") < 0:
                seed = sel
        var d = Dialog(D_SEMANTIC_SEARCH, "Semantic Codebase Search (Mojo CST + BM25)", min(72, self.scr.w - 4), 9)
        var f = Field("Natural-language / ~s~ymbol query", seed)
        f.fresh = True
        d.fields.append(f^)
        d.buttons.append("~S~earch")
        d.buttons.append("~C~ancel")
        self.show(d^)

    def semantic_search_run(mut self, query: String):
        var q = String(query.strip())
        if q.byte_length() == 0:
            self.say("Enter a semantic search query")
            return
        var idx = SemanticCodeIndex()
        var indexed_paths = List[String]()
        for wi in range(len(self.wins)):
            if self.wins[wi].kind == WK_EDITOR and self.wins[wi].path.byte_length() > 0:
                idx.index_buffer(self.wins[wi].path, self.wins[wi].buf)
                indexed_paths.append(self.wins[wi].path)
        var root = self.symidx_root()
        var files = collect_search_files(root, "")
        var cap = 0
        for fp in files:
            if cap >= 220:
                break
            if fp in indexed_paths:
                continue
            var low = lower_str(fp)
            if not (low.endswith(".mojo") or low.endswith(".py") or low.endswith(".md") or low.endswith(".ipynb")):
                continue
            var raw = read_file(fp)
            if len(raw) == 0 or len(raw) > MAX_FILE_BYTES or is_binary(raw):
                continue
            idx.index_file_text(fp, bytes_to_str(raw))
            cap += 1
        self.sem_hits = idx.search(q, 25)
        var report = List[String]()
        report.append("Semantic AST + BM25 search for \"" + q + "\" (" + String(len(self.sem_hits)) + " hits):")
        var locs = List[ErrLoc]()
        for h in self.sem_hits:
            var line_no = h.row + 1
            var score_s = String(h.score_x100 // 100) + "." + ("0" if (h.score_x100 % 100) < 10 else "") + String(h.score_x100 % 100)
            var msg_line = len(report)
            report.append(h.path + ":" + String(line_no) + ":1: [" + h.kind + " " + h.symbol_name + " · score " + score_s + "] " + h.preview)
            locs.append(ErrLoc(h.path, h.row, 0, msg_line))
        self.panel_write(PG_SEARCH)
        _ = self.fill_messages("", str_bytes("\n".join(report)), "")
        self.errs = locs^
        self.err_idx = 0 if len(self.errs) > 0 else -1
        self.panel_show(PG_SEARCH)
        if len(self.sem_hits) > 0:
            self.say("Semantic search: " + String(len(self.sem_hits)) + " ranked AST+BM25 matches (Enter in Search panel jumps)")
        else:
            self.say("Semantic search: 0 matches for \"" + q + "\"")

    # ========================================================================
    # Phase 25: Standalone HTML5 Notebook Export & AF_UNIX Live Share
    # ========================================================================
    def export_html_dialog(mut self):
        var ei = self.top_editor()
        if ei < 0:
            self.say("Open a notebook or # %% file first")
            return
        var src_p = self.wins[ei].path
        var def_out = (stem_without_ext(src_p) if src_p.byte_length() > 0 else (String(self.cwd) + "/notebook")) + ".html"
        var d = Dialog(D_EXPORT_HTML, "Export Standalone HTML5 Notebook", min(72, self.scr.w - 4), 9)
        var f = Field("Output ~H~TML path", def_out)
        f.fresh = True
        d.fields.append(f^)
        d.buttons.append("~E~xport HTML")
        d.buttons.append("~C~ancel")
        self.show(d^)

    def export_active_notebook_html(mut self, out_path: String) -> Bool:
        var dst = String(out_path.strip())
        if dst.byte_length() == 0:
            return False
        var ei = self.top_editor()
        if ei < 0:
            return False
        var p = self.wins[ei].path
        # If clean on-disk .ipynb with no unsaved buffer edits, export directly or from live buffer!
        if p.byte_length() > 0 and is_ipynb_path(p) and not self.wins[ei].buf.modified and len(self.wins[ei].buf.cell_out_rows) == 0 and path_exists(p):
            var r0 = export_ipynb_file_to_html(p, dst)
            if r0[0]:
                self.say("Exported standalone HTML5 notebook -> " + dst)
                return True
        var cells = parse_cells(self.wins[ei].buf)
        var is_mj = self.wins[ei].effective_lang() == HL_MOJO
        var views = List[HtmlCellView]()
        var exec_ord = 0
        for ci in range(len(cells)):
            var c = cells[ci].copy()
            var hrow = c.header_row if c.header_row >= 0 else 0
            var is_md = self.wins[ei].is_markdown_header(hrow) if c.header_row >= 0 else False
            var is_folded = self.wins[ei].buf.fold_index(hrow) >= 0 if c.header_row >= 0 else False
            var body_lines = List[String]()
            for r in range(c.start_row, min(c.end_row + 1, self.wins[ei].buf.count())):
                var raw_ln = to_str(self.wins[ei].buf.line(r))
                if is_md:
                    if raw_ln.startswith("# "):
                        body_lines.append(String(raw_ln[byte=2:]))
                    elif raw_ln == "#":
                        body_lines.append("")
                    else:
                        body_lines.append(raw_ln)
                else:
                    body_lines.append(raw_ln)
            var out_txt = String("")
            var is_err = False
            var media = List[String]()
            var ec = 0
            if not is_md:
                exec_ord += 1
                ec = self.wins[ei].cell_exec_count_at_header(hrow)
                if ec <= 0:
                    ec = exec_ord
                for oi in range(len(self.wins[ei].buf.cell_out_rows)):
                    if self.wins[ei].buf.cell_out_rows[oi] == hrow:
                        if oi < len(self.wins[ei].buf.cell_out_texts):
                            out_txt = self.wins[ei].buf.cell_out_texts[oi]
                        if oi < len(self.wins[ei].buf.cell_out_errs):
                            is_err = self.wins[ei].buf.cell_out_errs[oi]
                        if oi < len(self.wins[ei].buf.cell_out_plots):
                            for ps in self.wins[ei].buf.cell_out_plots[oi].split("\n"):
                                var sp = String(ps.strip())
                                if sp.byte_length() == 0:
                                    continue
                                if is_anim_spec(sp):
                                    media.append(sp)
                                elif path_exists(sp):
                                    var b = read_file(sp)
                                    if len(b) > 0:
                                        media.append("data:image/png;base64," + base64(b))
                        break
            views.append(
                HtmlCellView(
                    ci,
                    self.wins[ei].clean_cell_title(hrow) if c.header_row >= 0 else c.title,
                    is_md,
                    is_folded,
                    ec,
                    "\n".join(body_lines),
                    out_txt,
                    is_err,
                    media^,
                )
            )
        var doc_title = basename(p) if p.byte_length() > 0 else self.wins[ei].title
        var html = render_notebook_cells_html(doc_title, views, is_mj)
        if write_file(dst, str_bytes(html)):
            self.say("Exported standalone HTML5 notebook -> " + dst)
            return True
        self.say("Could not write HTML to " + dst)
        return False

    def live_share_dialog(mut self):
        var cur_sock = self.live_share.sock_path if self.live_share.sock_path.byte_length() > 0 else String("/tmp/turbomojo-live.sock")
        var status_s = (
            "Active HOST on " + self.live_share.sock_path + " (" + String(self.live_share.connected_peer_count()) + " peer(s))"
            if self.live_share.mode == LS_HOST
            else (
                "Connected as CLIENT to " + self.live_share.sock_path
                if self.live_share.mode == LS_CLIENT
                else "Inactive (zero-server AF_UNIX local or SSH -L socket)"
            )
        )
        var d = Dialog(D_LIVE_SHARE, "Live Share (Zero-Server Unix Socket)", min(74, self.scr.w - 4), 11)
        d.lines.append("Status: " + status_s)
        d.fields.append(Field("Unix ~s~ocket path", cur_sock))
        d.fields.append(Field("Your ~n~ame", env_or("USER", "peer")))
        d.buttons.append("~H~ost")
        d.buttons.append("~J~oin")
        d.buttons.append("S~t~op")
        d.buttons.append("~C~ancel")
        self.show(d^)

    def live_share_button(mut self, b: Int, sock: String, peer: String):
        var sp = String(sock.strip())
        var nm = String(peer.strip())
        if nm.byte_length() == 0:
            nm = "peer"
        if b == 2:
            self.live_share.stop()
            self.say("Live Share stopped")
            return
        if sp.byte_length() == 0:
            self.say("Enter a Unix socket path (e.g. /tmp/turbomojo-live.sock)")
            return
        self.live_share.stop()
        if b == 0:
            if self.live_share.start_host(sp, nm):
                self.say("Live Share hosting on " + sp + " (SSH forward: ssh -L " + sp + ":" + sp + " host)")
            else:
                self.say("Failed to bind Live Share socket: " + sp)
        elif b == 1:
            if self.live_share.connect_client(sp, nm):
                self.say("Joined Live Share session at " + sp + " as `" + nm + "`")
            else:
                self.say("Failed to connect to Live Share socket: " + sp)

    def live_share_tick(mut self):
        """Non-blocking poll & broadcast for collaborative `LiveShareSession`."""
        if not self.live_share.is_active():
            return
        var ei = self.top_editor()
        if ei >= 0:
            var p = self.wins[ei].path if self.wins[ei].path.byte_length() > 0 else self.wins[ei].title
            if self.wins[ei].cr != self.live_share_last_r or self.wins[ei].cc != self.live_share_last_c:
                self.live_share_last_r = self.wins[ei].cr
                self.live_share_last_c = self.wins[ei].cc
                self.live_share.broadcast(
                    LiveShareEvent("cursor", self.live_share.peer_name, p, self.wins[ei].cr, self.wins[ei].cc, self.wins[ei].cr, "")
                )
            if self.wins[ei].buf.version != self.live_share_last_ver:
                self.live_share_last_ver = self.wins[ei].buf.version
                self.live_share.broadcast(
                    LiveShareEvent("sync_full", self.live_share.peer_name, p, 0, 0, self.wins[ei].buf.count(), to_str(self.wins[ei].buf.all_text()))
                )
        var evs = self.live_share.poll_events()
        for ev in evs:
            if ev.peer_name == self.live_share.peer_name:
                continue
            if ev.kind == "sync_full":
                var wi = self.find_editor_or_title(ev.path)
                if wi < 0 and ei >= 0 and len(self.wins) == 1:
                    wi = ei
                if wi >= 0:
                    var cur_txt = to_str(self.wins[wi].buf.all_text())
                    if cur_txt != ev.text:
                        var keep_r = self.wins[wi].cr
                        var keep_c = self.wins[wi].cc
                        self.wins[wi].buf.load(decode(ev.text))
                        self.wins[wi].cr = min(keep_r, max(0, self.wins[wi].buf.count() - 1))
                        self.wins[wi].cc = min(keep_c, self.wins[wi].buf.llen(self.wins[wi].cr))
                        self.live_share_last_ver = self.wins[wi].buf.version
                        self.scr.force = True
            elif ev.kind == "cell_out":
                self.cell_apply_output(ev.path, 0, ev.row, ev.text, False, List[String]())
                self.scr.force = True

    def draw_live_share_cursors(mut self):
        """Render remote peer cursor tags inside open `WK_EDITOR` windows."""
        if not self.live_share.is_active() or len(self.live_share.peer_cursors) == 0 or self.reader:
            return
        var ei = self.top_editor()
        if ei < 0 or self.wins[ei].hidden:
            return
        var pd = self.wins[ei].pad()
        var cx0 = self.wins[ei].x + pd + self.wins[ei].gut
        var cls = self.wins[ei].cols()
        var rws = self.wins[ei].rows()
        var off = self.wins[ei].left
        self.scr.no_clip()
        for pc in self.live_share.peer_cursors:
            if pc.peer_name == self.live_share.peer_name:
                continue
            var sr = self.wins[ei].screen_row_of(pc.row, pc.col, rws)
            if sr < 0 or sr >= rws:
                continue
            var vc = self.wins[ei].vcol(pc.row, pc.col)
            if vc < off or vc >= off + cls:
                continue
            var sx = cx0 + (vc - off)
            var sy = self.wins[ei].y + pd + sr
            self.scr.set_bg(sx, sy, self.pal.msg_note)
            self.scr.set_fg(sx, sy, self.pal.ed_bg)
            var tag = " ◀ " + pc.peer_name + " "
            if sx + 2 + cp_len(tag) < cx0 + cls:
                _ = self.scr.text(sx + 2, sy, tag, self.pal.ed_bg, self.pal.msg_note)
