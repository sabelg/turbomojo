"""TurboMojo - a Turbo C++ style TUI IDE for Mojo, written in Mojo."""
from std.sys import argv
from std.ffi import external_call
from app import *
from term import is_terminal
from linemode import *
from util import env_or
from commands import CM_NEW, build_registry
from strings import strings_template
from config import config_home
from util import state_dir
from version import TURBOMOJO_VERSION
from helpbook import keymap_markdown
from std.sys.info import CompilationTarget


comptime USAGE = """Usage: tmide [FILE|FOLDER]...

TurboMojo, a Turbo C++ style IDE for Mojo in the terminal. With no arguments it
restores the last session (or opens an empty window); FILEs open in editors, a
FOLDER opens the Open dialog there.

  -h, --help      this text
  -V, --version   the version
  --keys          every command's keys in the three keymaps (docs/KEYMAP.md)
  --strings       the UI's English words, as a strings file to translate
  --caps          what this terminal reports it can do
  --lines         the line mode: commands and answers as lines, no screen
                  (also when TERM=dumb; for screen readers and Emacs shells)

Configuration: ~/.config/turbomojo/config.toml (Options writes there).
Documentation: Help (Alt-H) inside TurboMojo."""


def platform_name() -> String:
    comptime if CompilationTarget.is_macos():
        return "macos"
    else:
        return "linux"


def main() raises:
    var pre = argv()
    if len(pre) == 2 and (String(pre[1]) == "--version" or String(pre[1]) == "-V"):
        print("TurboMojo " + TURBOMOJO_VERSION + " (" + platform_name() + ")")
        return
    if len(pre) == 2 and (String(pre[1]) == "--help" or String(pre[1]) == "-h"):
        print(USAGE)
        return
    if len(pre) == 2 and String(pre[1]) == "--keys":
        print(keymap_markdown(), end="")   # docs/KEYMAP.md
        return
    if len(pre) == 2 and String(pre[1]) == "--strings":
        # the UI's English words as a strings file to translate (see src/strings.mojo)
        print(strings_template(build_registry()), end="")
        return
    var app = App()
    app.strings_dir = config_home() + "/strings"
    app.trust_enable(state_dir() + "/trusted")
    app.bp_enable(state_dir() + "/breakpoints")
    app.load_config()
    var args = argv()
    if len(args) == 2 and String(args[1]) == "--caps":
        # diagnostics: show what this terminal reports, then exit
        app.term.raw()
        var caps = app.term.probe(300)
        app.term.cooked()
        print("TurboMojo terminal capabilities")
        for line in caps.describe():
            print("  " + line)
        return
    var lines = env_or("TERM", "") == "dumb"
    var files = List[String]()
    for k in range(1, len(args)):
        if String(args[k]) == "--lines":
            lines = True
        else:
            files.append(String(args[k]))
    if lines:
        # no cursor addressing: read commands as lines, answer in lines (src/linemode.mojo)
        app.reader = True
        for f in files:
            try:
                app.open_path(f)
            except e:
                print("cannot open", f, ":", String(e))
        app.run_lines()
        return
    if not is_terminal():
        print("TurboMojo needs an interactive terminal (input or output is redirected).")
        external_call["exit", NoneType](Int32(2))
    app.enable_history()
    app.help_dir = state_dir() + "/help"
    app.key_uses_load(state_dir() + "/key-uses")
    app.tips_load(state_dir() + "/tips-shown")
    app.ex_home = state_dir() + "/exercises"
    app.plugins_dir = config_home() + "/plugins"
    app.plugins_log_dir = state_dir()
    app.whats_new_check(state_dir() + "/seen-version")
    for i in range(1, len(args)):
        try:
            app.open_path(String(args[i]))
        except e:
            print("cannot open", String(args[i]), ":", String(e))
    if len(args) == 1 and app.restore_session:
        # started without a file: go on where this project was left
        app.session_dir = state_dir() + "/sessions"
        try:
            _ = app.session_restore()
        except e:
            print("cannot restore the session:", String(e))
    if app.top_editor() < 0:
        app.exec(CM_NEW)
    app.plugins_start()             # (they answer in the background)
    app.show_config_warnings()
    app.offer_recovery()
    try:
        app.run()
    except e:
        # an error escaped the event loop: keep the user's work, then report
        var n = app.emergency_save()
        app.sig.close()
        app.term.leave()
        app.log_error("fatal: " + String(e))
        print("TurboMojo stopped because of an internal error:", String(e))
        if n > 0:
            print("Unsaved buffers were kept and will be offered when you start TurboMojo again.")
        print("Details:", app.log_path)
        external_call["exit", NoneType](Int32(1))
