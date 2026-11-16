"""E2E Test Suite for Card-Based Jupyter Notebook View, Inline Image Rendering & `Shift+Enter`:
1. Terminal `Shift+Enter` / `Ctrl+Enter` / `Alt+Enter` across CSI-u, Keypad Enter, LF, and xterm `modifyOtherKeys`.
2. Card-based `.ipynb` view (`╭─ In [k] ─╮`, `├─ Out [k] ─┤`, `╰───╯`), collapsible code cells keeping `Out [k]` + images visible (`jupyter.source_hidden`), 2×2 Unicode Quadrant (`▘▝▀▖▌▞▛`) subpixels, Kitty Virtual Placements (`U+10EEEE`), and Sixel / Direct-Kitty pixel overlays.
3. Rapid back-to-back `Shift+Enter` queueing (`[⋯ queued]`), cold-kernel `.ipynb` auto-warming, and clean Python `linecache` tracebacks.
4. Python rich display (`_repr_png_()` and `display()`) inline image rendering + `Shift+Enter` viewport retention keeping `Out [k]` and the rendered image visible alongside the next cell's cursor.
"""
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from std.collections import List
from std.ffi import external_call
from std.time import perf_counter_ns
from app import App, M_MENU, M_NORMAL
from commands import CM_CELL_TOGGLE_CODE, CM_CELL_TOGGLE_ALL_CODE, CM_CELL_VIEW_PLOT
from window import WK_IMGVIEW, WK_EDITOR
from kittygfx import PLACEHOLDER
from palette import ANSI_BASE
from screen import CONT
from term import Terminal, EV_KEY, KEY_ESC, KEY_ENTER, KEY_RIGHT, MOD_SHIFT, MOD_CTRL, MOD_ALT
from cells import parse_cells
from ipynb import percent_text_to_ipynb, ipynb_to_percent_text
from signals import own_pid
from util import (
    env_or,
    getcwd,
    run_system,
    read_file,
    write_file,
    str_bytes,
    bytes_to_str,
    to_str,
    path_exists,
)


def _scratch(tag: String) -> String:
    var d = env_or("TMPDIR", "/tmp") + "/tm-ipynb-img-" + tag + "-" + String(own_pid())
    _ = run_system("rm -rf '" + d + "' && mkdir -p '" + d + "'")
    return d


def _one_key(seq: String) raises -> Int:
    var t = Terminal()
    var evs = t.feed(str_bytes(seq), False)
    assert_equal(len(evs), 1, "Expected 1 key event for sequence")
    assert_equal(evs[0].kind, EV_KEY)
    return evs[0].key


def _screen_text(app: App) -> String:
    var cps = List[Int]()
    for y in range(app.scr.h):
        for x in range(app.scr.w):
            var c = app.scr.ch[y * app.scr.w + x]
            if c == CONT:
                continue
            cps.append(c if (c >= 32 and c != PLACEHOLDER) else 32)
        cps.append(10)
    return to_str(cps)


def _wait_cells_idle(mut app: App, timeout_s: Float64 = 20.0) raises:
    var t0 = Int(perf_counter_ns())
    var budget_ns = Int(timeout_s * 1_000_000_000.0)
    while (app.cell_k_active or app.job.active or len(app.cell_queue_indices) > 0) and (
        Int(perf_counter_ns()) - t0 < budget_ns
    ):
        app.cell_kernel_tick()
        if app.job.active:
            app.poll_job()
        _ = external_call["usleep", Int32](UInt32(10000))


def test_01_shift_enter_and_modify_other_keys_across_terminals() raises:
    """Verify Shift-Enter, Ctrl-Enter, Ctrl-Shift-Enter, and Alt-Enter across CSI-u and xterm modifyOtherKeys."""
    # Kitty keyboard protocol (CSI u + keypad Enter + LF codepoint)
    assert_equal(_one_key("\x1b[13;2u"), KEY_ENTER | MOD_SHIFT)
    assert_equal(_one_key("\x1b[57414;2u"), KEY_ENTER | MOD_SHIFT)
    assert_equal(_one_key("\x1b[13;5u"), KEY_ENTER | MOD_CTRL)
    assert_equal(_one_key("\x1b[10;5u"), KEY_ENTER | MOD_CTRL)
    assert_equal(_one_key("\x1b[13;6u"), KEY_ENTER | MOD_CTRL | MOD_SHIFT)
    assert_equal(_one_key("\x1b[13;3u"), KEY_ENTER | MOD_ALT)

    # xterm modifyOtherKeys (tmux extended-keys, VTE, Konsole, xterm, VS Code terminal)
    assert_equal(_one_key("\x1b[27;2;13~"), KEY_ENTER | MOD_SHIFT)
    assert_equal(_one_key("\x1b[27;5;13~"), KEY_ENTER | MOD_CTRL)
    assert_equal(_one_key("\x1b[27;5;10~"), KEY_ENTER | MOD_CTRL)
    assert_equal(_one_key("\x1b[27;6;13~"), KEY_ENTER | MOD_CTRL | MOD_SHIFT)
    assert_equal(_one_key("\x1b[27;3;13~"), KEY_ENTER | MOD_ALT)

    # Shifted letters via modifyOtherKeys stay plain uppercase characters
    assert_equal(_one_key("\x1b[27;2;65~"), 65)

    # Verify set_modify_other_keys pushes >4;1m and restores >4;0m before leaving alt screen
    var t = Terminal()
    t.set_modify_other_keys(True)
    assert_true(bytes_to_str(t.out).find("\x1b[>4;1m") >= 0)
    var rseq = t.restore_sequence()
    assert_true(rseq.find("\x1b[>4;0m") > 0 and rseq.find("\x1b[>4;0m") < rseq.find("\x1b[?1049l"))


def test_02_card_jupyter_view_collapsible_cells_and_multi_tier_images() raises:
    """Card-based `.ipynb` view keeps `Out [k]` & images visible on collapsed code cells, renders
    sharp 2×2 Quadrant subpixels, Kitty `U+10EEEE`, and Sixel overlays (with menu occlusion guard)."""
    var showcase = getcwd() + "/examples/mojo_3d_showcase.ipynb"
    assert_true(path_exists(showcase))

    var app = App()
    app.scr.resize(124, 44)
    app.open_path(showcase)
    var ei = app.find_editor(showcase)
    assert_true(ei >= 0)

    var cells = parse_cells(app.wins[ei].buf)
    assert_true(len(cells) >= 4)
    # Scene 1 (cell 3) has `jupyter.source_hidden = true` -> folded header, YET its output & image attach to `header_row`!
    var s1_hdr = cells[3].header_row
    assert_true(app.wins[ei].buf.fold_index(s1_hdr) >= 0, "Expected Scene 1 code cell folded via source_hidden")
    var scene1_end = app.wins[ei].buf.cell_end_for_header(s1_hdr)
    assert_equal(scene1_end, s1_hdr, "Collapsed cell must anchor virtual output right below its 1-line card header!")

    # Scroll right to Scene 1's collapsed card header -> entire 3D render is immediately visible beneath it!
    app.wins[ei].top = max(0, s1_hdr - 1)
    app.wins[ei].top_seg = 0
    app.wins[ei].cr = s1_hdr
    app.wins[ei].cc = 0
    app.wins[ei].follow = False

    # 1. Universal 24-bit 2x2 Quadrant (`U+2580..U+259F`) rendering + Jupyter Card Chrome
    app.gfx_on = False
    app.draw()
    var scr_txt = _screen_text(app)
    assert_true(scr_txt.find("In [2]") >= 0, "Expected Jupyter In [2] card header")
    assert_true(scr_txt.find("Out [2]") >= 0, "Expected connected Out [2] card divider")
    assert_true(scr_txt.find("[▸ +") >= 0, "Expected collapsed code line-count pill")
    assert_true(scr_txt.find("[▶ Run]") >= 0, "Expected [▶ Run] card pill")
    assert_true(scr_txt.find("Frame 1/16") >= 0, "Expected Scene 1 live 3D animation frame counter")
    assert_true(scr_txt.find("click image to zoom") >= 0)
    assert_equal(app.wins[ei].visible_anim_fps(), 16)
    assert_true(app.wins[ei].step_anim(1_000_000_000))
    app.draw()
    assert_true(_screen_text(app).find("Frame 2/16") >= 0, "Expected step_anim to advance to Frame 2/16")

    var quad_cells = 0
    var fine_subpixel_cells = 0
    var has_card_tl = False
    var has_card_mid = False
    var has_card_bot = False
    for k in range(app.scr.w * app.scr.h):
        var ch = app.scr.ch[k]
        if ch >= 0x2580 and ch <= 0x259F:
            quad_cells += 1
            if ch != 0x2580:
                fine_subpixel_cells += 1
        elif ch == 0x256D:
            has_card_tl = True
        elif ch == 0x251C:
            has_card_mid = True
        elif ch == 0x2570:
            has_card_bot = True
    assert_true(quad_cells >= 300, "Expected >=300 2x2 quadrant subpixel cells, got " + String(quad_cells))
    assert_true(fine_subpixel_cells >= 8, "Expected fine 2x2 diagonal quadrant glyphs on high-contrast edges")
    assert_true(has_card_tl and has_card_mid and has_card_bot, "Expected connected ╭ / ├ / ╰ Jupyter card frame")

    # Verify toggling code expand/collapse via CM_CELL_TOGGLE_CODE and CM_CELL_TOGGLE_ALL_CODE
    app.exec(CM_CELL_TOGGLE_CODE)
    assert_equal(app.wins[ei].buf.fold_index(s1_hdr), -1, "CM_CELL_TOGGLE_CODE should expand Scene 1")
    app.exec(CM_CELL_TOGGLE_CODE)
    assert_true(app.wins[ei].buf.fold_index(s1_hdr) >= 0, "CM_CELL_TOGGLE_CODE should re-collapse Scene 1")

    # 2. Native Kitty Graphics Virtual Placement (`U+10EEEE`) inline rendering
    app.wins[ei].top = max(0, s1_hdr - 1)
    app.wins[ei].top_seg = 0
    app.wins[ei].follow = False
    app.gfx_on = True
    app.gfx_sixel = False
    app.images_mode = "kitty"
    app.gfx_out = ""
    app.focused = False
    app.dim_unfocused = True
    app.draw()
    assert_true(app.gfx_out.find("\x1b_Ga=T,U=1,f=100") >= 0, "Expected Kitty virtual placement transmit APC")
    var kitty_cells = 0
    for k in range(app.scr.w * app.scr.h):
        if app.scr.ch[k] == PLACEHOLDER:
            kitty_cells += 1
            assert_true(app.scr.fg[k] >= ANSI_BASE + 200, "Unfocused dim must not corrupt Kitty image ID")
    assert_true(kitty_cells >= 300, "Expected >=300 Kitty U+10EEEE cells, got " + String(kitty_cells))

    # 3. Post-frame Sixel Pixel Overlay (`gfx_sixel = True`) + menu occlusion guard
    app.focused = True
    app.gfx_on = True
    app.gfx_sixel = True
    app.images_mode = "sixel"
    app.draw()
    app.sixel_prepare()
    var six_out = app.sixel_take()
    assert_true(six_out.find("\x1bP0;1;0q") >= 0, "Expected Sixel DCS image payload for wholly visible inline plot")
    # Open dropdown menu overlapping the editor -> Sixel overlay must suppress cleanly!
    app.open_menu(2)
    assert_equal(app.mode, M_MENU)
    app.draw()
    app.sixel_prepare()
    var six_occluded = app.sixel_take()
    assert_equal(six_occluded, "", "Occluded inline plot under dropdown menu must not emit Sixel bleed")
    app.mode = M_NORMAL


def test_03_rapid_shift_enter_queueing_and_cold_ipynb_warming() raises:
    """Rapid back-to-back Shift-Enter queues cells cleanly, and jumping into Cell 2 of a saved
    `.ipynb` on a cold kernel automatically warms Cell 1 (`execution_count > 0`)."""
    var d = _scratch("queue_warm")
    var app = App()
    try:
        app.cwd = d
        app.scr.resize(110, 36)

        # Part A: Rapid back-to-back Shift-Enter without waiting between presses!
        var nb1 = d + "/rapid.ipynb"
        var src1 = (
            "# %% [Step 1]\n"
            "import time\n"
            "time.sleep(0.15)\n"
            "val = 30\n"
            "print('step1_done')\n\n"
            "# %% [Step 2]\n"
            "print('step2_val=' + str(val + 12))\n"
        )
        assert_true(write_file(nb1, str_bytes(percent_text_to_ipynb(src1, False))))
        app.open_path(nb1)
        var i1 = app.find_editor(nb1)
        app.wins[i1].goto(1, 0)

        app.handle_key(KEY_ENTER | MOD_SHIFT)
        assert_true(app.cell_k_active)
        app.handle_key(KEY_ENTER | MOD_SHIFT)
        assert_equal(len(app.cell_queue_indices), 1, "Second Shift-Enter must queue Step 2 instead of dropping!")

        _wait_cells_idle(app, 15.0)
        assert_true(app.find_editor(nb1) >= 0)
        app.draw()
        var scr1 = _screen_text(app)
        assert_true(scr1.find("step1_done") >= 0, scr1)
        assert_true(scr1.find("step2_val=42") >= 0, scr1)

        # Part B: Cold-kernel jump-in on a saved `.ipynb` with persisted execution_count!
        app.cell_restart_kernels()
        var nb2 = d + "/saved_warm.ipynb"
        var saved_json = (
            "{\n"
            '  "cells": [\n'
            '    {"cell_type": "code", "execution_count": 1, "metadata": {}, "outputs": [], "source": ["secret_base = 100\\n"]},\n'
            '    {"cell_type": "code", "execution_count": 2, "metadata": {}, "outputs": [], "source": ["print(\'warm_sum=\' + str(secret_base + 23))\\n"]}\n'
            "  ],\n"
            '  "metadata": {"kernelspec": {"language": "python", "name": "python3"}},\n'
            '  "nbformat": 4, "nbformat_minor": 5\n'
            "}\n"
        )
        assert_true(write_file(nb2, str_bytes(saved_json)))
        app.open_path(nb2)
        var i2 = app.find_editor(nb2)
        var c2 = parse_cells(app.wins[i2].buf)
        assert_equal(len(c2), 2)

        app.wins[i2].goto(c2[1].start_row, 0)
        app.handle_key(KEY_ENTER | MOD_SHIFT)
        _wait_cells_idle(app, 15.0)

        assert_true(app.find_editor(nb2) >= 0)
        app.draw()
        var scr2 = _screen_text(app)
        assert_true(scr2.find("warm_sum=123") >= 0, scr2)

        # Part C: Verify `.ipynb` Python tracebacks show actual cell Python line (via linecache), NOT raw JSON!
        var nb_err = d + "/clean_tb.ipynb"
        assert_true(write_file(nb_err, str_bytes(percent_text_to_ipynb("# %% [ErrCell]\nmissing_var_xyz + 1\n", False))))
        app.open_path(nb_err)
        var ie = app.find_editor(nb_err)
        app.wins[ie].goto(1, 0)
        app.handle_key(KEY_ENTER | MOD_CTRL)
        _wait_cells_idle(app, 15.0)
        ie = app.find_editor(nb_err)
        var err_txt = app.wins[ie].buf.cell_out_texts[0]
        assert_true(err_txt.find("missing_var_xyz + 1") >= 0, err_txt)
        assert_equal(err_txt.find("\"cell_type\""), -1)
        assert_equal(err_txt.find("__tm_last_val"), -1)
    finally:
        app.cell_kernels_stop()
        _ = run_system("rm -rf '" + d + "'")


def test_04_shift_enter_keeps_rendered_image_and_next_cursor_in_view() raises:
    """`Shift-Enter` on a plot cell advances to Cell 2 WHILE keeping Cell 1's rendered image visible,
    and round-trip saves `jupyter.source_hidden` when collapsed."""
    var d = _scratch("shift_enter_view")
    var app = App()
    try:
        app.cwd = d
        app.scr.resize(110, 38)
        var py_src = (
            "# %% [Rich Image]\n"
            "import struct, zlib\n"
            "class MiniPlot:\n"
            "    def _repr_png_(self):\n"
            "        w, h = 24, 16\n"
            "        raw = b''.join(b'\\x00' + (b'\\xff\\x40\\x20' * w) for _ in range(h))\n"
            "        def ck(t, d): return struct.pack('>I', len(d)) + t + d + struct.pack('>I', zlib.crc32(t + d) & 0xffffffff)\n"
            "        return b'\\x89PNG\\r\\n\\x1a\\n' + ck(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0)) + ck(b'IDAT', zlib.compress(raw)) + ck(b'IEND', b'')\n"
            "display(MiniPlot())\n\n"
            "# %% [Next Step]\n"
            "x_next = 99\n"
        )
        var nb_p = d + "/rich_img.ipynb"
        assert_true(write_file(nb_p, str_bytes(percent_text_to_ipynb(py_src, False))))
        app.open_path(nb_p)
        var ni = app.find_editor(nb_p)
        app.wins[ni].goto_cell(1, 0)
        # Press Shift-Enter! Must advance cursor into Cell 2 AND keep Cell 1's rendered image in view!
        app.handle_key(KEY_ENTER | MOD_SHIFT)
        _wait_cells_idle(app, 15.0)

        ni = app.find_editor(nb_p)
        var cells_after = parse_cells(app.wins[ni].buf)
        assert_true(app.wins[ni].cr >= cells_after[1].header_row, "Cursor must have advanced to Cell 2")
        app.gfx_on = False
        app.draw()
        var img_cells = 0
        for k in range(app.scr.w * app.scr.h):
            if app.scr.ch[k] >= 0x2580 and app.scr.ch[k] <= 0x259F:
                img_cells += 1
        assert_true(img_cells >= 40, "Shift-Enter must keep rendered image visible in viewport, got " + String(img_cells))
        assert_true(app.wins[ni].cursor_cell().r >= 0, "Next cell's cursor must also be visible in viewport!")

        # Collapse all code cells via CM_CELL_TOGGLE_ALL_CODE and verify round-trip `source_hidden` persistence
        app.exec(CM_CELL_TOGGLE_ALL_CODE)
        assert_true(app.wins[ni].buf.fold_index(cells_after[0].header_row) >= 0)
        var saved = percent_text_to_ipynb(
            bytes_to_str(app.wins[ni].buf.to_bytes()),
            False,
            "",
            app.collect_ipynb_outputs(ni),
            app.collect_ipynb_folded_cells(ni),
        )
        assert_true(saved.find("\"source_hidden\":true") >= 0, "Expected jupyter.source_hidden in saved .ipynb")
        var reloaded = ipynb_to_percent_text(saved, False)
        assert_true(len(reloaded.folded_headers) >= 1)

        # Verify dedicated Image Zoom Window (`WK_IMGVIEW`) opens solely for the image, supports `+` zoom & pan, and closes on `Esc`!
        app.exec(CM_CELL_VIEW_PLOT)
        var top_i = app.top()
        assert_equal(app.wins[top_i].kind, WK_IMGVIEW, "Zoom must open dedicated WK_IMGVIEW window")
        assert_equal(app.wins[top_i].img_zoom_pct, 100)
        app.gfx_on = False
        app.draw()
        var zoom_win_quads = 0
        for yy in range(app.wins[top_i].y + 1, app.wins[top_i].y + app.wins[top_i].h - 1):
            for xx in range(app.wins[top_i].x + 1, app.wins[top_i].x + app.wins[top_i].w - 1):
                var c = app.scr.ch[yy * app.scr.w + xx]
                if c >= 0x2580 and c <= 0x259F:
                    zoom_win_quads += 1
        assert_true(zoom_win_quads >= 150, "Expected large zoomed image inside WK_IMGVIEW, got " + String(zoom_win_quads))
        # Press `+` to magnify to 150% and `Right` to pan, then `0` to fit, then `Esc` to close back to WK_EDITOR!
        app.handle_key(43)  # '+'
        assert_equal(app.wins[top_i].img_zoom_pct, 150)
        app.handle_key(KEY_RIGHT)
        assert_true(app.wins[top_i].img_pan_x > 500)
        app.draw()
        app.handle_key(48)  # '0'
        assert_equal(app.wins[top_i].img_zoom_pct, 100)
        app.handle_key(KEY_ESC)
        assert_equal(app.wins[app.top()].kind, WK_EDITOR, "Esc must close WK_IMGVIEW and return to notebook editor")
    finally:
        app.cell_kernels_stop()
        _ = run_system("rm -rf '" + d + "'")


def test_05_live_streaming_and_looping_animations_in_card_and_zoom_window() raises:
    """Python `clear_output(wait=True)` + `display()` streams frames live, bundles as `ANIM|fps|...`,
    loops inside `WK_IMGVIEW` while zoomed, supports `Space` pause / `]` step, and round-trips `.ipynb`."""
    var d = _scratch("anim_e2e")
    var app = App()
    try:
        app.cwd = d
        app.scr.resize(116, 40)
        var py_anim = (
            "# %% [Live Orbit]\n"
            "import struct, zlib\n"
            "class FrameImg:\n"
            "    def __init__(self, k):\n"
            "        self.k = k\n"
            "    def _repr_png_(self):\n"
            "        w, h = 24, 16\n"
            "        c = bytes([(40 + self.k * 50) & 255, (180 - self.k * 30) & 255, 220])\n"
            "        raw = b''.join(b'\\x00' + (c * w) for _ in range(h))\n"
            "        def ck(t, dt): return struct.pack('>I', len(dt)) + t + dt + struct.pack('>I', zlib.crc32(t + dt) & 0xffffffff)\n"
            "        return b'\\x89PNG\\r\\n\\x1a\\n' + ck(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0)) + ck(b'IDAT', zlib.compress(raw)) + ck(b'IEND', b'')\n"
            "for step in range(4):\n"
            "    clear_output(wait=True)\n"
            "    display(FrameImg(step))\n"
            "print('anim_ready')\n"
        )
        var nb_a = d + "/live_anim.ipynb"
        assert_true(write_file(nb_a, str_bytes(percent_text_to_ipynb(py_anim, False))))
        app.open_path(nb_a)
        var ai = app.find_editor(nb_a)
        app.wins[ai].goto_cell(1, 0)
        app.handle_key(KEY_ENTER | MOD_CTRL)
        _wait_cells_idle(app, 15.0)

        ai = app.find_editor(nb_a)
        assert_equal(len(app.wins[ai].buf.cell_out_plots), 1)
        assert_true(app.wins[ai].buf.cell_out_plots[0].startswith("ANIM|16|"), app.wins[ai].buf.cell_out_plots[0])

        # Open dedicated zoom window -> must play animation at 16 fps across all 4 frames!
        app.exec(CM_CELL_VIEW_PLOT)
        var zi = app.top()
        assert_equal(app.wins[zi].kind, WK_IMGVIEW)
        assert_equal(app.wins[zi].img_anim_fps, 16)
        assert_true(app.wins[zi].img_anim_playing)
        assert_equal(len(app.wins[zi].img_paths), 4)

        # Zoom in to 150% and verify animation stepping preserves zoom level!
        app.handle_key(43)  # '+'
        assert_equal(app.wins[zi].img_zoom_pct, 150)
        assert_true(app.wins[zi].step_anim(2_000_000_000))
        assert_equal(app.wins[zi].img_idx, 1)
        assert_equal(app.wins[zi].img_zoom_pct, 150)

        # Space pauses playback; `]` steps 1 frame forward
        app.handle_key(32)  # Space
        assert_false(app.wins[zi].img_anim_playing)
        app.handle_key(93)  # ']'
        assert_equal(app.wins[zi].img_idx, 2)
        app.handle_key(KEY_ESC)

        # Round-trip save & reload preserves `turbomojo_frames_png` animation!
        var saved_anim = percent_text_to_ipynb(
            bytes_to_str(app.wins[ai].buf.to_bytes()),
            False,
            "",
            app.collect_ipynb_outputs(ai),
        )
        assert_true(saved_anim.find("turbomojo_frames_png") >= 0)
        var doc_rt = ipynb_to_percent_text(saved_anim, False)
        assert_true(len(doc_rt.outputs) == 1 and len(doc_rt.outputs[0].png_b64) == 1)
        assert_true(doc_rt.outputs[0].png_b64[0].startswith("ANIM|16|"))
    finally:
        app.cell_kernels_stop()
        _ = run_system("rm -rf '" + d + "'")


def main() raises:
    var suite = TestSuite()
    suite.test[test_01_shift_enter_and_modify_other_keys_across_terminals]()
    suite.test[test_02_card_jupyter_view_collapsible_cells_and_multi_tier_images]()
    suite.test[test_03_rapid_shift_enter_queueing_and_cold_ipynb_warming]()
    suite.test[test_04_shift_enter_keeps_rendered_image_and_next_cursor_in_view]()
    suite.test[test_05_live_streaming_and_looping_animations_in_card_and_zoom_window]()
    suite^.run()
