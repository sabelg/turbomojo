"""Tests for the release (P9-04): the version is the same everywhere it is written
(src/version.mojo, pixi.toml, recipe/recipe.yaml, What's new), and the command line
answers --version and --help without a terminal."""
from std.testing import assert_equal, assert_true, TestSuite
from version import TURBOMOJO_VERSION
from helpbook import HELP_WHATS_NEW
from util import run_capture, read_file, bytes_to_str, getcwd, shell_quote


def test_one_version_everywhere() raises:
    var pixi = bytes_to_str(read_file(getcwd() + "/pixi.toml"))
    assert_true(pixi.find("version = \"" + TURBOMOJO_VERSION + "\"") >= 0, "pixi.toml")
    var recipe = bytes_to_str(read_file(getcwd() + "/recipe/recipe.yaml"))
    assert_true(recipe.find("version: \"" + TURBOMOJO_VERSION + "\"") >= 0, "recipe.yaml")
    var parts = TURBOMOJO_VERSION.split(".")
    var minor = String(parts[0]) + "." + String(parts[1])
    assert_true(String(HELP_WHATS_NEW).find("\n## " + minor) > 0, "What's new has no " + minor)


def test_the_command_line() raises:
    var exe = shell_quote(getcwd() + "/build/tmide")
    var v = run_capture(exe + " --version < /dev/null")
    assert_equal(v.status, 0)
    assert_true(bytes_to_str(v.out).startswith("TurboMojo " + TURBOMOJO_VERSION + " ("), bytes_to_str(v.out))
    var short = run_capture(exe + " -V < /dev/null")
    assert_equal(bytes_to_str(short.out), bytes_to_str(v.out))
    var h = run_capture(exe + " --help < /dev/null")
    assert_equal(h.status, 0)
    var text = bytes_to_str(h.out)
    assert_true(text.startswith("Usage: tmide [FILE|FOLDER]..."), text)
    for opt in ["--help", "--version", "--strings", "--caps"]:
        assert_true(text.find(String(opt)) > 0, String(opt))
    # without a terminal anything else is refused, with the exit status 2
    var none = run_capture(exe + " < /dev/null > /dev/null")
    assert_equal(none.status >> 8, 2)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
