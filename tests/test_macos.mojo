"""Tests for macOS, first part (P11-12): osx-arm64 is one of pixi's platforms and its
packages are locked; the hand-kept list of libSystem's functions that the macOS link
checks against has no Linux-only one; close_from (close_range on Linux, a loop on macOS)
closes what it should. The link itself (scripts/macos-link.sh) downloads the osx-arm64
packages, so it runs here only with TM_MACOS_LINK=1."""
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from std.collections import List
from std.ffi import external_call
from platform import close_from
from config import read_text
from util import env_or, run_capture, bytes_to_str


def test_osx_arm64_is_a_platform() raises:
    var toml = read_text("pixi.toml")
    assert_true(toml.find("\"osx-arm64\"") > 0)
    var lock = read_text("pixi.lock")
    for p in ["/osx-arm64/mojo-compiler-", "/osx-arm64/libghostty-vt-", "/osx-arm64/libcxx-"]:
        assert_true(lock.find(String(p)) > 0, String(p))


def test_the_list_of_macos_functions() raises:
    var names = List[String]()
    for l in read_text("scripts/macos/libSystem.symbols").split("\n"):
        var s = String(String(l).strip())
        if s.byte_length() == 0 or s.startswith("#"):
            continue
        assert_true(s.startswith("_"), s)
        assert_false(s in names, "twice: " + s)
        names.append(s)
    assert_true(len(names) > 50)
    assert_true("_getdtablesize" in names and "_tcsetattr" in names and "_posix_openpt" in names)
    # what macOS has not: the link must fail for these (close_range was one, P11-12)
    for linux in ["_close_range", "_eventfd", "_inotify_init1", "_inotify_add_watch", "_memfd_create", "_dup3", "_statx", "_signalfd", "_epoll_create1", "_pipe2", "_accept4", "_getrandom"]:
        assert_false(String(linux) in names, String(linux))


def test_close_from() raises:
    var fds = List[Int32](length=2, fill=0)
    _ = external_call["pipe", Int32](fds.unsafe_ptr())
    _ = external_call["dup2", Int32](fds[0], Int32(900))
    _ = external_call["dup2", Int32](fds[1], Int32(901))
    assert_true(Int(external_call["fcntl", Int32](Int32(901), Int32(1), Int32(0))) >= 0)    # F_GETFD: open
    close_from(900)
    assert_equal(Int(external_call["fcntl", Int32](Int32(900), Int32(1), Int32(0))), -1)
    assert_equal(Int(external_call["fcntl", Int32](Int32(901), Int32(1), Int32(0))), -1)
    assert_true(Int(external_call["fcntl", Int32](fds[0], Int32(1), Int32(0))) >= 0)       # (below: kept)
    _ = external_call["close", Int32](fds[0])
    _ = external_call["close", Int32](fds[1])


def test_the_macos_link() raises:
    if env_or("TM_MACOS_LINK", "") != "1":
        return
    var out = bytes_to_str(run_capture("scripts/macos-link.sh 2>&1").out)
    assert_true(out.find("Mach-O 64-bit arm64 executable") > 0, out)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
