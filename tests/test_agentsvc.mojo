"""Tests for the editor's services to a coding agent (src/agentsvc.mojo,
src/app_agentsvc.mojo): output cleaning, and in the IDE with the scripted agent reads
through the editor, proposed writes accepted and rejected in the diff view, and
commands run in terminals after a yes."""
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from std.collections import List
from std.time import perf_counter_ns
from agentsvc import *
from agentchat import *
from acp import AS_READY
from term import wait_readable, key_event, KEY_ENTER, KEY_ESC
from app import *
from appstate import App, now_ns, M_NORMAL
from window import WK_EDITOR, WK_AGENT, WK_DIFF
from commands import CM_AGENT, CM_UNDO
from signals import own_pid
from util import env_or, run_system, shell_quote, write_file, str_bytes, decode, to_str, getcwd, read_file, bytes_to_str, path_exists

comptime MS = 1000000


def test_output_cleaning() raises:
    var raw = str_bytes("\x1b[1;32mok\x1b[0m\r\nnext\r\n\x1b]0;title\x07done\rx")
    assert_equal(bytes_to_str(clean_output(raw)), "ok\nnext\ndonex")
    var b = str_bytes("abcdé")                     # é is two bytes
    assert_true(keep_last(b, 2))
    assert_equal(bytes_to_str(b), "é")
    var c = str_bytes("abcdé")
    assert_true(keep_last(c, 1))                    # not half a character
    assert_equal(len(c), 0)
    assert_false(keep_last(c, 10))
    assert_equal(tail_lines("a\nb\nc\n", 2), "b\nc")


def scratch(tag: String) -> String:
    var d = env_or("TMPDIR", "/tmp") + "/turbomojo-agentsvc-" + String(own_pid()) + "-" + tag
    _ = run_system("rm -rf " + shell_quote(d) + " && mkdir -p " + shell_quote(d))
    return d


def agent_cmd(log: String) -> String:
    return "python3 " + shell_quote(getcwd() + "/tests/helpers/fake_acp_agent.py") + " " + shell_quote(log)


def md(app: App) -> String:
    return app.chat.markdown(app.agent.agent_name)


def pump(mut app: App, until: String, idle: Bool = True, ms: Int = 10000) raises:
    var end = Int(perf_counter_ns()) + ms * MS
    while Int(perf_counter_ns()) < end:
        var fds = List[Int]()
        if app.agent.fd() >= 0:
            fds.append(app.agent.fd())
        for f in app.agent_term_fds():
            fds.append(f)
        _ = wait_readable(fds, 20)
        app.agent_tick(now_ns())
        if md(app).find(until) >= 0 and not (idle and app.agent.busy()):
            app.draw()
            return
    assert_true(False, "the conversation never had \"" + until + "\":\n" + md(app))


def say(mut app: App, text: String) raises:
    for c in decode(text):
        app.handle(key_event(c))
    app.handle(key_event(KEY_ENTER))


def ide(d: String) raises -> App:
    var app = App()
    app.scr.resize(120, 34)
    app.cwd = d
    app.project_dir = d
    _ = write_file(d + "/a.mojo", str_bytes("one\ntwo\nthree\n"))
    app.open_path(d + "/a.mojo")
    app.agent_command = agent_cmd(d + "/log")
    app.exec(CM_AGENT)
    pump(app, "Connected")
    return app^


def test_reads_go_through_the_editor() raises:
    var d = scratch("read")
    var app = ide(d)
    # the capabilities say the editor offers files and terminals now
    var log = bytes_to_str(read_file(d + "/log"))
    assert_true(log.find("\"readTextFile\":true") > 0 and log.find("\"terminal\":true") > 0, log)
    var ei = app.find_editor(d + "/a.mojo")
    app.wins[ei].buf.load(decode("one\nTWO (not saved)\nthree\n"))
    app.focus(app.agent_index())
    say(app, "readfile " + d + "/a.mojo")
    pump(app, "read: one")
    assert_true(md(app).find("read: one\nTWO (not saved)\nthree") > 0, md(app))
    say(app, "readlines " + d + "/a.mojo")
    pump(app, "lines: TWO (not saved)")
    # outside the project, or missing: refused with a reason
    say(app, "readfile /etc/hostname")
    pump(app, "read error: TurboMojo only gives the agent files of the project")
    say(app, "readfile " + d + "/missing.mojo")
    pump(app, "read error: no such file")
    app.agent.stop()
    _ = run_system("rm -rf " + shell_quote(d))


def test_writes_are_proposed_and_accepted_or_rejected() raises:
    var d = scratch("write")
    var app = ide(d)
    say(app, "write " + d + "/a.mojo one\\nTWO\\nthree\\nfour\\n")
    pump(app, "The agent proposes changes to a.mojo", False)
    # the diff view shows the proposal; nothing is written yet
    var di = app.gd_index()
    assert_true(di >= 0)
    assert_equal(app.top(), di)
    assert_true(app.gd_proposal)
    assert_equal(app.wins[di].title, "Proposed: a.mojo")
    var rows = String("")
    for r in range(app.wins[di].buf.count()):
        rows += to_str(app.wins[di].buf.line(r)) + "\n"
    assert_true(rows.find("-two\n+TWO\n") > 0 and rows.find("+four") > 0, rows)
    assert_equal(bytes_to_str(read_file(d + "/a.mojo")), "one\ntwo\nthree\n")
    assert_true(app.agent.busy())                   # the agent waits for the answer
    # A: into the editor (one undo step) and saved
    app.handle(key_event(97))
    pump(app, "write: ok")
    assert_equal(bytes_to_str(read_file(d + "/a.mojo")), "one\nTWO\nthree\nfour\n")
    assert_equal(app.gd_index(), -1)
    var ei = app.find_editor(d + "/a.mojo")
    app.focus(ei)
    app.exec(CM_UNDO)
    assert_equal(to_str(app.wins[app.find_editor(d + "/a.mojo")].buf.all_text()), "one\ntwo\nthree\n")
    # R: the agent is told; a new file is not made
    app.focus(app.agent_index())
    say(app, "write " + d + "/new.mojo hello\\n")
    pump(app, "proposes a new file new.mojo", False)
    assert_true(app.wins[app.gd_index()].title.startswith("Proposed new file: new.mojo"))
    app.handle(key_event(114))
    pump(app, "write refused: the user rejected the change")
    assert_false(path_exists(d + "/new.mojo"))
    # Esc leaves it proposed; Enter in the empty prompt shows it again; then accepted
    say(app, "write " + d + "/new.mojo hello\\n")
    pump(app, "proposes a new file new.mojo", False)
    app.handle(key_event(KEY_ESC))
    assert_equal(app.gd_index(), -1)
    assert_equal(app.wins[app.top()].kind, WK_AGENT)
    app.handle(key_event(KEY_ENTER))
    assert_true(app.gd_index() >= 0)
    app.handle(key_event(65))
    pump(app, "Accepted the change to new.mojo")
    assert_equal(bytes_to_str(read_file(d + "/new.mojo")), "hello\n")
    # outside the project: refused without a question
    app.focus(app.agent_index())
    say(app, "write /tmp/elsewhere-" + String(own_pid()) + ".txt x")
    pump(app, "write refused: TurboMojo only lets the agent write files of the project")
    assert_false(path_exists("/tmp/elsewhere-" + String(own_pid()) + ".txt"))
    app.agent.stop()
    _ = run_system("rm -rf " + shell_quote(d))


def test_commands_run_after_a_yes() raises:
    var d = scratch("run")
    var app = ide(d)
    say(app, "run echo hello $FAKE_AGENT_VAR; pwd; exit 3")
    pump(app, "Y runs it, A always (this session), N refuses", False)
    # the question names the command as the agent wrote it, not "sh -c"
    assert_true(md(app).find("The agent wants to run `echo hello $FAKE_AGENT_VAR; pwd; exit 3` in " + d) > 0, md(app))
    assert_equal(app.agent_asks[0].title, "echo hello $FAKE_AGENT_VAR; pwd; exit 3")
    app.draw()
    var scr = to_str(app.scr.to_text())
    assert_true(scr.find("› ") < 0)                  # the prompt gives way to the question
    assert_true(scr.find("Run `echo hello") > 0, scr)
    assert_equal(len(app.agent_asks), 1)
    # typing is not taken while the question is open
    app.handle(key_event(120))
    assert_equal(len(app.agent_input), 0)
    app.handle(key_event(121))                      # y
    pump(app, "released: True")
    var m = md(app)
    assert_true(m.find("exit 3 truncated False: hello set\n" + d + "\n|") > 0, m)
    assert_true(m.find("*(exit 3)*") > 0, m)        # the conversation shows the command's end
    # a long output keeps only its end (64 bytes), at a character boundary
    say(app, "run seq 1 100")
    pump(app, "Y runs it", False)
    app.handle(key_event(89))
    pump(app, "truncated True")
    assert_true(md(app).find("100\n|") > 0)
    # N: refused
    say(app, "run echo no")
    pump(app, "Y runs it", False)
    app.handle(key_event(110))
    pump(app, "run refused: the user did not allow the command")
    # kill
    say(app, "killrun")
    pump(app, "Y runs it", False)
    app.handle(key_event(121))
    # SIGHUP, or SIGKILL when it is not gone within half a second (a busy machine)
    pump(app, "before kill: False; signal SIG")
    assert_true(md(app).find("signal SIGHUP") > 0 or md(app).find("signal SIGKILL") > 0, md(app))
    assert_equal(len(app.agent_terms), 0)           # released
    app.agent.stop()
    _ = run_system("rm -rf " + shell_quote(d))


def test_auto_and_accept_edits_modes() raises:
    var d = scratch("automode")
    var app = App()
    app.scr.resize(120, 34)
    app.cwd = d
    app.project_dir = d
    app.agent_mode = "auto"
    _ = write_file(d + "/a.mojo", str_bytes("one\ntwo\n"))
    app.open_path(d + "/a.mojo")
    app.agent_command = agent_cmd(d + "/log")
    app.exec(CM_AGENT)
    pump(app, "Connected")
    # in auto mode, writes apply hands-free without opening a proposal diff, yet keep single-step Undo
    say(app, "write " + d + "/a.mojo one\\nAUTO\\n")
    pump(app, "write: ok")
    assert_equal(app.gd_index(), -1)
    assert_equal(bytes_to_str(read_file(d + "/a.mojo")), "one\nAUTO\n")
    var ei = app.find_editor(d + "/a.mojo")
    app.focus(ei)
    app.exec(CM_UNDO)
    assert_equal(to_str(app.wins[app.find_editor(d + "/a.mojo")].buf.all_text()), "one\ntwo\n")
    # in auto mode, terminal commands and permission requests run hands-free
    app.focus(app.agent_index())
    say(app, "run echo handsfree")
    pump(app, "exit 0 truncated False: handsfree")
    assert_equal(len(app.agent_asks), 0)
    say(app, "permrun")
    pump(app, "told: selected yes")
    assert_equal(len(app.agent_perms), 0)
    # in accept-edits mode, edits go in automatically while commands still ask
    app.agent_mode = "accept-edits"
    _ = app.agent.set_mode("accept-edits", now_ns())
    pump(app, "Mode: Accept Edits")
    say(app, "write " + d + "/a.mojo edited\\n")
    pump(app, "write: ok")
    assert_equal(bytes_to_str(read_file(d + "/a.mojo")), "edited\n")
    say(app, "run echo askme")
    pump(app, "The agent wants to run `echo askme`", False)
    assert_equal(len(app.agent_asks), 1)
    app.handle(key_event(110))
    pump(app, "run refused")
    app.agent.stop()
    _ = run_system("rm -rf " + shell_quote(d))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
