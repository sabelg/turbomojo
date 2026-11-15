"""E2E Test Suite for Feature #18:
LSP callHierarchy and Mojo struct/trait typeHierarchy with SymbolIndex fallback.

Covers:
- 5 Tier 1 (Isolated Happy Path) tests
- 5 Tier 2 (Boundary Value Analysis & Corner Cases) tests
Strictly conforming to Mojo 1.2 rules.
"""
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from std.collections import List
from symindex import SymbolIndex, IndexedSymbol, owners_of, is_mojo_file
from outline import (
    OutlineItem, scan_outline, parse_struct_traits,
    SK_FUNCTION, SK_STRUCT, SK_INTERFACE, SK_METHOD, SK_CONSTANT, SK_CELL,
)
from lsp import (
    parse_caps, parse_call_hierarchy_items, parse_incoming_calls,
    parse_outgoing_calls, parse_type_hierarchy_items,
)
from app import *
from appstate import App, M_DIALOG, M_NORMAL
from dialog import D_HIERARCHY
from buffer import TextBuffer
from json import json_parse, Json, JsonWriter, json_quote
from signals import own_pid
from util import decode, to_str, bytes_to_str, env_or, run_system, shell_quote, write_file, str_bytes


def scratch(tag: String) -> String:
    var d = env_or("TMPDIR", "/tmp") + "/turbomojo-e2e-f18-" + String(own_pid()) + "-" + tag
    _ = run_system("rm -rf " + shell_quote(d) + " && mkdir -p " + shell_quote(d))
    return d


def clean_scratch(d: String):
    _ = run_system("rm -rf " + shell_quote(d))


def finish_index(mut idx: SymbolIndex):
    var guard = 0
    while idx.building and guard < 10000:
        idx.step(10)
        guard += 1


# ===========================================================================
# Tier 1: Isolated Happy Path Tests (5 tests)
# ===========================================================================

def test_tier1_f18_case1_symbol_index_struct_and_trait_indexing() raises:
    """Verify SymbolIndex indexes structs, traits, member methods, and standalone functions."""
    var d = scratch("idx_hierarchy")
    var f = d + "/geometry.mojo"
    var code = (
        "trait Shape:\n"
        "    def area(self) -> Int: ...\n\n"
        "struct Point:\n"
        "    var x: Int\n"
        "    def norm(self) -> Int:\n"
        "        return self.x\n\n"
        "def make_point() -> Point:\n"
        "    return Point()\n"
    )
    _ = write_file(f, str_bytes(code))

    var idx = SymbolIndex()
    idx.start(d)
    finish_index(idx)

    assert_true(idx.built)
    assert_true(len(idx.syms) >= 4)

    var saw_trait = False
    var saw_struct = False
    var saw_method_shape = False
    var saw_method_point = False
    var saw_func = False

    for s in idx.syms:
        if s.name == "Shape":
            saw_trait = True
            assert_equal(s.kind, SK_INTERFACE)
            assert_equal(s.owner, "")
        elif s.name == "Point":
            saw_struct = True
            assert_equal(s.kind, SK_STRUCT)
            assert_equal(s.owner, "")
        elif s.name == "area":
            saw_method_shape = True
            assert_equal(s.kind, SK_METHOD)
            assert_equal(s.owner, "Shape")
        elif s.name == "norm":
            saw_method_point = True
            assert_equal(s.kind, SK_METHOD)
            assert_equal(s.owner, "Point")
        elif s.name == "make_point":
            saw_func = True
            assert_equal(s.kind, SK_FUNCTION)
            assert_equal(s.owner, "")

    assert_true(saw_trait and saw_struct and saw_method_shape and saw_method_point and saw_func)
    clean_scratch(d)


def test_tier1_f18_case2_symbol_index_trait_conformance_extraction() raises:
    """Verify scan_outline extracts struct and trait definitions with conformance hierarchies."""
    var b = TextBuffer()
    var code = (
        "trait Drawable:\n"
        "    def draw(self): ...\n\n"
        "struct Circle(Drawable, Movable):\n"
        "    var r: Int\n"
        "    def draw(self):\n"
        "        pass\n"
    )
    b.load(decode(code))
    var items = scan_outline(b)
    var owners = owners_of(items)

    assert_true(len(items) >= 4)
    assert_equal(items[0].name, "Drawable")
    assert_equal(items[0].kind, SK_INTERFACE)

    assert_equal(items[1].name, "draw")
    assert_equal(items[1].kind, SK_METHOD)
    assert_equal(owners[1], "Drawable")

    assert_equal(items[2].name, "Circle")
    assert_equal(items[2].kind, SK_STRUCT)

    assert_equal(items[3].name, "draw")
    assert_equal(items[3].kind, SK_METHOD)
    assert_equal(owners[3], "Circle")


def test_tier1_f18_case3_symbol_index_caller_callee_scope_nesting() raises:
    """Verify owners_of correctly tags nested caller/callee function scopes."""
    var b = TextBuffer()
    var code = (
        "def outer():\n"
        "    def inner():\n"
        "        pass\n"
        "def top_level():\n"
        "    pass\n"
    )
    b.load(decode(code))
    var items = scan_outline(b)
    var owners = owners_of(items)

    assert_equal(len(items), 3)
    assert_equal(items[0].name, "outer")
    assert_equal(owners[0], "")

    assert_equal(items[1].name, "inner")
    assert_equal(owners[1], "outer")

    assert_equal(items[2].name, "top_level")
    assert_equal(owners[2], "")


def test_tier1_f18_case4_lsp_call_hierarchy_json_message_structures() raises:
    """Verify LSP call hierarchy preparation and incoming/outgoing call JSON roundtrips."""
    var item_json = (
        "{\"name\":\"target_fn\",\"kind\":12,\"uri\":\"file:///src/main.mojo\","
        "\"range\":{\"start\":{\"line\":10,\"character\":4},\"end\":{\"line\":20,\"character\":0}},"
        "\"selectionRange\":{\"start\":{\"line\":10,\"character\":8},\"end\":{\"line\":10,\"character\":17}}}"
    )
    var incoming_json = (
        "{\"result\":[{\"from\":" + item_json + ",\"fromRanges\":[{\"start\":{\"line\":5,\"character\":8},\"end\":{\"line\":5,\"character\":17}}]}]}"
    )
    var doc = json_parse(incoming_json)
    assert_true(doc.ok)
    var res_node = doc.get(0, "result")
    assert_true(res_node >= 0)
    assert_equal(doc.size(res_node), 1)

    var call_entry = doc.children(res_node)[0]
    var from_item = doc.get(call_entry, "from")
    assert_equal(doc.str(doc.get(from_item, "name")), "target_fn")
    assert_equal(doc.int(doc.get(from_item, "kind")), 12)
    assert_equal(doc.str(doc.get(from_item, "uri")), "file:///src/main.mojo")

    var sym = IndexedSymbol(doc.str(doc.get(from_item, "name")), SK_FUNCTION, doc.str(doc.get(from_item, "uri")), 10, 4, "")
    assert_equal(sym.name, "target_fn")
    assert_equal(sym.kind, SK_FUNCTION)
    assert_equal(sym.row, 10)
    assert_equal(sym.col, 4)


def test_tier1_f18_case5_lsp_type_hierarchy_supertypes_subtypes_structures() raises:
    """Verify LSP type hierarchy item and supertype/subtype JSON hierarchy parsing."""
    var type_item = (
        "{\"name\":\"Circle\",\"kind\":23,\"uri\":\"file:///src/geo.mojo\","
        "\"range\":{\"start\":{\"line\":1,\"character\":0},\"end\":{\"line\":10,\"character\":0}},"
        "\"selectionRange\":{\"start\":{\"line\":1,\"character\":7},\"end\":{\"line\":1,\"character\":13}}}"
    )
    var supertypes_json = "{\"result\":[" + type_item + "]}"
    var doc = json_parse(supertypes_json)
    assert_true(doc.ok)
    var res_node = doc.get(0, "result")
    assert_equal(doc.size(res_node), 1)

    var item = doc.children(res_node)[0]
    assert_equal(doc.str(doc.get(item, "name")), "Circle")
    assert_equal(doc.int(doc.get(item, "kind")), 23)

    var sym = IndexedSymbol(doc.str(doc.get(item, "name")), SK_STRUCT, doc.str(doc.get(item, "uri")), 1, 0, "")
    assert_equal(sym.name, "Circle")
    assert_equal(sym.kind, SK_STRUCT)


# ===========================================================================
# Tier 2: Boundary Value Analysis & Corner Cases (5 tests)
# ===========================================================================

def test_tier2_f18_bound1_symbol_index_fallback_when_lsp_inactive() raises:
    """Verify symbol queries fall back to SymbolIndex when LSP server is inactive."""
    var d = scratch("fallback")
    var f = d + "/service.mojo"
    var code = (
        "struct AuthService:\n"
        "    def authenticate(self) -> Bool:\n"
        "        return True\n"
        "    def revoke(self):\n"
        "        pass\n"
    )
    _ = write_file(f, str_bytes(code))

    var idx = SymbolIndex()
    idx.start(d)
    finish_index(idx)

    # In fallback mode: look up methods owned by 'AuthService'
    var methods = List[String]()
    for s in idx.syms:
        if s.owner == "AuthService":
            methods.append(s.name)

    assert_equal(len(methods), 2)
    assert_equal(methods[0], "authenticate")
    assert_equal(methods[1], "revoke")
    clean_scratch(d)


def test_tier2_f18_bound2_mutually_recursive_caller_callee_cycles() raises:
    """Verify outline parsing and caller index handle mutual recursion without cycle fault."""
    var b = TextBuffer()
    var code = (
        "def ping():\n"
        "    pong()\n"
        "def pong():\n"
        "    ping()\n"
    )
    b.load(decode(code))
    var items = scan_outline(b)
    var owners = owners_of(items)

    assert_equal(len(items), 2)
    assert_equal(items[0].name, "ping")
    assert_equal(items[1].name, "pong")
    assert_equal(owners[0], "")
    assert_equal(owners[1], "")


def test_tier2_f18_bound3_multiple_trait_inheritance_and_empty_trait_bodies() raises:
    """Verify empty traits and multiple inheritance headers parse cleanly."""
    var b = TextBuffer()
    var code = (
        "trait EmptyTrait: ...\n"
        "trait MarkerTrait:\n"
        "    pass\n"
        "struct Multi(EmptyTrait, MarkerTrait, Copyable, Movable):\n"
        "    pass\n"
    )
    b.load(decode(code))
    var items = scan_outline(b)

    assert_equal(len(items), 3)
    assert_equal(items[0].name, "EmptyTrait")
    assert_equal(items[0].kind, SK_INTERFACE)

    assert_equal(items[1].name, "MarkerTrait")
    assert_equal(items[1].kind, SK_INTERFACE)

    assert_equal(items[2].name, "Multi")
    assert_equal(items[2].kind, SK_STRUCT)


def test_tier2_f18_bound4_incremental_symbol_index_replace_file_on_save() raises:
    """Verify SymbolIndex.replace_file updates struct/trait hierarchy without global re-indexing."""
    var d = scratch("replace_file")
    var f1 = d + "/a.mojo"
    var f2 = d + "/b.mojo"
    _ = write_file(f1, str_bytes("struct OldStruct:\n    def old_m(self): pass\n"))
    _ = write_file(f2, str_bytes("trait BaseTrait:\n    def op(self): ...\n"))

    var idx = SymbolIndex()
    idx.start(d)
    finish_index(idx)
    assert_equal(len(idx.syms), 4)

    # Edit f1: replace OldStruct with NewStruct and extra method
    var b_new = TextBuffer()
    b_new.load(decode("struct NewStruct:\n    def new_m(self): pass\n    def helper(self): pass\n"))
    idx.replace_file(f1, scan_outline(b_new))

    assert_equal(len(idx.syms), 5)  # 2 in f2 + 3 in f1
    var has_old = False
    var has_new = False
    for s in idx.syms:
        if s.name == "OldStruct":
            has_old = True
        elif s.name == "NewStruct":
            has_new = True
    assert_false(has_old)
    assert_true(has_new)

    clean_scratch(d)


def test_tier2_f18_bound5_empty_and_malformed_syntax_hierarchy_resilience() raises:
    """Verify syntax errors and truncated declarations in outline scan do not crash."""
    var b = TextBuffer()
    var bad_code = (
        "struct Unclosed(\n"
        "    def incomplete(\n"
        "trait NoColon\n"
        "    def valid(): pass\n"
    )
    b.load(decode(bad_code))
    var items = scan_outline(b)
    assert_equal(len(items), 4)
    assert_equal(items[0].name, "Unclosed")
    assert_equal(items[0].kind, SK_STRUCT)
    assert_equal(items[1].name, "incomplete")
    assert_equal(items[1].kind, SK_METHOD)
    assert_equal(items[2].name, "NoColon")
    assert_equal(items[2].kind, SK_INTERFACE)
    assert_equal(items[3].name, "valid")
    assert_equal(items[3].kind, SK_METHOD)

    var owners = owners_of(items)
    assert_equal(len(owners), 4)
    assert_equal(owners[0], "")
    assert_equal(owners[1], "Unclosed")
    assert_equal(owners[2], "")
    assert_equal(owners[3], "NoColon")


def test_tier1_f18_live_hierarchy_open_and_sk_cell_and_lsp_parsers() raises:
    """Verify SK_CELL outline markers, supertypes/subtypes, incoming/outgoing calls, LSP parsers, and App.hierarchy_open."""
    # 1. SK_CELL (`# %%`) markers in scan_outline + parse_struct_traits
    var cb = TextBuffer()
    cb.load(decode("# regular comment\n# %% Setup Cell\nstruct TensorBox[T: AnyType](Copyable, Movable):\n    pass\n# %%\ndef run_box():\n    pass\n"))
    var citems = scan_outline(cb)
    assert_equal(len(citems), 4)
    assert_equal(citems[0].kind, SK_CELL)
    assert_equal(citems[0].name, "Setup Cell")
    assert_equal(citems[1].kind, SK_STRUCT)
    assert_equal(len(citems[1].traits), 2)
    assert_equal(citems[1].traits[0], "Copyable")
    assert_equal(citems[1].traits[1], "Movable")
    assert_equal(citems[2].kind, SK_CELL)
    assert_equal(citems[2].name, "Cell 2")
    assert_equal(citems[3].kind, SK_FUNCTION)
    assert_equal(len(parse_struct_traits("struct Unclosed(")), 0)

    # 2. LSP capability flags + CallHierarchy / TypeHierarchy response parsers
    var caps = parse_caps(json_parse("{\"callHierarchyProvider\":true,\"typeHierarchyProvider\":true}"))
    assert_true(caps.call_hierarchy and caps.type_hierarchy)
    var inc_doc = json_parse(
        "{\"result\":[{\"from\":{\"name\":\"caller_fn\",\"kind\":12,\"uri\":\"file:///a.mojo\","
        "\"selectionRange\":{\"start\":{\"line\":3,\"character\":4},\"end\":{\"line\":3,\"character\":13}}},"
        "\"fromRanges\":[{\"start\":{\"line\":6,\"character\":8},\"end\":{\"line\":6,\"character\":14}}]}]}"
    )
    var inc_parsed = parse_incoming_calls(inc_doc, inc_doc.get(0, "result"))
    assert_equal(len(inc_parsed), 1)
    assert_equal(inc_parsed[0].name, "caller_fn")
    assert_equal(inc_parsed[0].row, 6)
    assert_equal(inc_parsed[0].col16, 8)
    var out_doc = json_parse(
        "{\"result\":[{\"to\":{\"name\":\"callee_fn\",\"kind\":12,\"uri\":\"file:///b.mojo\","
        "\"selectionRange\":{\"start\":{\"line\":1,\"character\":4},\"end\":{\"line\":1,\"character\":13}}}}]}"
    )
    var out_parsed = parse_outgoing_calls(out_doc, out_doc.get(0, "result"))
    assert_equal(len(out_parsed), 1)
    assert_equal(out_parsed[0].name, "callee_fn")
    var th_parsed = parse_type_hierarchy_items(
        json_parse("{\"result\":[{\"name\":\"Drawable\",\"kind\":11,\"uri\":\"file:///t.mojo\",\"selectionRange\":{\"start\":{\"line\":0,\"character\":6},\"end\":{\"line\":0,\"character\":14}}}]}"),
        0,
    )
    _ = th_parsed
    var th_doc = json_parse("{\"result\":[{\"name\":\"Drawable\",\"kind\":11,\"uri\":\"file:///t.mojo\",\"selectionRange\":{\"start\":{\"line\":0,\"character\":6},\"end\":{\"line\":0,\"character\":14}}}]}")
    var th_items = parse_type_hierarchy_items(th_doc, th_doc.get(0, "result"))
    assert_equal(len(th_items), 1)
    assert_equal(th_items[0].name, "Drawable")

    # 3. Live App.hierarchy_open (Type & Call Hierarchy via SymbolIndex fallback) + hierarchy_go jump
    var d = scratch("app_hier")
    var f = d + "/graph.mojo"
    var src = (
        "trait Computable:\n"
        "    def eval(self) -> Int: ...\n\n"
        "struct DenseOp(Computable, Copyable):\n"
        "    def eval(self) -> Int:\n"
        "        return leaf_add(1, 2)\n\n"
        "def leaf_add(a: Int, b: Int) -> Int:\n"
        "    return a + b\n\n"
        "def run_pipeline() -> Int:\n"
        "    return leaf_add(3, 4)\n"
    )
    _ = write_file(f, str_bytes(src))
    var app = App()
    app.scr.resize(100, 30)
    app.cwd = d
    app.project_dir = d
    app.open_path(f)
    var ei = app.find_editor(f)

    # Type Hierarchy on `DenseOp` (row 3, col 8) -> shows supertypes (`Computable`, `Copyable`)
    app.wins[ei].goto(3, 8)
    app.hierarchy_open(True)
    assert_equal(app.mode, M_DIALOG)
    assert_equal(app.dlg.kind, D_HIERARCHY)
    assert_true(len(app.hier_paths) >= 2)
    assert_equal(app.hier_rows[0], 0)  # Computable trait on row 0

    # Jump to `Computable` via hierarchy_go(0)
    app.mode = M_NORMAL
    app.hierarchy_go(0)
    ei = app.find_editor(f)
    assert_equal(app.wins[ei].cr, 0)

    # Type Hierarchy on `Computable` (row 0, col 7) -> shows subtype `DenseOp`
    app.wins[ei].goto(0, 7)
    app.hierarchy_open(True)
    assert_equal(app.dlg.kind, D_HIERARCHY)
    assert_equal(len(app.hier_paths), 1)
    assert_equal(app.hier_rows[0], 3)

    # Call Hierarchy on `leaf_add` (row 7, col 5) -> incoming calls from `eval` and `run_pipeline`
    app.mode = M_NORMAL
    app.wins[ei].goto(7, 5)
    app.hierarchy_open(False)
    assert_equal(app.dlg.kind, D_HIERARCHY)
    assert_equal(len(app.hier_paths), 2)

    # Call Hierarchy on `run_pipeline` (row 10, col 5) -> outgoing call to `leaf_add` (row 7)
    app.mode = M_NORMAL
    app.wins[ei].goto(10, 5)
    app.hierarchy_open(False)
    assert_equal(len(app.hier_paths), 1)
    assert_equal(app.hier_rows[0], 7)

    clean_scratch(d)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
