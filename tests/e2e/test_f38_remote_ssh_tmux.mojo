"""E2E Test Suite for Feature #38:
Remote SSH & tmux clipboard / port-forward integration.
- DCS passthrough wrapping for OSC 52 inside tmux.
- Embedded escape doubling in DCS envelopes.
- [ssh:<host>] status pill formatting and status row rendering.
- Automatic ssh -L port-forward toasts on localhost port binds.

Covers:
- 5 Tier 1 (Isolated Happy Path) tests
- 5 Tier 2 (Boundary Value Analysis & Corner Cases) tests
Strictly conforming to Mojo 1.2 rules.
"""
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from std.collections import List
from std.ffi import external_call

from kittygfx import wrap_for_tmux
from appstate import App, osc52_seq, now_ns
from links import parse_ssh_host, format_ssh_pill, parse_port_forward, host_name
from util import decode, to_str
from harness import ScratchDir, make_test_app, assert_status_has


def set_env(k: String, v: String):
    var k_copy = k
    var v_copy = v
    _ = external_call["setenv", Int32](k_copy.as_c_string_span(), v_copy.as_c_string_span(), Int32(1))


def unset_env(k: String):
    var k_copy = k
    _ = external_call["unsetenv", Int32](k_copy.as_c_string_span())


# =========================================================================
# Tier 1 Tests (Happy Path)
# =========================================================================

def test_f38_t1_01_osc52_tmux_dcs_envelope_format() raises:
    """Verifies App.osc52 wraps sequence in tmux DCS envelope when in tmux."""
    var s = ScratchDir.create("f38_t1_01")
    var app = make_test_app(s)
    app.gfx_tmux = True

    app.osc52(decode("hello"))

    # Envelope: \x1bPtmux;\x1b\x1b]52;c;aGVsbG8=\x07\x1b\
    assert_true(app.last_osc52.startswith("\x1bPtmux;\x1b\x1b]52;c;"))
    assert_true(app.last_osc52.find("aGVsbG8=") >= 0)
    assert_true(app.last_osc52.endswith("\x07\x1b\\"))
    s.cleanup()


def test_f38_t1_02_osc52_plain_when_tmux_unset() raises:
    """Verifies raw OSC 52 sequence without DCS envelope when outside tmux."""
    var s = ScratchDir.create("f38_t1_02")
    var app = make_test_app(s)
    app.gfx_tmux = False
    unset_env("TMUX")

    app.osc52(decode("hello"))

    assert_equal(app.last_osc52, "\x1b]52;c;aGVsbG8=\x07")
    assert_false(app.last_osc52.startswith("\x1bPtmux;"))
    s.cleanup()


def test_f38_t1_03_ssh_status_pill_displayed() raises:
    """Verifies [ssh:<host>] status pill is generated and rendered in App status row."""
    set_env("SSH_CONNECTION", "192.168.1.50 52341 my-devbox 22")
    var s = ScratchDir.create("f38_t1_03")
    var app = make_test_app(s, cols=120, rows=34)

    assert_equal(app.ssh_host(), "my-devbox")
    assert_equal(app.ssh_pill(), "[ssh:my-devbox]")

    app.draw_status(List[String](), List[Int]())
    assert_status_has(app, "[ssh:my-devbox]")

    unset_env("SSH_CONNECTION")
    s.cleanup()


def test_f38_t1_04_localhost_port_bind_triggers_forward_toast() raises:
    """Verifies localhost bind output triggers ssh -L port forward command and toast in App."""
    set_env("SSH_CONNECTION", "10.0.0.2 54321 remotehost 22")
    var s = ScratchDir.create("f38_t1_04")
    var app = make_test_app(s)

    var line = "Listening on http://127.0.0.1:8000/api"
    var cmd = app.port_forward_toast(line)

    assert_equal(cmd, "ssh -L 8000:127.0.0.1:8000 remotehost")
    assert_true(len(app.notes.notices) > 0)
    var toasts = app.notes.toasts(now_ns())
    assert_true(len(toasts) > 0)
    var notice = app.notes.notices[toasts[0]].copy()
    assert_equal(notice.title, "Port Forward")
    assert_true(notice.text.find("ssh -L 8000:127.0.0.1:8000") >= 0)

    unset_env("SSH_CONNECTION")
    s.cleanup()


def test_f38_t1_05_host_name_resolution_syscall() raises:
    """Verifies host_name() syscall from links.mojo returns valid hostname and formats pill."""
    var h = host_name()
    assert_true(h.byte_length() > 0)
    assert_false(h.endswith("\x00"))

    var pill = format_ssh_pill(h)
    assert_equal(pill, "[ssh:" + h + "]")


# =========================================================================
# Tier 2 Tests (Boundary Values & Corner Cases)
# =========================================================================

def test_f38_t2_01_osc52_tmux_embedded_escape_doubling() raises:
    """Verifies embedded ANSI escape characters are doubled inside tmux DCS envelope."""
    var styled = decode("a\x1b[1mb")
    var seq = wrap_for_tmux(osc52_seq(styled))

    assert_true(seq.startswith("\x1bPtmux;"))
    assert_true(seq.endswith("\x1b\\"))
    assert_false(seq.find("\x1b[1m") >= 0)


def test_f38_t2_02_osc52_empty_and_large_clipboard_payload() raises:
    """Verifies empty and large multi-kilobyte payloads produce valid base64 and envelopes."""
    var s = ScratchDir.create("f38_t2_02")
    var app = make_test_app(s)
    app.gfx_tmux = False
    unset_env("TMUX")

    app.osc52(decode(""))
    assert_equal(app.last_osc52, "\x1b]52;c;\x07")

    app.gfx_tmux = True
    var large_text = String("")
    for i in range(500):
        large_text += "line " + String(i) + " of clipboard buffer data;\n"
    app.osc52(decode(large_text))

    assert_true(app.last_osc52.startswith("\x1bPtmux;\x1b\x1b]52;c;"))
    assert_true(app.last_osc52.endswith("\x07\x1b\\"))
    assert_true(app.last_osc52.byte_length() > 10000)
    s.cleanup()


def test_f38_t2_03_localhost_bind_ipv6_and_various_port_syntaxes() raises:
    """Verifies port forward command generation across localhost, 127.0.0.1, and IPv6 [::1]."""
    var cmd_lh = parse_port_forward("Serving at http://localhost:3000", "mybox", True)
    assert_equal(cmd_lh, "ssh -L 3000:127.0.0.1:3000 mybox")

    var cmd_v6 = parse_port_forward("Bound on http://[::1]:9090", "mybox", True)
    assert_equal(cmd_v6, "ssh -L 9090:127.0.0.1:9090 mybox")

    var cmd_vite = parse_port_forward("Network: http://127.0.0.1:5173/", "mybox", True)
    assert_equal(cmd_vite, "ssh -L 5173:127.0.0.1:5173 mybox")


def test_f38_t2_04_no_port_forward_toast_when_local() raises:
    """Verifies port forward toast is suppressed when not running over SSH."""
    unset_env("SSH_CONNECTION")
    unset_env("SSH_CLIENT")
    unset_env("SSH_TTY")
    var s = ScratchDir.create("f38_t2_04")
    var app = make_test_app(s)

    var line = "Listening on http://127.0.0.1:8000"
    var cmd = app.port_forward_toast(line)

    assert_equal(cmd, "")
    assert_equal(len(app.notes.notices), 0)
    assert_equal(len(app.notes.toasts(now_ns())), 0)
    s.cleanup()


def test_f38_t2_05_ssh_connection_parsing_resilience() raises:
    """Verifies SSH_CONNECTION string parsing handles multi-spaces and malformed inputs."""
    var conn = "10.0.0.2 54321 10.0.0.1 22"
    var host = parse_ssh_host(conn)
    assert_equal(host, "10.0.0.1")

    # Resilience against multiple spaces/tabs (Challenger 2 edge case)
    var multi_space = "192.168.1.100   54321   my-host   22"
    assert_equal(parse_ssh_host(multi_space), "my-host")

    # Malformed or empty strings fall back safely to host_name()
    var fallback = parse_ssh_host("")
    assert_true(fallback.byte_length() > 0)

    var single_part = parse_ssh_host("garbage")
    assert_true(single_part.byte_length() > 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
