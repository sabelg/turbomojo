"""E2E Test Suite for Feature #22: Binary File Safety Guard & WK_HEX View.
Covers Tier 1 (5 Happy Path tests) and Tier 2 (5 Boundary/Corner tests).
"""
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from std.collections import List
from signals import own_pid
from util import decode, to_str, env_or, run_system, shell_quote, str_bytes, bytes_to_str, write_file, read_file, path_exists

from window import Window, WK_EDITOR, WK_HEX
from screen import Screen
from palette import theme
from highlight import Highlighter
from search import make_search
from window_search import *
from window_draw import *
from hexview import (
    is_binary_data, BinaryGuard,
    byte_to_hex, format_hex_offset,
    VirtualHexView, parse_hex_query, search_hex,
    render_hex_rows,
)


def scratch(tag: String) -> String:
    var d = env_or("TMPDIR", "/tmp") + "/turbomojo-e2e-f22-" + String(own_pid()) + "-" + tag
    _ = run_system("rm -rf " + shell_quote(d) + " && mkdir -p " + shell_quote(d))
    return d


# ---------------------------------------------------------------------------
# Tier 1: Isolated Happy Path Tests
# ---------------------------------------------------------------------------

def test_tier1_f22_case1_binary_auto_detect_nul_header() raises:
    """Verify binary detection triggers on NUL byte in header, while plain text passes."""
    var elf_header = List[UInt8]()
    elf_header.append(0x7F)
    elf_header.append(0x45) # 'E'
    elf_header.append(0x4C) # 'L'
    elf_header.append(0x46) # 'F'
    elf_header.append(0x02) # 64-bit
    elf_header.append(0x01) # little endian
    elf_header.append(0x01) # version
    elf_header.append(0x00) # ABI sysv (NUL)
    
    assert_true(is_binary_data(elf_header))
    
    var text_bytes = List[UInt8]()
    for c in decode("def main() raises:\n    print(\"Hello world\")\n"):
        text_bytes.append(UInt8(c))
    assert_false(is_binary_data(text_bytes))


def test_tier1_f22_case2_read_only_safety_guard_enforcement() raises:
    """Verify binary guard locks buffer as read_only and blocks edits."""
    var bin_bytes = List[UInt8]()
    bin_bytes.append(0xDE)
    bin_bytes.append(0xAD)
    bin_bytes.append(0x00)
    bin_bytes.append(0xBE)
    bin_bytes.append(0xEF)
    
    var guard = BinaryGuard(bin_bytes)
    assert_true(guard.is_binary)
    assert_true(guard.read_only)
    assert_false(guard.can_modify())
    assert_true(guard.status_msg.find("read-only") >= 0)


def test_tier1_f22_case3_wk_hex_row_virtualization_and_formatting() raises:
    """Verify 16-byte row formatting: offset, hex columns, and ASCII delimiters."""
    var sample = List[UInt8]()
    for i in range(16):
        sample.append(UInt8(65 + i)) # 'A'..'P'
        
    var hex_view = VirtualHexView(sample)
    assert_equal(hex_view.row_count(), 1)
    
    var rendered = hex_view.render_row(0)
    assert_true(rendered.startswith("00000000  "))
    assert_true(rendered.find("41 42 43 44 45 46 47 48  49 4a 4b 4c 4d 4e 4f 50") >= 0)
    assert_true(rendered.endswith("|ABCDEFGHIJKLMNOP|"))


def test_tier1_f22_case4_cursor_hex_to_ascii_bidirectional_sync() raises:
    """Cursor position synchronization between hex column and ASCII column."""
    var data = List[UInt8]()
    for i in range(32):
        data.append(UInt8(i))
        
    var hex_view = VirtualHexView(data)
    hex_view.set_cursor_from_hex(1, 5) # row 1, col 5 -> byte offset 21
    assert_equal(hex_view.cursor_offset, 21)
    assert_false(hex_view.in_ascii_column)
    
    var coords = hex_view.get_cursor_coords()
    assert_equal(coords[0], 1) # row 1
    # hex col: 10 + 5*3 = 25
    assert_equal(coords[1], 25)
    # ascii col: 61 + 5 = 66
    assert_equal(coords[2], 66)
    
    # Move via ascii pane
    hex_view.set_cursor_from_ascii(0, 10)
    assert_equal(hex_view.cursor_offset, 10)
    assert_true(hex_view.in_ascii_column)
    var coords2 = hex_view.get_cursor_coords()
    assert_equal(coords2[0], 0)
    assert_equal(coords2[1], 41) # 10 + 10*3 + 1 (gap) = 41
    assert_equal(coords2[2], 71) # 61 + 10 = 71


def test_tier1_f22_case5_hex_pattern_search_and_jump() raises:
    """Search for hex byte pattern 'CA FE BA BE' and jump cursor to match offset."""
    var data = List[UInt8]()
    for _ in range(40):
        data.append(0x00)
    # Insert magic at byte 25
    data[25] = 0xCA
    data[26] = 0xFE
    data[27] = 0xBA
    data[28] = 0xBE
    
    var matches = search_hex(data, "CA FE BA BE")
    assert_equal(len(matches), 1)
    assert_equal(matches[0], 25)
    
    var hex_view = VirtualHexView(data)
    hex_view.cursor_offset = matches[0]
    var coords = hex_view.get_cursor_coords()
    assert_equal(coords[0], 1) # row 1 (25 // 16)
    assert_equal(coords[1], 10 + 9 * 3 + 1) # col 9 in row 1


# ---------------------------------------------------------------------------
# Tier 2: Boundary Value Analysis & Corner Cases
# ---------------------------------------------------------------------------

def test_tier2_f22_bound1_empty_binary_file_zero_rows() raises:
    """Empty 0-byte file: 0 rows, safe rendering, and no binary detection."""
    var empty = List[UInt8]()
    assert_false(is_binary_data(empty))
    var hex_view = VirtualHexView(empty)
    assert_equal(hex_view.row_count(), 0)
    assert_equal(hex_view.render_row(0), "")


def test_tier2_f22_bound2_partial_last_row_padding_and_alignment() raises:
    """Partial row (23 bytes = 16 bytes in row 0, 7 bytes in row 1) with correct padding."""
    var data = List[UInt8]()
    for i in range(23):
        data.append(0x30 + UInt8(i % 10))
        
    var hex_view = VirtualHexView(data)
    assert_equal(hex_view.row_count(), 2)
    
    var row1 = hex_view.render_row(1)
    assert_true(row1.startswith("00000010  "))
    # Row 1 has 7 hex pairs
    assert_true(row1.find("36 37 38 39 30 31 32") >= 0)
    # Remaining 9 columns padded with spaces
    assert_true(row1.find("|6789012         |") >= 0)


def test_tier2_f22_bound3_nul_byte_at_extreme_scan_boundary_4095() raises:
    """NUL byte placed at the exact 4095 boundary byte is still caught by binary scan."""
    var data = List[UInt8]()
    for _ in range(4095):
        data.append(0x61) # 'a'
    data.append(0x00) # byte 4095 NUL
    
    assert_true(is_binary_data(data))


def test_tier2_f22_bound4_all_control_and_high_ascii_bytes() raises:
    """Non-printable bytes 0x00..0x1F and 0x7F..0xFF rendered as dots in ASCII column."""
    var data = List[UInt8]()
    data.append(0x00) # NUL
    data.append(0x01) # SOH
    data.append(0x1F) # US
    data.append(0x7F) # DEL
    data.append(0x80) # High byte
    data.append(0xFF) # High byte
    
    var hex_view = VirtualHexView(data)
    var row0 = hex_view.render_row(0)
    assert_true(row0.find("00 01 1f 7f 80 ff") >= 0)
    assert_true(row0.find("|......          |") >= 0)


def test_tier2_f22_bound5_cross_row_hex_pattern_search() raises:
    """Hex pattern matching across 16-byte row boundary (spanning row 0 to row 1)."""
    var data = List[UInt8]()
    for _ in range(32):
        data.append(0x00)
    # Place pattern at bytes 14, 15, 16, 17
    data[14] = 0xAA
    data[15] = 0xBB
    data[16] = 0xCC
    data[17] = 0xDD
    
    var matches = search_hex(data, "aabbccdd")
    assert_equal(len(matches), 1)
    assert_equal(matches[0], 14)


def test_tier2_f22_bound6_wk_hex_window_draw_and_readonly_guard() raises:
    """Verify render_hex_rows viewport slicing, WK_HEX Window.draw, and read_only replace guard."""
    var raw = List[UInt8]()
    for i in range(40):
        raw.append(UInt8(65 + (i % 26)))
    var rows = render_hex_rows(raw, 1, 2)
    assert_equal(len(rows), 2)
    assert_true(rows[0].startswith("00000010  "))
    assert_true(rows[1].startswith("00000020  "))

    var win = Window(WK_HEX, "blob.bin", "blob.bin", 0, 0, 80, 12, 1)
    win.hex_bytes = raw^
    win.read_only = True
    win.cr = 0
    var scr = Screen(80, 12)
    var pal = theme(0)
    var hl = Highlighter()
    win.draw(scr, pal, hl, True, True, True, False)

    var top_bar = to_str(scr.row_text(0))
    var row1_txt = to_str(scr.row_text(1))
    assert_true(top_bar.find("[HEX READ-ONLY]") >= 0)
    assert_true(row1_txt.find("00000000") >= 0)

    # read_only guard prevents replace_matches / replace_current from mutating buffer
    var ro_ed = Window(WK_EDITOR, "ro.txt", "", 0, 0, 60, 10, 2)
    ro_ed.buf.load(decode("hello world"))
    ro_ed.read_only = True
    var s = make_search(decode("hello"), True, False, False)
    assert_equal(ro_ed.replace_matches(s, decode("bye")), 0)
    assert_equal(to_str(ro_ed.buf.all_text()), "hello world")


# ---------------------------------------------------------------------------
# Test Runner
# ---------------------------------------------------------------------------

def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
