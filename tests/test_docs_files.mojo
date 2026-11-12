"""Tests that the documents made from the program and the records are up to date
(P9-05): docs/KEYMAP.md is what `tmide --keys` prints, CHANGELOG.md and docs/SOURCE.md
are what scripts/gen_docs.py makes, every source file is listed, and every key the user
guide names is a key of the default keymap that does something."""
from std.testing import assert_equal, assert_true, TestSuite
from std.collections import List
from commands import build_registry, parse_key, CM_NONE
from util import run_capture, read_file, bytes_to_str, getcwd, shell_quote


def test_the_keymap_reference_is_the_programs() raises:
    var r = run_capture(shell_quote(getcwd() + "/build/tmide") + " --keys < /dev/null")
    assert_equal(r.status, 0)
    assert_equal(bytes_to_str(read_file(getcwd() + "/docs/KEYMAP.md")), bytes_to_str(r.out), "docs/KEYMAP.md is out of date: build/tmide --keys > docs/KEYMAP.md")


def test_the_generated_documents_are_up_to_date() raises:
    var r = run_capture("cd " + shell_quote(getcwd()) + " && python3 scripts/gen_docs.py --check")
    assert_equal(r.status, 0, bytes_to_str(r.out))
    var src = bytes_to_str(read_file(getcwd() + "/docs/SOURCE.md"))
    var ls = run_capture("ls " + shell_quote(getcwd() + "/src"))
    var n = 0
    for f in bytes_to_str(ls.out).split("\n"):
        var name = String(String(f).strip())
        if name.endswith(".mojo"):
            assert_true(src.find("`src/" + name + "`") > 0, name + " is not in docs/SOURCE.md")
            n += 1
    assert_true(n >= 100, String(n))


def test_the_guides_keys_do_something() raises:
    """Every **key** in the user guide is a key, and the default keymap binds it (or it
    is one of the few keys the IDE handles itself)."""
    var guide = bytes_to_str(read_file(getcwd() + "/docs/USER_GUIDE.md"))
    var reg = build_registry()
    var own = ["F10", "F7", "F8", "Shift-F8", "F4", "Shift-F5", "Alt-1", "Alt-9", "Ctrl-Alt-Down", "Ctrl-Space"]
    var parts = guide.split("**")
    var checked = 0
    for k in range(1, len(parts), 2):
        var word = String(parts[k]).replace("\\\\", "\\")
        var looks = word.startswith("F") or word.startswith("Ctrl-") or word.startswith("Alt-") or word.startswith("Shift-")
        if not looks or word.find(" ") >= 0 and not word.startswith("Ctrl-"):
            continue
        var code = parse_key(word)
        if code == 0:
            continue                       # (bold words that are not keys)
        var known = reg.find_key(code) != CM_NONE or reg.find_debug_key(code) != CM_NONE
        assert_true(known or word in own, "the guide's key " + word + " does nothing in the Modern keymap")
        checked += 1
    assert_true(checked >= 50, String(checked))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
