"""Tests for the Mojo version check (P11-03): the build records `mojo --version`; the IDE
compares it with what the configured compiler says, once, and says plainly when the
release differs; `tmide --caps` shows both."""
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from mojover import mojo_version_of, mojo_mismatch, mojo_summary
from app import *
from appstate import App
from signals import own_pid
from util import env_or, run_system, run_capture, shell_quote, write_file, str_bytes, bytes_to_str


def test_reading_the_version() raises:
    assert_equal(mojo_version_of("Mojo 1.2.0 (2016d0cd)\n"), "1.2.0")
    assert_equal(mojo_version_of("Mojo 1.3.0.dev2026111305 (ab12cd34)"), "1.3.0.dev2026111305")
    assert_equal(mojo_version_of("mojo 25.4.0 (5d2d6be9)"), "25.4.0")
    assert_equal(mojo_version_of("warning: something\nMojo 1.2.0 (x)\n"), "1.2.0")   # a line before it
    assert_equal(mojo_version_of("sh: 1: mojo: not found\n"), "")
    assert_equal(mojo_version_of("Mojo is a language"), "")
    assert_equal(mojo_version_of(""), "")


def test_when_to_say_something() raises:
    assert_equal(mojo_mismatch("Mojo 1.2.0 (aaaa)", "Mojo 1.2.0 (aaaa)\n"), "")
    var m = mojo_mismatch("Mojo 1.2.0 (aaaa)", "Mojo 1.3.0 (bbbb)\n")
    assert_true(m.find("built with Mojo 1.2.0") >= 0 and m.find("found is 1.3.0") >= 0, m)
    assert_true(m.find("Rebuild TurboMojo") >= 0, m)                    # and what to do
    # a nightly of the same number is another Mojo
    assert_true(mojo_mismatch("Mojo 1.3.0 (a)", "Mojo 1.3.0.dev2026111305 (b)").byte_length() > 0)
    # unknown on either side: nothing (a build without the record; no mojo at all is
    # told elsewhere)
    assert_equal(mojo_mismatch("", "Mojo 1.3.0 (b)"), "")
    assert_equal(mojo_mismatch("Mojo 1.2.0 (a)", "sh: mojo: not found"), "")
    assert_equal(mojo_summary("Mojo 1.2.0 (a)", "Mojo 1.2.0 (a)"), "1.2.0 (TurboMojo was built with 1.2.0)")
    assert_equal(mojo_summary("Mojo 1.2.0 (a)", "Mojo 1.3.0 (b)"), "1.3.0 (TurboMojo was built with 1.2.0) - DIFFERENT")
    assert_equal(mojo_summary("", ""), "not found (TurboMojo was built with an unknown version)")


def fake_mojo(d: String, says: String) raises -> String:
    var p = d + "/mojo-" + mojo_version_of(says)
    _ = write_file(p, str_bytes("#!/bin/sh\necho '" + says + "'\n"))
    _ = run_system("chmod +x " + shell_quote(p))
    return p


def test_the_ide_says_it_once() raises:
    var d = env_or("TMPDIR", "/tmp") + "/turbomojo-mojover-" + String(own_pid())
    _ = run_system("rm -rf " + shell_quote(d) + " && mkdir -p " + shell_quote(d))
    var app = App()
    app.compiler = fake_mojo(d, "Mojo 9.9.0 (cafe)")
    app.mojo_version_check("Mojo 1.2.0 (abcd)")
    assert_true(app.mojo_checked)
    assert_true(app.status.find("built with Mojo 1.2.0") >= 0 and app.status.find("9.9.0") >= 0, app.status)
    assert_equal(app.mojo_warning, app.status)
    # the same release: nothing said
    var ok = App()
    ok.compiler = fake_mojo(d, "Mojo 1.2.0 (abcd)")
    ok.status = "before"
    ok.mojo_version_check("Mojo 1.2.0 (abcd)")
    assert_true(ok.mojo_checked)
    assert_equal(ok.mojo_warning, "")
    assert_equal(ok.status, "before")
    # built without the record: the compiler is not even asked
    var none = App()
    none.compiler = d + "/does-not-exist"
    none.mojo_version_check("")
    assert_true(none.mojo_checked)
    assert_equal(none.mojo_warning, "")
    _ = run_system("rm -rf " + shell_quote(d))


def test_caps_shows_both() raises:
    # build/tmide is built by the gate with the record (-D TURBOMOJO_MOJO=...)
    var d = env_or("TMPDIR", "/tmp") + "/turbomojo-mojover-caps-" + String(own_pid())
    _ = run_system("rm -rf " + shell_quote(d) + " && mkdir -p " + shell_quote(d))
    var env = "HOME=" + shell_quote(d) + " XDG_CONFIG_HOME=" + shell_quote(d + "/c") + " XDG_STATE_HOME=" + shell_quote(d + "/s") + " "
    var other = run_capture(env + "TURBOMOJO_COMPILER=" + shell_quote(fake_mojo(d, "Mojo 9.9.0 (cafe)")) + " build/tmide --caps < /dev/null 2>&1")
    var o = bytes_to_str(other.out)
    assert_true(o.find("mojo                : 9.9.0 (TurboMojo was built with ") >= 0, o)
    assert_true(o.find("an unknown version") < 0, "the build recorded its Mojo: " + o)
    assert_true(o.find("- DIFFERENT") >= 0 and o.find("Rebuild TurboMojo") >= 0, o)
    var gone = run_capture(env + "TURBOMOJO_COMPILER=" + shell_quote(d + "/nothing") + " build/tmide --caps < /dev/null 2>&1")
    assert_true(bytes_to_str(gone.out).find("mojo                : not found") >= 0, bytes_to_str(gone.out))
    _ = run_system("rm -rf " + shell_quote(d))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
