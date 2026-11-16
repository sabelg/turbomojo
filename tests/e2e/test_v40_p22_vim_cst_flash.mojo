"""E2E Test Suite for v4.0 Phase 22 (`v3.2`):
CST-Powered Structural Vim Text Objects (`af`/`if`, `ac`/`ic`, `aa`/`ia`, `aj`/`ij`),
2-Char Flash / Leap Jump Beacons Across Split Panes (`gs` / `<Space>j` / `CM_FLASH_JUMP`),
Surround Operations (`ys`, `yss`, `ds`, `cs`), Harpoon `1..4` Quick-Marks, `g;`/`g,` Change-List,
and Live Register Preview Popup.
"""
from std.testing import assert_equal, assert_true, TestSuite
from std.collections import List
from app import App
from screen import CONT
from term import KEY_ESC
from vim import KEYMAP_VIM, VM_NORMAL
from commands import CM_KEYMAP3, CM_SPLIT_RIGHT, CM_VIM_ZEN, CM_HARPOON_MENU
from dialog import D_HARPOON
from signals import own_pid
from util import (
    env_or,
    run_system,
    write_file,
    str_bytes,
    decode,
    to_str,
    shell_quote,
)


def _scratch(tag: String) -> String:
    var d = env_or("TMPDIR", "/tmp") + "/tm-v40-p22-" + tag + "-" + String(own_pid())
    _ = run_system("rm -rf " + shell_quote(d) + " && mkdir -p " + shell_quote(d))
    return d


def _clean(d: String):
    _ = run_system("rm -rf " + shell_quote(d))


def _screen_text(app: App) -> String:
    var out = String("")
    for r in range(app.scr.h):
        var cps = List[Int]()
        for c in range(app.scr.w):
            var ch = app.scr.ch[r * app.scr.w + c]
            if ch != CONT:
                cps.append(ch)
        out += to_str(cps) + "\n"
    return out^


def _type(mut app: App, s: String) raises:
    for cp in decode(s):
        app.handle_key(cp)


def test_p22_e2e_cst_text_objects_af_ac_aa_aj_in_app_vim() raises:
    var d = _scratch("cstobj")
    var fpath = d + "/sample.mojo"
    var src = (
        "# %% Cell Alpha\n"
        "@fieldwise_init\n"
        "struct Vec2(Copyable, Movable):\n"
        "    var x: Float64\n"
        "    var y: Float64\n"
        "\n"
        "# %% Cell Beta\n"
        "@always_inline\n"
        "def launch(alpha: Int, beta: Int, gamma: Int) -> Int:\n"
        "    var acc = alpha + beta\n"
        "    return acc + gamma\n"
    )
    _ = write_file(fpath, str_bytes(src))
    var app = App()
    app.scr.resize(120, 36)
    app.open_path(fpath)
    app.exec(CM_KEYMAP3)
    assert_equal(app.keymap, KEYMAP_VIM)
    var ei = app.top_editor()

    # 1) `daa` on middle parameter `beta: Int` deletes `, ` cleanly!
    app.wins[ei].goto(8, 25)
    _type(app, "daa")
    assert_equal(to_str(app.wins[ei].buf.line(8)), "def launch(alpha: Int, gamma: Int) -> Int:")

    # 2) `dif` inside `launch` deletes only the body lines, keeping decorator + `def` header!
    app.wins[ei].goto(9, 4)
    _type(app, "dif")
    assert_equal(to_str(app.wins[ei].buf.line(7)), "@always_inline")
    assert_equal(to_str(app.wins[ei].buf.line(8)), "def launch(alpha: Int, gamma: Int) -> Int:")

    # 3) `dic` inside `struct Vec2` deletes struct fields while keeping `@fieldwise_init` + `struct Vec2`!
    app.wins[ei].goto(3, 4)
    _type(app, "dic")
    assert_equal(to_str(app.wins[ei].buf.line(2)), "struct Vec2(Copyable, Movable):")

    # 4) `daj` on `# %% Cell Alpha` deletes the entire first notebook cell!
    app.wins[ei].goto(0, 0)
    _type(app, "daj")
    assert_true(to_str(app.wins[ei].buf.line(0)).find("# %% Cell Beta") >= 0)
    _clean(d)


def test_p22_e2e_surround_ys_ds_cs_changelist_and_reg_popup() raises:
    var d = _scratch("surround")
    var fpath = d + "/edit.mojo"
    _ = write_file(fpath, str_bytes("var msg = token\nvar sec = other\n"))
    var app = App()
    app.scr.resize(120, 36)
    app.open_path(fpath)
    app.exec(CM_KEYMAP3)
    var ei = app.top_editor()

    # Cursor on `token` (row 0, col 10): `ysiw(` -> spaced `( token )`
    app.wins[ei].goto(0, 10)
    _type(app, "ysiw(")
    assert_equal(to_str(app.wins[ei].buf.line(0)), "var msg = ( token )")

    # `cs(]` -> tight `[token]`
    app.wins[ei].goto(0, 12)
    _type(app, "cs(]")
    assert_equal(to_str(app.wins[ei].buf.line(0)), "var msg = [token]")

    # `cs]"` -> `"token"`
    _type(app, "cs]\"")
    assert_equal(to_str(app.wins[ei].buf.line(0)), "var msg = \"token\"")

    # `ds"` -> `token`
    _type(app, "ds\"")
    assert_equal(to_str(app.wins[ei].buf.line(0)), "var msg = token")

    # Edit row 1 (`yss)` wraps whole non-blank line in `(...)`), move away, then `g;` jumps back to edit!
    app.wins[ei].goto(1, 4)
    _type(app, "yss)")
    assert_equal(to_str(app.wins[ei].buf.line(1)), "(var sec = other)")
    app.wins[ei].goto(0, 0)
    _type(app, "g;")
    assert_equal(app.wins[ei].cr, 1)

    #Yank word into `"a`, press `"` and draw -> live Register Preview Popup shows `"a`!
    app.wins[ei].goto(0, 4)
    _type(app, "\"ayiw")
    _type(app, "\"")
    app.draw()
    var scr = _screen_text(app)
    assert_true(scr.find("Registers (\")") >= 0 and scr.find("\"a  msg") >= 0)
    app.handle_key(KEY_ESC)
    assert_equal(app.vim.mode, VM_NORMAL)
    _clean(d)


def test_p22_e2e_flash_jump_across_splits_and_harpoon_marks() raises:
    var d = _scratch("flash")
    var f1 = d + "/left.mojo"
    var f2 = d + "/right.mojo"
    _ = write_file(f1, str_bytes("def alpha():\n    var zeta_one = 1\n"))
    _ = write_file(f2, str_bytes("def beta():\n    var zeta_two = 2\n    var UniqueTarget = 42\n"))

    var app = App()
    app.scr.resize(120, 36)
    app.open_path(f1)
    app.exec(CM_VIM_ZEN)
    # Pin f1 row 1 into Harpoon slot 1 via `<Space>m`
    app.wins[app.top_editor()].goto(1, 8)
    _type(app, " m")
    assert_equal(app.harpoon.count(), 1)

    # Open f2 in a right split pane and pin into Harpoon slot 2
    app.open_path(f2)
    app.exec(CM_SPLIT_RIGHT)
    app.draw()
    app.wins[app.top_editor()].goto(2, 8)
    _type(app, " m")
    assert_equal(app.harpoon.count(), 2)

    # Focus left pane (`f1`), then use `gs` + `"Un"` -> unique match `UniqueTarget` in right pane teleports immediately!
    var left_wi = app.find_editor(f1)
    app.focus(left_wi)
    assert_equal(app.wins[app.top_editor()].path, f1)
    _type(app, "gsUn")
    assert_equal(app.wins[app.top_editor()].path, f2)
    assert_equal(app.wins[app.top_editor()].cr, 2)

    # Multi-match `gs` + `"ze"` (`zeta_one` in left pane + `zeta_two` in right pane) enters stage 3 & draws beacons!
    _type(app, "gsze")
    assert_equal(app.flash_stage, 3)
    assert_equal(len(app.flash_targets), 2)
    app.draw()
    var first_lbl = app.flash_targets[0].label
    app.handle_key(first_lbl)
    assert_equal(app.flash_stage, 0)
    assert_equal(app.wins[app.top_editor()].path, f1)

    # Jump to Harpoon slot 2 via `<Space>2`, then slot 1 via `g1`, and open Harpoon menu
    _type(app, " 2")
    assert_equal(app.wins[app.top_editor()].path, f2)
    _type(app, "g1")
    assert_equal(app.wins[app.top_editor()].path, f1)
    app.exec(CM_HARPOON_MENU)
    assert_equal(app.dlg.kind, D_HARPOON)
    app.dismiss_dialog()
    _clean(d)


def main() raises:
    var suite = TestSuite()
    suite.test[test_p22_e2e_cst_text_objects_af_ac_aa_aj_in_app_vim]()
    suite.test[test_p22_e2e_surround_ys_ds_cs_changelist_and_reg_popup]()
    suite.test[test_p22_e2e_flash_jump_across_splits_and_harpoon_marks]()
    suite^.run()
