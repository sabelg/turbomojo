"""Inline notebook image & plot renderer for `WK_EDITOR` virtual cell outputs.

Renders PNG outputs (`__TM_PLOT__`, `matplotlib`, `PIL.Image`, `_repr_png_()`, and saved
`.ipynb` `image/png` payloads) directly beneath `# %%` cells inside the editor buffer:
- **Tier 1A (Kitty / Ghostty Virtual Placements)**: pixel-exact `U+10EEEE` grid placements
  (`U=1`) with row/column combining diacritics (`src/kittygfx.mojo`), which scroll, clip
  to pane splits/menus/dialogs, and pass through `tmux`.
- **Tier 1B (Sixel & Direct Kitty Pixel Overlays)**: full-pixel post-frame overlays for
  Sixel terminals (`foot`, `xterm`) and non-`U=1` Kitty terminals (`WezTerm`, `Konsole`),
  guarded by `Screen.blank_in` occlusion checks and invalidated cleanly on scroll/move.
- **Tier 2 (24-Bit Optimal 2×2 Unicode Quadrant `▘▝▀▖▌▞▛` Subpixel Canvas)**: area-averaged
  `2×2` subpixel RGB downsampling with least-squares 2-cluster truecolor partitioning —
  giving `2×` sharper horizontal resolution in Alacritty, `tmux`, SSH, and `--screenshot` SVG.
"""
from std.collections import List
from std.ffi import external_call
from kittygfx import (
    PLACEHOLDER,
    GFX_MAX_BYTES,
    GFX_CHUNK,
    kitty_diacritics,
    png_size,
    image_cells,
    kitty_transmit,
    kitty_delete,
    wrap_for_tmux,
)
from palette import ANSI_BASE
from png import png_decode, Picture
from screen import Screen
from sixel import scale_to, fit_pixels, sixel_encode
from util import read_file, path_exists, base64
from watch import file_sig

comptime CELL_IMG_MARK = "\x01IMG\t"
comptime CELL_NB_HDR_MARK = "\x01NBHDR\t"
comptime CELL_NB_SUB_MARK = "\x01NBSUB\t"
comptime CELL_NB_BOT_MARK = "\x01NBBOT"

comptime NB_IMG_QUADRANT = 0
comptime NB_IMG_KITTY_VIRTUAL = 1
comptime NB_IMG_SIXEL = 2
comptime NB_IMG_KITTY_DIRECT = 3

comptime NB_GFX_FIRST_ID = 200
comptime NB_GFX_LAST_ID = 255
comptime NB_QUAD_CACHE_MAX = 48
comptime NB_OVL_CACHE_MAX = 40
comptime ANIM_SPEC_PREFIX = "ANIM|"


def is_anim_spec(spec: String) -> Bool:
    return spec.startswith(String(ANIM_SPEC_PREFIX))


def build_anim_spec(fps: Int, frames: List[String]) -> String:
    var safe_fps = max(1, min(60, fps))
    return String(ANIM_SPEC_PREFIX) + String(safe_fps) + "|" + "|".join(frames)


def parse_anim_spec(spec: String) -> Tuple[Bool, Int, List[String]]:
    """Decode `ANIM|<fps>|<path0>|<path1>|...` into `(is_anim, fps, frame_paths)`."""
    var frames = List[String]()
    var pref = String(ANIM_SPEC_PREFIX)
    if not spec.startswith(pref):
        return (False, 0, frames^)
    var body = String(spec[byte=pref.byte_length() :])
    var parts = body.split("|")
    if len(parts) < 2:
        return (False, 0, frames^)
    var fps = max(1, min(60, _parse_nonneg_int(String(parts[0]), 16)))
    for k in range(1, len(parts)):
        var fp = String(parts[k].strip())
        if fp.byte_length() > 0:
            frames.append(fp)
    return (len(frames) > 0, fps, frames^)


def read_png_header_size(path: String) -> Tuple[Int, Int]:
    """Read only the first 24 bytes of `path` to extract PNG IHDR `(width, height)` in ~2 us."""
    if path.byte_length() == 0:
        return (-1, -1)
    var p = String(path)
    var mode = String("rb")
    var fp = external_call["fopen", Int](p.as_c_string_span(), mode.as_c_string_span())
    if fp == 0:
        return (-1, -1)
    var hdr = List[UInt8](length=24, fill=0)
    var n = external_call["fread", Int](hdr.unsafe_ptr(), Int(1), Int(24), fp)
    _ = external_call["fclose", Int32](fp)
    if n < 24:
        return (-1, -1)
    return png_size(hdr)


def cell_image_grid_size(
    pw: Int,
    ph: Int,
    ed_cols: Int,
    n_plots: Int,
    cell_w: Int = 10,
    cell_h: Int = 20,
    ed_rows: Int = 34,
) -> Tuple[Int, Int]:
    """Compute proportional `(cols, rows)` for an inline editor plot, sized generously for notebooks."""
    var max_cols = (
        max(14, min(60, ed_cols - 8))
        if n_plots > 1
        else max(16, min(72, ed_cols - 8))
    )
    var max_rows = (
        max(8, min(12, max(8, ed_rows // 3)))
        if n_plots > 1
        else max(10, min(18, max(12, (ed_rows * 56) // 100)))
    )
    var cw = cell_w if cell_w > 0 else 10
    var ch = cell_h if cell_h > 0 else 20
    var eff_w = max(1, pw)
    var eff_h = max(1, ph)
    # Upscale small ML images (e.g. 28x28 MNIST or 64x64 attention heatmaps) to a readable grid
    if eff_w >= 4 and eff_h >= 4 and eff_w < 200 and eff_h < 200:
        var scale = max(1, (20 * cw + eff_w - 1) // eff_w)
        eff_w *= scale
        eff_h *= scale
    return image_cells(eff_w, eff_h, max_cols, max_rows, cw, ch)


def encode_cell_img_line(path: String, row_i: Int, rows_n: Int, cols_n: Int) -> String:
    """Encode a virtual output row sentinel representing row `row_i` of an inline PNG image."""
    return (
        String(CELL_IMG_MARK)
        + path
        + "\t"
        + String(row_i)
        + "\t"
        + String(rows_n)
        + "\t"
        + String(cols_n)
    )


def _parse_nonneg_int(s: String, default_val: Int = 0) -> Int:
    if s.byte_length() == 0:
        return default_val
    var v = 0
    for b in s.as_bytes():
        if b < 48 or b > 57:
            return default_val
        v = v * 10 + (Int(b) - 48)
    return v


def decode_cell_img_line(vline: String) -> Tuple[Bool, String, Int, Int, Int]:
    """Decode `CELL_IMG_MARK` sentinel into `(ok, png_path, row_i, rows_n, cols_n)`."""
    var mark = String(CELL_IMG_MARK)
    if not vline.startswith(mark):
        return (False, "", 0, 0, 0)
    var body = String(vline[byte=mark.byte_length() :])
    var parts = body.split("\t")
    if len(parts) < 4:
        return (False, "", 0, 0, 0)
    var p = String(parts[0])
    var row_i = _parse_nonneg_int(String(parts[1]), 0)
    var rows_n = _parse_nonneg_int(String(parts[2]), 1)
    var cols_n = _parse_nonneg_int(String(parts[3]), 1)
    return (p.byte_length() > 0 and rows_n > 0 and cols_n > 0, p, row_i, rows_n, cols_n)


def _box_sample_rgb(
    pic: Picture,
    x0_num: Int,
    x1_num: Int,
    w_den: Int,
    y0_num: Int,
    y1_num: Int,
    h_den: Int,
    bg_rgb: Int,
) -> Int:
    """Area-averaged RGB sample over `[x0..x1) x [y0..y1)` of `pic`, alpha-composited over `bg_rgb`."""
    var sx0 = max(0, min(pic.w - 1, x0_num // w_den))
    var sx1 = max(sx0 + 1, min(pic.w, (x1_num + w_den - 1) // w_den))
    var sy0 = max(0, min(pic.h - 1, y0_num // h_den))
    var sy1 = max(sy0 + 1, min(pic.h, (y1_num + h_den - 1) // h_den))
    var step_x = max(1, (sx1 - sx0) // 6)
    var step_y = max(1, (sy1 - sy0) // 6)
    var br = (bg_rgb >> 16) & 255
    var bg = (bg_rgb >> 8) & 255
    var bb = bg_rgb & 255
    var sum_r = 0
    var sum_g = 0
    var sum_b = 0
    var count = 0
    var py = sy0
    while py < sy1:
        var px = sx0
        while px < sx1:
            var off = (py * pic.w + px) * 4
            var r = Int(pic.rgba[off])
            var g = Int(pic.rgba[off + 1])
            var b = Int(pic.rgba[off + 2])
            var a = Int(pic.rgba[off + 3])
            if a < 255:
                r = (r * a + br * (255 - a) + 127) // 255
                g = (g * a + bg * (255 - a) + 127) // 255
                b = (b * a + bb * (255 - a) + 127) // 255
            sum_r += r
            sum_g += g
            sum_b += b
            count += 1
            px += step_x
        py += step_y
    if count <= 0:
        return bg_rgb
    var rr = (sum_r + count // 2) // count
    var gg = (sum_g + count // 2) // count
    var bb_out = (sum_b + count // 2) // count
    return ((rr & 255) << 16) | ((gg & 255) << 8) | (bb_out & 255)


def _rgb_dist2(c1: Int, c2: Int) -> Int:
    var dr = ((c1 >> 16) & 255) - ((c2 >> 16) & 255)
    var dg = ((c1 >> 8) & 255) - ((c2 >> 8) & 255)
    var db = (c1 & 255) - (c2 & 255)
    return dr * dr + dg * dg + db * db


def _scanline_dim_rgb(rgb: Int) -> Int:
    if rgb < 0 or rgb > 0xFFFFFF:
        return rgb
    var r = ((rgb >> 16) & 255) * 78 // 100
    var g = ((rgb >> 8) & 255) * 78 // 100
    var b = (rgb & 255) * 78 // 100
    return (r << 16) | (g << 8) | b


def _overlay_unoccluded(scr: Screen, x: Int, y: Int, w: Int, h: Int, bg: Int) -> Bool:
    """True when every cell in `(x, y, w, h)` is untouched blank image backing (`bg` or CRT scanline dim)."""
    if x < 0 or y < 0 or x + w > scr.w or y + h > scr.h:
        return False
    var dim_bg = _scanline_dim_rgb(bg)
    for yy in range(y, y + h):
        for xx in range(x, x + w):
            var k = yy * scr.w + xx
            if scr.ch[k] != 32 or scr.cmb[k] != 0:
                return False
            var cbg = scr.bg[k]
            if cbg != bg and cbg != dim_bg:
                return False
    return True


def _quadrant_best_cell(p0: Int, p1: Int, p2: Int, p3: Int) -> Tuple[Int, Int, Int]:
    """Choose the optimal 2-color Unicode 2×2 quadrant `(glyph, fg_rgb, bg_rgb)` for 4 subpixels.
    Uses seamless `▀` (`0x2580`) on smooth gradients to prevent font subpixel vertical hairlines,
    switching to split-horizontal 2×2 quadrants (`▘▝▖▌▞▛`) on genuine high-contrast edges."""
    if p0 == p1 and p0 == p2 and p0 == p3:
        return (0x2580, p0, p0)
    var glyphs: List[Int] = [0x2580, 0x2598, 0x259D, 0x2580, 0x2596, 0x258C, 0x259E, 0x259B]
    var px: List[Int] = [p0, p1, p2, p3]
    # Baseline: horizontal half-block `▀` (m == 3: top = avg(p0, p1), bottom = avg(p2, p3))
    var top_fg = (
        (((((p0 >> 16) & 255) + ((p1 >> 16) & 255) + 1) // 2) << 16)
        | (((((p0 >> 8) & 255) + ((p1 >> 8) & 255) + 1) // 2) << 8)
        | ((((p0 & 255) + (p1 & 255) + 1) // 2))
    )
    var bot_bg = (
        (((((p2 >> 16) & 255) + ((p3 >> 16) & 255) + 1) // 2) << 16)
        | (((((p2 >> 8) & 255) + ((p3 >> 8) & 255) + 1) // 2) << 8)
        | ((((p2 & 255) + (p3 & 255) + 1) // 2))
    )
    var err_hb = (
        _rgb_dist2(p0, top_fg)
        + _rgb_dist2(p1, top_fg)
        + _rgb_dist2(p2, bot_bg)
        + _rgb_dist2(p3, bot_bg)
    )
    var best_ch = 0x2580
    var best_fg = top_fg
    var best_bg = bot_bg
    # Require a meaningful edge improvement (>= 900 sq RGB units) before splitting horizontally
    var best_err = max(0, err_hb - 900)
    for m in range(1, 8):
        if m == 3:
            continue
        var sr1 = 0
        var sg1 = 0
        var sb1 = 0
        var n1 = 0
        var sr0 = 0
        var sg0 = 0
        var sb0 = 0
        var n0 = 0
        for k in range(4):
            var c = px[k]
            if ((m >> k) & 1) != 0:
                sr1 += (c >> 16) & 255
                sg1 += (c >> 8) & 255
                sb1 += c & 255
                n1 += 1
            else:
                sr0 += (c >> 16) & 255
                sg0 += (c >> 8) & 255
                sb0 += c & 255
                n0 += 1
        var fg = (
            (((sr1 + n1 // 2) // n1) << 16)
            | (((sg1 + n1 // 2) // n1) << 8)
            | ((sb1 + n1 // 2) // n1)
        )
        var bg = (
            (((sr0 + n0 // 2) // n0) << 16)
            | (((sg0 + n0 // 2) // n0) << 8)
            | ((sb0 + n0 // 2) // n0)
        )
        var err = 0
        for k in range(4):
            err += _rgb_dist2(px[k], fg if ((m >> k) & 1) != 0 else bg)
        if err < best_err:
            best_err = err
            best_ch = glyphs[m]
            best_fg = fg
            best_bg = bg
    return (best_ch, best_fg, best_bg)


def build_halfblock_canvas(
    pic: Picture, cols_n: Int, rows_n: Int, bg_rgb: Int
) -> Tuple[List[Int], List[Int]]:
    """Downsample `pic` into `(top_rgb, bot_rgb)` arrays of length `cols_n * rows_n` for `▀` (`U+2580`)."""
    var total = cols_n * rows_n
    var top_px = List[Int](length=total, fill=bg_rgb)
    var bot_px = List[Int](length=total, fill=bg_rgb)
    if not pic.ok or pic.w <= 0 or pic.h <= 0 or cols_n <= 0 or rows_n <= 0:
        return (top_px^, bot_px^)
    var h2 = rows_n * 2
    for r in range(rows_n):
        var y_top0 = (r * 2) * pic.h
        var y_top1 = (r * 2 + 1) * pic.h
        var y_bot0 = y_top1
        var y_bot1 = (r * 2 + 2) * pic.h
        for c in range(cols_n):
            var x0 = c * pic.w
            var x1 = (c + 1) * pic.w
            var idx = r * cols_n + c
            top_px[idx] = _box_sample_rgb(pic, x0, x1, cols_n, y_top0, y_top1, h2, bg_rgb)
            bot_px[idx] = _box_sample_rgb(pic, x0, x1, cols_n, y_bot0, y_bot1, h2, bg_rgb)
    return (top_px^, bot_px^)


def build_quadrant_canvas(
    pic: Picture, cols_n: Int, rows_n: Int, bg_rgb: Int
) -> Tuple[List[Int], List[Int], List[Int]]:
    """Downsample `pic` at `2×2` subpixel resolution into `(ch, fg_rgb, bg_rgb)` arrays (`U+2580..U+259F`)."""
    var total = cols_n * rows_n
    var ch_arr = List[Int](length=total, fill=0x2580)
    var fg_arr = List[Int](length=total, fill=bg_rgb)
    var bg_arr = List[Int](length=total, fill=bg_rgb)
    if not pic.ok or pic.w <= 0 or pic.h <= 0 or cols_n <= 0 or rows_n <= 0:
        return (ch_arr^, fg_arr^, bg_arr^)
    var w2 = cols_n * 2
    var h2 = rows_n * 2
    for r in range(rows_n):
        var y0 = (r * 2) * pic.h
        var y1 = (r * 2 + 1) * pic.h
        var y2 = (r * 2 + 2) * pic.h
        for c in range(cols_n):
            var x0 = (c * 2) * pic.w
            var x1 = (c * 2 + 1) * pic.w
            var x2 = (c * 2 + 2) * pic.w
            var p0 = _box_sample_rgb(pic, x0, x1, w2, y0, y1, h2, bg_rgb)
            var p1 = _box_sample_rgb(pic, x1, x2, w2, y0, y1, h2, bg_rgb)
            var p2 = _box_sample_rgb(pic, x0, x1, w2, y1, y2, h2, bg_rgb)
            var p3 = _box_sample_rgb(pic, x1, x2, w2, y1, y2, h2, bg_rgb)
            var best = _quadrant_best_cell(p0, p1, p2, p3)
            var idx = r * cols_n + c
            ch_arr[idx] = best[0]
            fg_arr[idx] = best[1]
            bg_arr[idx] = best[2]
    return (ch_arr^, fg_arr^, bg_arr^)


def kitty_direct_transmit(id: Int, png: List[UInt8], cols: Int, rows: Int, tmux: Bool) -> String:
    """Transmit & display PNG directly at the current cursor via Kitty APC without `U=1` (for WezTerm/Konsole)."""
    var data = base64(png)
    var n = data.byte_length()
    var out = String("")
    var at = 0
    var first = True
    while first or at < n:
        var end = min(n, at + GFX_CHUNK)
        var more = 1 if end < n else 0
        var head: String
        if first:
            head = (
                "a=T,f=100,t=d,i="
                + String(id)
                + ",c="
                + String(cols)
                + ",r="
                + String(rows)
                + ",C=1,q=2,m="
                + String(more)
            )
        else:
            head = "m=" + String(more) + ",q=2"
        var apc = "\x1b_G" + head + ";" + String(data[byte=at:end]) + "\x1b\\"
        out += wrap_for_tmux(apc) if tmux else apc
        at = end
        first = False
    return out


def crop_picture(pic: Picture, zoom_pct: Int, pan_x_pm: Int, pan_y_pm: Int) -> Picture:
    """Extract a zoomed sub-rectangle of `pic` centered at `(pan_x_pm/1000, pan_y_pm/1000)`."""
    var out = Picture()
    if not pic.ok or pic.w <= 0 or pic.h <= 0:
        return out^
    var z = max(100, zoom_pct)
    var cw = max(1, min(pic.w, (pic.w * 100 + z // 2) // z))
    var ch = max(1, min(pic.h, (pic.h * 100 + z // 2) // z))
    var px_clamped = max(0, min(1000, pan_x_pm))
    var py_clamped = max(0, min(1000, pan_y_pm))
    var x0 = ((pic.w - cw) * px_clamped + 500) // 1000
    var y0 = ((pic.h - ch) * py_clamped + 500) // 1000
    out.ok = True
    out.w = cw
    out.h = ch
    out.rgba = List[UInt8](length=cw * ch * 4, fill=0)
    for ry in range(ch):
        var src_row = (y0 + ry) * pic.w * 4
        var dst_row = ry * cw * 4
        for rx in range(cw * 4):
            out.rgba[dst_row + rx] = pic.rgba[src_row + x0 * 4 + rx]
    return out^


def kitty_rgba_transmit(
    id: Int, pic: Picture, cols: Int, rows: Int, tmux: Bool, virtual_place: Bool
) -> String:
    """Transmit cropped 32-bit RGBA `Picture` (`f=32,s=w,v=h`) for zoomed `WK_IMGVIEW` rendering."""
    var send_w = pic.w
    var send_h = pic.h
    var raw: List[UInt8]
    if send_w > 640 or send_h > 640:
        var fp = fit_pixels(send_w, send_h, 640, 640)
        send_w = fp[0]
        send_h = fp[1]
        raw = scale_to(pic, send_w, send_h)
    else:
        raw = pic.rgba.copy()
    var data = base64(raw)
    var n = data.byte_length()
    var out = String("")
    var at = 0
    var first = True
    while first or at < n:
        var end = min(n, at + GFX_CHUNK)
        var more = 1 if end < n else 0
        var head: String
        if first:
            head = (
                "a=T,"
                + ("U=1," if virtual_place else "")
                + "f=32,s="
                + String(send_w)
                + ",v="
                + String(send_h)
                + ",t=d,i="
                + String(id)
                + ",c="
                + String(cols)
                + ",r="
                + String(rows)
                + ("" if virtual_place else ",C=1")
                + ",q=2,m="
                + String(more)
            )
        else:
            head = "m=" + String(more) + ",q=2"
        var apc = "\x1b_G" + head + ";" + String(data[byte=at:end]) + "\x1b\\"
        out += wrap_for_tmux(apc) if tmux else apc
        at = end
        first = False
    return out


struct InlineImageCache(Copyable, Movable):
    var kitty_keys: List[String]
    var kitty_ids: List[Int]
    var kitty_next_id: Int
    var diac: List[Int]
    var pending_out: String
    var q_keys: List[String]
    var q_cols: List[Int]
    var q_rows: List[Int]
    var q_ch: List[List[Int]]
    var q_fg: List[List[Int]]
    var q_bg: List[List[Int]]
    # Cached Sixel / Direct-Kitty payloads & per-frame screen placement tracking
    var ovl_keys: List[String]
    var ovl_seqs: List[String]
    var ovl_ids: List[Int]
    var cur_keys: List[String]
    var cur_x: List[Int]
    var cur_y: List[Int]
    var cur_cols: List[Int]
    var cur_rows: List[Int]
    var cur_vis: List[Int]
    var cur_bg: List[Int]
    var cur_seqs: List[String]
    var cur_ids: List[Int]
    var shown_keys: List[String]
    var shown_x: List[Int]
    var shown_y: List[Int]
    var shown_cols: List[Int]
    var shown_rows: List[Int]
    var shown_ids: List[Int]

    def __init__(out self):
        self.kitty_keys = List[String]()
        self.kitty_ids = List[Int]()
        self.kitty_next_id = NB_GFX_FIRST_ID
        self.diac = List[Int]()
        self.pending_out = ""
        self.q_keys = List[String]()
        self.q_cols = List[Int]()
        self.q_rows = List[Int]()
        self.q_ch = List[List[Int]]()
        self.q_fg = List[List[Int]]()
        self.q_bg = List[List[Int]]()
        self.ovl_keys = List[String]()
        self.ovl_seqs = List[String]()
        self.ovl_ids = List[Int]()
        self.cur_keys = List[String]()
        self.cur_x = List[Int]()
        self.cur_y = List[Int]()
        self.cur_cols = List[Int]()
        self.cur_rows = List[Int]()
        self.cur_vis = List[Int]()
        self.cur_bg = List[Int]()
        self.cur_seqs = List[String]()
        self.cur_ids = List[Int]()
        self.shown_keys = List[String]()
        self.shown_x = List[Int]()
        self.shown_y = List[Int]()
        self.shown_cols = List[Int]()
        self.shown_rows = List[Int]()
        self.shown_ids = List[Int]()

    def clear(mut self, tmux: Bool):
        for kid in self.kitty_ids:
            if kid > 0:
                self.pending_out += kitty_delete(kid, tmux)
        for sid in self.shown_ids:
            if sid > 0:
                self.pending_out += kitty_delete(sid, tmux)
        self.kitty_keys.clear()
        self.kitty_ids.clear()
        self.q_keys.clear()
        self.q_cols.clear()
        self.q_rows.clear()
        self.q_ch.clear()
        self.q_fg.clear()
        self.q_bg.clear()
        self.ovl_keys.clear()
        self.ovl_seqs.clear()
        self.ovl_ids.clear()
        self.begin_frame()
        self.shown_keys.clear()
        self.shown_x.clear()
        self.shown_y.clear()
        self.shown_cols.clear()
        self.shown_rows.clear()
        self.shown_ids.clear()

    def begin_frame(mut self):
        self.cur_keys.clear()
        self.cur_x.clear()
        self.cur_y.clear()
        self.cur_cols.clear()
        self.cur_rows.clear()
        self.cur_vis.clear()
        self.cur_bg.clear()
        self.cur_seqs.clear()
        self.cur_ids.clear()

    def _next_id(mut self) -> Int:
        var id = self.kitty_next_id
        self.kitty_next_id = NB_GFX_FIRST_ID if id >= NB_GFX_LAST_ID else id + 1
        return id

    def _ensure_kitty_id(
        mut self,
        cache_key: String,
        png_path: String,
        cols_n: Int,
        rows_n: Int,
        tmux: Bool,
    ) -> Int:
        for i in range(len(self.kitty_keys)):
            if self.kitty_keys[i] == cache_key:
                return self.kitty_ids[i]
        if not path_exists(png_path):
            return 0
        var data = read_file(png_path)
        if len(data) == 0 or len(data) > GFX_MAX_BYTES:
            return 0
        if png_size(data)[0] <= 0:
            return 0
        var id = self._next_id()
        var kept_k = List[String]()
        var kept_i = List[Int]()
        var evicted = False
        for i in range(len(self.kitty_ids)):
            if self.kitty_ids[i] == id:
                evicted = True
            else:
                kept_k.append(self.kitty_keys[i])
                kept_i.append(self.kitty_ids[i])
        if evicted:
            self.pending_out += kitty_delete(id, tmux)
        self.kitty_keys = kept_k^
        self.kitty_ids = kept_i^
        self.pending_out += kitty_transmit(id, data, cols_n, rows_n, tmux)
        self.kitty_keys.append(cache_key)
        self.kitty_ids.append(id)
        return id

    def _ensure_overlay_seq(
        mut self,
        cache_key: String,
        png_path: String,
        cols_n: Int,
        rows_n: Int,
        bg_rgb: Int,
        cell_w: Int,
        cell_h: Int,
        gfx_mode: Int,
        tmux: Bool,
    ) -> Int:
        for i in range(len(self.ovl_keys)):
            if self.ovl_keys[i] == cache_key:
                return i
        if not path_exists(png_path):
            return -1
        var data = read_file(png_path)
        if len(data) == 0 or len(data) > GFX_MAX_BYTES:
            return -1
        if png_size(data)[0] <= 0:
            return -1
        var seq: String
        var kid = 0
        if gfx_mode == NB_IMG_SIXEL:
            var pic = png_decode(data)
            if not pic.ok:
                return -1
            var cw = cell_w if cell_w > 0 else 10
            var ch = cell_h if cell_h > 0 else 20
            var px = fit_pixels(pic.w, pic.h, cols_n * cw, rows_n * ch)
            var safe_bg = bg_rgb if (bg_rgb >= 0 and bg_rgb <= 0xFFFFFF) else 0x1E1E2E
            seq = sixel_encode(scale_to(pic, px[0], px[1]), px[0], px[1], safe_bg)
        elif gfx_mode == NB_IMG_KITTY_DIRECT:
            kid = self._next_id()
            seq = kitty_direct_transmit(kid, data, cols_n, rows_n, tmux)
        else:
            return -1
        if len(self.ovl_keys) >= NB_OVL_CACHE_MAX:
            _ = self.ovl_keys.pop(0)
            _ = self.ovl_seqs.pop(0)
            var old_id = self.ovl_ids.pop(0)
            if old_id > 0:
                self.pending_out += kitty_delete(old_id, tmux)
        self.ovl_keys.append(cache_key)
        self.ovl_seqs.append(seq)
        self.ovl_ids.append(kid)
        return len(self.ovl_keys) - 1

    def _ensure_quadrant(
        mut self, cache_key: String, png_path: String, cols_n: Int, rows_n: Int, bg_rgb: Int
    ) -> Int:
        for i in range(len(self.q_keys)):
            if self.q_keys[i] == cache_key:
                return i
        if not path_exists(png_path):
            return -1
        var data = read_file(png_path)
        if len(data) == 0 or len(data) > GFX_MAX_BYTES:
            return -1
        var pic = png_decode(data)
        if not pic.ok:
            return -1
        if len(self.q_keys) >= NB_QUAD_CACHE_MAX:
            _ = self.q_keys.pop(0)
            _ = self.q_cols.pop(0)
            _ = self.q_rows.pop(0)
            _ = self.q_ch.pop(0)
            _ = self.q_fg.pop(0)
            _ = self.q_bg.pop(0)
        var safe_bg = bg_rgb if (bg_rgb >= 0 and bg_rgb <= 0xFFFFFF) else 0x1E1E2E
        var canvas = build_quadrant_canvas(pic, cols_n, rows_n, safe_bg)
        self.q_keys.append(cache_key)
        self.q_cols.append(cols_n)
        self.q_rows.append(rows_n)
        self.q_ch.append(canvas[0].copy())
        self.q_fg.append(canvas[1].copy())
        self.q_bg.append(canvas[2].copy())
        return len(self.q_keys) - 1

    def _record_overlay_row(
        mut self,
        inst_key: String,
        x0: Int,
        y: Int,
        draw_w: Int,
        rows_n: Int,
        img_row: Int,
        bg_rgb: Int,
        seq: String,
        kid: Int,
    ):
        for i in range(len(self.cur_keys)):
            if self.cur_keys[i] == inst_key:
                if img_row == 0:
                    self.cur_x[i] = x0
                    self.cur_y[i] = y
                self.cur_vis[i] += 1
                return
        self.cur_keys.append(inst_key)
        self.cur_x.append(x0)
        self.cur_y.append(y - img_row)
        self.cur_cols.append(draw_w)
        self.cur_rows.append(rows_n)
        self.cur_vis.append(1)
        self.cur_bg.append(bg_rgb)
        self.cur_seqs.append(seq)
        self.cur_ids.append(kid)

    def prepare_overlays(mut self, mut scr: Screen, tmux: Bool) -> String:
        """Reconcile post-frame Sixel / Direct-Kitty overlays with `scr` occlusion and scroll state."""
        if len(self.shown_keys) == 0 and len(self.cur_keys) == 0:
            return ""
        var emit = String("")
        # 1. Wipe any previously shown overlay that moved, scrolled partially out, or disappeared
        for oi in range(len(self.shown_keys)):
            var sk = self.shown_keys[oi]
            var sx = self.shown_x[oi]
            var sy = self.shown_y[oi]
            var sc = self.shown_cols[oi]
            var sr = self.shown_rows[oi]
            var sid = self.shown_ids[oi]
            var still_same = False
            for ci in range(len(self.cur_keys)):
                if (
                    self.cur_keys[ci] == sk
                    and self.cur_vis[ci] == self.cur_rows[ci]
                    and self.cur_x[ci] == sx
                    and self.cur_y[ci] == sy
                    and self.cur_cols[ci] == sc
                    and self.cur_rows[ci] == sr
                    and sy >= 0
                    and sy + sr < scr.h
                    and _overlay_unoccluded(scr, sx, sy, sc, sr, self.cur_bg[ci])
                ):
                    still_same = True
                    break
            if not still_same:
                scr.invalidate(sx, sy, sc, sr)
                if sid > 0:
                    self.pending_out += kitty_delete(sid, tmux)

        var next_keys = List[String]()
        var next_x = List[Int]()
        var next_y = List[Int]()
        var next_cols = List[Int]()
        var next_rows = List[Int]()
        var next_ids = List[Int]()

        # 2. Emit overlays that are wholly visible inside the pane and unoccluded by menus/dialogs
        for ci in range(len(self.cur_keys)):
            var ck = self.cur_keys[ci]
            var cx = self.cur_x[ci]
            var cy = self.cur_y[ci]
            var cc = self.cur_cols[ci]
            var cr = self.cur_rows[ci]
            var cid = self.cur_ids[ci]
            if self.cur_vis[ci] != cr or cy < 0 or cy + cr >= scr.h:
                continue
            if not _overlay_unoccluded(scr, cx, cy, cc, cr, self.cur_bg[ci]):
                continue
            var was_shown = False
            for oi in range(len(self.shown_keys)):
                if (
                    self.shown_keys[oi] == ck
                    and self.shown_x[oi] == cx
                    and self.shown_y[oi] == cy
                    and self.shown_cols[oi] == cc
                    and self.shown_rows[oi] == cr
                ):
                    was_shown = True
                    break
            if not was_shown or scr.changed_in(cx, cy, cc, cr):
                emit += "\x1b[" + String(cy + 1) + ";" + String(cx + 1) + "H" + self.cur_seqs[ci]
            next_keys.append(ck)
            next_x.append(cx)
            next_y.append(cy)
            next_cols.append(cc)
            next_rows.append(cr)
            next_ids.append(cid)

        self.shown_keys = next_keys^
        self.shown_x = next_x^
        self.shown_y = next_y^
        self.shown_cols = next_cols^
        self.shown_rows = next_rows^
        self.shown_ids = next_ids^
        self.begin_frame()
        return emit

    def draw_image_row(
        mut self,
        mut scr: Screen,
        x0: Int,
        y: Int,
        max_w: Int,
        bg_rgb: Int,
        png_path: String,
        img_row: Int,
        rows_n: Int,
        cols_n: Int,
        gfx_mode: Int,
        tmux: Bool,
        cell_w: Int = 10,
        cell_h: Int = 20,
        inst_tag: Int = 0,
        win_y0: Int = 1,
        win_y1: Int = 9999,
    ):
        """Render row `img_row` of `png_path` onto `scr` at `(x0, y)` via Kitty virtual
        placement, Sixel / Direct-Kitty pixel overlay, or 24-bit 2×2 Quadrant subpixels."""
        if max_w <= 0 or img_row < 0 or img_row >= rows_n:
            return
        if scr.plain:
            if img_row == 0:
                _ = scr.text(x0, y, "[Image: " + png_path + "]", 0xFFFFFF, 0)
            return
        var sig = file_sig(png_path)
        if not sig.exists:
            return
        var eff_cols = min(cols_n, 290)
        var eff_rows = min(rows_n, 290)
        var draw_w = min(eff_cols, max_w)
        var base_key = (
            png_path
            + "|"
            + String(sig.size)
            + "|"
            + String(sig.mtime_s)
            + "|"
            + String(sig.mtime_ns)
            + "|"
            + String(draw_w)
            + "x"
            + String(eff_rows)
        )
        if gfx_mode == NB_IMG_KITTY_VIRTUAL:
            var kid = self._ensure_kitty_id(base_key, png_path, draw_w, eff_rows, tmux)
            if kid > 0:
                if len(self.diac) == 0:
                    self.diac = kitty_diacritics()
                if img_row < len(self.diac):
                    var kfg = ANSI_BASE + kid
                    for c in range(draw_w):
                        if c < len(self.diac):
                            scr.put(x0 + c, y, PLACEHOLDER, kfg, bg_rgb)
                            scr.combine(x0 + c, y, self.diac[img_row])
                            scr.combine(x0 + c, y, self.diac[c])
                    return
        elif gfx_mode == NB_IMG_SIXEL or gfx_mode == NB_IMG_KITTY_DIRECT:
            var ovl_key = base_key + "|m" + String(gfx_mode) + "|" + String(bg_rgb) + "|" + String(cell_w) + "x" + String(cell_h)
            var oi = self._ensure_overlay_seq(
                ovl_key, png_path, draw_w, eff_rows, bg_rgb, cell_w, cell_h, gfx_mode, tmux
            )
            if oi >= 0:
                # Only use post-frame overlay when the entire image vertically fits in the screen;
                # if partially scrolled off-top/bottom, seamlessly render crisp 2x2 Quadrant subpixels!
                var est_top = y - img_row
                if est_top >= max(1, win_y0) and est_top + eff_rows <= min(win_y1, scr.h - 1):
                    var oseq = String(self.ovl_seqs[oi])
                    var oid = self.ovl_ids[oi]
                    scr.fill(x0, y, draw_w, 1, 32, bg_rgb, bg_rgb)
                    self._record_overlay_row(
                        ovl_key + "|#" + String(inst_tag),
                        x0,
                        y,
                        draw_w,
                        eff_rows,
                        img_row,
                        bg_rgb,
                        oseq,
                        oid,
                    )
                    return

        var qi = self._ensure_quadrant(base_key + "|" + String(bg_rgb), png_path, draw_w, eff_rows, bg_rgb)
        if qi < 0:
            return
        var row_off = img_row * draw_w
        for c in range(draw_w):
            var idx = row_off + c
            if idx < len(self.q_ch[qi]):
                scr.put(x0 + c, y, self.q_ch[qi][idx], self.q_fg[qi][idx], self.q_bg[qi][idx])

    def invalidate_shown(mut self, mut scr: Screen):
        """Mark any currently shown Sixel / Direct-Kitty overlay cells dirty on `scr`."""
        for oi in range(len(self.shown_keys)):
            scr.invalidate(
                self.shown_x[oi], self.shown_y[oi], self.shown_cols[oi], self.shown_rows[oi]
            )

    def draw_zoomed_view(
        mut self,
        mut scr: Screen,
        inner_x: Int,
        inner_y: Int,
        inner_w: Int,
        inner_h: Int,
        bg_rgb: Int,
        png_path: String,
        zoom_pct: Int,
        pan_x_pm: Int,
        pan_y_pm: Int,
        gfx_mode: Int,
        tmux: Bool,
        cell_w: Int = 10,
        cell_h: Int = 20,
    ):
        """Render `png_path` centered inside `(inner_x, inner_y, inner_w, inner_h)` for `WK_IMGVIEW`
        with full support for `100%` Fit-to-Window and `>100%` pan & crop magnification."""
        if inner_w <= 2 or inner_h <= 1:
            return
        if scr.plain:
            _ = scr.text(inner_x + 1, inner_y + inner_h // 2, "[Image: " + png_path + "]", 0xFFFFFF, 0)
            return
        var sig = file_sig(png_path)
        if not sig.exists:
            return
        var sz = read_png_header_size(png_path)
        if sz[0] <= 0 or sz[1] <= 0:
            return
        var cw = cell_w if cell_w > 0 else 10
        var ch = cell_h if cell_h > 0 else 20
        var z = max(100, zoom_pct)
        var eff_pw = max(1, (sz[0] * 100 + z // 2) // z)
        var eff_ph = max(1, (sz[1] * 100 + z // 2) // z)
        # Scale image proportionally to fill the dedicated zoom window cleanly!
        var max_c = max(4, min(290, inner_w - 2))
        var max_r = max(2, min(290, inner_h))
        var fitted = fit_pixels(eff_pw, eff_ph, max_c * cw, max_r * ch)
        var gsz = image_cells(fitted[0], fitted[1], max_c, max_r, cw, ch)
        var cols_n = gsz[0]
        var rows_n = gsz[1]
        var x0 = inner_x + max(0, (inner_w - cols_n) // 2)
        var y0 = inner_y + max(0, (inner_h - rows_n) // 2)

        # At 100% fit, reuse the fast direct PNG pipeline row-by-row!
        if z <= 100:
            for ri in range(rows_n):
                self.draw_image_row(
                    scr,
                    x0,
                    y0 + ri,
                    cols_n,
                    bg_rgb,
                    png_path,
                    ri,
                    rows_n,
                    cols_n,
                    gfx_mode,
                    tmux,
                    cw,
                    ch,
                    9000,
                    inner_y,
                    inner_y + inner_h,
                )
            return

        # Magnified crop (`z > 100`): cache by `(sig, cols_n x rows_n, zoom, pan_x, pan_y)`
        var zkey = (
            png_path
            + "|"
            + String(sig.size)
            + "|"
            + String(sig.mtime_s)
            + "|"
            + String(sig.mtime_ns)
            + "|"
            + String(cols_n)
            + "x"
            + String(rows_n)
            + "|z"
            + String(z)
            + "@"
            + String(pan_x_pm)
            + ","
            + String(pan_y_pm)
        )
        if gfx_mode == NB_IMG_KITTY_VIRTUAL:
            var kid = 0
            for i in range(len(self.kitty_keys)):
                if self.kitty_keys[i] == zkey:
                    kid = self.kitty_ids[i]
                    break
            if kid == 0:
                var raw_bytes = read_file(png_path)
                if len(raw_bytes) > 0 and len(raw_bytes) <= GFX_MAX_BYTES:
                    var full_pic = png_decode(raw_bytes)
                    if full_pic.ok:
                        var cropped = crop_picture(full_pic, z, pan_x_pm, pan_y_pm)
                        if cropped.ok:
                            var new_id = self._next_id()
                            var kept_k = List[String]()
                            var kept_i = List[Int]()
                            var evicted = False
                            for i in range(len(self.kitty_ids)):
                                if self.kitty_ids[i] == new_id:
                                    evicted = True
                                else:
                                    kept_k.append(self.kitty_keys[i])
                                    kept_i.append(self.kitty_ids[i])
                            if evicted:
                                self.pending_out += kitty_delete(new_id, tmux)
                            self.kitty_keys = kept_k^
                            self.kitty_ids = kept_i^
                            self.pending_out += kitty_rgba_transmit(
                                new_id, cropped, cols_n, rows_n, tmux, True
                            )
                            self.kitty_keys.append(zkey)
                            self.kitty_ids.append(new_id)
                            kid = new_id
            if kid > 0:
                if len(self.diac) == 0:
                    self.diac = kitty_diacritics()
                var kfg = ANSI_BASE + kid
                for r in range(rows_n):
                    if r < len(self.diac):
                        for c in range(cols_n):
                            if c < len(self.diac):
                                scr.put(x0 + c, y0 + r, PLACEHOLDER, kfg, bg_rgb)
                                scr.combine(x0 + c, y0 + r, self.diac[r])
                                scr.combine(x0 + c, y0 + r, self.diac[c])
                return

        elif (gfx_mode == NB_IMG_SIXEL or gfx_mode == NB_IMG_KITTY_DIRECT) and y0 >= 1 and y0 + rows_n <= scr.h - 1:
            var ovl_zkey = zkey + "|m" + String(gfx_mode) + "|" + String(bg_rgb) + "|" + String(cw) + "x" + String(ch)
            var oi = -1
            for i in range(len(self.ovl_keys)):
                if self.ovl_keys[i] == ovl_zkey:
                    oi = i
                    break
            if oi < 0:
                var raw_bytes = read_file(png_path)
                if len(raw_bytes) > 0 and len(raw_bytes) <= GFX_MAX_BYTES:
                    var full_pic = png_decode(raw_bytes)
                    if full_pic.ok:
                        var cropped = crop_picture(full_pic, z, pan_x_pm, pan_y_pm)
                        if cropped.ok:
                            var seq: String
                            var kid_d = 0
                            if gfx_mode == NB_IMG_SIXEL:
                                var px = fit_pixels(cropped.w, cropped.h, cols_n * cw, rows_n * ch)
                                var safe_bg = bg_rgb if (bg_rgb >= 0 and bg_rgb <= 0xFFFFFF) else 0x1E1E2E
                                seq = sixel_encode(scale_to(cropped, px[0], px[1]), px[0], px[1], safe_bg)
                            else:
                                kid_d = self._next_id()
                                seq = kitty_rgba_transmit(kid_d, cropped, cols_n, rows_n, tmux, False)
                            if len(self.ovl_keys) >= NB_OVL_CACHE_MAX:
                                _ = self.ovl_keys.pop(0)
                                _ = self.ovl_seqs.pop(0)
                                var old_id = self.ovl_ids.pop(0)
                                if old_id > 0:
                                    self.pending_out += kitty_delete(old_id, tmux)
                            self.ovl_keys.append(ovl_zkey)
                            self.ovl_seqs.append(seq)
                            self.ovl_ids.append(kid_d)
                            oi = len(self.ovl_keys) - 1
            if oi >= 0:
                var oseq = String(self.ovl_seqs[oi])
                var oid = self.ovl_ids[oi]
                for r in range(rows_n):
                    scr.fill(x0, y0 + r, cols_n, 1, 32, bg_rgb, bg_rgb)
                    self._record_overlay_row(
                        ovl_zkey + "|#9001",
                        x0,
                        y0 + r,
                        cols_n,
                        rows_n,
                        r,
                        bg_rgb,
                        oseq,
                        oid,
                    )
                return

        # 24-bit 2x2 Quadrant subpixel zoomed canvas
        var qz_key = zkey + "|" + String(bg_rgb)
        var qi = -1
        for i in range(len(self.q_keys)):
            if self.q_keys[i] == qz_key:
                qi = i
                break
        if qi < 0:
            var raw_bytes = read_file(png_path)
            if len(raw_bytes) > 0 and len(raw_bytes) <= GFX_MAX_BYTES:
                var full_pic = png_decode(raw_bytes)
                if full_pic.ok:
                    var cropped = crop_picture(full_pic, z, pan_x_pm, pan_y_pm)
                    if cropped.ok:
                        if len(self.q_keys) >= NB_QUAD_CACHE_MAX:
                            _ = self.q_keys.pop(0)
                            _ = self.q_cols.pop(0)
                            _ = self.q_rows.pop(0)
                            _ = self.q_ch.pop(0)
                            _ = self.q_fg.pop(0)
                            _ = self.q_bg.pop(0)
                        var safe_bg = bg_rgb if (bg_rgb >= 0 and bg_rgb <= 0xFFFFFF) else 0x1E1E2E
                        var canvas = build_quadrant_canvas(cropped, cols_n, rows_n, safe_bg)
                        self.q_keys.append(qz_key)
                        self.q_cols.append(cols_n)
                        self.q_rows.append(rows_n)
                        self.q_ch.append(canvas[0].copy())
                        self.q_fg.append(canvas[1].copy())
                        self.q_bg.append(canvas[2].copy())
                        qi = len(self.q_keys) - 1
        if qi < 0:
            return
        for r in range(rows_n):
            var row_off = r * cols_n
            for c in range(cols_n):
                var idx = row_off + c
                if idx < len(self.q_ch[qi]):
                    scr.put(x0 + c, y0 + r, self.q_ch[qi][idx], self.q_fg[qi][idx], self.q_bg[qi][idx])
