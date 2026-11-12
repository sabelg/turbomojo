"""Tests for one search box for code-shaped queries (P7-11, src/codequery.mojo and the
finder in src/app_docs.mojo): names, dotted paths and pasted error lines; one-line
answers; the explanation of a pasted error and the commands at the top; the palette's
"?" handing over to the finder."""
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from std.collections import List
from codequery import *
from window import WK_EXPLAIN
from dialog import D_DOCFIND
from term import key_event, ctrl, KEY_ENTER, KEY_ESC
from commands import CM_NEW, CM_DOCFIND
from app import *
from appstate import App, M_NORMAL, M_DIALOG, M_DOCS
from signals import own_pid
from util import env_or, run_system, shell_quote, write_file, str_bytes, decode, to_str

comptime STD_JSON = "{\"decl\": {\"kind\": \"package\", \"name\": \"std\", \"summary\": \"\", \"description\": \"\", \"modules\": [{\"kind\": \"module\", \"name\": \"__init__\", \"summary\": \"The standard library.\", \"description\": \"\"}], \"packages\": [{\"kind\": \"package\", \"name\": \"collections\", \"summary\": \"\", \"description\": \"\", \"packages\": [], \"modules\": [{\"kind\": \"module\", \"name\": \"list\", \"summary\": \"Defines the List type.\", \"description\": \"Imported automatically.\", \"aliases\": [], \"traits\": [], \"functions\": [{\"name\": \"make_list\", \"overloads\": [{\"signature\": \"def make_list(n: Int) -> List[Int]\", \"summary\": \"Makes a list.\", \"description\": \"\", \"deprecated\": \"\", \"args\": [{\"name\": \"n\", \"type\": \"Int\", \"description\": \"How many.\"}], \"parameters\": [], \"returns\": {\"type\": \"List[Int]\", \"doc\": \"The list.\"}, \"raisesDoc\": \"\"}]}, {\"name\": \"append\", \"overloads\": [{\"signature\": \"def append(a: List[Int], b: Int)\", \"summary\": \"Appends to a list.\", \"description\": \"\", \"deprecated\": \"\", \"args\": [], \"parameters\": [], \"raisesDoc\": \"\"}]}], \"structs\": [{\"kind\": \"struct\", \"name\": \"List\", \"signature\": \"struct List[T: AnyType, /]\", \"summary\": \"A resizable list.\", \"description\": \"Grows as needed.\", \"deprecated\": \"\", \"aliases\": [], \"fields\": [{\"name\": \"capacity\", \"type\": \"Int\", \"summary\": \"Room.\", \"description\": \"\"}], \"parameters\": [{\"name\": \"T\", \"type\": \"AnyType\", \"description\": \"The element type.\"}], \"parentTraits\": [{\"name\": \"Sized\"}, {\"name\": \"Copyable\"}], \"functions\": [{\"name\": \"append\", \"overloads\": [{\"signature\": \"def append(mut self, var value: T)\", \"summary\": \"Appends a value.\", \"description\": \"\", \"deprecated\": \"\", \"args\": [], \"parameters\": [], \"raisesDoc\": \"\"}]}]}]}, {\"kind\": \"module\", \"name\": \"empty\", \"summary\": \"\", \"description\": \"\", \"aliases\": [], \"structs\": [], \"traits\": [], \"functions\": []}]}]}, \"version\": \"1.2\"}"


def test_what_a_query_looks_like() raises:
    assert_equal(query_shape("append"), QS_NAME)
    assert_equal(query_shape("  List  "), QS_NAME)
    assert_equal(query_shape("List.append"), QS_PATH)
    assert_equal(query_shape("std.collections.list"), QS_PATH)
    assert_equal(query_shape("how to sort"), QS_WORDS)
    assert_equal(query_shape("@List"), QS_WORDS)          # the finder's own syntax stays
    assert_equal(query_shape("3.5"), QS_WORDS)
    assert_equal(query_shape("a..b"), QS_WORDS)
    var line = "/p/x.mojo:3:5: error: use of unknown declaration 'totl'"
    assert_equal(query_shape(line), QS_ERROR)
    assert_equal(error_text(line), "use of unknown declaration 'totl'")
    assert_equal(error_text("x.mojo:1:1: warning: assignment to 'x' was never used\nmore"), "assignment to 'x' was never used")
    assert_equal(finder_query("append"), "@append")
    assert_equal(finder_query("List.append"), "@append")
    assert_equal(finder_query(line), "use unknown declaration")          # the quoted name is the user's
    assert_equal(finder_query("sort a list"), "sort a list")
    assert_equal(first_prose("## `f`\n\n```mojo\ndef f()\n```\n\n**Args:**\n\n- `n`: x\n"), "")
    assert_equal(first_prose("## `f`\n\n```mojo\ndef f()\n```\n\nMakes a `list`. Then more.\n"), "Makes a list.")


def finder_app() raises -> App:
    var d = env_or("TMPDIR", "/tmp") + "/turbomojo-codequery-" + String(own_pid())
    _ = run_system("rm -rf " + shell_quote(d) + " && mkdir -p " + shell_quote(d + "/docs"))
    _ = write_file(d + "/docs/std.docs.json", str_bytes(STD_JSON))
    var app = App()
    app.scr.resize(120, 34)
    app.doc_home = d + "/docs"
    app.exec(CM_NEW)
    app.wins[app.top()].buf.load(decode("one\ntwo\n"))
    return app^


def rows(app: App) -> List[String]:
    var out = List[String]()
    for s in app.dlg.items:
        out.append(s)
    return out^


def test_names_paths_and_answers_in_the_finder() raises:
    var app = finder_app()
    app.docs_find_dialog("make_list")
    assert_equal(app.dlg.kind, D_DOCFIND)
    var r = rows(app)
    assert_true(r[0].find("make_list") > 0 and r[0].find(" - Makes a list.") > 0, "\n".join(r))
    app.handle(key_event(KEY_ESC))
    # a dotted path: the method of that struct first
    app.docs_find_dialog("List.append")
    r = rows(app)
    assert_true(r[0].find("List.append - Appends a value.") > 0, "\n".join(r))
    assert_true(len(r) >= 2 and r[1].find("Appends to a list.") > 0, "\n".join(r))    # the function after it
    app.handle(key_event(KEY_ENTER))
    assert_equal(app.mode, M_DOCS)
    assert_true(app.doc_path.endswith("std.collections.list.md"), app.doc_path)
    app.handle(key_event(KEY_ESC))


def test_a_pasted_error_and_the_commands() raises:
    var app = finder_app()
    app.docs_find_dialog("/p/x.mojo:3:5: error: use of unknown declaration 'totl'")
    var r = rows(app)
    assert_true(r[0].startswith("! Explanation: Unknown name"), "\n".join(r))
    app.handle(key_event(KEY_ENTER))
    assert_equal(app.mode, M_NORMAL)
    assert_equal(app.wins[app.top()].kind, WK_EXPLAIN)
    app.handle(key_event(KEY_ESC))                   # (closes the explanation)
    # words that name a command: the command first, with its key; Enter runs it
    app.docs_find_dialog("duplicate")
    r = rows(app)
    assert_true(r[0].startswith("> Command: Duplicate line   Ctrl-D"), "\n".join(r))
    app.handle(key_event(KEY_ENTER))
    assert_equal(app.mode, M_NORMAL)
    assert_equal(to_str(app.wins[app.top()].buf.all_text()), "one\none\ntwo\n")
    # the finder's own syntax is left alone: no commands for @names
    app.docs_find_dialog("@append")
    for s in rows(app):
        assert_false(s.startswith("> Command"), s)
    app.handle(key_event(KEY_ESC))


def test_the_palette_hands_over() raises:
    var app = finder_app()
    app.quick_dialog("?List.append")
    var r = rows(app)
    assert_equal(len(r), 1)
    assert_true(r[0].startswith("Search the documentation for \"List.append\""), r[0])
    assert_true(r[0].find(app.reg.key_label(CM_DOCFIND)) > 0, r[0])
    app.handle(key_event(KEY_ENTER))
    assert_equal(app.mode, M_DIALOG)
    assert_equal(app.dlg.kind, D_DOCFIND)
    assert_equal(app.dlg.field_text(0), "List.append")
    assert_true(rows(app)[0].find("List.append - Appends a value.") > 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
