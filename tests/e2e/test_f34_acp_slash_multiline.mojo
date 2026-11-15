"""E2E Test Suite for Feature #34:
ACP Slash-Command Picker & Multiline Prompt Composer.
Covers slash-command prefix parsing, multi-line prompt editing in WK_AGENT,
cursor positioning, draft preservation during history navigation,
and slash command popup picker integration.

Covers:
- 5 Tier 1 (Isolated Happy Path) tests
- 5 Tier 2 (Boundary Value Analysis & Corner Cases) tests
Strictly conforming to Mojo 1.2 rules.
"""
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from std.collections import List
from term import (
    KEY_ENTER, KEY_BACKSPACE, KEY_DELETE, KEY_LEFT, KEY_RIGHT,
    KEY_HOME, KEY_END, MOD_ALT, MOD_SHIFT, KEY_UP, KEY_DOWN, K_BASE,
)
from agentprompt import (
    AgentPrompt, parse_slash_command, available_slash_commands, filter_slash_commands,
)
from signals import own_pid
from util import env_or, run_system, shell_quote, str_bytes, bytes_to_str, decode, to_str


def scratch(tag: String) -> String:
    var d = env_or("TMPDIR", "/tmp") + "/turbomojo-e2e-f34-" + String(own_pid()) + "-" + tag
    _ = run_system("rm -rf " + shell_quote(d) + " && mkdir -p " + shell_quote(d))
    return d


def clean_scratch(d: String):
    _ = run_system("rm -rf " + shell_quote(d))


# ===========================================================================
# Tier 1: Isolated Happy Path Tests (5 tests)
# ===========================================================================

def test_tier1_f34_case1_agent_input_typing_and_cursor() raises:
    """Verify typing characters into agent composer updates input and cursor position."""
    var composer = AgentPrompt()

    # Type "Hello Mojo"
    for c in decode("Hello Mojo"):
        _ = composer.key(c)

    assert_equal(len(composer.input), 10)
    assert_equal(composer.cur, 10)
    assert_equal(to_str(composer.input), "Hello Mojo")

    # Move left 4 times
    for _ in range(4):
        _ = composer.key(KEY_LEFT)
    assert_equal(composer.cur, 6)

    # Insert a space
    _ = composer.key(32)
    assert_equal(to_str(composer.input), "Hello  Mojo")
    assert_equal(composer.cur, 7)


def test_tier1_f34_case2_multiline_paste_preserves_content() raises:
    """Verify pasting multi-line text into composer preserves newlines."""
    var composer = AgentPrompt()

    var pasted = decode("First line\nSecond line\nThird line")
    var ok = composer.paste(pasted)
    assert_true(ok)
    assert_equal(composer.cur, len(composer.input))

    var text = to_str(composer.input)
    assert_true(text.find("First line\nSecond line\nThird line") >= 0)


def test_tier1_f34_case3_agent_input_rows_wrapping() raises:
    """Verify input_rows wraps multi-line prompt text into formatted rows."""
    var composer = AgentPrompt()

    composer.input = decode("Short text")
    var rows1 = composer.input_rows(40)
    assert_equal(len(rows1), 1)
    assert_equal(to_str(rows1[0]), "› Short text")

    # Multi-line text with explicit newlines
    composer.input = decode("Line 1\nLine 2\nLine 3")
    var rows2 = composer.input_rows(40)
    assert_equal(len(rows2), 3)
    assert_equal(to_str(rows2[0]), "› Line 1")
    assert_equal(to_str(rows2[1]), "  Line 2")
    assert_equal(to_str(rows2[2]), "  Line 3")


def test_tier1_f34_case4_history_navigation_draft_preservation() raises:
    """Verify Alt-Up loads prompt history and Alt-Down restores user's draft."""
    var composer = AgentPrompt()
    composer.history.append("history query 1")
    composer.history.append("history query 2")

    # Active user draft
    composer.input = decode("my active draft")
    composer.cur = len(composer.input)

    # Alt-Up to navigate back
    _ = composer.key(KEY_UP | MOD_ALT)
    assert_equal(to_str(composer.input), "history query 2")

    _ = composer.key(KEY_UP | MOD_ALT)
    assert_equal(to_str(composer.input), "history query 1")

    # Alt-Down to navigate forward
    _ = composer.key(KEY_DOWN | MOD_ALT)
    assert_equal(to_str(composer.input), "history query 2")

    # Alt-Down back to draft
    _ = composer.key(KEY_DOWN | MOD_ALT)
    assert_equal(to_str(composer.input), "my active draft")


def test_tier1_f34_case5_slash_command_parsing() raises:
    """Verify parse_slash_command parses command verbs and arguments."""
    var composer = AgentPrompt()

    composer.input = decode("/model gemini-3.1-pro")
    var cmd1 = composer.parse_slash_command()
    assert_equal(cmd1[0], "/model")
    assert_equal(cmd1[1], "gemini-3.1-pro")

    composer.input = decode("/help")
    var cmd2 = composer.parse_slash_command()
    assert_equal(cmd2[0], "/help")
    assert_equal(cmd2[1], "")

    composer.input = decode("/mode accept-edits")
    var cmd3 = composer.parse_slash_command()
    assert_equal(cmd3[0], "/mode")
    assert_equal(cmd3[1], "accept-edits")

    # Test standalone parser function
    var direct_cmd = parse_slash_command("/thinking budget=1000")
    assert_equal(direct_cmd[0], "/thinking")
    assert_equal(direct_cmd[1], "budget=1000")


# ===========================================================================
# Tier 2: Boundary Value Analysis & Corner Cases (5 tests)
# ===========================================================================

def test_tier2_f34_bound1_empty_prompt_enter_noop() raises:
    """Verify empty prompt produces empty slash command and 1 empty row."""
    var composer = AgentPrompt()
    assert_equal(len(composer.input), 0)

    var cmd = composer.parse_slash_command()
    assert_equal(cmd[0], "")
    assert_equal(cmd[1], "")

    var rows = composer.input_rows(40)
    assert_equal(len(rows), 1)
    assert_equal(to_str(rows[0]), "› ")


def test_tier2_f34_bound2_backspace_and_delete_at_boundaries() raises:
    """Verify Backspace at index 0 and Delete at end of input safely no-op."""
    var composer = AgentPrompt()
    composer.input = decode("abc")
    composer.cur = 0

    # Backspace at start
    _ = composer.key(KEY_BACKSPACE)
    assert_equal(composer.cur, 0)
    assert_equal(to_str(composer.input), "abc")

    # Move to end
    _ = composer.key(KEY_END)
    assert_equal(composer.cur, 3)

    # Delete at end
    _ = composer.key(KEY_DELETE)
    assert_equal(composer.cur, 3)
    assert_equal(to_str(composer.input), "abc")


def test_tier2_f34_bound3_slash_command_without_slash() raises:
    """Verify regular prompt text does not trigger slash command parser."""
    var composer = AgentPrompt()
    composer.input = decode("regular question about /path/to/file")

    var cmd = composer.parse_slash_command()
    assert_equal(cmd[0], "")
    assert_equal(cmd[1], "")


def test_tier2_f34_bound4_cursor_calculation_at_exact_wrap_boundary() raises:
    """Verify calculate_cursor stays bounded within window dimensions."""
    var composer = AgentPrompt()
    var input_str = String("")
    for _ in range(50):
        input_str += "x"
    composer.input = decode(input_str)
    composer.cur = 25

    var coords = composer.calculate_cursor(25, 0, 1, 30, 20)
    assert_true(coords[0] < 30)
    assert_true(coords[1] < 21)


def test_tier2_f34_bound5_extreme_prompt_length_and_picker_filtering() raises:
    """Verify extreme prompt lengths wrap cleanly and slash command picker filters correctly."""
    var composer = AgentPrompt()
    var long_s = String("")
    for _ in range(100):
        long_s += "This is a repeated 32-character "
    composer.input = decode(long_s)

    var rows = composer.input_rows(50)
    assert_true(len(rows) > 30)
    assert_true(to_str(rows[0]).startswith("› "))

    # Verify slash command picker filtering
    var all_cmds = available_slash_commands()
    assert_true(len(all_cmds) >= 5)

    var m_cmds = filter_slash_commands("/m")
    assert_true(len(m_cmds) >= 2)
    assert_true("/model" in m_cmds)
    assert_true("/mode" in m_cmds)


def test_tier2_f34_bound6_multiline_newline_cursor_advances_row_and_resets_col() raises:
    """Verify explicit newline (10) advances cursor row and resets segment column."""
    var composer = AgentPrompt()
    composer.input = decode("first\nsecond")
    composer.cur = 6  # right after '\n', at start of 'second'
    var c_start = composer.calculate_cursor(40, 10, 1, 42, 24)
    assert_equal(c_start[0], 10 + 2)  # 2-col indent on second row

    composer.cur = 9  # after 'sec' on second row
    var c_mid = composer.calculate_cursor(40, 10, 1, 42, 24)
    assert_equal(c_mid[0], 10 + 5)
    assert_equal(c_mid[1], c_start[1])


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
