"""Offline documentation: reading `mojo doc` output, and F1 / Ctrl-F1 on a name. The
application tests run the real `mojo doc` (skipped when the toolchain is not on PATH)."""
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from std.collections import List
from docs import *
from json import json_parse
from markdown import md_plain
from term import fkey, key_event, MOD_CTRL, KEY_ESC
from app import *
from appstate import App, M_NORMAL, M_HOVER, M_DIALOG
from dialog import D_HELP
from commands import CM_DOCS, CM_HELP, build_registry
from config import load_settings
from signals import own_pid
from util import decode, to_str, env_or, run_system, which


def scratch(tag: String) -> String:
    var d = env_or("TMPDIR", "/tmp") + "/turbomojo-docs-" + String(own_pid()) + "-" + tag
    _ = run_system("rm -rf '" + d + "' && mkdir -p '" + d + "' && printf 'root = true\\n' > '" + d + "/.editorconfig'")
    return d


def put(path: String, text: String) raises:
    with open(path, "w") as f:
        f.write(text)


comptime SAMPLE = "{\"decl\": {\"kind\": \"module\", \"name\": \"geo\", \"aliases\": [{\"name\": \"LIMIT\", \"signature\": \"comptime LIMIT\", \"value\": \"3\", \"summary\": \"The limit.\", \"description\": \"\"}], \"functions\": [{\"kind\": \"function\", \"name\": \"scale\", \"overloads\": [{\"signature\": \"def scale(n: Int, by: Int) -> Int\", \"summary\": \"Scales a number.\", \"description\": \"Longer text.\", \"deprecated\": \"\", \"args\": [{\"name\": \"n\", \"type\": \"Int\", \"description\": \"\"}, {\"name\": \"by\", \"type\": \"Int\", \"description\": \"The factor.\"}], \"returns\": {\"type\": \"Int\", \"doc\": \"The product.\"}, \"raisesDoc\": \"If it overflows.\"}, {\"signature\": \"def scale(n: Float64) -> Float64\", \"summary\": \"For floats.\", \"description\": \"\", \"deprecated\": \"Use the Int form.\", \"args\": [], \"returns\": {\"type\": \"Float64\"}, \"raisesDoc\": \"\"}]}], \"structs\": [{\"kind\": \"struct\", \"name\": \"Point\", \"summary\": \"A point.\", \"description\": \"Has an x.\", \"deprecated\": \"\", \"aliases\": [], \"fields\": [{\"name\": \"x\", \"type\": \"Int\", \"summary\": \"The x coordinate.\", \"description\": \"\"}], \"functions\": [{\"name\": \"norm\", \"overloads\": [{\"signature\": \"def norm(self) -> Int\", \"summary\": \"Returns the norm.\", \"description\": \"\", \"deprecated\": \"\", \"args\": [{\"name\": \"self\", \"type\": \"Self\", \"description\": \"\"}], \"raisesDoc\": \"\"}]}]}], \"traits\": [{\"kind\": \"trait\", \"name\": \"Shape\", \"summary\": \"A shape.\", \"description\": \"\", \"deprecated\": \"\", \"fields\": [], \"functions\": [{\"name\": \"norm\", \"overloads\": [{\"signature\": \"def norm(self) -> Int\", \"summary\": \"Its size.\", \"description\": \"\", \"deprecated\": \"\", \"args\": [], \"raisesDoc\": \"\"}]}]}], \"modules\": [{\"kind\": \"module\", \"name\": \"inner\", \"functions\": [{\"name\": \"deep\", \"overloads\": [{\"signature\": \"def deep()\", \"summary\": \"Deep down.\", \"description\": \"\", \"deprecated\": \"\", \"args\": [], \"raisesDoc\": \"\"}]}]}]}, \"version\": \"1.2\"}"


def test_mojo_doc_output_becomes_entries() raises:
    var e = parse_mojo_doc(json_parse(SAMPLE))
    var listed = String("")
    for x in e:
        listed += x.kind + ":" + (x.owner + "." if x.owner.byte_length() > 0 else String("")) + x.name + " "
    assert_equal(listed, "alias:LIMIT function:scale field:Point.x struct:Point method:Point.norm trait:Shape method:Shape.norm function:deep ")
    assert_equal(e[7].module, "inner")                   # a module inside the package
    assert_equal(len(parse_mojo_doc(json_parse("{}"))), 0)
    assert_equal(len(parse_mojo_doc(json_parse("{\"decl\": {\"kind\": \"module\", \"name\": \"empty\"}}"))), 0)


def test_function_documentation_text() raises:
    var e = parse_mojo_doc(json_parse(SAMPLE))
    # both overloads; only explained arguments; returns, raises, deprecation
    assert_equal(docs_for(e, "scale"), "```mojo\ndef scale(n: Int, by: Int) -> Int\n```\n\n*function* in module `geo`\n\nScales a number.\n\nLonger text.\n\n**Args:**\n\n- `by` (`Int`): The factor.\n\n**Returns:** The product.\n\n**Raises:** If it overflows.\n\n---\n\n```mojo\ndef scale(n: Float64) -> Float64\n```\n\n*function* in module `geo`\n\n**Deprecated:** Use the Int form.\n\nFor floats.")
    assert_equal(docs_for(e, "LIMIT"), "```mojo\ncomptime LIMIT = 3\n```\n\n*constant* in module `geo`\n\nThe limit.")
    assert_equal(docs_for(e, "nothing_like_it"), "")


def test_type_field_and_same_name_in_two_places() raises:
    var e = parse_mojo_doc(json_parse(SAMPLE))
    assert_equal(docs_for(e, "Point"), "```mojo\nstruct Point\n```\n\n*struct* in module `geo`\n\nA point.\n\nHas an x.\n\n**Fields:**\n\n- `x: Int` - The x coordinate.\n\n**Methods:** `norm`")
    assert_equal(docs_for(e, "x"), "```mojo\nvar x: Int\n```\n\n*field* of `Point` in module `geo`\n\nThe x coordinate.")
    # a method of a struct and of a trait with the same name: both, with a rule between
    var both = docs_for(e, "norm")
    assert_true(both.find("*method* of `Point` in module `geo`\n\nReturns the norm.") > 0, both)
    assert_true(both.find("\n\n---\n\n") > 0, both)
    assert_true(both.find("*method* of `Shape` in module `geo`\n\nIts size.") > 0, both)


# ------------------------------------------------------- in the application
comptime LIB = "\"\"\"A small library.\"\"\"\n\nstruct Point:\n    \"\"\"A point on a line.\"\"\"\n    var x: Int\n    \"\"\"Where it is.\"\"\"\n\n    def norm(self, scale: Int = 1) -> Int:\n        \"\"\"Returns the distance from zero.\n\n        Args:\n            scale: A factor applied to the result.\n\n        Returns:\n            The scaled distance.\n        \"\"\"\n        return self.x * scale\n\ndef twice(n: Int) -> Int:\n    \"\"\"Returns n times two.\"\"\"\n    return n * 2\n\ndef bare(n: Int) -> Int:\n    return n\n"


def docs_app(dir: String) raises -> App:
    put(dir + "/lib.mojo", LIB)
    put(dir + "/main.mojo", "from lib import twice, Point\n\ndef main():\n    var p = Point(3)\n    print(twice(p.norm()), bare(1), zzz_unknown)\n")
    var app = App()
    app.scr.resize(100, 30)
    app.cwd = dir
    app.open_path(dir + "/main.mojo")
    return app^


def window_text(app: App) -> String:
    return md_plain(app.hover_lines)


def have_mojo() -> Bool:
    if which("mojo").byte_length() == 0:
        print("      (skipped: mojo is not on PATH)")
        return False
    return True


def test_topic_search_shows_the_documentation() raises:
    if not have_mojo():
        return
    var dir = scratch("app1")
    var app = docs_app(dir)
    var i = app.find_editor(dir + "/main.mojo")
    assert_equal(build_registry().find_key(fkey(1) | MOD_CTRL), CM_DOCS)
    app.wins[i].goto(4, 12)                              # on "twice"
    app.handle(key_event(fkey(1) | MOD_CTRL))
    assert_equal(app.mode, M_HOVER, app.status)
    var t = window_text(app)
    assert_true(t.find("def twice(n: Int) -> Int") == 0, t)
    assert_true(t.find("function in module lib") > 0, t)
    assert_true(t.find("Returns n times two.") > 0, t)
    app.draw()
    assert_true(to_str(app.scr.to_text()).find("Returns n times two.") > 0)
    app.handle(key_event(KEY_ESC))
    assert_equal(app.mode, M_NORMAL)
    # a method: arguments and result as written in the docstring
    app.wins[i].goto(4, 19)                              # on "norm"
    app.exec(CM_DOCS)
    t = window_text(app)
    assert_true(t.find("def norm(self, scale: Int = ") == 0, t)
    assert_true(t.find("method of Point in module lib") > 0, t)
    assert_true(t.find("Returns the distance from zero.") > 0, t)
    assert_true(t.find("scale (Int): A factor applied to the result.") > 0, t)
    assert_true(t.find("Returns: The scaled distance.") > 0, t)
    app.handle(key_event(KEY_ESC))
    # a struct lists its fields and methods
    app.wins[i].goto(3, 13)
    app.exec(CM_DOCS)
    t = window_text(app)
    assert_true(t.find("struct Point") == 0, t)
    assert_true(t.find("A point on a line.") > 0, t)
    assert_true(t.find("x: Int - Where it is.") > 0, t)
    assert_true(t.find("Methods: ") > 0 and t.find("norm") > 0, t)
    app.handle(key_event(KEY_ESC))
    # `mojo doc` ran once for the file, however often it was asked
    assert_equal(len(app.doc_files), 1)
    assert_equal(app.doc_files[0], dir + "/lib.mojo")
    _ = run_system("rm -rf '" + dir + "'")


def test_f1_is_documentation_on_a_known_name_and_help_elsewhere() raises:
    if not have_mojo():
        return
    var dir = scratch("app2")
    var app = docs_app(dir)
    var i = app.find_editor(dir + "/main.mojo")
    # before anything is known about the project F1 is the keyboard reference
    app.wins[i].goto(4, 12)
    app.handle(key_event(fkey(1)))
    assert_equal(app.mode, M_DIALOG)
    assert_equal(app.dlg.kind, D_HELP)
    app.handle(key_event(KEY_ESC))
    # ... and it set the index going; once that is there F1 on the name is its documentation
    while app.symidx.building:
        app.symidx_tick()
    app.handle(key_event(fkey(1)))
    assert_equal(app.mode, M_HOVER)
    assert_true(window_text(app).find("Returns n times two.") > 0)
    app.handle(key_event(KEY_ESC))
    # on something that is not a documented name: the reference, as always
    app.wins[i].goto(4, 6)                               # on "print"
    app.handle(key_event(fkey(1)))
    assert_equal(app.dlg.kind, D_HELP)
    app.handle(key_event(KEY_ESC))
    app.wins[i].goto(1, 0)                               # an empty line
    app.handle(key_event(fkey(1)))
    assert_equal(app.dlg.kind, D_HELP)
    app.handle(key_event(KEY_ESC))
    _ = run_system("rm -rf '" + dir + "'")


def test_topic_search_without_documentation_and_after_changes() raises:
    if not have_mojo():
        return
    var dir = scratch("app3")
    var app = docs_app(dir)
    var i = app.find_editor(dir + "/main.mojo")
    app.wins[i].goto(4, 40)                              # on "zzz_unknown"
    app.exec(CM_DOCS)
    assert_equal(app.mode, M_NORMAL)
    assert_equal(app.status, "No documentation found for zzz_unknown")
    app.wins[i].goto(1, 0)
    app.exec(CM_DOCS)
    assert_equal(app.status, "Put the cursor on a name first")
    # a function without a docstring still shows what it is
    app.wins[i].goto(4, 28)                              # on "bare"
    app.exec(CM_DOCS)
    assert_equal(app.mode, M_HOVER, app.status)
    assert_true(window_text(app).find("def bare(n: Int) -> Int") == 0, window_text(app))
    app.handle(key_event(KEY_ESC))
    # the library changes on disk: the next question reads it again
    _ = run_system("sleep 1.1")
    put(dir + "/lib.mojo", LIB + "\ndef zzz_unknown() -> Int:\n    \"\"\"No longer unknown.\"\"\"\n    return 0\n")
    app.symidx.built_ns = 0                              # (the index is rebuilt when it is old)
    app.symidx.start(dir)
    app.wins[i].goto(4, 40)
    app.exec(CM_DOCS)
    assert_equal(app.mode, M_HOVER, app.status)
    assert_true(window_text(app).find("No longer unknown.") > 0, window_text(app))
    assert_equal(len(app.doc_files), 1)
    app.handle(key_event(KEY_ESC))
    # a file that does not compile gives no documentation, and says so
    put(dir + "/lib.mojo", "def twice(:\n")
    _ = run_system("sleep 1.1; touch '" + dir + "/lib.mojo'")
    app.symidx.start(dir)
    app.wins[i].goto(4, 12)
    app.exec(CM_DOCS)
    assert_equal(app.mode, M_NORMAL)
    assert_equal(app.status, "No documentation found for twice")
    _ = run_system("rm -rf '" + dir + "'")


def test_documentation_folders_outside_the_project() raises:
    if not have_mojo():
        return
    var dir = scratch("app4")
    var libdir = scratch("app4lib")
    put(libdir + "/extras.mojo", "def far_away(n: Int) -> Int:\n    \"\"\"Lives in a library folder.\"\"\"\n    return n\n")
    put(dir + "/main.mojo", "def main():\n    far_away(1)\n")
    var app = App()
    app.scr.resize(100, 30)
    app.cwd = dir
    app.open_path(dir + "/main.mojo")
    var i = app.find_editor(dir + "/main.mojo")
    app.wins[i].goto(1, 6)
    app.exec(CM_DOCS)
    assert_equal(app.status, "No documentation found for far_away")
    var s = load_settings("[tools]\ndocs_paths = [\"" + libdir + "\"]\n", "")
    assert_equal(len(s.warnings), 0)
    app.apply_settings(s)
    app.exec(CM_DOCS)
    assert_equal(app.mode, M_HOVER, app.status)
    assert_true(window_text(app).find("Lives in a library folder.") > 0, window_text(app))
    app.handle(key_event(KEY_ESC))
    # a single folder may be given as a string; anything else is a warning
    assert_equal(len(load_settings("[tools]\ndocs_paths = \"/somewhere\"\n", "").docs_paths), 1)
    assert_equal(len(load_settings("[tools]\ndocs_paths = 3\n", "").warnings), 1)
    _ = run_system("rm -rf '" + dir + "' '" + libdir + "'")


def test_parametric_struct_and_trait_metadata() raises:
    var rich_json = "{\"decl\": {\"kind\": \"module\", \"name\": \"boxmod\", \"structs\": [{\"kind\": \"struct\", \"name\": \"Box\", \"signature\": \"struct Box[T: Copyable]\", \"summary\": \"Holds a T.\", \"description\": \"\", \"deprecated\": \"\", \"parameters\": [{\"name\": \"T\", \"type\": \"Copyable\", \"description\": \"Element type.\"}], \"parentTraits\": [{\"name\": \"Copyable\"}, {\"name\": \"Writable\"}], \"fields\": [], \"functions\": []}]}, \"version\": \"1.2\"}"
    var e = parse_mojo_doc(json_parse(rich_json))
    var out = docs_for(e, "Box")
    assert_true(out.find("struct Box[T: Copyable]") >= 0, out)
    assert_true(out.find("**Parameters:**\n\n- `T: Copyable` - Element type.") >= 0, out)
    assert_true(out.find("**Implemented traits:** `Copyable`, `Writable`") >= 0, out)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
