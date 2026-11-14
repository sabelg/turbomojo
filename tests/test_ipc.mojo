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

    # 4. debug_inspect reports live debugger/CPU state cleanly
    var w4 = JsonWriter()
    w4.begin_obj()
    w4.kv_str("id", "t4")
    w4.kv_str("op", "debug_inspect")
    w4.end_obj()
    _ = write_bytes_atomic(tmp + "/ipc/req-t4.json", str_bytes(w4.text()))
    assert_true(app.ipc_tick())
    var r4 = json_parse(bytes_to_str(read_file(tmp + "/ipc/resp-t4.json")))
    assert_true(r4.bool(r4.get(0, "ok"), False))
    assert_false(r4.bool(r4.get(0, "active"), True))
    assert_equal(r4.str(r4.get(0, "state"), ""), "inactive")

    # 5. report_test_results updates TestFile counts and syncs editor gutter test lenses
    var test_path = tmp + "/test_sample.mojo"
    _ = write_file(
        test_path,
        str_bytes(
            "from std.testing import assert_equal, TestSuite\n\ndef test_ok() raises:\n    assert_equal(1, 1)\n\ndef test_bad() raises:\n    assert_equal(1, 2)\n\ndef main() raises:\n    TestSuite.discover_tests[__functions_in_module()]().run()\n"
        ),
    )
    app.open_path(test_path)
    var tei = app.find_editor(test_path)
    assert_true(tei >= 0)
    var w5 = JsonWriter()
    w5.begin_obj()
    w5.kv_str("id", "t5")
    w5.kv_str("op", "report_test_results")
    w5.kv_str("path", test_path)
    w5.kv_int("exit_code", 1)
    w5.kv_str(
        "output",
        "Running 2 tests for " + test_path + "\n    PASS [ 0.001 ] test_ok\n    FAIL [ 0.002 ] test_bad\n      At " + test_path + ":7:17: AssertionError: 1 != 2\nSummary [ 0.003 ] 2 tests run: 1 passed , 1 failed , 0 skipped\n",
    )
    w5.end_obj()
    _ = write_bytes_atomic(tmp + "/ipc/req-t5.json", str_bytes(w5.text()))
    assert_true(app.ipc_tick())
    var r5 = json_parse(bytes_to_str(read_file(tmp + "/ipc/resp-t5.json")))
    assert_true(r5.bool(r5.get(0, "ok"), False))
    assert_equal(r5.int(r5.get(0, "passed")), 1)
    assert_equal(r5.int(r5.get(0, "failed")), 1)
    assert_equal(len(app.wins[tei].test_lens_rows), 2)

    _ = run_system("rm -rf " + shell_quote(tmp))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
