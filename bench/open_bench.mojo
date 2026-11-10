"""Benchmark: time to open a file the way the editor does, and to draw the first screen.
Usage: open_bench <file> [old]   ("old" uses the codepoint path that was used before P1-05)."""
from std.sys import argv
from std.time import perf_counter_ns
from std.collections import List
from window import Window, WK_EDITOR
from window_search import *
from window_draw import *
from screen import Screen
from palette import theme
from highlight import Highlighter
from util import decode, read_file


def ms(a: Int, b: Int) -> String:
    var us = (Int(b) - Int(a)) // 1000
    return String(us // 1000) + "." + String((us % 1000) // 100) + " ms"


def main() raises:
    var args = argv()
    var path = String(args[1])
    var old = len(args) > 2
    var w = Window(WK_EDITOR, "bench", path, 0, 0, 120, 40, 1)
    var t0 = Int(perf_counter_ns())
    var t1 = t0
    if old:
        var txt: String
        with open(path, "r") as f:
            txt = f.read()
        t1 = Int(perf_counter_ns())
        w.buf.load(decode(txt))
    else:
        var bytes = read_file(path)
        t1 = Int(perf_counter_ns())
        w.buf.load_bytes(bytes)
    var t2 = Int(perf_counter_ns())
    var s = Screen(120, 40)
    var p = theme(0)
    var h = Highlighter()
    w.gut = w.gutter_for(True)
    w.sync_lex(w.top + w.rows() + 1)
    w.draw(s, p, h, True, True, True, False)
    var t3 = Int(perf_counter_ns())
    w.cr = w.buf.count() - 1
    w.ensure_visible()
    w.sync_lex(w.top + w.rows() + 1)
    w.draw(s, p, h, True, True, True, False)
    var t4 = Int(perf_counter_ns())
    print("lines", w.buf.count(), " read", ms(t0, t1), " load", ms(t1, t2), " first draw", ms(t2, t3), " jump to end + draw", ms(t3, t4), " open total", ms(t0, t3))
