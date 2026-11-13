"""Tests for pictures of the IDE made from itself (P11-02): the screen as SVG keeps every
cell's place (runs of a background as rectangles, runs of a colour as text stretched to
their cells), its colours, bold and underlines, escapes what XML needs, and
`tmide --screenshot` writes one without a terminal and without anyone's paths in it."""
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from std.collections import List
from screen import Screen, UL_CURLY
from svgshot import screen_svg, svg_rgb, xml_text, SVG_CELL_W, SVG_CELL_H
from palette import ANSI_BASE, COLOR_DEFAULT
from signals import own_pid
from util import env_or, run_system, run_capture, shell_quote, read_file, bytes_to_str


def put_text(mut scr: Screen, x: Int, y: Int, text: String, fg: Int, bg: Int):
    var k = x
    for c in text.codepoints():
        scr.put(k, y, Int(c), fg, bg)
        k += 1


def test_colours() raises:
    assert_equal(svg_rgb(0x123ABC, 0), "#123abc")
    assert_equal(svg_rgb(ANSI_BASE + 4, 0), "#0000aa")           # slot 4, the VGA blue
    assert_equal(svg_rgb(ANSI_BASE + 196, 0), "#ff0000")
    assert_equal(svg_rgb(COLOR_DEFAULT, 0xAAAAAA), "#aaaaaa")     # the terminal's default
    assert_equal(xml_text(60) + xml_text(38) + xml_text(62) + xml_text(34), "&lt;&amp;&gt;&quot;")
    assert_equal(xml_text(7), " ")                                 # not allowed in XML
    assert_equal(xml_text(0x2550), "═")


def test_cells_keep_their_places() raises:
    var scr = Screen(10, 2)
    for y in range(2):
        for x in range(10):
            scr.put(x, y, 32, 0xFFFFFF, 0x000000)
    put_text(scr, 2, 0, "ab", 0xFF0000, 0x0000FF)
    put_text(scr, 4, 0, "c<", 0x00FF00, 0x0000FF)
    scr.bold(4, 0, 2)
    var svg = screen_svg(scr, 0xFFFFFF, 0x000000)
    assert_true(svg.startswith("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"" + String(10 * SVG_CELL_W) + "\" height=\"" + String(2 * SVG_CELL_H) + "\""), svg)
    # one rectangle for the four blue cells, none for the page's own background
    assert_true(svg.find("<rect x=\"" + String(2 * SVG_CELL_W) + "\" y=\"0\" width=\"" + String(4 * SVG_CELL_W) + "\" height=\"" + String(SVG_CELL_H) + "\" fill=\"#0000ff\"/>") >= 0, svg)
    assert_equal(svg.count("fill=\"#000000\"/>"), 1)                   # (the page)
    # the red run, then the green bold run with its "<" escaped, each at its cells
    assert_true(svg.find("<text x=\"" + String(2 * SVG_CELL_W) + "\" y=\"14\" textLength=\"" + String(2 * SVG_CELL_W) + "\" lengthAdjust=\"spacingAndGlyphs\" xml:space=\"preserve\" fill=\"#ff0000\">ab</text>") >= 0, svg)
    assert_true(svg.find("fill=\"#00ff00\" font-weight=\"bold\">c&lt;</text>") >= 0, svg)
    # a row of blanks gives no text at all
    assert_equal(svg.count("<text"), 2)


def test_wide_characters_and_underlines() raises:
    var scr = Screen(8, 1)
    for x in range(8):
        scr.put(x, 0, 32, 0xFFFFFF, 0x000000)
    scr.put(1, 0, 0x4E2D, 0xFFFFFF, 0x000000)      # 中: two cells
    scr.put(3, 0, 120, 0xFFFFFF, 0x000000)
    var svg = screen_svg(scr, 0xFFFFFF, 0x000000)
    # one text for the whole row: the wide character once, the run eight cells long
    assert_true(svg.find("textLength=\"" + String(8 * SVG_CELL_W) + "\"") >= 0, svg)
    assert_true(svg.find("> 中x    </text>") >= 0, svg)
    var u = Screen(4, 1)
    for x in range(4):
        u.put(x, 0, 32, 0xFFFFFF, 0x000000)
    for x in range(3):
        u.underline_kind(x, 0, UL_CURLY, 0xFF0000)
    var s2 = screen_svg(u, 0xFFFFFF, 0x000000)
    assert_true(s2.find("text-decoration=\"underline\"") >= 0, s2)  # (blanks, but underlined)


def test_the_command_line_writes_one() raises:
    var d = env_or("TMPDIR", "/tmp") + "/turbomojo-shot-" + String(own_pid())
    _ = run_system("rm -rf " + shell_quote(d) + " && mkdir -p " + shell_quote(d))
    var env = "HOME=" + shell_quote(d) + " XDG_CONFIG_HOME=" + shell_quote(d + "/c") + " XDG_STATE_HOME=" + shell_quote(d + "/s") + " "
    var r = run_capture(env + "build/tmide --screenshot " + shell_quote(d + "/a.svg") + " --size 100x30 --theme midnight --command window.tiledLayout --command view.commandPalette examples/hello.mojo < /dev/null 2>&1")
    assert_equal(r.status, 0, bytes_to_str(r.out))
    var svg = bytes_to_str(read_file(d + "/a.svg"))
    assert_true(svg.startswith("<svg") and svg.endswith("</svg>\n"))
    assert_true(svg.find("width=\"" + String(100 * SVG_CELL_W) + "\"") >= 0)
    assert_true(svg.find(">hello.mojo<") >= 0 or svg.find(" hello.mojo ") >= 0, "the window's title")
    assert_true(svg.find("Go to") >= 0, "the palette is open")
    assert_true(svg.find(" 10:00") >= 0, "a fixed time, so the same picture each time")
    # the theme's own colours, whatever depth the environment names for a terminal
    for theme in ["classic", "midnight"]:
        var shots = List[String]()
        for depth in ["truecolor", "256", "16"]:
            var f = d + "/" + theme + "-" + depth + ".svg"
            var rr = run_capture(env + "TURBOMOJO_COLORS=" + depth + " build/tmide --screenshot " + shell_quote(f) + " --theme " + theme + " examples/hello.mojo < /dev/null 2>&1")
            assert_equal(rr.status, 0)
            shots.append(bytes_to_str(read_file(f)))
        assert_true(shots[0] == shots[1] and shots[0] == shots[2], theme + ": the same picture at every depth")
    assert_false(run_system("test -e " + shell_quote(d + "/c/turbomojo/config.toml")) == 0, "a toggled option is not saved")
    assert_equal(svg.find("Loaded "), -1)                             # no one's paths
    assert_equal(svg.find(bytes_to_str(run_capture("pwd").out).strip()), -1)
    # mistakes are told, not drawn
    var bad = run_capture(env + "build/tmide --screenshot " + shell_quote(d + "/b.svg") + " --command no.such < /dev/null 2>&1")
    assert_true(bad.status != 0)
    assert_true(bytes_to_str(bad.out).find("no.such") >= 0)
    var theme = run_capture(env + "build/tmide --screenshot " + shell_quote(d + "/t.svg") + " --theme no-such < /dev/null 2>&1")
    assert_true(theme.status != 0 and bytes_to_str(theme.out).find("classic") >= 0, bytes_to_str(theme.out))
    var size = run_capture(env + "build/tmide --screenshot " + shell_quote(d + "/c.svg") + " --size big < /dev/null 2>&1")
    assert_true(size.status != 0)
    _ = run_system("rm -rf " + shell_quote(d))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
