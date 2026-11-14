"""Tests for two-way file-queue IPC (`src/ipc.mojo`, `src/app_ipc.mojo`) and `--reuse`."""
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from app import *
from ipc import parse_file_loc, ipc_live_dir, ipc_send_request
from json import json_parse, JsonWriter
from signals import own_pid
from swap import write_bytes_atomic


def test_parse_file_loc() raises:
    var a = parse_file_loc("src/main.mojo:42:7")
    assert_equal(a.path, "src/main.mojo")
    assert_equal(a.line, 42)
    assert_equal(a.col, 7)

    var b = parse_file_loc("src/main.mojo:19")
    assert_equal(b.path, "src/main.mojo")
    assert_equal(b.line, 19)
    assert_equal(b.col, 0)

    var c = parse_file_loc("src/main.mojo")
    assert_equal(c.path, "src/main.mojo")
    assert_equal(c.line, 0)
    assert_equal(c.col, 0)


def test_ipc_roundtrip_and_edits_undo() raises:
    var tmp = "/tmp/tmide-test-ipc-" + String(own_pid())
    _ = run_system("rm -rf " + shell_quote(tmp) + " && mkdir -p " + shell_quote(tmp))
    var sample = tmp + "/hello.mojo"
    _ = write_file(sample, str_bytes("def main():\n    var x = 1\n    print(x)\n"))

    var app = App()
    app.cwd = tmp
    app.ide_state_path = tmp + "/ide-state.json"
    app.ipc_enable(tmp + "/ipc")
    app.export_ide_state()

    assert_equal(ipc_live_dir(app.ide_state_path), tmp + "/ipc")

    # 1. open_location jumps to line/col
    var w1 = JsonWriter()
    w1.begin_obj()
    w1.kv_str("id", "t1")
    w1.kv_str("op", "open_location")
    w1.kv_str("path", sample)
    w1.kv_int("line", 2)
    w1.kv_int("col", 13)
    w1.end_obj()
    _ = write_bytes_atomic(tmp + "/ipc/req-t1.json", str_bytes(w1.text()))
    assert_true(app.ipc_tick())
    var r1 = json_parse(bytes_to_str(read_file(tmp + "/ipc/resp-t1.json")))
    assert_true(r1.ok and r1.bool(r1.get(0, "ok"), False))
    var ei = app.find_editor(sample)
    assert_true(ei >= 0)
    assert_equal(app.wins[ei].cr, 1)
    assert_equal(app.wins[ei].cc, 12)

    # 2. get_buffer sees unsaved live edits
    app.wins[ei].type_char(50, True)  # insert '2' before '1' -> '21'
    var w2 = JsonWriter()
    w2.begin_obj()
    w2.kv_str("id", "t2")
    w2.kv_str("op", "get_buffer")
    w2.kv_str("path", sample)
    w2.end_obj()
    _ = write_bytes_atomic(tmp + "/ipc/req-t2.json", str_bytes(w2.text()))
    assert_true(app.ipc_tick())
    var r2 = json_parse(bytes_to_str(read_file(tmp + "/ipc/resp-t2.json")))
    assert_true(r2.bool(r2.get(0, "live"), False))
    assert_true(r2.bool(r2.get(0, "modified"), False))
    assert_true(r2.str(r2.get(0, "text"), "").find("21") >= 0)

    # 3. apply_edits modifies live buffer as a single undoable step
    var w3 = JsonWriter()
    w3.begin_obj()
    w3.kv_str("id", "t3")
    w3.kv_str("op", "apply_edits")
    w3.kv_str("path", sample)
    w3.key("edits")
    w3.begin_arr()
    w3.begin_obj()
    w3.kv_int("start_line", 2)
    w3.kv_int("end_line", 2)
    w3.kv_str("text", "    var x = 99")
    w3.end_obj()
    w3.end_arr()
    w3.end_obj()
    _ = write_bytes_atomic(tmp + "/ipc/req-t3.json", str_bytes(w3.text()))
    assert_true(app.ipc_tick())
    var r3 = json_parse(bytes_to_str(read_file(tmp + "/ipc/resp-t3.json")))
    assert_true(r3.bool(r3.get(0, "ok"), False))
    assert_equal(to_str(app.wins[ei].buf.line(1)), "    var x = 99")

    # Single undo reverts the entire apply_edits step back to "21"
    app.wins[ei].undo()
    assert_true(to_str(app.wins[ei].buf.line(1)).find("21") >= 0)

    _ = run_system("rm -rf " + shell_quote(tmp))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
