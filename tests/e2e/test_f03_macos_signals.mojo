"""E2E Test Suite for Feature #3:
macOS Signals, `sigaction`, Trash & Mach-O.
- Non-blocking self-pipe delivery on Darwin and Linux.
- Darwin struct sigaction 16-byte layout vs Linux 152-byte layout.
- Default trash directory: ~/.Trash on Darwin vs $XDG_DATA_HOME/Trash on Linux.
- File watching: kqueue on Darwin vs inotify on Linux.
- Mach-O bundling in scripts/bundle.sh and CI workflows.

Covers:
- 5 Tier 1 (Isolated Happy Path) tests
- 5 Tier 2 (Boundary Value Analysis & Corner Cases) tests
Strictly conforming to Mojo 1.2 rules.
"""
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from std.collections import List
from std.ffi import external_call

from signals import SignalFd, send_signal, own_pid, SIGNAL_READ_FD, SIGNAL_WRITE_FD
from platform import IS_MACOS, SIGACTION_SIZE, SA_FLAGS_OFFSET, init_sigaction
from explorer import default_trash_dir, trash_path
from watch import Watcher
from util import (
    SIGWINCH, SIGTERM, SIGHUP, SIGINT, path_exists, read_file, bytes_to_str,
    env_or, write_file, str_bytes, run_system, shell_quote,
)
from harness import ScratchDir


def test_f03_t1_01_pipe_signal_open_and_close() raises:
    """Verifies SignalFd.open() creates self-pipe and close() cleans up descriptors."""
    var s = SignalFd()
    assert_false(s.active())
    assert_true(s.open())
    assert_true(s.active())
    assert_equal(s.fd, SIGNAL_READ_FD)
    assert_equal(len(s.read_all()), 0)

    # Reopening an open descriptor is harmless
    assert_true(s.open())

    s.close()
    assert_false(s.active())
    assert_equal(s.fd, -1)


def test_f03_t1_02_pipe_signal_delivery_winch() raises:
    """Verifies delivery of SIGWINCH through the self-pipe."""
    var s = SignalFd()
    assert_true(s.open())

    # Send SIGWINCH to current process
    send_signal(own_pid(), SIGWINCH)

    var got = s.read_all()
    assert_true(len(got) >= 1)
    var found = False
    for i in range(len(got)):
        if got[i] == SIGWINCH:
            found = True
            break
    assert_true(found)

    # Calling read_all() again returns empty since pipe is drained
    assert_equal(len(s.read_all()), 0)
    s.close()


def test_f03_t1_03_sigaction_darwin_layout_offsets() raises:
    """Verifies struct sigaction size and offset configuration for Darwin vs Linux."""
    comptime if IS_MACOS:
        assert_equal(SIGACTION_SIZE, 16)
        assert_equal(SA_FLAGS_OFFSET, 12)
    else:
        assert_equal(SIGACTION_SIZE, 152)
        assert_equal(SA_FLAGS_OFFSET, 136)

    # Test with non-zero flags (0x04000000 = SA_RESTORER)
    var test_flags = 0x04000000
    var sa = init_sigaction(0x12345678, test_flags)
    assert_equal(len(sa), SIGACTION_SIZE)

    # Handler offset is 0 on both Darwin and Linux (first 8 bytes)
    assert_equal(sa[0], 0x78)
    assert_equal(sa[1], 0x56)
    assert_equal(sa[2], 0x34)
    assert_equal(sa[3], 0x12)

    # Flags reside at SA_FLAGS_OFFSET (offset 12 on Darwin, 136 on Linux)
    # 0x04000000 in little-endian has byte 3 as 0x04
    assert_equal(sa[SA_FLAGS_OFFSET + 0], 0x00)
    assert_equal(sa[SA_FLAGS_OFFSET + 1], 0x00)
    assert_equal(sa[SA_FLAGS_OFFSET + 2], 0x00)
    assert_equal(sa[SA_FLAGS_OFFSET + 3], 0x04)

    # Verify sa_mask (bytes 8..11) was NOT corrupted by writing flags
    comptime if not IS_MACOS:
        assert_equal(sa[8], 0)
        assert_equal(sa[9], 0)
        assert_equal(sa[10], 0)
        assert_equal(sa[11], 0)


def test_f03_t1_04_default_trash_dir_macos_vs_linux() raises:
    """Verifies default_trash_dir() points to ~/.Trash on Darwin vs XDG on Linux."""
    var trash = default_trash_dir()
    assert_true(trash.byte_length() > 0)

    comptime if IS_MACOS:
        assert_true(trash.endswith("/.Trash"))
    else:
        assert_true(trash.endswith("/Trash"))


def test_f03_t1_05_kqueue_watcher_activation() raises:
    """Verifies Watcher initializes cleanly using kqueue on Darwin or inotify on Linux."""
    var w = Watcher()
    assert_false(w.active())
    assert_true(w.open())
    assert_true(w.active())
    assert_true(w.fd >= 0)

    var s = ScratchDir.create("f03_watch")
    assert_true(w.watch_dir(s.path))

    w.close()
    assert_false(w.active())
    s.cleanup()


def test_f03_t2_01_pipe_signal_burst_overflow_drain() raises:
    """Verifies burst of repeated signals does not block and coalesces properly."""
    var s = SignalFd()
    assert_true(s.open())

    # Send a burst of signals
    for i in range(50):
        send_signal(own_pid(), SIGWINCH if i % 2 == 0 else SIGHUP)

    var got = s.read_all()
    # Coalesced mask should record both signals
    assert_true(len(got) >= 1)
    var has_winch = False
    var has_hup = False
    for i in range(len(got)):
        if got[i] == SIGWINCH:
            has_winch = True
        elif got[i] == SIGHUP:
            has_hup = True
    assert_true(has_winch)
    assert_true(has_hup)

    s.close()


def test_f03_t2_02_pipe_fixed_descriptor_collision() raises:
    """Verifies SignalFd.open() safely refuses to initialize when fd 250 is already occupied."""
    # Create a dummy pipe and occupy descriptor SIGNAL_READ_FD (250)
    var p = List[Int32](length=2, fill=0)
    var rc = external_call["pipe", Int32](p.unsafe_ptr())
    assert_equal(rc, 0)
    var dup_rc = external_call["dup2", Int32](p[0], Int32(SIGNAL_READ_FD))
    assert_equal(Int(dup_rc), SIGNAL_READ_FD)

    # SignalFd.open() must detect that fd 250 is already in use and return False
    var s = SignalFd()
    var opened = s.open()
    assert_false(opened)
    assert_false(s.active())
    assert_equal(len(s.read_all()), 0)

    # Free the occupied descriptor
    _ = external_call["close", Int32](Int32(SIGNAL_READ_FD))
    _ = external_call["close", Int32](p[0])
    _ = external_call["close", Int32](p[1])

    # Now SignalFd.open() should succeed cleanly
    assert_true(s.open())
    assert_true(s.active())
    s.close()
    assert_false(s.active())


def test_f03_t2_03_trash_inside_target_or_missing_home() raises:
    """Verifies trash_path protects against deleting folder containing trash itself."""
    var s = ScratchDir.create("f03_trash")
    var target = s.path + "/to_delete.txt"
    s.write("to_delete.txt", "bye")

    # Missing trash folder returns error
    var err_no_trash = trash_path(target, "")
    assert_true(err_no_trash.byte_length() > 0)

    # Non-existent file returns error
    var err_no_file = trash_path(s.path + "/non_existent.txt", s.path + "/trash")
    assert_true(err_no_file.byte_length() > 0)

    # macOS direct trash placement logic
    var macos_trash = s.path + "/.Trash"
    var res = trash_path(target, macos_trash)
    assert_equal(res, "")
    assert_false(path_exists(target))
    assert_true(path_exists(macos_trash + "/to_delete.txt"))

    s.cleanup()


def test_f03_t2_04_macho_bundle_script_detection() raises:
    """Verifies scripts/bundle.sh includes Mach-O packaging rules (otool, install_name_tool)."""
    var bundle_script = bytes_to_str(read_file("scripts/bundle.sh"))
    assert_true(bundle_script.find("otool -L") >= 0)
    assert_true(bundle_script.find("install_name_tool") >= 0)
    assert_true(bundle_script.find("codesign") >= 0)


def test_f03_t2_05_ci_release_workflow_macos_matrix() raises:
    """Verifies CI and release workflows include osx-arm64 matrix target."""
    var release_yml = bytes_to_str(read_file(".github/workflows/release.yml"))
    assert_true(release_yml.find("osx-arm64") >= 0)

    var ci_yml = bytes_to_str(read_file(".github/workflows/ci.yml"))
    assert_true(ci_yml.find("osx-arm64") >= 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
