"""Tests for working on a remote machine (P11-07): copying goes to the terminal's
clipboard with OSC 52 only, so it needs no X11, no Wayland and no clipboard program -
the same over SSH; through tmux (set-clipboard on) the copy arrives, checked end to end
with the real program in a tmux of its own with DISPLAY and WAYLAND_DISPLAY unset and
only /usr/bin:/bin on PATH."""
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from appstate import osc52_seq
from signals import own_pid
from util import decode, env_or, run_system, run_capture, bytes_to_str, shell_quote, which


def test_the_sequence() raises:
    assert_equal(osc52_seq(decode("hi")), "\x1b]52;c;aGk=\x07")
    assert_equal(osc52_seq(decode("✓")), "\x1b]52;c;4pyT\x07")    # UTF-8, then base64
    assert_equal(osc52_seq(decode("")), "\x1b]52;c;\x07")


def test_no_clipboard_program_is_used() raises:
    # the source asks for none of them: copying never depends on the machine's desktop
    for prog in ["xclip", "xsel", "wl-copy", "pbcopy", "clip.exe"]:
        var r = run_capture("grep -l " + shell_quote(prog) + " src/*.mojo 2>/dev/null")
        assert_equal(bytes_to_str(r.out), "", prog)


def test_copy_reaches_tmux_with_no_display() raises:
    if which("tmux").byte_length() == 0:
        print("(no tmux: skipped)")
        return
    var h = env_or("TMPDIR", "/tmp") + "/turbomojo-remote-" + String(own_pid())
    var sock = "tmremote" + String(own_pid())
    var t = "tmux -L " + sock + " -f /dev/null "
    _ = run_system("rm -rf " + shell_quote(h) + " && mkdir -p " + shell_quote(h + "/c") + " " + shell_quote(h + "/s/turbomojo") + " && touch " + shell_quote(h + "/s/turbomojo/theme-asked"))
    _ = run_system("printf 'copied over ssh \\342\\234\\223\\n' > " + shell_quote(h + "/f.txt"))
    var ide = "env -u DISPLAY -u WAYLAND_DISPLAY PATH=/usr/bin:/bin HOME=" + h + " XDG_CONFIG_HOME=" + h + "/c XDG_STATE_HOME=" + h + "/s " + bytes_to_str(run_capture("pwd").out).strip() + "/build/tmide " + h + "/f.txt"
    _ = run_system(t + "new-session -d -s s -x 100 -y 30 " + shell_quote(ide))
    _ = run_system(t + "set -g set-clipboard on")
    # wait for the window, then select all and copy
    var up = False
    for _ in range(60):
        if bytes_to_str(run_capture(t + "capture-pane -p -t s").out).find("f.txt") >= 0:
            up = True
            break
        _ = run_system("sleep 0.1")
    assert_true(up, "the IDE did not start")
    _ = run_system(t + "send-keys -t s C-a && sleep 0.3 && " + t + "send-keys -t s C-c")
    var got = String("")
    for _ in range(40):
        got = bytes_to_str(run_capture(t + "show-buffer 2>/dev/null").out)
        if got.byte_length() > 0:
            break
        _ = run_system("sleep 0.1")
    _ = run_system(t + "kill-server 2>/dev/null")
    _ = run_system("rm -rf " + shell_quote(h))
    assert_true(got.startswith("copied over ssh ✓"), "[" + got + "]")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
