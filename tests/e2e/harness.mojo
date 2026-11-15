"""Shared E2E test harness for TurboMojo milestone suites (tests/e2e/).
Provides isolated scratch directories, App factory, headless TUI driving,
and assertion helpers conforming strictly to Mojo 1.2.0.
"""
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from std.collections import List
from std.time import perf_counter_ns
from std.ffi import external_call

from app import *
from appstate import App, M_NORMAL, M_DIALOG, M_MENU
from screen import Screen
from config import load_settings
from term import key_event, Event, KEY_ENTER, KEY_ESC, KEY_TAB, KEY_UP, KEY_DOWN, fkey, ctrl, alt
from signals import own_pid
from util import (
    decode, to_str, env_or, run_system, run_capture, bytes_to_str,
    path_exists, is_dir, shell_quote, write_file, read_file, str_bytes,
    dirname,
)

comptime MS = 1000000


def _setenv(k: String, v: String):
    var k_copy = k
    var v_copy = v
    _ = external_call["setenv", Int32](k_copy.as_c_string_span(), v_copy.as_c_string_span(), Int32(1))


def _unsetenv(k: String):
    var k_copy = k
    _ = external_call["unsetenv", Int32](k_copy.as_c_string_span())


@fieldwise_init
struct ScratchDir(Movable):
    var path: String
    var tmux_tmp: String
    var prev_term: String
    var had_term: Bool
    var prev_tmux: String
    var had_tmux: Bool
    var prev_reader: String
    var had_reader: Bool
    var prev_nocolor: String
    var had_nocolor: Bool

    @staticmethod
    def create(tag: String) raises -> ScratchDir:
        var prev_term = env_or("TERM", "")
        var had_term = prev_term.byte_length() > 0
        var prev_tmux = env_or("TMUX_TMPDIR", "")
        var had_tmux = prev_tmux.byte_length() > 0
        var prev_reader = env_or("TURBOMOJO_SCREEN_READER", "")
        var had_reader = prev_reader.byte_length() > 0
        var prev_nocolor = env_or("NO_COLOR", "")
        var had_nocolor = prev_nocolor.byte_length() > 0

        var base = env_or("TURBOMOJO_SCRATCH", "/home/user/tmp")
        if not path_exists(base):
            base = env_or("TMPDIR", "/tmp")
        var d = base + "/tm-e2e-" + String(own_pid()) + "-" + tag + "-" + String(Int(perf_counter_ns()) % 1000000)
        var tmux_d = d + "/tmux"
        _ = run_system(
            "rm -rf "
            + shell_quote(d)
            + " && mkdir -p -m 700 "
            + shell_quote(tmux_d)
            + " && mkdir -p "
            + shell_quote(d + "/config")
            + " "
            + shell_quote(d + "/state")
        )
        return ScratchDir(d, tmux_d, prev_term, had_term, prev_tmux, had_tmux, prev_reader, had_reader, prev_nocolor, had_nocolor)

    def write(self, rel: String, content: String) raises:
        var p = self.path + "/" + rel
        var d = dirname(p)
        if d.byte_length() > 0:
            _ = run_system("mkdir -p " + shell_quote(d))
        _ = write_file(p, str_bytes(content))

    def read(self, rel: String) raises -> String:
        return bytes_to_str(read_file(self.path + "/" + rel))

    def exists(self, rel: String) -> Bool:
        return path_exists(self.path + "/" + rel)

    def restore_env(self):
        if self.had_term:
            _setenv("TERM", self.prev_term)
        else:
            _unsetenv("TERM")

        if self.had_tmux:
            _setenv("TMUX_TMPDIR", self.prev_tmux)
        else:
            _unsetenv("TMUX_TMPDIR")

        if self.had_reader:
            _setenv("TURBOMOJO_SCREEN_READER", self.prev_reader)
        else:
            _unsetenv("TURBOMOJO_SCREEN_READER")

        if self.had_nocolor:
            _setenv("NO_COLOR", self.prev_nocolor)
        else:
            _unsetenv("NO_COLOR")

    def cleanup(mut self):
        self.restore_env()
        _ = run_system("rm -rf " + shell_quote(self.path))


def make_test_app(scratch: ScratchDir, cols: Int = 120, rows: Int = 34, reader: Bool = False) raises -> App:
    """Creates a headless App instance isolated from host configurations."""
    var term_k = String("TERM")
    var term_v = String("xterm-256color")
    _ = external_call["setenv", Int32](term_k.as_c_string_span(), term_v.as_c_string_span(), Int32(1))
    var tmux_k = String("TMUX_TMPDIR")
    var tmux_v = scratch.tmux_tmp
    _ = external_call["setenv", Int32](tmux_k.as_c_string_span(), tmux_v.as_c_string_span(), Int32(1))
    var r_k = String("TURBOMOJO_SCREEN_READER")
    _ = external_call["unsetenv", Int32](r_k.as_c_string_span())
    var nc_k = String("NO_COLOR")
    _ = external_call["unsetenv", Int32](nc_k.as_c_string_span())

    var app = App()
    app.scr.resize(cols, rows)
    app.cwd = scratch.path
    app.config_path = scratch.path + "/config/config.toml"
    var cfg = "[ui]\nreduced_motion = true\n" + ("screen_reader = true\n" if reader else "screen_reader = false\n")
    app.apply_settings(load_settings(cfg, ""))
    if reader:
        app.reader = True
        app.scr.plain = True
    else:
        app.reader = False
        app.scr.plain = False
    return app^


def screen_text(app: App) -> String:
    return to_str(app.scr.to_text())


def screen_row(app: App, r: Int) -> String:
    return to_str(app.scr.row_text(r))


def status_text(app: App) -> String:
    if app.scr.h <= 0:
        return String("")
    return to_str(app.scr.row_text(app.scr.h - 1))


def count_decorations(s: String) -> Int:
    var n = 0
    for c in decode(s):
        if c >= 0x2500 and c <= 0x259F:
            n += 1
    return n


def assert_screen_has(app: App, needle: String) raises:
    var t = screen_text(app)
    assert_true(t.find(needle) >= 0, "Expected screen to contain '" + needle + "', got:\n" + t)


def assert_screen_lacks(app: App, needle: String) raises:
    var t = screen_text(app)
    assert_false(t.find(needle) >= 0, "Expected screen NOT to contain '" + needle + "'")


def assert_status_has(app: App, needle: String) raises:
    if app.status.find(needle) >= 0:
        return
    var s = status_text(app)
    assert_true(s.find(needle) >= 0, "Expected status line or app.status to contain '" + needle + "', got status line: " + s + ", app.status: " + app.status)


def test_scratch_dir_lifecycle() raises:
    var s = ScratchDir.create("harness_test")
    assert_true(path_exists(s.path))
    assert_true(path_exists(s.tmux_tmp))
    s.write("test.txt", "hello harness")
    assert_true(s.exists("test.txt"))
    assert_equal(s.read("test.txt"), "hello harness")
    s.cleanup()
    assert_false(path_exists(s.path))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

