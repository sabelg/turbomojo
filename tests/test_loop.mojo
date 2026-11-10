"""Tests for the event loop pieces: poll()-based waiting and timer selection."""
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from std.collections import List
from std.ffi import external_call
from std.time import perf_counter_ns
from term import Terminal, wait_readable, ESC_TIMEOUT_MS, KEY_ESC, KEY_UP
from app import *
from appstate import App, now_ns, STATUS_MS, RESIZE_POLL_MS, SPINNER_MS
from util import str_bytes, secs_to_next_minute


struct Pipe:
    var r: Int
    var w: Int

    def __init__(out self):
        var fds = List[Int32](length=2, fill=0)
        _ = external_call["pipe", Int32](fds.unsafe_ptr())
        self.r = Int(fds[0])
        self.w = Int(fds[1])

    def send(self, s: String):
        var b = str_bytes(s)
        _ = external_call["write", Int](Int32(self.w), b.unsafe_ptr(), len(b))

    def close(self):
        _ = external_call["close", Int32](Int32(self.r))
        _ = external_call["close", Int32](Int32(self.w))


def elapsed_ms(t0: Int) -> Int:
    return (Int(perf_counter_ns()) - t0) // 1000000


# ------------------------------------------------------------ wait_readable
def test_wait_times_out_when_nothing_arrives() raises:
    var p = Pipe()
    var fds = List[Int]()
    fds.append(p.r)
    var t0 = Int(perf_counter_ns())
    assert_equal(wait_readable(fds, 60), 0)
    var ms = elapsed_ms(t0)
    assert_true(ms >= 55, "returned too early: " + String(ms) + " ms")
    assert_true(ms < 500, "slept far too long: " + String(ms) + " ms")
    p.close()


def test_wait_returns_immediately_when_data_is_waiting() raises:
    var p = Pipe()
    p.send("x")
    var fds = List[Int]()
    fds.append(p.r)
    var t0 = Int(perf_counter_ns())
    assert_equal(wait_readable(fds, 2000), 1)
    assert_true(elapsed_ms(t0) < 200)
    p.close()


def test_wait_reports_which_descriptor_is_ready() raises:
    var a = Pipe()
    var b = Pipe()
    var c = Pipe()
    var fds = List[Int]()
    fds.append(a.r)
    fds.append(b.r)
    fds.append(c.r)
    assert_equal(wait_readable(fds, 0), 0)
    b.send("x")
    assert_equal(wait_readable(fds, 0), 2)
    c.send("y")
    assert_equal(wait_readable(fds, 0), 6)
    a.close()
    b.close()
    c.close()


def test_wait_wakes_when_writer_closes() raises:
    # a finished compiler closes its pipe: the loop must wake to collect the exit status
    var p = Pipe()
    _ = external_call["close", Int32](Int32(p.w))
    var fds = List[Int]()
    fds.append(p.r)
    assert_equal(wait_readable(fds, 1000), 1)
    _ = external_call["close", Int32](Int32(p.r))


def test_zero_timeout_never_blocks() raises:
    var p = Pipe()
    var fds = List[Int]()
    fds.append(p.r)
    var t0 = Int(perf_counter_ns())
    for _ in range(100):
        _ = wait_readable(fds, 0)
    assert_true(elapsed_ms(t0) < 200)
    p.close()


# ---------------------------------------------------------- timer selection
def idle_app() -> App:
    var app = App()
    app.show_clock = False
    return app^


def test_idle_timeout_is_the_resize_poll() raises:
    var app = idle_app()
    assert_equal(app.next_timeout_ms(now_ns(), False, 30), RESIZE_POLL_MS)


def test_pending_escape_shortens_the_wait() raises:
    var app = idle_app()
    assert_equal(app.next_timeout_ms(now_ns(), True, 30), ESC_TIMEOUT_MS)


def test_running_job_ticks_the_spinner() raises:
    var app = idle_app()
    app.job.active = True
    assert_equal(app.next_timeout_ms(now_ns(), False, 30), SPINNER_MS)
    app.job.active = False


def test_status_message_wakes_the_loop_when_it_expires() raises:
    var app = idle_app()
    var now = now_ns()
    app.status_until = now + 100 * 1000000          # expires in 100 ms
    var t = app.next_timeout_ms(now, False, 30)
    assert_true(t >= 100 and t <= 102, "got " + String(t))
    app.status_until = now + 10000 * 1000000        # far away: resize poll wins
    assert_equal(app.next_timeout_ms(now, False, 30), RESIZE_POLL_MS)
    app.status_until = now - 1                      # already expired: ignored
    assert_equal(app.next_timeout_ms(now, False, 30), RESIZE_POLL_MS)


def test_say_sets_a_deadline() raises:
    var app = idle_app()
    var before = now_ns()
    app.say("hello")
    assert_equal(app.status, "hello")
    assert_true(app.status_until >= before + STATUS_MS * 1000000)
    assert_true(app.status_until <= now_ns() + STATUS_MS * 1000000)


def test_clock_wakes_at_the_minute_boundary() raises:
    var app = idle_app()
    app.show_clock = True
    # 0 s to the minute: wake almost at once to redraw the clock
    assert_equal(app.next_timeout_ms(now_ns(), False, 0), 50)
    # far from the boundary the resize poll is shorter
    assert_equal(app.next_timeout_ms(now_ns(), False, 30), RESIZE_POLL_MS)


def test_timeout_is_never_zero_or_negative() raises:
    var app = idle_app()
    var now = now_ns()
    app.status_until = now + 1                       # expires in 1 ns
    assert_true(app.next_timeout_ms(now, True, 0) >= 1)


def test_secs_to_next_minute_range() raises:
    var s = secs_to_next_minute()
    assert_true(s >= 1 and s <= 60)


# ----------------------------------------------------- escape timing in poll
def test_lone_escape_waits_for_the_timeout() raises:
    # feed() with stale=False keeps ESC pending; pending() tells the loop to wake soon
    var t = Terminal()
    assert_false(t.pending())
    var esc = List[UInt8]()
    esc.append(27)
    assert_equal(len(t.feed(esc, False)), 0)
    assert_true(t.pending())
    var evs = t.feed(List[UInt8](), True)
    assert_equal(evs[0].key, KEY_ESC)
    assert_false(t.pending())


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
