"""Tests for grounded "explain" requests to the agent (P7-13, src/agentexplain.mojo,
src/app_agentexplain.mojo): the prompt carries the numbered code, the message, the
built-in explanation and the documentation of the names, with the rules for the
answer; the chat shows one line; the answer's imports are built with the installed
Mojo and a made-up one is reported. The agent is tests/helpers/fake_acp_agent.py."""
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from std.collections import List
from std.time import perf_counter_ns
from agentexplain import *
from agentchat import CE_USER, CE_NOTE
from problems import Problem, PS_BUILD, SEV_ERROR
from term import wait_readable
from commands import CM_AGENT_EXPLAIN, CM_AGENT_EXPLAIN_CODE, CM_AGENT_PROBLEMS
from app import *
from appstate import App, now_ns
from signals import own_pid
from util import env_or, run_system, shell_quote, write_file, str_bytes, getcwd, which, read_file, bytes_to_str, path_exists

comptime MS = 1000000
comptime STD_JSON = "{\"decl\": {\"kind\": \"package\", \"name\": \"std\", \"summary\": \"\", \"description\": \"\", \"modules\": [{\"kind\": \"module\", \"name\": \"__init__\", \"summary\": \"The standard library.\", \"description\": \"\"}], \"packages\": [{\"kind\": \"package\", \"name\": \"collections\", \"summary\": \"\", \"description\": \"\", \"packages\": [], \"modules\": [{\"kind\": \"module\", \"name\": \"list\", \"summary\": \"Defines the List type.\", \"description\": \"Imported automatically.\", \"aliases\": [], \"traits\": [], \"functions\": [{\"name\": \"make_list\", \"overloads\": [{\"signature\": \"def make_list(n: Int) -> List[Int]\", \"summary\": \"Makes a list.\", \"description\": \"\", \"deprecated\": \"\", \"args\": [{\"name\": \"n\", \"type\": \"Int\", \"description\": \"How many.\"}], \"parameters\": [], \"returns\": {\"type\": \"List[Int]\", \"doc\": \"The list.\"}, \"raisesDoc\": \"\"}]}, {\"name\": \"append\", \"overloads\": [{\"signature\": \"def append(a: List[Int], b: Int)\", \"summary\": \"Appends to a list.\", \"description\": \"\", \"deprecated\": \"\", \"args\": [], \"parameters\": [], \"raisesDoc\": \"\"}]}], \"structs\": [{\"kind\": \"struct\", \"name\": \"List\", \"signature\": \"struct List[T: AnyType, /]\", \"summary\": \"A resizable list.\", \"description\": \"Grows as needed.\", \"deprecated\": \"\", \"aliases\": [], \"fields\": [{\"name\": \"capacity\", \"type\": \"Int\", \"summary\": \"Room.\", \"description\": \"\"}], \"parameters\": [{\"name\": \"T\", \"type\": \"AnyType\", \"description\": \"The element type.\"}], \"parentTraits\": [{\"name\": \"Sized\"}, {\"name\": \"Copyable\"}], \"functions\": [{\"name\": \"append\", \"overloads\": [{\"signature\": \"def append(mut self, var value: T)\", \"summary\": \"Appends a value.\", \"description\": \"\", \"deprecated\": \"\", \"args\": [], \"parameters\": [], \"raisesDoc\": \"\"}]}]}]}, {\"kind\": \"module\", \"name\": \"empty\", \"summary\": \"\", \"description\": \"\", \"aliases\": [], \"structs\": [], \"traits\": [], \"functions\": []}]}]}, \"version\": \"1.2\"}"


def test_the_pieces() raises:
    var n = names_in("cannot implicitly convert 'List[Int]' value to 'Int' in def f(x: Str)")
    assert_equal(n[0], "List")                     # the quoted ones first
    assert_equal(n[1], "Int")
    assert_true("cannot" in n and "Str" in n)
    assert_false("def" in n)                       # keywords left out
    var lines = List[String]()
    lines.append("def main():")
    lines.append("    pass")
    assert_equal(numbered(lines, 7), "7: def main():\n8:     pass\n")
    var ans = "Try:\n\n```mojo\nfrom std.collections import List\nimport std.os\nvar x = 1\nfrom std.collections import List\n```\n\nfrom nowhere import x (prose)\n"
    var im = answer_imports(ans)
    assert_equal(len(im), 2)                       # in code only, each once
    assert_equal(im[1], "import std.os")
    assert_true(import_check_program(im).startswith("from std.collections import List\nimport std.os\n"))
    var bad = failed_import_lines("/d/check.mojo:2:6: error: unable to locate module 'nope'\n/d/check.mojo:2:6: note: x\n/d/check.mojo:4:1: error: y\n", "check.mojo")
    assert_equal(len(bad), 2)
    assert_equal(bad[0], 2)
    assert_equal(bad[1], 4)
    var ex = List[String]()
    ex.append(doc_excerpt("list - struct List", "## struct `List`\n\nA list."))
    var p = explain_error_prompt("use of unknown declaration 'x'", "a.mojo:3", "3: print(x)\n", "# Unknown name\n\nText.", ex)
    assert_true(p.startswith("Explain this Mojo compiler error"))
    assert_true(p.find("[page: title]") > 0 and p.find("there is no `fn`") > 0)
    assert_true(p.find("### Page: TurboMojo's explanation of this message") > 0)
    assert_true(p.find("### Page: list - struct List") > 0)
    var long = String("x") * (EXCERPT_MAX * 2)
    assert_true(doc_excerpt("t", long).byte_length() < EXCERPT_MAX + 40)


def pump(mut app: App, until: String, ms: Int = 60000) raises:
    var end = Int(perf_counter_ns()) + ms * MS
    while Int(perf_counter_ns()) < end:
        var fds = List[Int]()
        if app.agent.fd() >= 0:
            fds.append(app.agent.fd())
        _ = wait_readable(fds, 20)
        app.agent_tick(now_ns())
        if app.chat.markdown(app.agent.agent_name).find(until) >= 0 and not app.agent.busy():
            return
    assert_true(False, "the conversation never had \"" + until + "\":\n" + app.chat.markdown(app.agent.agent_name))


def ide(d: String) raises -> App:
    _ = run_system("mkdir -p " + shell_quote(d + "/docs"))
    _ = write_file(d + "/docs/std.docs.json", str_bytes(STD_JSON))
    _ = write_file(d + "/a.mojo", str_bytes("def main():\n    var l = List[Int]()\n    var n: Int = l\n    print(n)\n"))
    var app = App()
    app.scr.resize(120, 34)
    app.cwd = d
    app.project_dir = d
    app.doc_home = d + "/docs"
    app.open_path(d + "/a.mojo")
    app.agent_command = "python3 " + shell_quote(getcwd() + "/tests/helpers/fake_acp_agent.py") + " " + shell_quote(d + "/log")
    return app^


def notes(app: App) -> String:
    var s = String("")
    for e in app.chat.entries:
        if e.kind == CE_NOTE:
            s += e.text + "\n"
    return s^


def test_explain_an_error_with_local_help() raises:
    var d = env_or("TMPDIR", "/tmp") + "/turbomojo-agentexplain-" + String(own_pid())
    _ = run_system("rm -rf " + shell_quote(d) + " && mkdir -p " + shell_quote(d))
    var app = ide(d)
    app.prob_build.append(Problem(PS_BUILD, SEV_ERROR, d + "/a.mojo", 3, 18, "cannot implicitly convert 'List[Int]' value to 'Int'"))
    app.wins[app.top()].goto(2, 4)                 # on the line of the problem
    app.exec(CM_AGENT_EXPLAIN)
    pump(app, "NoSuchThing")
    var md = app.chat.markdown(app.agent.agent_name)
    # the chat shows one line, the agent got all of it
    var shown = String("")
    for e in app.chat.entries:
        if e.kind == CE_USER:
            shown = e.text
    assert_true(shown.startswith("Explain this error: a.mojo:3: cannot implicitly convert"), shown)
    assert_true(shown.find("[with 2 page(s) of local help]") > 0, shown)    # the explanation and List's page
    assert_true(md.find("pages given: 2; rules: True; numbered: True") >= 0, md)
    if which("mojo").byte_length() > 0:
        var n = notes(app)
        assert_true(n.find("✗ Not in the installed Mojo: `from std.collections import NoSuchThing`") >= 0, n)
        assert_true(n.find("import List`") < 0, n)                      # the real one is fine
    assert_false(app.agent_explaining)
    # this code: the function the cursor is in
    app.focus(app.find_editor(d + "/a.mojo"))
    app.wins[app.top()].goto(1, 4)
    app.exec(CM_AGENT_EXPLAIN_CODE)
    pump(app, "Explain this code: a.mojo:1-4")
    # send diagnostics to agent + live ide-state.json export
    app.ide_state_path = d + "/ide-state.json"
    app.problems_show(False)
    assert_true(path_exists(d + "/ide-state.json"))
    var state_json = bytes_to_str(read_file(d + "/ide-state.json"))
    assert_true(state_json.find("cannot implicitly convert") > 0, state_json)
    app.exec(CM_AGENT_PROBLEMS)
    pump(app, "Send diagnostics to agent: 1 problem(s)")
    _ = app.agent.stop()
    _ = run_system("rm -rf " + shell_quote(d))


def test_nothing_to_explain() raises:
    var app = App()
    app.scr.resize(100, 30)
    app.open_path("/nowhere/x.mojo")
    app.exec(CM_AGENT_EXPLAIN)
    assert_true(app.status.find("Put the cursor on a line with a problem") >= 0, app.status)
    assert_equal(app.agent_index(), -1)            # no panel for nothing


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
