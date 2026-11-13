"""Tests for images in the docs pane, second part (P10-22b): kitty graphics. A PNG of
the download is sent once, as it is, with a virtual placement; the page shows it
through placeholder cells (U+10EEEE, the row and column marks, the image id as the
colour), so it scrolls with the text and works through tmux; it is deleted when the
page changes; the "[image: ...]" line stays as its caption. Off where it is not
asked for or the terminal cannot show it."""
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from std.collections import List
from kittygfx import *
from markdown import image_only, MdLine
from palette import ANSI_BASE
from app import *
from appstate import App
from term import key_event, fkey, MOD_SHIFT
from signals import own_pid
from util import env_or, run_system, shell_quote, write_file, str_bytes, base64, to_str, decode, bytes_to_str


def fake_png(w: Int, h: Int) -> List[UInt8]:
    """The first bytes of a PNG: signature and IHDR (enough for its size)."""
    var b: List[UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13, 0x49, 0x48, 0x44, 0x52]
    for v in [w, h]:
        b.append(UInt8((v >> 24) & 255))
        b.append(UInt8((v >> 16) & 255))
        b.append(UInt8((v >> 8) & 255))
        b.append(UInt8(v & 255))
    b.append(8)
    b.append(6)
    for _ in range(7):
        b.append(0)
    return b^


def test_the_pieces() raises:
    var d = kitty_diacritics()
    assert_equal(len(d), 297)
    assert_equal(d[0], 0x305)
    assert_equal(d[1], 0x30D)
    assert_equal(d[296], 0x1D244)
    var s = png_size(fake_png(800, 400))
    assert_equal(s[0], 800)
    assert_equal(s[1], 400)
    assert_equal(png_size(str_bytes("GIF89a, not a PNG at all"))[0], -1)
    # cells: a cell is twice as high as wide; proportions kept within the limits
    var c = image_cells(800, 400, 80, 24)
    assert_equal(c[0], 80)
    assert_equal(c[1], 20)
    var t = image_cells(100, 1000, 80, 24)          # tall: limited by the rows
    assert_equal(t[1], 24)
    assert_equal(t[0], 5)
    var small = image_cells(30, 10, 80, 24)
    assert_equal(small[0], 3)
    assert_equal(small[1], 1)


def test_sending_and_deleting() raises:
    var png = fake_png(200, 100)
    var one = kitty_transmit(17, png, 20, 5, False)
    assert_equal(one, "\x1b_Ga=T,U=1,f=100,t=d,i=17,c=20,r=5,q=2,m=0;" + base64(png) + "\x1b\\")
    # a large file goes in chunks of 4096 base64 characters, the last with m=0
    var big = List[UInt8]()
    for k in range(5000):
        big.append(UInt8(k % 251))
    var parts = kitty_transmit(18, big, 10, 3, False).split("\x1b_G")
    assert_equal(len(parts), 3)
    assert_true(String(parts[1]).startswith("a=T,U=1,f=100,t=d,i=18,c=10,r=3,q=2,m=1;"))
    assert_true(String(parts[2]).startswith("m=0,q=2;"))
    var joined = String(String(parts[1]).split(";")[1]).replace("\x1b\\", "") + String(String(parts[2]).split(";")[1]).replace("\x1b\\", "")
    assert_equal(joined, base64(big))
    assert_equal(kitty_delete(17, False), "\x1b_Ga=d,d=I,i=17,q=2\x1b\\")
    # through tmux: passed on, every ESC doubled
    assert_equal(kitty_delete(17, True), "\x1bPtmux;\x1b\x1b_Ga=d,d=I,i=17,q=2\x1b\x1b\\\x1b\\")


def test_when_pictures_are_shown() raises:
    var a = App()
    a.gfx_decide(False, "", "", "")
    assert_false(a.gfx_on)                          # auto, and nothing answered
    a.gfx_decide(True, "", "", "")
    assert_true(a.gfx_on)
    assert_false(a.gfx_tmux)
    a.gfx_decide(False, "/tmp/tmux-1/default,1,0", "3", "")
    assert_true(a.gfx_on)                           # tmux in kitty
    assert_true(a.gfx_tmux)
    a.gfx_decide(False, "/tmp/tmux-1/default,1,0", "", "")
    assert_false(a.gfx_on)                          # tmux somewhere else
    a.images_mode = "off"
    a.gfx_decide(True, "", "", "")
    assert_false(a.gfx_on)
    a.images_mode = "kitty"
    a.gfx_decide(False, "", "", "")
    assert_true(a.gfx_on)
    a.reader = True
    a.gfx_decide(True, "", "", "")
    assert_false(a.gfx_on)                          # screen-reader mode: words only


def page_home(tag: String) raises -> String:
    var d = env_or("TMPDIR", "/tmp") + "/turbomojo-docpic-" + String(own_pid()) + "-" + tag
    var site = d + "/modular/Mojo/docs/site/manual"
    _ = run_system("rm -rf " + shell_quote(d) + " && mkdir -p " + shell_quote(site + "/images"))
    _ = write_file(site + "/images/arch.png", fake_png(200, 100))
    _ = write_file(site + "/images/photo.jpg", str_bytes("JFIF"))
    _ = write_file(site + "/pics.mdx", str_bytes("---\ntitle: Pictures\n---\n\nAbove.\n\n![The parts](./images/arch.png)\n\nBetween ![inline](./images/arch.png) text.\n\n![A photo](./images/photo.jpg)\n\n![Web](https://e.org/x.png)\n\nBelow.\n" + "More text.\n\n" * 40))
    _ = write_file(site + "/other.mdx", str_bytes("---\ntitle: Other\n---\n\nNo pictures.\n"))
    return d


def reader(d: String, mode: String) raises -> App:
    var app = App()
    app.scr.resize(120, 34)
    app.cwd = d
    app.doc_home = d
    app.images_mode = mode
    app.gfx_decide(False, "", "", "")
    app.handle(key_event(fkey(1) | MOD_SHIFT))
    app.docs_show(d + "/modular/Mojo/docs/site/manual/pics.mdx", "", True)
    app.draw()
    return app^


def image_rows(app: App) -> Int:
    var n = 0
    for l in app.doc_lines:
        if l.img >= 0:
            n += 1
    return n


def test_a_picture_in_the_reader() raises:
    var d = page_home("show")
    var app = reader(d, "kitty")
    # 200 x 100 pixels: 20 columns, 5 rows; only the picture on a line of its own, of
    # the download, and a PNG (the JPEG, the web one and the inline one stay links)
    assert_equal(len(app.doc_images), 1)
    assert_equal(image_rows(app), 5)
    var cap = -1
    for k in range(len(app.doc_lines)):
        if app.doc_lines[k].img == 0 and app.doc_lines[k].img_row == 0:
            cap = k - 1
    assert_true(cap >= 0 and to_str(app.doc_lines[cap].cps) == "[image: The parts]")   # the caption stays
    assert_true(app.gfx_out.find("\x1b_Ga=T,U=1,f=100,t=d,i=16,c=20,r=5,q=2,m=0;" + base64(fake_png(200, 100))) == 0, app.gfx_out)
    # the cells: placeholder, image id 16 as the colour, the row and the column mark
    var diac = kitty_diacritics()
    var found = 0
    for y in range(app.scr.h):
        for x in range(app.scr.w):
            var k = y * app.scr.w + x
            if app.scr.ch[k] == PLACEHOLDER:
                found += 1
                assert_equal(app.scr.fg[k], ANSI_BASE + 16)
                var m = app.scr.extras(k)
                assert_equal(len(m), 2)
                var row_ok = False
                for r in range(5):
                    if m[0] == diac[r]:
                        row_ok = True
                assert_true(row_ok)                     # one of the picture's 5 rows
                assert_true(m[1] in diac[0:20])         # one of its 20 columns
    assert_equal(found, 100)
    # the frame sends them as the colour 38;5;16 and the marks after the character
    var out = List[UInt8]()
    app.scr.render(out)
    var frame = to_str(decode_bytes(out))
    var cell = String("")
    cell += chr(PLACEHOLDER) + chr(diac[2]) + chr(diac[3])
    assert_true(frame.find("38;5;16m") >= 0)
    assert_true(frame.find(cell) >= 0)                  # row 2, column 3
    # drawn again: not sent again
    app.gfx_out = ""
    app.draw()
    assert_equal(app.gfx_out, "")
    # scrolled so that its first rows are above the page: the rows still shown are the
    # right ones (their own marks)
    app.doc_scroll = cap + 3
    app.draw()
    var rows_seen = List[Int]()
    for y in range(app.scr.h):
        for x in range(app.scr.w):
            var k = y * app.scr.w + x
            if app.scr.ch[k] == PLACEHOLDER:
                var r = app.scr.extras(k)[0]
                if not (r in rows_seen):
                    rows_seen.append(r)
    var seen = String(app.doc_scroll) + " cap " + String(cap) + ":"
    for r in rows_seen:
        seen += " " + hex(r)
    assert_true(not (diac[0] in rows_seen) and not (diac[1] in rows_seen) and diac[2] in rows_seen and diac[4] in rows_seen, seen)
    # another page: deleted in the terminal
    app.docs_show(d + "/modular/Mojo/docs/site/manual/other.mdx", "", True)
    app.draw()
    assert_true(app.gfx_out.find("\x1b_Ga=d,d=I,i=16,q=2\x1b\\") >= 0, app.gfx_out)
    assert_equal(len(app.doc_images), 0)
    _ = run_system("rm -rf " + shell_quote(d))


def decode_bytes(b: List[UInt8]) -> List[Int]:
    return decode(bytes_to_str(b))


def test_words_only_where_pictures_are_off() raises:
    var d = page_home("off")
    var app = reader(d, "auto")                     # (nothing answered the query here)
    assert_false(app.gfx_on)
    assert_equal(image_rows(app), 0)
    assert_equal(app.gfx_out, "")
    var t = to_str(app.scr.to_text())
    assert_true(t.find("[image: The parts]") >= 0)
    _ = run_system("rm -rf " + shell_quote(d))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
