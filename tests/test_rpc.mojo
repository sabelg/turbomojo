"""Tests for the child-process transport (src/proc.mojo) and JSON-RPC (src/rpc.mojo).

The integration tests talk to tests/helpers/fake_rpc_server.py (needs python3)."""
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from std.collections import List
from std.time import perf_counter_ns
from rpc import *
from proc import Proc
from json import JsonWriter, json_parse, J_STR, J_OBJ
from term import wait_readable
from signals import own_pid
from util import str_bytes, bytes_to_str, env_or, run_system, run_capture

comptime SERVER = "python3 tests/helpers/fake_rpc_server.py"
comptime MS = 1000000


def now() -> Int:
    return Int(perf_counter_ns())


def collect(mut c: RpcConn, want: Int, timeout_ms: Int) -> List[RpcMessage]:
    """Poll until `want` messages have arrived or the timeout passes."""
    var out = List[RpcMessage]()
    var deadline = now() + timeout_ms * MS
    while len(out) < want and now() < deadline:
        var fds = List[Int]()
        fds.append(c.fd())
        _ = wait_readable(fds, 20)
        for m in c.poll():
            out.append(m.copy())
        if c.ended() and c.framer.pending_bytes() == 0:
            break
    return out^


def started() raises -> RpcConn:
    var c = RpcConn()
    assert_true(c.start(SERVER))
    return c^


# ------------------------------------------------------------------ framing
def test_frame_and_single_message() raises:
    var f = Framer()
    var body = List[UInt8]()
    assert_false(f.next(body))
    f.feed(frame("{\"a\":1}"))
    assert_true(f.next(body))
    assert_equal(bytes_to_str(body), "{\"a\":1}")
    assert_false(f.next(body))
    assert_equal(f.pending_bytes(), 0)
    assert_equal(bytes_to_str(frame("héllo")), "Content-Length: 6\r\n\r\nhéllo")   # bytes, not chars


def test_message_arriving_byte_by_byte() raises:
    var f = Framer()
    var body = List[UInt8]()
    var data = frame("{\"k\":\"value\"}")
    for i in range(len(data)):
        var one = List[UInt8]()
        one.append(data[i])
        f.feed(one)
        if i < len(data) - 1:
            assert_false(f.next(body), "complete too early at byte " + String(i))
    assert_true(f.next(body))
    assert_equal(bytes_to_str(body), "{\"k\":\"value\"}")


def test_several_messages_in_one_chunk_and_extra_headers() raises:
    var f = Framer()
    var data = frame("1")
    for b in str_bytes("content-length: 3\r\nContent-Type: application/vscode-jsonrpc; charset=utf-8\r\n\r\n222"):
        data.append(b)
    for b in frame(""):
        data.append(b)
    for b in frame("4444"):
        data.append(b)
    f.feed(data)
    var body = List[UInt8]()
    assert_true(f.next(body))
    assert_equal(bytes_to_str(body), "1")
    assert_true(f.next(body))
    assert_equal(bytes_to_str(body), "222")       # lower-case header name, extra header
    assert_true(f.next(body))
    assert_equal(len(body), 0)                    # empty body is legal framing
    assert_true(f.next(body))
    assert_equal(bytes_to_str(body), "4444")
    assert_false(f.next(body))


def test_stray_output_before_a_frame_is_skipped() raises:
    var f = Framer()
    var data = str_bytes("debug: starting up\n")
    for b in frame("{\"ok\":true}"):
        data.append(b)
    for b in str_bytes("X-Nothing: here\r\n\r\n"):
        data.append(b)                            # a header block with no length at all
    for b in frame("2"):
        data.append(b)
    f.feed(data)
    var body = List[UInt8]()
    assert_true(f.next(body))
    assert_equal(bytes_to_str(body), "{\"ok\":true}")
    assert_true(f.next(body))
    assert_equal(bytes_to_str(body), "2")
    assert_true(f.dropped > 0)


def test_framer_survives_many_messages() raises:
    var f = Framer()
    var body = List[UInt8]()
    for i in range(3000):
        f.feed(frame("{\"n\":" + String(i) + "}"))
        assert_true(f.next(body))
    assert_equal(bytes_to_str(body), "{\"n\":2999}")
    assert_true(len(f.buf) < 200000, "consumed data must be released")


# ----------------------------------------------------------- classification
def test_classify_without_a_process() raises:
    var c = RpcConn()
    var id1 = c.request("textDocument/hover", "{\"x\":1}")
    var id2 = c.request("shutdown", "")
    assert_equal(id1, 1)
    assert_equal(id2, 2)
    assert_true(c.is_pending(1))
    var data = frame("{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":null}")
    for b in frame("{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-32601,\"message\":\"nope\"}}"):
        data.append(b)
    for b in frame("{\"jsonrpc\":\"2.0\",\"method\":\"window/logMessage\",\"params\":{\"message\":\"hi\"}}"):
        data.append(b)
    for b in frame("{\"jsonrpc\":\"2.0\",\"id\":\"abc\",\"method\":\"workspace/configuration\",\"params\":{}}"):
        data.append(b)
    for b in frame("{\"jsonrpc\":\"2.0\",\"id\":77,\"result\":5}"):
        data.append(b)
    for b in frame("not json at all"):
        data.append(b)
    for b in frame("[1,2,3]"):
        data.append(b)
    var ms = c.feed(data)
    assert_equal(len(ms), 5)
    assert_equal(ms[0].kind, RPC_RESPONSE)
    assert_equal(ms[0].id, 2)
    assert_equal(ms[0].method, "shutdown")           # paired with our request
    assert_true(ms[0].doc.is_null(ms[0].result()))
    assert_equal(ms[1].kind, RPC_ERROR)
    assert_equal(ms[1].method, "textDocument/hover")
    assert_equal(ms[1].error_code(), -32601)
    assert_equal(ms[1].error_message(), "nope")
    assert_equal(ms[2].kind, RPC_NOTIFICATION)
    assert_equal(ms[2].method, "window/logMessage")
    assert_equal(ms[2].doc.str(ms[2].doc.path(ms[2].params(), "message")), "hi")
    assert_equal(ms[3].kind, RPC_REQUEST)
    assert_equal(ms[3].id_json, "\"abc\"")           # string ids are echoed verbatim
    assert_equal(ms[4].kind, RPC_RESPONSE)
    assert_equal(ms[4].method, "")                   # a reply to nothing we asked
    assert_false(c.is_pending(1))
    assert_false(c.is_pending(2))
    assert_equal(c.invalid, 2)


def test_request_text_is_valid_json_rpc() raises:
    var c = RpcConn()
    _ = c.request("m/with \"quotes\"", "{\"a\":[1,2]}")
    c.notify("note", "")
    c.respond("\"srv-1\"", "true")
    c.respond_error("9", -32603, "bad \"thing\"")
    # what was queued for the (not running) child: parse it back with our own framer
    var f = Framer()
    f.feed(c.proc.outbox)
    var body = List[UInt8]()
    assert_true(f.next(body))
    var d = json_parse(bytes_to_str(body))
    assert_true(d.ok)
    assert_equal(d.str(d.get(0, "jsonrpc")), "2.0")
    assert_equal(d.int(d.get(0, "id")), 1)
    assert_equal(d.str(d.get(0, "method")), "m/with \"quotes\"")
    assert_equal(d.int(d.path(0, "params/a/1")), 2)
    assert_true(f.next(body))
    d = json_parse(bytes_to_str(body))
    assert_false(d.has(0, "id"))
    assert_false(d.has(0, "params"))
    assert_true(f.next(body))
    assert_equal(bytes_to_str(body), "{\"jsonrpc\":\"2.0\",\"id\":\"srv-1\",\"result\":true}")
    assert_true(f.next(body))
    d = json_parse(bytes_to_str(body))
    assert_equal(d.int(d.path(0, "error/code")), -32603)
    assert_equal(d.str(d.path(0, "error/message")), "bad \"thing\"")


def test_timeouts_and_cancel() raises:
    var c = RpcConn()
    var a = c.request("slow", "", 1000 * MS)
    var b = c.request("fast", "", 5000 * MS)
    var none = c.timed_out(5500 * MS, 5000 * MS)
    assert_equal(len(none), 0)
    var late = c.timed_out(6000 * MS, 5000 * MS)
    assert_equal(len(late), 1)
    assert_equal(late[0], a)
    assert_false(c.is_pending(a))
    assert_true(c.is_pending(b))
    assert_true(c.cancel(b))
    assert_false(c.cancel(b))
    assert_false(c.is_pending(b))


# ---------------------------------------------------------- with a process
def test_request_and_response() raises:
    var c = started()
    var id = c.request("add", "{\"a\":2,\"b\":40}")
    var ms = collect(c, 1, 5000)
    assert_equal(len(ms), 1)
    assert_equal(ms[0].kind, RPC_RESPONSE)
    assert_equal(ms[0].id, id)
    assert_equal(ms[0].method, "add")
    assert_equal(ms[0].doc.int(ms[0].result()), 42)
    assert_true(c.proc.pid > 0)
    assert_true(c.alive())
    _ = c.stop()
    assert_false(c.alive())


def test_echo_keeps_unicode_and_structure() raises:
    var c = started()
    _ = c.request("echo", "{\"text\":\"日本語 🔥 \\\"q\\\"\\n\",\"list\":[1,{\"k\":null}]}")
    var ms = collect(c, 1, 5000)
    assert_equal(len(ms), 1)
    var r = ms[0].result()
    assert_equal(ms[0].doc.str(ms[0].doc.get(r, "text")), "日本語 🔥 \"q\"\n")
    assert_true(ms[0].doc.is_null(ms[0].doc.path(r, "list/1/k")))
    _ = c.stop()


def test_error_response() raises:
    var c = started()
    _ = c.request("fail", "")
    _ = c.request("no/such/method", "")
    var ms = collect(c, 2, 5000)
    assert_equal(len(ms), 2)
    assert_equal(ms[0].kind, RPC_ERROR)
    assert_equal(ms[0].error_message(), "boom")
    assert_equal(ms[0].error_code(), -32000)
    assert_equal(ms[1].kind, RPC_ERROR)
    assert_equal(ms[1].method, "no/such/method")
    assert_equal(ms[1].error_code(), -32601)
    _ = c.stop()


def test_notification_before_reply_and_replies_in_order() raises:
    var c = started()
    var a = c.request("notify_then_reply", "")
    var b = c.request("add", "{\"a\":1,\"b\":1}")
    var ms = collect(c, 3, 5000)
    assert_equal(len(ms), 3)
    assert_equal(ms[0].kind, RPC_NOTIFICATION)
    assert_equal(ms[0].method, "log")
    assert_equal(ms[1].id, a)
    assert_equal(ms[1].doc.str(ms[1].result()), "done")
    assert_equal(ms[2].id, b)
    _ = c.stop()


def test_reply_split_into_small_pieces() raises:
    var c = started()
    _ = c.request("split", "")
    var ms = collect(c, 1, 5000)
    assert_equal(len(ms), 1)
    assert_equal(ms[0].doc.str(ms[0].result()), "in pieces")
    _ = c.stop()


def test_burst_of_messages_in_one_write() raises:
    var c = started()
    _ = c.request("burst", "")
    var ms = collect(c, 4, 5000)
    assert_equal(len(ms), 4)
    for n in range(3):
        assert_equal(ms[n].kind, RPC_NOTIFICATION)
        assert_equal(ms[n].doc.int(ms[n].doc.path(ms[n].params(), "n")), n)
    assert_equal(ms[3].doc.str(ms[3].result()), "after burst")
    _ = c.stop()


def test_large_reply() raises:
    var c = started()
    _ = c.request("big", "{\"n\":300000}")
    var ms = collect(c, 1, 10000)
    assert_equal(len(ms), 1)
    assert_equal(ms[0].doc.str(ms[0].result()).byte_length(), 300000)
    _ = c.stop()


def test_large_request_goes_through_the_write_queue() raises:
    # bigger than a pipe buffer (64 KiB): the write cannot complete in one go
    var c = started()
    var w = JsonWriter()
    w.begin_obj()
    w.key("data")
    var big = String("")
    for _ in range(4000):
        big += "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789abcdefghijklmnopqrstuvwxyz--"
    w.str(big)
    w.end_obj()
    _ = c.request("count_bytes", w.text())
    var ms = collect(c, 1, 10000)
    assert_equal(len(ms), 1)
    assert_equal(ms[0].doc.int(ms[0].result()), 400000)
    assert_false(c.wants_write())
    _ = c.stop()


def test_server_asks_the_client() raises:
    var c = started()
    var id = c.request("ask", "")
    var ms = collect(c, 1, 5000)
    assert_equal(len(ms), 1)
    assert_equal(ms[0].kind, RPC_REQUEST)
    assert_equal(ms[0].method, "client/confirm")
    assert_equal(ms[0].id_json, "\"srv-1\"")
    assert_equal(ms[0].doc.str(ms[0].doc.path(ms[0].params(), "question")), "ok?")
    c.respond(ms[0].id_json, "\"yes\"")
    var after = collect(c, 1, 5000)
    assert_equal(len(after), 1)
    assert_equal(after[0].id, id)
    assert_equal(after[0].doc.str(after[0].doc.path(after[0].result(), "client_said")), "yes")
    _ = c.stop()


def test_client_can_refuse_a_server_request() raises:
    var c = started()
    _ = c.request("ask", "")
    var ms = collect(c, 1, 5000)
    c.respond_error(ms[0].id_json, -32601, "not supported")
    var after = collect(c, 1, 5000)
    assert_equal(after[0].doc.str(after[0].doc.path(after[0].result(), "client_error/message")), "not supported")
    _ = c.stop()


def test_notifications_reach_the_server() raises:
    var c = started()
    c.notify("seen", "")
    c.notify("seen", "{\"x\":1}")
    _ = c.request("how_many_seen", "")
    var ms = collect(c, 1, 5000)
    assert_equal(ms[0].doc.int(ms[0].result()), 2)
    _ = c.stop()


def test_stray_stdout_does_not_break_the_stream() raises:
    var c = started()
    _ = c.request("garbage", "")
    _ = c.request("add", "{\"a\":1,\"b\":2}")
    var ms = collect(c, 2, 5000)
    assert_equal(len(ms), 2)
    assert_equal(ms[0].doc.str(ms[0].result()), "still fine")
    assert_equal(ms[1].doc.int(ms[1].result()), 3)
    _ = c.stop()


def test_stderr_goes_to_the_given_file() raises:
    var log = env_or("TMPDIR", "/tmp") + "/turbomojo-rpctest-" + String(own_pid()) + ".log"
    _ = run_system("rm -f '" + log + "'")
    var c = RpcConn()
    assert_true(c.start(SERVER, log))
    _ = c.request("stderr", "")
    var ms = collect(c, 1, 5000)
    assert_equal(ms[0].doc.str(ms[0].result()), "wrote stderr")
    _ = c.stop()
    assert_equal(bytes_to_str(run_capture("cat '" + log + "'").out), "warning from the server\n")
    _ = run_system("rm -f '" + log + "'")


def test_no_reply_times_out_without_blocking() raises:
    var c = started()
    var t0 = now()
    var id = c.request("never", "", t0)
    var ms = collect(c, 1, 300)
    assert_equal(len(ms), 0)
    assert_true(c.is_pending(id))
    var late = c.timed_out(now(), 200 * MS)
    assert_equal(len(late), 1)
    # the connection still works afterwards
    _ = c.request("add", "{\"a\":5,\"b\":5}")
    var again = collect(c, 1, 5000)
    assert_equal(again[0].doc.int(again[0].result()), 10)
    _ = c.stop()


def test_server_death_is_noticed_and_writing_afterwards_is_harmless() raises:
    var c = started()
    _ = c.request("die", "")
    var ms = collect(c, 1, 5000)
    assert_equal(len(ms), 0)
    assert_true(c.ended())
    assert_false(c.alive())
    # writing to the dead child must neither block nor kill this process (SIGPIPE)
    for _ in range(20):
        _ = c.request("add", "{\"a\":1,\"b\":1}")
        _ = c.poll()
    var status = c.stop()
    assert_equal((status >> 8) & 255, 3)             # the server's exit code
    assert_false(c.proc.running)


def test_exit_notification_ends_the_server_cleanly() raises:
    var c = started()
    _ = c.request("add", "{\"a\":1,\"b\":1}")
    _ = collect(c, 1, 5000)
    c.notify("exit", "")
    _ = collect(c, 1, 2000)                          # returns when the stream ends
    assert_true(c.ended())
    assert_equal(c.stop(), 0)


def test_stop_ends_a_server_that_is_still_running() raises:
    var c = started()
    _ = c.request("add", "{\"a\":1,\"b\":1}")
    _ = collect(c, 1, 5000)
    var pid = c.proc.pid
    var t0 = now()
    _ = c.stop()
    assert_true(now() - t0 < 2000 * MS, "stop must not hang")
    assert_true(run_system("kill -0 " + String(pid) + " 2>/dev/null") != 0, "the child is gone")


def test_starting_a_missing_program_does_not_hang() raises:
    var c = RpcConn()
    assert_true(c.start("/no/such/program-anywhere"))    # the shell starts, then fails
    _ = c.request("add", "{}")
    var ms = collect(c, 1, 3000)
    assert_equal(len(ms), 0)
    assert_true(c.ended())
    var status = c.stop()
    assert_true(status != 0)


def test_restart_after_stop() raises:
    var c = started()
    _ = c.request("add", "{\"a\":1,\"b\":1}")
    _ = collect(c, 1, 5000)
    _ = c.stop()
    assert_true(c.start(SERVER))
    _ = c.request("add", "{\"a\":20,\"b\":3}")
    var ms = collect(c, 1, 5000)
    assert_equal(ms[0].doc.int(ms[0].result()), 23)
    _ = c.stop()


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
