"""E2E Test Suite for v2.5.0 Milestone 3:
Structural Refactorings (`Extract Variable`, `Extract Function`) &
One-Click Mojo 1.2 Migration Assistant (`CM_MIGRATE_MOJO12`, `CM_MIGRATE_MOJO12_PROJECT`).
"""
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from app import App
from appstate import M_DIALOG, M_NORMAL
from commands import (
    CM_SAVE, CM_UNDO, CM_REDO,
    CM_MIGRATE_MOJO12, CM_MIGRATE_MOJO12_PROJECT,
    CM_EXTRACT_VAR, CM_EXTRACT_FUNC,
)
from dialog import D_RENAME_APPLY, D_EXTRACT_VAR, D_EXTRACT_FUNC
from signals import own_pid
from util import (
    env_or, run_system, write_file, bytes_to_str, str_bytes, decode, to_str, shell_quote, popen_read,
)
from std.ffi import external_call


def _scratch(tag: String) -> String:
    var d = env_or("TMPDIR", "/tmp") + "/tm-v25-m3-" + tag + "-" + String(own_pid())
    _ = run_system("rm -rf '" + d + "' && mkdir -p '" + d + "'")
    return d


def _capture_shell(cmd: String) -> String:
    var fp = popen_read(cmd)
    if fp == 0:
        return ""
    var out = List[UInt8]()
    var chunk = List[UInt8](length=4096, fill=0)
    while True:
        var n = external_call["read", Int](external_call["fileno", Int32](fp), chunk.unsafe_ptr(), Int(4096))
        if n <= 0:
            break
        for k in range(n):
            out.append(chunk[k])
    _ = external_call["pclose", Int32](fp)
    return bytes_to_str(out)


def test_v25_m3_01_mojo12_migration_all_rules_and_comment_string_safety() raises:
    """Migrate all legacy Mojo constructs, preserve comments/strings, compile & run on Mojo 1.2, and 1-step Undo."""
    var dir = _scratch("migrate_file")
    var fpath = dir + "/legacy_mod.mojo"
    var legacy_src = (
        "\"\"\"Docstring must stay untouched: fn old(inout x: Int): let y = 1 alias Z = 2\"\"\"\n"
        "from collections import List\n"
        "from testing import assert_equal\n"
        "\n"
        "alias FACTOR = 4\n"
        "\n"
        "@value\n"
        "struct Pair:\n"
        "    var a: Int\n"
        "    var b: Int\n"
        "\n"
        "struct Counter(Movable):\n"
        "    var n: Int\n"
        "    var tag: String\n"
        "\n"
        "    fn __init__(inout self, borrowed start: Int, owned label: String):\n"
        "        self.n = start\n"
        "        self.tag = label^\n"
        "\n"
        "fn add_scaled(inout total: Int, borrowed x: Int):\n"
        "    # Comment untouched: fn let alias inout owned @parameter @value\n"
        "    let msg = \"fn let alias inout owned @value from collections import List\"\n"
        "    _ = msg\n"
        "    @parameter\n"
        "    for k in range(2):\n"
        "        total += x * FACTOR + k\n"
        "    @parameter if True:\n"
        "        total += 1\n"
        "\n"
        "fn main() raises:\n"
        "    let p = Pair(3, 5)\n"
        "    var c = Counter(p.a + p.b, String(\"ok\"))\n"
        "    let items = List[Int]()\n"
        "    _ = len(items)\n"
        "    add_scaled(c.n, 2)\n"
        "    assert_equal(c.n, 26)\n"
        "    print(\"MIGRATED_OK\", c.n, c.tag)\n"
    )
    _ = write_file(fpath, str_bytes(legacy_src))

    var app = App()
    app.scr.resize(100, 32)
    app.cwd = dir
    app.open_path(fpath)
    var ei = app.find_editor(fpath)
    assert_true(ei >= 0)

    # Verify quick-fix offers whole-file migration before migrating
    var qfs = app.local_code_actions(ei)
    var saw_whole_mig = False
    for q in qfs:
        if q.title.find("Migrate entire file to Mojo 1.2") >= 0:
            saw_whole_mig = True
    assert_true(saw_whole_mig, "Expected whole-file Mojo 1.2 migration quick fix")

    # Execute 1-click file migration
    app.exec(CM_MIGRATE_MOJO12)
    ei = app.find_editor(fpath)
    var migrated = bytes_to_str(app.wins[ei].buf.to_bytes())

    # Check migrated constructs
    assert_true(migrated.find("from std.collections import List") >= 0, migrated)
    assert_true(migrated.find("from std.testing import assert_equal") >= 0, migrated)
    assert_true(migrated.find("comptime FACTOR = 4") >= 0, migrated)
    assert_true(migrated.find("@fieldwise_init\nstruct Pair(Copyable, Movable):") >= 0, migrated)
    assert_true(migrated.find("def __init__(out self, start: Int, var label: String):") >= 0, migrated)
    assert_true(migrated.find("def add_scaled(mut total: Int, x: Int):") >= 0, migrated)
    assert_true(migrated.find("    comptime for k in range(2):") >= 0, migrated)
    assert_true(migrated.find("    comptime if True:") >= 0, migrated)
    assert_true(migrated.find("    var p = Pair(3, 5)") >= 0, migrated)

    # Verify docstring, string literal, and comment were 100% preserved!
    assert_true(migrated.find("Docstring must stay untouched: fn old(inout x: Int): let y = 1 alias Z = 2") >= 0, migrated)
    assert_true(migrated.find("# Comment untouched: fn let alias inout owned @parameter @value") >= 0, migrated)
    assert_true(migrated.find("\"fn let alias inout owned @value from collections import List\"") >= 0, migrated)

    # 1-step Undo must restore byte-identical legacy source; Redo brings back migrated source!
    app.exec(CM_UNDO)
    assert_equal(bytes_to_str(app.wins[ei].buf.to_bytes()), legacy_src)
    app.exec(CM_REDO)
    assert_equal(bytes_to_str(app.wins[ei].buf.to_bytes()), migrated)

    # Save and actually compile + execute with Mojo 1.2!
    app.exec(CM_SAVE)
    var run_out = _capture_shell("mojo run " + shell_quote(fpath) + " 2>&1")
    assert_true(run_out.find("MIGRATED_OK 26 ok") >= 0, "Migrated Mojo code failed to run:\n" + run_out + "\n---\n" + migrated)

    _ = run_system("rm -rf '" + dir + "'")


def test_v25_m3_02_workspace_migration_preview_and_apply() raises:
    """`CM_MIGRATE_MOJO12_PROJECT` previews edits across multiple `.mojo` files and applies cleanly."""
    var dir = _scratch("migrate_proj")
    var f1 = dir + "/a.mojo"
    var f2 = dir + "/b.mojo"
    _ = write_file(f1, str_bytes("alias A = 1\nfn fa() -> Int:\n    let x = A\n    return x\n"))
    _ = write_file(f2, str_bytes("from math import sqrt\nfn fb(inout v: Float64):\n    v = sqrt(v)\n"))

    var app = App()
    app.scr.resize(100, 32)
    app.cwd = dir
    app.open_path(f1)
    app.exec(CM_MIGRATE_MOJO12_PROJECT)

    assert_equal(app.mode, M_DIALOG)
    assert_equal(app.dlg.kind, D_RENAME_APPLY)
    app.dialog_button(0)
    assert_equal(app.mode, M_NORMAL)

    var e1 = app.find_editor(f1)
    var e2 = app.find_editor(f2)
    assert_true(e1 >= 0 and e2 >= 0)
    var s1 = bytes_to_str(app.wins[e1].buf.to_bytes())
    var s2 = bytes_to_str(app.wins[e2].buf.to_bytes())
    assert_true(s1.find("comptime A = 1") >= 0 and s1.find("def fa() -> Int:") >= 0 and s1.find("var x = A") >= 0, s1)
    assert_true(s2.find("from std.math import sqrt") >= 0 and s2.find("def fb(mut v: Float64):") >= 0, s2)

    _ = run_system("rm -rf '" + dir + "'")


def test_v25_m3_03_extract_variable_and_extract_function_with_undo_and_compile() raises:
    """`CM_EXTRACT_VAR` and `CM_EXTRACT_FUNC` infer types/params/return, support 1-step Undo, and compile on Mojo 1.2."""
    var dir = _scratch("extract")
    var fpath = dir + "/geom.mojo"
    var orig = (
        "def compute_score(x: Int, y: Int) -> Int:\n"
        "    var base = (x * x + y * y) + 5\n"
        "    var bonus = base * 2\n"
        "    var adjusted = bonus + x\n"
        "    return adjusted + 1\n"
        "\n"
        "def main():\n"
        "    print(\"SCORE\", compute_score(3, 4))\n"
    )
    _ = write_file(fpath, str_bytes(orig))

    var app = App()
    app.scr.resize(100, 32)
    app.cwd = dir
    app.open_path(fpath)
    var ei = app.find_editor(fpath)
    assert_true(ei >= 0)

    # 1. Select `(x * x + y * y)` on row 1 and invoke CM_EXTRACT_VAR -> `norm_sq`
    var row1 = to_str(app.wins[ei].buf.line(1))
    var c1 = row1.find("(x * x + y * y)")
    var c2 = c1 + 15
    app.wins[ei].ar = 1
    app.wins[ei].ac = c1
    app.wins[ei].cr = 1
    app.wins[ei].cc = c2
    app.wins[ei].sel = True

    app.exec(CM_EXTRACT_VAR)
    assert_equal(app.mode, M_DIALOG)
    assert_equal(app.dlg.kind, D_EXTRACT_VAR)
    app.dlg.fields[0].text = decode("norm_sq")
    app.dialog_button(0)
    assert_equal(app.mode, M_NORMAL)

    var after_var = bytes_to_str(app.wins[ei].buf.to_bytes())
    assert_true(after_var.find("    var norm_sq = (x * x + y * y)\n    var base = norm_sq + 5\n") >= 0, after_var)

    # 1-step Undo restores exact `orig`; Redo restores `after_var`
    app.exec(CM_UNDO)
    assert_equal(bytes_to_str(app.wins[ei].buf.to_bytes()), orig)
    app.exec(CM_REDO)
    assert_equal(bytes_to_str(app.wins[ei].buf.to_bytes()), after_var)

    # 2. Select rows 3..4 (`var bonus = base * 2` and `var adjusted = bonus + x`) -> CM_EXTRACT_FUNC `calc_adjusted`
    app.wins[ei].ar = 3
    app.wins[ei].ac = 0
    app.wins[ei].cr = 4
    app.wins[ei].cc = app.wins[ei].buf.llen(4)
    app.wins[ei].sel = True

    app.exec(CM_EXTRACT_FUNC)
    assert_equal(app.mode, M_DIALOG)
    assert_equal(app.dlg.kind, D_EXTRACT_FUNC)
    app.dlg.fields[0].text = decode("calc_adjusted")
    app.dialog_button(0)
    assert_equal(app.mode, M_NORMAL)

    ei = app.find_editor(fpath)
    var after_fn = bytes_to_str(app.wins[ei].buf.to_bytes())
    assert_true(after_fn.find("def calc_adjusted(x: Int, base: Int) -> Int:") >= 0, after_fn)
    assert_true(after_fn.find("    return adjusted") >= 0, after_fn)
    assert_true(after_fn.find("    var adjusted = calc_adjusted(x, base)") >= 0, after_fn)

    # 1-step Undo restores `after_var`; Redo restores `after_fn`
    app.exec(CM_UNDO)
    assert_equal(bytes_to_str(app.wins[ei].buf.to_bytes()), after_var)
    app.exec(CM_REDO)
    assert_equal(bytes_to_str(app.wins[ei].buf.to_bytes()), after_fn)

    # Save and run with Mojo 1.2 compiler: (9+16)=25 -> base=30 -> bonus=60 -> adjusted=63 -> +1 = 64!
    app.exec(CM_SAVE)
    var out = _capture_shell("mojo run " + shell_quote(fpath) + " 2>&1")
    assert_true(out.find("SCORE 64") >= 0, "Extracted Mojo program failed:\n" + out + "\n---\n" + after_fn)

    _ = run_system("rm -rf '" + dir + "'")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
