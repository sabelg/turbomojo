"""Tests for images in the docs pane, first part (P10-22a): Markdown and HTML images are
shown as a "[image: alt]" link to the picture (the text fallback every terminal gets),
also inside a link (badges); and the probe learns whether the terminal can show images
- kitty graphics (its query answered) or sixel (DA1 attribute 4) - without taking the
answers for keys."""
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from std.collections import List
from doclib import doc_prepare
from markdown import md_render_rich, md_plain, image_name, html_attr, MdLine
from highlight import Highlighter
from caps import Caps, caps_query, KITTY_GRAPHICS_QUERY, images_summary
from term import Terminal
from util import decode, to_str, str_bytes, env_or, run_system, shell_quote, write_file
from app import *
from appstate import App
from term import key_event, fkey, MOD_SHIFT
from signals import own_pid


def rich(text: String, mut links: List[String]) -> List[MdLine]:
    return md_render_rich(text, 80, Highlighter(), links, True)


def linked(line: MdLine, text: String) -> Int:
    """The link index (0-based) the characters of `text` in the line lead to, -1 none,
    -2 if they are not all the same link."""
    var s = to_str(line.cps)
    var at = s.find(text)
    if at < 0:
        return -1
    var start = len(decode(String(s[byte=0:at])))
    var st = line.st[start]
    for k in range(start, start + len(decode(text))):
        if line.st[k] != st:
            return -2
    return -st - 1 if st < 0 else -1


def test_markdown_images() raises:
    var links = List[String]()
    var l = rich("See ![Architecture Diagram](./images/architecture-diagram.png \"The parts\") below.", links)
    assert_equal(to_str(l[0].cps), "See [image: Architecture Diagram] below.")
    var k = linked(l[0], "[image: Architecture Diagram]")
    assert_true(k >= 0)
    assert_equal(links[k], "./images/architecture-diagram.png")     # (the title left out)
    # no alt text: the file name
    var l2 = rich("![](plots/perf.png?raw=true)", links)
    assert_equal(to_str(l2[0].cps), "[image: perf.png]")
    # a badge: an image inside a link leads where the link does
    var l3 = rich("[![Discord](https://img.shields.io/badge/Discord-5865F2)](https://discord.gg/x)", links)
    assert_equal(to_str(l3[0].cps), "[image: Discord]")
    assert_equal(links[linked(l3[0], "[image: Discord]")], "https://discord.gg/x")
    # an exclamation mark before a plain word stays
    assert_equal(to_str(rich("Hello! [docs](x.md)", links)[0].cps), "Hello! docs")


def test_html_images() raises:
    var links = List[String]()
    var l = rich("<img src=\"assets/gpu.png\" alt=\"GPU threads\" width=\"400\"/> and <IMG SRC='b.gif'>", links)
    assert_equal(to_str(l[0].cps), "[image: GPU threads] and [image: b.gif]")
    assert_equal(links[linked(l[0], "[image: GPU threads]")], "assets/gpu.png")
    assert_equal(links[linked(l[0], "[image: b.gif]")], "b.gif")
    # an <img> without a source, and other tags, stay as they are
    assert_equal(to_str(rich("<img alt=x> <imgx>", links)[0].cps), "<img alt=x> <imgx>")
    assert_equal(html_attr(decode(" src=a.png alt=\"x y\""), "alt"), "x y")
    assert_equal(html_attr(decode(" data-src=a.png"), "src"), "")
    assert_equal(image_name("https://e.org/a/b/c.png#top"), "c.png")
    # the documentation's own clean-up keeps where a picture is (it said only its alt)
    var page = doc_prepare("# P\n\nSee <img src=\"my plot.png\" alt=\"The plot\"> here and ![Arch](./a.png).\n", "/d/p.md")
    assert_true(page.find("See ![The plot](my%20plot.png) here and ![Arch](./a.png).") >= 0, page)


def test_the_terminal_says_what_it_can_show() raises:
    var t = Terminal()
    # kitty graphics: its answer to the query, then DA1
    var evs = t.feed(str_bytes("\x1b_Gi=31;OK\x1b\\\x1b[?62;22c"), False)
    assert_equal(len(evs), 0)
    assert_true(t.caps.kitty_graphics)
    assert_false(t.caps.sixel)
    assert_true(t.caps.answered)
    # sixel: attribute 4 in DA1 (not the first number, the terminal class)
    var u = Terminal()
    _ = u.feed(str_bytes("\x1b[?4;1c"), False)
    assert_false(u.caps.sixel)
    var v = Terminal()
    _ = v.feed(str_bytes("\x1b[?62;4;9;22c"), False)
    assert_true(v.caps.sixel)
    # an error answer is not support; Alt-_ followed by typing stays keys
    var w = Terminal()
    _ = w.feed(str_bytes("\x1b_Gi=31;ENOTSUPPORTED\x1b\\"), False)
    assert_false(w.caps.kitty_graphics)
    var keys = w.feed(str_bytes("\x1b_ab"), True)
    assert_equal(len(keys), 3)
    # asked (not under GNU screen), and before DA1
    var q = caps_query(True)
    assert_true(q.find(KITTY_GRAPHICS_QUERY) >= 0 and q.find(KITTY_GRAPHICS_QUERY) < q.find("\x1b[c"))
    assert_equal(caps_query(False).find("\x1b_G"), -1)
    assert_equal(images_summary(False, False), "no (shown as text)")
    assert_equal(images_summary(True, True), "kitty graphics, sixel")


def test_following_an_image_link_names_the_picture() raises:
    var d = env_or("TMPDIR", "/tmp") + "/turbomojo-docimg-" + String(own_pid())
    var site = d + "/modular/Mojo/docs/site/manual"
    _ = run_system("rm -rf " + shell_quote(d) + " && mkdir -p " + shell_quote(site + "/images"))
    _ = write_file(site + "/images/arch.png", str_bytes("\x89PNG"))
    _ = write_file(site + "/pics.mdx", str_bytes("---\ntitle: Pictures\n---\n\n![The parts](./images/arch.png)\n\n![Lost](./images/gone.png)\n"))
    var app = App()
    app.scr.resize(120, 34)
    app.cwd = d
    app.doc_home = d
    app.handle(key_event(fkey(1) | MOD_SHIFT))
    app.docs_show(site + "/pics.mdx", "", True)
    app.draw()
    assert_true(to_str(app.scr.to_text()).find("[image: The parts]") >= 0, to_str(app.scr.to_text()))
    var here = -1
    var lost = -1
    for k in range(len(app.doc_links)):
        if app.doc_links[k] == "./images/arch.png":
            here = k
        if app.doc_links[k] == "./images/gone.png":
            lost = k
    assert_true(here >= 0 and lost >= 0, String(app.mode) + " " + app.doc_path + " " + String(len(app.doc_lines)) + " " + String(app.doc_width))
    app.docs_follow(here)
    assert_equal(app.status, "An image (copied to the clipboard): " + site + "/images/arch.png")
    app.docs_follow(lost)
    assert_equal(app.status, "That image is not part of the download: ./images/gone.png")
    _ = run_system("rm -rf " + shell_quote(d))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
