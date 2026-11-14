"""Tests for inline agent checkpoints, `CM_AGENT_REVERT`, and `@problems` / `@git` / `@terminal` mentions."""
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from app import *
from problems import Problem, PS_BUILD, SEV_ERROR
from signals import own_pid


def test_agent_virtual_mentions_in_blocks() raises:
    var tmp = "/tmp/tmide-test-agent-ctx-" + String(own_pid())
    _ = run_system("rm -rf " + shell_quote(tmp) + " && mkdir -p " + shell_quote(tmp))

    var app = App()
    app.cwd = tmp
    app.project_dir = tmp
    # Populate a build error in prob_build so problems_collect() reports it
    app.prob_build.append(Problem(PS_BUILD, SEV_ERROR, tmp + "/src/foo.mojo", 4, 5, "unknown identifier 'bar'"))

    var blocks = app.agent_blocks("Please inspect @problems and @terminal and @git")
    assert_true(blocks.find("unknown identifier") >= 0 or blocks.find("foo.mojo") >= 0)
    assert_true(blocks.find("Context (@terminal)") >= 0 or blocks.find("turbomojo://context/terminal") >= 0)
    assert_true(blocks.find("Context (@git)") >= 0 or blocks.find("turbomojo://context/git") >= 0)

    # With embedded_context = True, emits ACP resource blocks
    app.agent.embedded_context = True
    var res_blocks = app.agent_blocks("Check @problems")
    assert_true(res_blocks.find("turbomojo://context/problems") >= 0)

    _ = run_system("rm -rf " + shell_quote(tmp))


def test_agent_checkpoint_and_revert_turn() raises:
    var tmp = "/tmp/tmide-test-agent-snap-" + String(own_pid())
    _ = run_system("rm -rf " + shell_quote(tmp) + " && mkdir -p " + shell_quote(tmp))
    var existing = tmp + "/mod.mojo"
    var created = tmp + "/added.mojo"
    _ = write_file(existing, str_bytes("def orig() -> Int:\n    return 1\n"))

    var app = App()
    app.cwd = tmp
    app.project_dir = tmp
    app.open_path(existing)

    # Snapshot pre-turn state
    app.agent_snapshot_turn()

    # Simulate agent modifying existing file (both buffer and disk) and creating a new file
    var ei = app.find_editor(existing)
    assert_true(ei >= 0)
    app.replace_text_min(ei, decode("def orig() -> Int:\n    return 999\n"))
    _ = app.save_window(ei, NEXT_NONE)
    _ = write_file(created, str_bytes("def brand_new():\n    pass\n"))

    app.agent_finish_turn_checkpoint()
    assert_equal(len(app.agent_changed_files), 2)

    # Revert the turn via CM_AGENT_REVERT
    app.exec(CM_AGENT_REVERT)
    assert_false(path_exists(created))
    assert_equal(read_text(existing), "def orig() -> Int:\n    return 1\n")
    assert_equal(to_str(app.wins[ei].buf.all_text()), "def orig() -> Int:\n    return 1\n")
    assert_equal(len(app.agent_changed_files), 0)

    _ = run_system("rm -rf " + shell_quote(tmp))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
