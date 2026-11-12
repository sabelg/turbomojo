"""Tests for the docs pane (P7-09, src/docpane.mojo, src/app_docpane.mojo): the section
of a page one heading starts; the pane at the right edge, the editor making room and
getting it back; the name at the cursor looked up once the cursor rests - never a
compile while it does (only `mojo doc` answers already there), more with Ctrl-F1;
standard library declarations from the downloaded reference; Enter opens the viewer."""
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from std.collections import List
from docpane import md_section, DOCPANE_SECTION_MAX
from app_docpane import DOCPANE_IDLE_MS
from window import WK_DOCPANE, WK_EDITOR
from term import key_event, fkey, MOD_CTRL, KEY_ENTER, KEY_ESC
from commands import CM_DOCS_PANE, CM_DOCS
from app import *
from appstate import App, M_NORMAL, M_DOCS, now_ns
from signals import own_pid
from util import env_or, run_system, shell_quote, write_file, str_bytes, to_str, which

comptime MS = 1000000
comptime STD_JSON = "{\"decl\": {\"kind\": \"package\", \"name\": \"std\", \"summary\": \"\", \"description\": \"\", \"modules\": [{\"kind\": \"module\", \"name\": \"__init__\", \"summary\": \"The standard library.\", \"description\": \"\"}], \"packages\": [{\"kind\": \"package\", \"name\": \"collections\", \"summary\": \"\", \"description\": \"\", \"packages\": [], \"modules\": [{\"kind\": \"module\", \"name\": \"list\", \"summary\": \"Defines the List type.\", \"description\": \"Imported automatically.\", \"aliases\": [], \"traits\": [], \"functions\": [{\"name\": \"make_list\", \"overloads\": [{\"signature\": \"def make_list(n: Int) -> List[Int]\", \"summary\": \"Makes a list.\", \"description\": \"\", \"deprecated\": \"\", \"args\": [{\"name\": \"n\", \"type\": \"Int\", \"description\": \"How many.\"}], \"parameters\": [], \"returns\": {\"type\": \"List[Int]\", \"doc\": \"The list.\"}, \"raisesDoc\": \"\"}]}, {\"name\": \"append\", \"overloads\": [{\"signature\": \"def append(a: List[Int], b: Int)\", \"summary\": \"Appends to a list.\", \"description\": \"\", \"deprecated\": \"\", \"args\": [], \"parameters\": [], \"raisesDoc\": \"\"}]}], \"structs\": [{\"kind\": \"struct\", \"name\": \"List\", \"signature\": \"struct List[T: AnyType, /]\", \"summary\": \"A resizable list.\", \"description\": \"Grows as needed.\", \"deprecated\": \"\", \"aliases\": [], \"fields\": [{\"name\": \"capacity\", \"type\": \"Int\", \"summary\": \"Room.\", \"description\": \"\"}], \"parameters\": [{\"name\": \"T\", \"type\": \"AnyType\", \"description\": \"The element type.\"}], \"parentTraits\": [{\"name\": \"Sized\"}, {\"name\": \"Copyable\"}], \"functions\": [{\"name\": \"append\", \"overloads\": [{\"signature\": \"def append(mut self, var value: T)\", \"summary\": \"Appends a value.\", \"description\": \"\", \"deprecated\": \"\", \"args\": [], \"parameters\": [], \"raisesDoc\": \"\"}]}]}]}, {\"kind\": \"module\", \"name\": \"empty\", \"summary\": \"\", \"description\": \"\", \"aliases\": [], \"structs\": [], \"traits\": [], \"functions\": []}]}]}, \"version\": \"1.2\"}"


def scratch(tag: String) -> String:
    var d = env_or("TMPDIR", "/tmp") + "/turbomojo-docpane-" + String(own_pid()) + "-" + tag
    _ = run_system("rm -rf " + shell_quote(d) + " && mkdir -p " + shell_quote(d))
    return d


def test_a_section() raises:
    var page = "# std.m\n\nIntro.\n\n## struct `List`\n\nA list.\n\n```mojo\n# not a heading\n```\n\n### Methods\n\n#### `append`\n\nAppends.\n\n## Functions\n\n### `append`\n\nThe function.\n"
    var s = md_section(page, "struct List", 0)
    assert_true(s.startswith("## struct `List`\n"), s)
    assert_true(s.find("# not a heading") > 0 and s.find("Appends.") > 0, s)       # deeper headings and code stay
    assert_true(s.find("Functions") < 0, s)                                      # the next ## ends it
    assert_equal(md_section(page, "append", 0), "#### `append`\n\nAppends.\n\n")
    assert_equal(String(md_section(page, "append", 1).strip()), "### `append`\n\nThe function.")
    assert_equal(md_section(page, "not a heading", 0), "")                      # (in code)
    assert_equal(md_section(page, "nothing", 0), "")
    var long = String("## `big`\n```mojo\n")
    for k in range(DOCPANE_SECTION_MAX * 2):
        long += "x = " + String(k) + "\n"
    var cutshort = md_section(long, "big", 0)
    assert_true(cutshort.endswith("```\n\n..."), cutshort)


def pane_text(app: App) -> String:
    var pi = app.docpane_index()
    var s = String("")
    for r in range(app.wins[pi].buf.count()):
        s += to_str(app.wins[pi].buf.line(r)) + "\n"
    return s^


def rest(mut app: App):
    """The cursor rests: a round of events, then the time it waits."""
    var now = now_ns()
    app.docpane_tick(now)
    app.docpane_tick(now + (DOCPANE_IDLE_MS + 1) * MS)


def test_the_pane_follows_the_cursor() raises:
    var d = scratch("follow")
    _ = run_system("mkdir -p " + shell_quote(d + "/docs") + " && printf 'root = true\\n' > " + shell_quote(d + "/.editorconfig"))
    _ = write_file(d + "/docs/std.docs.json", str_bytes(STD_JSON))
    _ = write_file(d + "/lib.mojo", str_bytes("def twice(n: Int) -> Int:\n    \"\"\"Returns n times two.\"\"\"\n    return n * 2\n"))
    _ = write_file(d + "/main.mojo", str_bytes("from lib import twice\n\ndef main():\n    var l = List[Int]()\n    print(twice(len(l)), make_list(2))\n"))
    var app = App()
    app.scr.resize(120, 34)
    app.cwd = d
    app.doc_home = d + "/docs"
    app.open_path(d + "/main.mojo")
    var ei = app.top()
    var full = app.wins[ei].w
    app.exec(CM_DOCS_PANE)
    var pi = app.docpane_index()
    assert_true(pi >= 0)
    assert_equal(app.wins[pi].x + app.wins[pi].w, 120)                         # at the right edge
    ei = app.find_editor(d + "/main.mojo")
    assert_equal(app.wins[ei].x + app.wins[ei].w, app.wins[pi].x)               # beside the code
    assert_equal(app.wins[app.top()].kind, WK_EDITOR)                           # the keys stay with the code
    # a standard library struct: its section of the reference
    app.wins[ei].goto(3, 14)                                                    # on List
    rest(app)
    var t = pane_text(app)
    assert_true(t.find("A resizable list.") >= 0 and t.find("Appends a value.") >= 0, t)
    assert_true(t.find("Makes a list.") < 0, t)                                 # (another declaration)
    assert_true(app.wins[app.docpane_index()].title.find("List") > 0)
    # moving on: nothing until the cursor rests
    app.wins[ei].goto(4, 30)                                                    # on make_list
    app.docpane_tick(now_ns())
    assert_true(pane_text(app).find("A resizable list.") >= 0)
    rest(app)
    assert_true(pane_text(app).find("Makes a list.") >= 0, pane_text(app))
    # a function of the project: no compile while resting...
    app.wins[ei].goto(4, 11)                                                    # on twice
    rest(app)
    assert_equal(len(app.doc_files), 0)
    assert_true(pane_text(app).find("Ctrl-F1") >= 0, pane_text(app))
    if which("mojo").byte_length() > 0:
        # ... Ctrl-F1 asks `mojo doc`, and the answer lands in the pane
        app.handle(key_event(fkey(1) | MOD_CTRL))
        assert_equal(app.mode, M_NORMAL)                                         # (no popup)
        assert_true(pane_text(app).find("Returns n times two.") >= 0, pane_text(app))
        assert_equal(len(app.doc_files), 1)
        # later rests use what it said
        app.wins[ei].goto(3, 14)
        rest(app)
        app.wins[ei].goto(4, 11)
        rest(app)
        assert_true(pane_text(app).find("Returns n times two.") >= 0, pane_text(app))
    # Enter in the pane: the page in the full viewer, for study
    app.wins[ei].goto(3, 14)
    rest(app)
    app.focus(app.docpane_index())
    app.handle(key_event(KEY_ENTER))
    assert_equal(app.mode, M_DOCS)
    assert_true(app.doc_path.endswith("std.collections.list.md"), app.doc_path)
    app.handle(key_event(KEY_ESC))
    assert_equal(app.mode, M_NORMAL)
    # closed: the editor has its room back
    app.exec(CM_DOCS_PANE)
    assert_equal(app.docpane_index(), -1)
    assert_equal(app.wins[app.find_editor(d + "/main.mojo")].w, full)
    _ = run_system("rm -rf " + shell_quote(d))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
