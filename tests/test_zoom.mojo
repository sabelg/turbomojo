"""Tests for zoom in three steps (P10-16b): F5 goes normal -> half -> full -> normal;
half is the half of the desk a classic window is mostly in, or half the room for a
tiled pane with the other panes still in view; it is passed over where it would
change nothing; the layout's own ratios are not changed by it."""
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from std.collections import List
from layout import Layout, L_ROW, L_COL
from app import *
from appstate import App
from commands import CM_ZOOM, CM_TILED, CM_SPLIT_RIGHT, CM_SPLIT_DOWN
from signals import own_pid
from util import env_or, run_system, shell_quote, write_file, str_bytes


def test_half_ratios() raises:
    var l = Layout()
    l.add(1)
    l.add(2)
    assert_equal(l.split(True), "")     # [1] | [2] side by side
    var g = l.cur
    var p = l.parent[g]
    l.ratio[p] = 700                    # the first side has 70%
    var r = l.half_ratios(g)
    if l.first[p] == g:
        assert_equal(r[p], 700)          # (already more than half)
    else:
        assert_equal(r[p], 500)          # 30% -> half
    assert_equal(l.ratio[p], 700)        # (the saved ratio stays)
    # two splits the same way on the path: each grows to 70.8% (their product is half)
    l.add(3)
    assert_equal(l.split(True), "")     # [1] | ([2] | [3])
    var g2 = l.cur
    var r2 = l.half_ratios(g2)
    var n = g2
    var shares = List[Int]()
    while l.parent[n] >= 0:
        var q = l.parent[n]
        shares.append(r2[q] if l.first[q] == n else 1000 - r2[q])
        n = q
    assert_equal(len(shares), 2)
    for s in shares:
        assert_true(s >= 708, String(s))
    assert_true(shares[0] * shares[1] >= 500000)


def scratch(tag: String) -> String:
    var d = env_or("TMPDIR", "/tmp") + "/turbomojo-zoom-" + String(own_pid()) + "-" + tag
    _ = run_system("rm -rf " + shell_quote(d) + " && mkdir -p " + shell_quote(d))
    for name in ["a", "b", "c"]:
        _ = write_file(d + "/" + name + ".mojo", str_bytes("text of " + name + "\n"))
    _ = write_file(d + "/d.mojo", str_bytes("text of d\n"))
    return d


def geom(app: App, i: Int) -> String:
    if app.wins[i].hidden:
        return "hidden"
    return String(app.wins[i].x) + "," + String(app.wins[i].y) + " " + String(app.wins[i].w) + "x" + String(app.wins[i].h)


def test_classic_windows() raises:
    var d = scratch("classic")
    var app = App()
    app.scr.resize(120, 30)
    app.cwd = d
    app.open_path(d + "/a.mojo")
    var t = app.top_editor()
    app.wins[t].x = 70
    app.wins[t].y = 5
    app.wins[t].w = 40
    app.wins[t].h = 10
    var dh = app.desk_h()
    app.exec(CM_ZOOM)                               # half: the right half (it is mostly there)
    assert_true(app.wins[t].half and not app.wins[t].zoomed)
    assert_equal(geom(app, t), "60,1 60x" + String(dh))
    assert_true(app.status.startswith("Zoom: half"), app.status)
    app.exec(CM_ZOOM)                               # full
    assert_true(app.wins[t].zoomed and not app.wins[t].half)
    assert_equal(geom(app, t), "0,1 120x" + String(dh))
    app.exec(CM_ZOOM)                               # back as it was
    assert_false(app.wins[t].zoomed or app.wins[t].half)
    assert_equal(geom(app, t), "70,5 40x10")
    # on the left
    app.wins[t].x = 2
    app.exec(CM_ZOOM)
    assert_equal(geom(app, t), "0,1 60x" + String(dh))
    app.exec(CM_ZOOM)
    app.exec(CM_ZOOM)
    # a window as large as the desk already: half would shrink it - straight to full
    app.wins[t].x = 0
    app.wins[t].y = 1
    app.wins[t].w = 120
    app.wins[t].h = dh
    app.exec(CM_ZOOM)
    assert_true(app.wins[t].zoomed)
    assert_equal(app.status, "Zoom: full")
    app.exec(CM_ZOOM)
    assert_equal(geom(app, t), "0,1 120x" + String(dh))
    # the zoom box on the frame is the two-step maximize / restore; from half it restores
    app.wins[t].x = 70
    app.wins[t].y = 5
    app.wins[t].w = 40
    app.wins[t].h = 10
    app.zoom_toggle()
    assert_true(app.wins[t].zoomed)
    app.zoom_toggle()
    assert_equal(geom(app, t), "70,5 40x10")
    app.exec(CM_ZOOM)
    assert_true(app.wins[t].half)
    app.zoom_toggle()
    assert_false(app.wins[t].half or app.wins[t].zoomed)
    assert_equal(geom(app, t), "70,5 40x10")
    _ = run_system("rm -rf " + shell_quote(d))


def index_of(app: App, title: String) -> Int:
    for i in range(len(app.wins)):
        if app.wins[i].title == title:
            return i
    return -1


def test_tiled_panes() raises:
    var d = scratch("tiled")
    var app = App()
    app.scr.resize(120, 30)
    app.cwd = d
    for name in ["a", "b", "c", "d"]:
        app.open_path(d + "/" + name + ".mojo")
    app.exec(CM_TILED)
    assert_equal(app.lay.split(True), "")       # [a b c] | [d]
    app.lay.cur = app.lay.first_group_under(app.lay.root)
    assert_equal(app.lay.split(True), "")       # ([a b] | [c]) | [d]: c has a quarter
    app.layout_focus_shown()
    app.draw()
    var t = app.top()
    var title = app.wins[t].title
    var before = geom(app, t)
    var w0 = app.wins[t].w
    var ratios = app.lay.ratio.copy()
    var others = List[Int]()
    for i in range(len(app.wins)):
        if i != t and not app.wins[i].hidden and app.wins[i].kind == app.wins[t].kind:
            others.append(i)
    assert_true(len(others) >= 1)
    var area = 120
    if app.explorer_index() >= 0:
        area -= app.wins[app.explorer_index()].w
    assert_true(w0 < area // 2, before)
    # half: at least half the width, the other panes still there
    app.exec(CM_ZOOM)
    app.draw()
    t = index_of(app, title)
    assert_true(app.wins[t].half)
    assert_true(app.wins[t].w >= area // 2 - 1, geom(app, t))
    for i in others:
        assert_true(geom(app, i) != "hidden")
    # full: only it
    app.exec(CM_ZOOM)
    app.draw()
    t = index_of(app, title)
    assert_true(app.wins[t].zoomed)
    for i in others:
        assert_equal(geom(app, i), "hidden")
    # normal again: where it was, the layout's ratios untouched
    app.exec(CM_ZOOM)
    app.draw()
    t = index_of(app, title)
    assert_equal(geom(app, t), before)
    assert_equal(len(app.lay.ratio), len(ratios))
    for k in range(len(ratios)):
        assert_equal(app.lay.ratio[k], ratios[k])
    _ = run_system("rm -rf " + shell_quote(d))


def test_two_equal_panes_go_straight_to_full() raises:
    var d = scratch("two")
    var app = App()
    app.scr.resize(120, 30)
    app.cwd = d
    app.open_path(d + "/a.mojo")
    app.open_path(d + "/b.mojo")
    app.exec(CM_TILED)
    app.exec(CM_SPLIT_RIGHT)
    app.draw()
    var t = app.top()
    app.exec(CM_ZOOM)                   # (it has half already)
    assert_true(app.wins[app.top()].zoomed)
    assert_equal(app.status, "Zoom: full")
    _ = t
    _ = run_system("rm -rf " + shell_quote(d))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
