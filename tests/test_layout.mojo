"""The tiled layout tree (splits and tab groups), without any windows."""
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from std.collections import List
from layout import *


def with_tabs(n: Int) -> Layout:
    var l = Layout()
    for id in range(1, n + 1):
        l.add(id)
    return l^


def rect(l: Layout, g: Int) -> String:
    return String(l.gx[g]) + "," + String(l.gy[g]) + " " + String(l.gw[g]) + "x" + String(l.gh[g])


def test_windows_become_tabs_of_the_current_group() raises:
    var l = Layout()
    assert_equal(l.describe(), "[]!")
    l.add(1)
    l.add(2)
    l.add(3)
    assert_equal(l.describe(), "[1 2 3*]!")              # the newest shows
    l.add(2)                                             # already there: nothing
    assert_equal(l.describe(), "[1 2 3*]!")
    l.activate(1)
    l.add(4)                                             # next to the one in front
    assert_equal(l.describe(), "[1 4* 2 3]!")
    assert_equal(l.shown(l.cur), 4)
    assert_equal(l.group_of(3), l.cur)
    assert_equal(l.group_of(99), -1)
    l.next_tab(1)
    assert_equal(l.describe(), "[1 4 2* 3]!")
    l.next_tab(-3)
    assert_equal(l.describe(), "[1 4 2 3*]!")            # round the end


def test_removing_tabs() raises:
    var l = with_tabs(4)
    l.activate(2)
    l.remove(2)                                          # the one showing: its right neighbour shows
    assert_equal(l.describe(), "[1 3* 4]!")
    l.activate(1)
    l.remove(4)                                          # behind the one showing
    assert_equal(l.describe(), "[1* 3]!")
    l.remove(3)
    l.add(3)
    assert_equal(l.describe(), "[1 3*]!")
    l.remove(3)                                          # the last tab showing: the one before it
    assert_equal(l.describe(), "[1*]!")
    l.add(3)
    l.remove(1)                                          # before the one showing
    assert_equal(l.describe(), "[3*]!")
    l.remove(77)
    l.remove(3)
    assert_equal(l.describe(), "[]!")                    # the last group stays, empty
    assert_equal(l.shown(l.cur), -1)
    l.add(9)
    assert_equal(l.describe(), "[9*]!")


def test_splitting_moves_the_shown_tab_into_a_new_group() raises:
    var l = with_tabs(3)
    assert_equal(l.split(True), "")
    assert_equal(l.describe(), "([1 2*] | [3*]!)")
    l.add(4)
    assert_equal(l.describe(), "([1 2*] | [3 4*]!)")
    assert_equal(l.split(False), "")
    assert_equal(l.describe(), "([1 2*] | ([3*] / [4*]!))")
    # one tab cannot be split off from itself
    assert_true(l.split(True).find("Open a second file") == 0)
    assert_equal(l.describe(), "([1 2*] | ([3*] / [4*]!))")
    var gs = l.groups()
    assert_equal(len(gs), 3)
    assert_equal(len(l.ids()), 4)


def test_closing_the_last_tab_of_a_group_removes_the_split() raises:
    var l = with_tabs(3)
    _ = l.split(True)
    l.add(4)
    _ = l.split(False)                                   # ([1 2*] | ([3*] / [4*]!))
    l.remove(4)
    assert_equal(l.describe(), "([1 2*] | [3*]!)")       # the current group went: its neighbour is current
    l.remove(1)
    l.remove(2)
    assert_equal(l.describe(), "[3*]!")
    # removing from a group that is not the current one keeps the current one
    var m = with_tabs(3)
    _ = m.split(True)                                    # ([1 2*] | [3*]!)
    m.remove(1)
    m.remove(2)
    assert_equal(m.describe(), "[3*]!")
    var k = with_tabs(4)
    _ = k.split(True)                                    # ([1 2 3*] | [4*]!)
    k.activate(3)
    k.remove(4)
    assert_equal(k.describe(), "[1 2 3*]!")


def test_moving_between_groups() raises:
    var l = with_tabs(4)
    _ = l.split(True)                                    # ([1 2 3*] | [4*]!)
    l.next_group(1)
    assert_equal(l.describe(), "([1 2 3*]! | [4*])")
    l.next_group(-1)
    assert_equal(l.describe(), "([1 2 3*] | [4*]!)")
    l.activate(2)
    assert_equal(l.describe(), "([1 2* 3]! | [4*])")
    # the shown tab goes to the next group and is followed there
    assert_true(l.move_tab())
    assert_equal(l.describe(), "([1 3*] | [4 2*]!)")
    assert_true(l.move_tab())                            # round to the first group
    assert_equal(l.describe(), "([1 3 2*]! | [4*])")
    # moving the only tab of a group away removes that group
    l.next_group(1)
    assert_true(l.move_tab())
    assert_equal(l.describe(), "[1 3 2 4*]!")
    assert_false(l.move_tab())                           # nowhere to go


def test_geometry() raises:
    var l = with_tabs(3)
    l.place(0, 1, 100, 30)
    assert_equal(rect(l, l.root), "0,1 100x30")
    _ = l.split(True)
    l.place(0, 1, 100, 30)
    var gs = l.groups()
    assert_equal(rect(l, gs[0]), "0,1 50x30")
    assert_equal(rect(l, gs[1]), "50,1 50x30")
    l.add(4)
    _ = l.split(False)
    l.place(0, 1, 101, 31)
    gs = l.groups()
    assert_equal(rect(l, gs[0]), "0,1 50x31")
    assert_equal(rect(l, gs[1]), "50,1 51x15")
    assert_equal(rect(l, gs[2]), "50,16 51x16")          # nothing lost to rounding
    # the current pane grows at its neighbour's cost, within limits
    assert_true(l.resize(100))
    l.place(0, 1, 101, 31)
    gs = l.groups()
    assert_equal(rect(l, gs[1]), "50,1 51x12")
    assert_equal(rect(l, gs[2]), "50,13 51x19")
    for _ in range(20):
        _ = l.resize(100)
    assert_false(l.resize(100))
    l.place(0, 1, 101, 31)
    gs = l.groups()
    assert_equal(l.gh[gs[1]], 5)                         # never under the least height
    # a single group cannot be resized
    var one = with_tabs(1)
    assert_false(one.resize(100))


def test_panes_too_small_are_not_split() raises:
    var l = with_tabs(6)
    l.place(0, 1, 40, 12)
    assert_equal(l.split(True), "")
    l.place(0, 1, 40, 12)                                # two panes of 20
    l.add(7)
    assert_equal(l.split(True), "This pane is too narrow to split")
    assert_equal(l.split(False), "")
    l.place(0, 1, 40, 12)                                # 6 rows each
    l.add(8)
    assert_equal(l.split(False), "This pane is too low to split")
    assert_equal(len(l.groups()), 3)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
