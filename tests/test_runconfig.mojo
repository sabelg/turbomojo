"""Run configurations: reading and writing them in the project file, the command they
make, and choosing and editing them in the application."""
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from std.collections import List
from runconfig import *
from toml import toml_parse
from term import key_event, KEY_ENTER, KEY_ESC
from app import *
from appstate import App, M_NORMAL, M_DIALOG
from dialog import D_RUNCFGS, D_RUNCFG
from commands import CM_RUNCONFIGS
from config import load_settings, read_text
from signals import own_pid
from util import decode, to_str, env_or, run_system, run_capture, bytes_to_str


def scratch(tag: String) -> String:
    var d = env_or("TMPDIR", "/tmp") + "/turbomojo-runcfg-" + String(own_pid()) + "-" + tag
    _ = run_system("rm -rf '" + d + "' && mkdir -p '" + d + "' && printf 'root = true\\n' > '" + d + "/.editorconfig'")
    return d


def put(path: String, text: String) raises:
    with open(path, "w") as f:
        f.write(text)


def sample() -> RunConfig:
    var c = RunConfig("demo")
    c.file = "src/main.mojo"
    c.args = "--fast \"two words\""
    c.env.append("MODE=debug")
    c.env.append("GREETING=hello world")
    c.cwd = "data"
    c.build = True
    return c^


def describe(c: RunConfig) -> String:
    var s = c.name + "|" + c.file + "|" + c.args + "|"
    for e in c.env:
        s += e + ";"
    return s + "|" + c.cwd + "|" + ("build" if c.build else "run")


def test_configurations_are_written_and_read_back() raises:
    var text = "# my project\n[editor]\ntab_width = 4\n"
    text = save_run_config(text, sample())
    assert_equal(text, "# my project\n[editor]\ntab_width = 4\n\n[run.demo]\nfile = \"src/main.mojo\"\nargs = \"--fast \\\"two words\\\"\"\nenv = [\"MODE=debug\", \"GREETING=hello world\"]\ncwd = \"data\"\nbuild = true\n")
    var plain = RunConfig("plain")
    text = save_run_config(text, plain)
    text = set_active_config(text, "demo")
    var doc = toml_parse(text)
    assert_equal(len(doc.problems), 0)
    var got = load_run_configs(doc)
    assert_equal(len(got), 2)
    assert_equal(describe(got[0]), describe(sample()))
    assert_equal(describe(got[1]), "plain|||||run")
    assert_equal(active_run_config(doc), "demo")
    assert_equal(doc.get_int("editor.tab_width", 0), 4)          # the rest of the file is untouched
    # saving again under the same name replaces, it does not add
    var changed = sample()
    changed.args = ""
    changed.build = False
    changed.env.clear()
    text = save_run_config(text, changed)
    got = load_run_configs(toml_parse(text))
    assert_equal(len(got), 2)
    var demo = got[0].copy() if got[0].name == "demo" else got[1].copy()
    assert_equal(describe(demo), "demo|src/main.mojo|||data|run")
    # removing
    text = remove_table(text, "run.plain")
    got = load_run_configs(toml_parse(text))
    assert_equal(len(got), 1)
    assert_equal(got[0].name, "demo")
    assert_true(text.find("tab_width = 4") > 0)
    assert_equal(active_run_config(toml_parse(text)), "demo")
    assert_equal(len(load_run_configs(toml_parse(""))), 0)
    assert_equal(remove_table("[a]\nx = 1\n", "b"), "[a]\nx = 1\n")


def test_names_and_environment_are_checked() raises:
    assert_equal(config_name_problem("debug-1_x"), "")
    assert_equal(config_name_problem(""), "A name is needed")
    assert_true(config_name_problem("two words").find("letters, digits") > 0)
    assert_true(config_name_problem("a.b").find("letters, digits") > 0)
    assert_true(config_name_problem("active").find("choose another") > 0)
    var e = parse_env("A=1  B_2='two words' C=\"x y\" EMPTY=")
    assert_equal(e[1], "")
    assert_equal(len(e[0]), 4)
    assert_equal(e[0][1], "B_2=two words")
    assert_equal(e[0][2], "C=x y")
    assert_equal(e[0][3], "EMPTY=")
    assert_equal(env_text(e[0]), "A=1 B_2=\"two words\" C=\"x y\" EMPTY=\"\"")
    assert_equal(parse_env(env_text(e[0]))[0][1], "B_2=two words")       # round trip
    assert_equal(len(parse_env("")[0]), 0)
    assert_true(parse_env("JUSTAWORD")[1].find("has no =") > 0)
    assert_true(parse_env("1A=x")[1].find("cannot be the name") > 0)
    assert_true(parse_env("A-B=x")[1].find("cannot be the name") > 0)
    assert_true(parse_env("A='open")[1].find("not closed") > 0)


def test_the_command_a_configuration_makes() raises:
    var c = RunConfig("x")
    # nothing set: the file being edited, in its folder, with `mojo run`
    assert_equal(run_core_command(c, "/proj", "/proj/src/a.mojo", "mojo", ""), "cd '/proj/src' && mojo run '/proj/src/a.mojo'")
    assert_equal(run_core_command(c, "/proj", "", "mojo", ""), "")           # no file at all
    var full = sample()
    assert_equal(run_core_command(full, "/proj", "/proj/other.mojo", "mojo", " -I '/inc'"), "cd '/proj/data' && export MODE='debug' && export GREETING='hello world' && mkdir -p '/proj/src/build' && mojo build -I '/inc' '/proj/src/main.mojo' -o '/proj/src/build/main' && '/proj/src/build/main' --fast \"two words\"")
    # an absolute file and folder are taken as they are
    c.file = "/elsewhere/p.mojo"
    c.cwd = "/tmp/x"
    assert_equal(run_core_command(c, "/proj", "/proj/a.mojo", "mojo", ""), "cd '/tmp/x' && mojo run '/elsewhere/p.mojo'")
    c.gpu_sync = True
    assert_true(run_core_command(c, "/proj", "/proj/a.mojo", "mojo", "").find("MODULAR_DEVICE_CONTEXT_SYNC_MODE=true") >= 0)
    var saved_sync = save_run_config("", c)
    var parsed_sync = load_run_configs(toml_parse(saved_sync))
    assert_true(len(parsed_sync) == 1 and parsed_sync[0].gpu_sync)


def test_the_command_really_runs_with_environment_folder_and_arguments() raises:
    var d = scratch("exec")
    _ = run_system("mkdir -p '" + d + "/data' '" + d + "/src'")
    put(d + "/src/main.mojo", "x\n")
    # a stand-in compiler: "run FILE ARGS" prints what it sees; "build FILE -o EXE" writes a script that does
    put(d + "/fakemojo", "#!/bin/sh\nif [ \"$1\" = build ]; then printf '#!/bin/sh\\necho \"built in $(pwd) MODE=$MODE GREETING=$GREETING args=$*\"\\n' > \"$4\"; chmod +x \"$4\"; echo compiled; exit 0; fi\necho \"ran $2 in $(pwd) MODE=$MODE args=$3,$4\"\n")
    _ = run_system("chmod +x '" + d + "/fakemojo'")
    var c = sample()
    var out = bytes_to_str(run_capture(run_core_command(c, d, "", d + "/fakemojo", "") + " 2>&1").out)
    assert_equal(out, "compiled\nbuilt in " + d + "/data MODE=debug GREETING=hello world args=--fast two words\n")
    c.build = False
    out = bytes_to_str(run_capture(run_core_command(c, d, "", d + "/fakemojo", "") + " 2>&1").out)
    assert_equal(out, "ran " + d + "/src/main.mojo in " + d + "/data MODE=debug args=--fast,two words\n")
    _ = run_system("rm -rf '" + d + "'")


# ------------------------------------------------------- in the application
def cfg_app(d: String) raises -> App:
    _ = run_system("mkdir -p '" + d + "/src' '" + d + "/data'")
    put(d + "/src/main.mojo", "def main(): pass\n")
    put(d + "/src/tool.mojo", "def main(): pass\n")
    var app = App()
    app.scr.resize(100, 30)
    app.cwd = d
    app.compiler = d + "/mojo-stand-in"
    app.open_path(d + "/src/main.mojo")
    return app^


def set_field(mut app: App, k: Int, text: String):
    app.dlg.fields[k].text = decode(text)


def test_run_uses_the_file_in_front_until_a_configuration_is_made() raises:
    var d = scratch("app1")
    var app = cfg_app(d)
    var core = app.run_core(False)
    assert_true(core.startswith("cd '" + d + "/src' && "), core)
    assert_true(core.endswith(" run '" + d + "/src/main.mojo'"), core)
    app.run_args = "one two"
    assert_true(app.run_core(False).endswith(" run '" + d + "/src/main.mojo' one two"), app.run_core(False))
    app.run_args = ""
    # the list has only the entry for the file in front
    app.exec(CM_RUNCONFIGS)
    assert_equal(app.mode, M_DIALOG)
    assert_equal(app.dlg.kind, D_RUNCFGS)
    assert_equal(len(app.dlg.items), 1)
    assert_true(app.dlg.items[0].startswith("• (the file being edited)"), app.dlg.items[0])
    # New: the dialog starts from the file in front
    app.dialog_button(2)
    assert_equal(app.dlg.kind, D_RUNCFG)
    assert_equal(app.dlg.field_text(0), "main")
    assert_equal(app.dlg.field_text(1), "src/main.mojo")
    set_field(app, 0, "fast")
    set_field(app, 2, "--fast 3")
    set_field(app, 3, "MODE=quick NAME='two words'")
    set_field(app, 4, "data")
    app.dlg.check_vals[0] = True
    app.dialog_button(0)
    assert_equal(app.mode, M_NORMAL)
    assert_equal(app.status, "Saved the configuration fast - Run uses it now")
    # written to the project's file
    assert_equal(read_text(d + "/.turbomojo.toml"), "[run.fast]\nfile = \"src/main.mojo\"\nargs = \"--fast 3\"\nenv = [\"MODE=quick\", \"NAME=two words\"]\ncwd = \"data\"\nbuild = true\n\n[run]\nactive = \"fast\"\n")
    assert_equal(len(load_settings("", read_text(d + "/.turbomojo.toml")).warnings), 0)      # not taken for a typo
    # Run now does what the configuration says, whatever file is in front
    app.open_path(d + "/src/tool.mojo")
    core = app.run_core(False)
    assert_true(core.startswith("cd '" + d + "/data' && export MODE='quick' && export NAME='two words' && mkdir -p '" + d + "/src/build' && "), core)
    assert_true(core.endswith(" build '" + d + "/src/main.mojo' -o '" + d + "/src/build/main' && '" + d + "/src/build/main' --fast 3"), core)
    # Test still runs the file in front
    assert_true(app.run_core(True).endswith(" run '" + d + "/src/tool.mojo'"), app.run_core(True))
    # another start of the IDE in this project finds it
    var again = App()
    again.cwd = d
    again.run_configs_load()
    assert_equal(again.run_active, "fast")
    assert_equal(len(again.run_cfgs), 1)
    _ = run_system("rm -rf '" + d + "'")


def test_configurations_are_checked_selected_renamed_and_deleted() raises:
    var d = scratch("app2")
    var app = cfg_app(d)
    # what cannot be saved is said and nothing is written
    app.exec(CM_RUNCONFIGS)
    app.dialog_button(2)
    set_field(app, 0, "two words")
    app.dialog_button(0)
    assert_true(app.status.find("letters, digits") > 0, app.status)
    app.exec(CM_RUNCONFIGS)
    app.dialog_button(2)
    set_field(app, 3, "NOEQUALS")
    app.dialog_button(0)
    assert_true(app.status.find("has no =") > 0, app.status)
    app.exec(CM_RUNCONFIGS)
    app.dialog_button(2)
    set_field(app, 1, "src/missing.mojo")
    app.dialog_button(0)
    assert_equal(app.status, "The file src/missing.mojo does not exist")
    app.exec(CM_RUNCONFIGS)
    app.dialog_button(2)
    set_field(app, 4, "no_such_folder")
    app.dialog_button(0)
    assert_equal(app.status, "The folder no_such_folder does not exist")
    assert_equal(read_text(d + "/.turbomojo.toml"), "")
    # two configurations
    app.exec(CM_RUNCONFIGS)
    app.dialog_button(2)
    app.dialog_button(0)                                 # as offered: "main"
    app.exec(CM_RUNCONFIGS)
    app.dialog_button(2)
    set_field(app, 0, "tool")
    set_field(app, 1, "src/tool.mojo")
    app.dialog_button(0)
    assert_equal(app.run_active, "main")                 # the first stays the one in use
    app.exec(CM_RUNCONFIGS)
    app.dialog_button(2)
    set_field(app, 0, "tool")
    app.dialog_button(0)
    assert_equal(app.status, "There is a configuration called tool already")
    # select the second in the list
    app.exec(CM_RUNCONFIGS)
    assert_equal(len(app.dlg.items), 3)
    assert_true(app.dlg.items[1].startswith("• main"), app.dlg.items[1])
    assert_equal(app.dlg.selected_item(), 1)             # the list opens on the active one
    app.run_configs_button(0, 2)
    app.mode = M_NORMAL
    assert_equal(app.status, "Run now uses the configuration tool")
    assert_true(app.run_core(False).endswith(" run '" + d + "/src/tool.mojo'"), app.run_core(False))
    # edit: rename the active one - it stays active, the old table is gone
    app.exec(CM_RUNCONFIGS)
    app.run_configs_button(1, 2)
    assert_equal(app.dlg.kind, D_RUNCFG)
    assert_equal(app.dlg.field_text(0), "tool")
    set_field(app, 0, "helper")
    set_field(app, 2, "-v")
    app.dialog_button(0)
    assert_equal(app.run_active, "helper")
    assert_equal(len(app.run_cfgs), 2)
    assert_true(read_text(d + "/.turbomojo.toml").find("[run.tool]") < 0)
    assert_true(app.run_core(False).endswith(" run '" + d + "/src/tool.mojo' -v"), app.run_core(False))
    # delete it: Run falls back to the file in front
    app.exec(CM_RUNCONFIGS)
    var sel = 1 if app.dlg.items[1].find("helper") > 0 else 2
    app.run_configs_button(3, sel)
    app.mode = M_NORMAL
    assert_equal(app.status, "Deleted the configuration helper")
    assert_equal(app.run_active, "")
    assert_equal(len(app.run_cfgs), 1)
    assert_true(app.run_core(False).endswith(" run '" + d + "/src/main.mojo'"), app.run_core(False))
    # the first entry can be selected, not edited or deleted
    app.exec(CM_RUNCONFIGS)
    app.run_configs_button(0, 1)
    assert_equal(app.run_active, "main")
    app.run_configs_button(1, 0)
    assert_true(app.status.find("nothing to edit") > 0, app.status)
    app.run_configs_button(3, 0)
    assert_equal(app.status, "That entry cannot be deleted")
    app.run_configs_button(0, 0)
    assert_equal(app.status, "Run now uses the file being edited")
    assert_equal(app.run_active, "")
    app.mode = M_NORMAL
    _ = run_system("rm -rf '" + d + "'")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
