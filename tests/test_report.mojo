"""Tests for Help > Report a problem (P11-08): the issue text (versions, the terminal's
answers, the last crash, the configuration), what is removed from it (secret-looking
values, the values of program environments, the home folder's path), and the command
writing it to a file, the clipboard and an editor window without sending anything."""
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from std.collections import List
from report import *
from app import *
from appstate import App, M_NORMAL
from commands import CM_REPORT, build_registry
from window import WK_EDITOR
from config import read_text
from signals import own_pid
from util import env_or, run_system, to_str


def test_secret_names_and_values() raises:
    for k in ["token", "api_key", "GITHUB_TOKEN", "password", "client_secret", "key", "auth_header", "openai-key"]:
        assert_true(secret_name(String(k)), String(k))
    for k in ["keymap", "key_hints", "theme", "compiler", "keys", "monkey"]:
        assert_false(secret_name(String(k)), String(k))
    assert_true(secret_value("\"sk-abcdefghijklmnop\""))
    assert_true(secret_value("\"ghp_0123456789abcdefghijklmn\""))
    assert_true(secret_value("\"a8F3kq9Z2mX7pL4vB6nR1tY5\""))           # long and random
    assert_false(secret_value("\"/home/someone/.pixi/envs/default/bin/mojo\""))  # a path
    assert_false(secret_value("\"midnight\""))
    assert_false(secret_value("\"claude-agent-acp --verbose and more words\""))
    assert_false(secret_value("120"))


def test_the_config_is_cleaned() raises:
    var cfg = String("# my settings\n[ui]\ntheme = \"midnight\"\nkeymap = \"modern\"\n\n[tools]\nagent = \"claude-agent-acp\"\napi_key = \"abc\"\nother = \"a8F3kq9Z2mX7pL4vB6nR1tY5\"\n\n[agents.claude.env]\nANTHROPIC_API_KEY = \"whatever\"\nPLAIN = \"x\"\n\n[lsp.rust]\ncommand = \"rust-analyzer\"\nenv = { RUST_LOG = \"debug\", TOKEN = \"t\" }\n")
    var r = redact_config(cfg)
    assert_true(r.find("theme = \"midnight\"") >= 0 and r.find("keymap = \"modern\"") >= 0, r)
    assert_true(r.find("# my settings") == 0)
    assert_true(r.find("agent = \"claude-agent-acp\"") >= 0)
    assert_true(r.find("api_key = \"(removed)\"") >= 0, r)
    assert_true(r.find("other = \"(removed)\"") >= 0, r)
    assert_true(r.find("ANTHROPIC_API_KEY = \"(removed)\"") >= 0 and r.find("PLAIN = \"(removed)\"") >= 0, r)
    assert_true(r.find("command = \"rust-analyzer\"") >= 0, r)
    assert_true(r.find("env = { (values removed) }") >= 0, r)
    for gone in ["abc\"", "a8F3kq9Z", "whatever", "RUST_LOG", "\"t\""]:
        assert_equal(r.find(String(gone)), -1, String(gone))
    assert_equal(home_as_tilde("/home/sam/x and /home/sam/y", "/home/sam"), "~/x and ~/y")
    assert_equal(home_as_tilde("/x", ""), "/x")


def test_the_last_crash() raises:
    var log = String("2026-11-10 13:55:12  error: something small\n/state/crash.log\nTurboMojo 2.0.0  pid 7  started 2026-11-10\nold trace\n2026-11-11  error: between\n/state/crash.log\nTurboMojo 2.1.0  pid 9  started 2026-11-12\nSIGSEGV\n#0 somewhere\n")
    var c = last_crash_entry(log)
    assert_true(c.startswith("TurboMojo 2.1.0  pid 9"), c)
    assert_true(c.find("#0 somewhere") > 0)
    assert_equal(c.find("old trace"), -1)
    # no crash: the last lines; nothing: nothing
    assert_equal(last_crash_entry("a\nb\n"), "a\nb")
    assert_equal(last_crash_entry(""), "")
    var long = String("TurboMojo 2.1.0  pid 1  started x\n")
    for k in range(100):
        long += "line " + String(k) + "\n"
    var cut = last_crash_entry(long, 10)
    assert_true(cut.find("line 8") > 0 and cut.find("line 9\n") < 0 and cut.find("more lines)") > 0, cut)


def test_the_text() raises:
    var caps = List[String]()
    caps.append("colour depth        : 24-bit colour")
    var t = report_text("2.1.0", "Mojo 1.2.0 (x)", "Mojo 1.2.0 (x)", "Linux 6.1 aarch64", "xterm-256color, COLORTERM=truecolor", caps, "", "[ui]\ntheme = \"classic\"")
    assert_true(t.find("Nothing has been sent") > 0)
    assert_true(t.find(REPORT_ISSUES_URL) > 0)
    assert_true(t.find("- TurboMojo 2.1.0, built with Mojo 1.2.0 (x)") > 0)
    assert_true(t.find("- System: Linux 6.1 aarch64") > 0)
    assert_true(t.find("```\ncolour depth        : 24-bit colour\n```") > 0, t)
    assert_true(t.find("## Last crash-log entry\n\n```\n(none)\n```") > 0, t)
    assert_true(t.find("theme = \"classic\"\n```") > 0)


def test_the_command_writes_copies_and_opens_it() raises:
    var d = env_or("TMPDIR", "/tmp") + "/turbomojo-report-" + String(own_pid())
    _ = run_system("rm -rf '" + d + "' && mkdir -p '" + d + "'")
    with open(d + "/config.toml", "w") as f:
        f.write("[ui]\ntheme = \"amber\"\n[tools]\napi_token = \"sk-verysecretvalue123\"\n")
    with open(d + "/crash.log", "w") as f:
        f.write("/x/crash.log\nTurboMojo 2.1.0  pid 4  started now\nSIGSEGV in the test\n")
    var app = App()
    app.scr.resize(100, 30)
    app.cwd = d
    app.config_path = d + "/config.toml"
    app.log_path = d + "/crash.log"
    app.report_path = d + "/out/problem-report.md"
    assert_true(build_registry().index_of_name("help.reportProblem") >= 0)
    app.exec(CM_REPORT)
    var text = read_text(d + "/out/problem-report.md")
    assert_true(text.find("## What happened") >= 0, text)
    assert_true(text.find("theme = \"amber\"") >= 0)
    assert_true(text.find("api_token = \"(removed)\"") >= 0, text)
    assert_equal(text.find("verysecret"), -1)
    assert_true(text.find("SIGSEGV in the test") >= 0)
    assert_true(text.find("(not asked: no terminal)") >= 0)
    assert_equal(to_str(app.clipboard), text)                 # copied
    assert_equal(app.wins[app.top_editor()].path, d + "/out/problem-report.md")   # opened
    assert_true(app.status.find("nothing was sent") >= 0, app.status)
    # again: one window with the new text, not two, nor the old text
    with open(d + "/config.toml", "w") as f:
        f.write("[ui]\ntheme = \"light\"\n")
    app.exec(CM_REPORT)
    assert_true(to_str(app.wins[app.top_editor()].buf.all_text()).find("theme = \"light\"") >= 0)
    var n = 0
    for w in app.wins:
        if w.kind == WK_EDITOR and w.path == d + "/out/problem-report.md":
            n += 1
    assert_equal(n, 1)
    _ = run_system("rm -rf '" + d + "'")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
