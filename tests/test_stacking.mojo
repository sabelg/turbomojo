"""Tests for stacking on narrow terminals (P10-16c): in the tiled layout below 90
columns the explorer is a full-width band above the editors and the outline one
below them, nothing overlapping; wide again, they go back beside the editors at their
usual widths; too few rows, or the classic layout, and nothing is stacked."""
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from std.collections import List
from responsive import band_heights, explorer_width, outline_width, STACK_W
from app import *
from appstate import App
from window import WK_EDITOR
from commands import CM_TILED, CM_EXPLORER, CM_OUTLINE, CM_SPLIT_RIGHT
from signals import own_pid
from util import env_or, run_system, shell_quote, write_file, str_bytes, to_str


def test_band_heights() raises:
    assert_equal(band_heights(28, 1, 1)[0], 7)
    assert_equal(band_heights(28, 1, 1)[1], 7)
    assert_equal(band_heights(16, 1, 0)[0], 5)
    assert_equal(band_heights(16, 1, 0)[1], 0)
    assert_equal(band_heights(12, 1, 1)[0], 0)          # no room: not stacked
    assert_equal(band_heights(20, 0, 0)[0], 0)
    var b = band_heights(17, 1, 1)                      # bands shrink to leave 6 rows
    assert_true(17 - b[0] - b[1] >= 6)


def scratch(tag: String) -> String:
    var d = env_or("TMPDIR", "/tmp") + "/turbomojo-stack-" + String(own_pid()) + "-" + tag
    _ = run_system("rm -rf " + shell_quote(d) + " && mkdir -p " + shell_quote(d))
    _ = write_file(d + "/a.mojo", str_bytes("struct A:\n    var n: Int\n\ndef main():\n    pass\n"))
    _ = write_file(d + "/b.mojo", str_bytes("def f():\n    pass\n"))
    return d


def tiled(d: String, w: Int, h: Int) raises -> App:
    var app = App()
    app.scr.resize(w, h)
    app.cwd = d
    app.open_path(d + "/a.mojo")
    app.open_path(d + "/b.mojo")
    app.exec(CM_TILED)
    app.exec(CM_EXPLORER)
    app.focus(app.top_editor())
    app.exec(CM_OUTLINE)
    app.focus(app.top_editor())
    app.layout_sync()
    app.draw()
    return app^


def rect(app: App, i: Int) -> Tuple[Int, Int, Int, Int]:
    return (app.wins[i].x, app.wins[i].y, app.wins[i].w, app.wins[i].h)


def overlap(a: Tuple[Int, Int, Int, Int], b: Tuple[Int, Int, Int, Int]) -> Bool:
    return a[0] < b[0] + b[2] and b[0] < a[0] + a[2] and a[1] < b[1] + b[3] and b[1] < a[1] + a[3]


def shown_editors(app: App) -> List[Int]:
    var out = List[Int]()
    for i in range(len(app.wins)):
        if app.wins[i].kind == WK_EDITOR and not app.wins[i].hidden:
            out.append(i)
    return out^


def test_narrow_stacks() raises:
    var d = scratch("narrow")
    var app = tiled(d, 80, 30)
    var xi = app.explorer_index()
    var oi = app.outline_index()
    assert_true(xi >= 0 and oi >= 0)
    assert_true(app.wins[xi].stacked and app.wins[oi].stacked)
    assert_equal(app.wins[xi].x, 0)
    assert_equal(app.wins[xi].y, 1)
    assert_equal(app.wins[xi].w, 80)
    assert_equal(app.wins[oi].w, 80)
    assert_true(app.wins[oi].y > app.wins[xi].y + app.wins[xi].h)
    var eds = shown_editors(app)
    assert_true(len(eds) >= 1)
    for e in eds:
        assert_equal(app.wins[e].x, 0)
        assert_equal(app.wins[e].w, 80)
        assert_equal(app.wins[e].y, app.wins[xi].y + app.wins[xi].h)
        assert_equal(app.wins[e].y + app.wins[e].h, app.wins[oi].y)
        assert_true(app.wins[e].h >= 6)
        assert_false(overlap(rect(app, e), rect(app, xi)) or overlap(rect(app, e), rect(app, oi)))
    # drawn so: the explorer's title on the first row, the code below it
    assert_true(to_str(app.scr.row_text(1)).find("Files") >= 0, to_str(app.scr.row_text(1)))
    assert_true(to_str(app.scr.to_text()).find("struct A") >= 0 or to_str(app.scr.to_text()).find("def f") >= 0)
    # wider: beside the editors again
    app.scr.resize(140, 30)
    app.layout_sync()
    app.draw()
    xi = app.explorer_index()
    oi = app.outline_index()
    assert_false(app.wins[xi].stacked or app.wins[oi].stacked)
    assert_equal(app.wins[xi].x, 0)
    assert_equal(app.wins[xi].w, explorer_width(140))
    assert_equal(app.wins[oi].w, outline_width(140))
    assert_equal(app.wins[oi].x, 140 - outline_width(140))
    assert_equal(app.wins[xi].y, 1)
    for e in shown_editors(app):
        assert_equal(app.wins[e].x, explorer_width(140))
        assert_equal(app.wins[e].x + app.wins[e].w, app.wins[oi].x)
        assert_false(overlap(rect(app, e), rect(app, xi)) or overlap(rect(app, e), rect(app, oi)))
    _ = run_system("rm -rf " + shell_quote(d))


def test_not_stacked() raises:
    var d = scratch("not")
    # wide enough
    var wide = tiled(d, STACK_W, 30)
    assert_false(wide.wins[wide.explorer_index()].stacked)
    # too few rows for bands and editors
    var low = tiled(d, 80, 14)
    assert_false(low.wins[low.explorer_index()].stacked)
    # the classic layout keeps its windows
    var app = App()
    app.scr.resize(80, 30)
    app.cwd = d
    app.open_path(d + "/a.mojo")
    app.exec(CM_EXPLORER)
    app.draw()
    var xi = app.explorer_index()
    assert_false(app.wins[xi].stacked)
    assert_equal(app.wins[xi].w, explorer_width(80))
    _ = run_system("rm -rf " + shell_quote(d))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
