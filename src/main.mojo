"""TurboMojo - a Turbo C++ style TUI IDE for Mojo, written in Mojo."""
from std.sys import argv
from std.ffi import external_call
from app import *
from window import WK_HEX
from term import is_terminal
from linemode import *
from util import env_or
from commands import CM_NEW, build_registry
from strings import strings_template
from config import config_home
from util import state_dir
from version import TURBOMOJO_VERSION, MOJO_BUILT_WITH
from mojover import mojo_summary, mojo_mismatch
from gpuinfo import GPU_QUERY, parse_gpus, gpu_line
from util import run_capture, bytes_to_str
from helpbook import keymap_markdown
from std.sys.info import CompilationTarget
from svgshot import screen_svg
from util import write_file, str_bytes
from ipc import parse_file_loc, ipc_open_in_running_ide


comptime USAGE = """Usage: tmide [FILE|FOLDER]...
       tmide [vim | --vim] [FILE]...

TurboMojo, a Turbo C++ style IDE for Mojo in the terminal. With no arguments it
restores the last session (or opens an empty window); FILEs open in editors, a
FOLDER opens the Open dialog there. `tmide vim [FILE]...` (or `--vim`) opens
chromeless Whole-Vim mode (full-bleed buffer, `~` EOF lines, `<Space>` leader).

  vim, --vim      chromeless Whole-Vim / Neovim mode (`<Space>` leader, `:zen` toggles)
  -h, --help      this text
  -V, --version   the version
  --keys          every command's keys in the three keymaps (docs/KEYMAP.md)
  --strings       the UI's English words, as a strings file to translate
  --caps          what this terminal reports it can do
  --reuse         open FILE[:LINE[:COL]] in the running TurboMojo instance if any
  --lines         the line mode: commands and answers as lines, no screen
  --screenshot OUT.svg [--size WxH] [--theme ID] [--command NAME]... [FILE]...
                  draw the IDE without a terminal and save the screen as SVG
                  (also when TERM=dumb; for screen readers and Emacs shells)
  --warm-docs [FOLDER]
                  pre-build the standard library Markdown pages and search cache
  --completions bash|zsh|fish
                  print shell completion script for tmide

Configuration: ~/.config/turbomojo/config.toml (Options writes there).
Documentation: Help (Alt-H) inside TurboMojo."""


def platform_name() -> String:
    comptime if CompilationTarget.is_macos():
        return "macos"
    else:
        return "linux"


def screenshot(mut app: App, args: List[String]) raises -> Int:
    """`tmide --screenshot OUT.svg [--size WxH] [--theme ID] [--command NAME]... [FILE]...`:
    lay the IDE out without a terminal, as it would first appear (after the commands,
    in order), and write the screen as SVG."""
    if len(args) < 3:
        print("usage: tmide --screenshot OUT.svg [--size WxH] [--theme ID] [--command NAME]... [FILE]...")
        return 2
    var out = args[2]
    var w = 120
    var h = 36
    var cmds = List[String]()
    var files = List[String]()
    var k = 3
    while k < len(args):
        var a = args[k]
        if (a == "--size" or a == "--theme" or a == "--command") and k + 1 < len(args):
            var v = args[k + 1]
            if a == "--size":
                var p = v.split("x")
                if len(p) != 2:
                    print("--size wants WIDTHxHEIGHT, for example 120x36")
                    return 2
                w = max(40, min(400, atol(String(p[0]))))
                h = max(12, min(200, atol(String(p[1]))))
            elif a == "--theme":
                if app.themes.find(v) < 0:
                    print("there is no theme \"" + v + "\" (themes: " + ", ".join(app.themes.ids) + ")")
                    return 2
                app.theme_id = v
            else:
                cmds.append(v)
            k += 2
        elif a == "--vim" or a == "vim":
            cmds.append("view.vimZen")
            k += 1
        else:
            files.append(a)
            k += 1
    app.config_path = ""             # a toggled option is for the picture, not saved
    app.help_dir = state_dir() + "/help"
    app.scr.resize(w, h)
    app.theme_apply()
    for f in files:
        app.open_path(f)
    if app.top_editor() < 0 and (app.top() < 0 or app.wins[app.top()].kind != WK_HEX):
        app.exec(CM_NEW)
    app.clock_fixed = "10:00"          # the same picture each time
    app.status = ""                   # ("Loaded /home/...": a picture shows no one's paths)
    for name in cmds:
        var i = app.reg.index_of_name(name)
        if i < 0:
            print("there is no command \"" + name + "\" (see the palette, Ctrl-P)")
            return 2
        app.exec(app.reg.cmds[i].id)
    app.draw()
    if not write_file(out, str_bytes(screen_svg(app.scr, app.pal.ed_fg, app.pal.desk_bg, "TurboMojo"))):
        print("cannot write", out)
        return 1
    return 0


def shell_completions(sh: String) -> String:
    if sh == "bash":
        return (
            "_tmide() {\n"
            "  local cur=\"${COMP_WORDS[COMP_CWORD]}\"\n"
            "  if [[ \"$cur\" == -* ]]; then\n"
            "    COMPREPLY=( $(compgen -W \"-h --help -V --version --keys --strings --caps --reuse --lines --screenshot --warm-docs --completions\" -- \"$cur\") )\n"
            "  else\n"
            "    COMPREPLY=( $(compgen -f -- \"$cur\") )\n"
            "  fi\n"
            "}\n"
            "complete -F _tmide tmide\n"
        )
    if sh == "zsh":
        return (
            "#compdef tmide\n"
            "_arguments \\\n"
            "  '(-h --help)'{-h,--help}'[Show help]' \\\n"
            "  '(-V --version)'{-V,--version}'[Show version]' \\\n"
            "  '--keys[Print keymap reference]' \\\n"
            "  '--strings[Print translatable UI strings]' \\\n"
            "  '--caps[Probe terminal capabilities]' \\\n"
            "  '--reuse[Open in running TurboMojo instance if any]' \\\n"
            "  '--lines[Line-oriented screen-reader mode]' \\\n"
            "  '--screenshot[Render SVG screenshot]:output file:_files' \\\n"
            "  '--warm-docs[Pre-build documentation index]:docs folder:_files -/' \\\n"
            "  '--completions[Print shell completions]:shell:(bash zsh fish)' \\\n"
            "  '*:file:_files'\n"
        )
    if sh == "fish":
        return (
            "complete -c tmide -s h -l help -d 'Show help'\n"
            "complete -c tmide -s V -l version -d 'Show version'\n"
            "complete -c tmide -l keys -d 'Print keymap reference'\n"
            "complete -c tmide -l strings -d 'Print translatable UI strings'\n"
            "complete -c tmide -l caps -d 'Probe terminal capabilities'\n"
            "complete -c tmide -l reuse -d 'Open in running TurboMojo instance if any'\n"
            "complete -c tmide -l lines -d 'Line-oriented screen-reader mode'\n"
            "complete -c tmide -l screenshot -r -d 'Render SVG screenshot'\n"
            "complete -c tmide -l warm-docs -d 'Pre-build documentation index'\n"
            "complete -c tmide -l completions -xa 'bash zsh fish' -d 'Print shell completions'\n"
        )
    return ""


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
    if len(pre) == 3 and String(pre[1]) == "--completions":
        var comp = shell_completions(String(pre[2]))
        if comp.byte_length() == 0:
            print("usage: tmide --completions bash|zsh|fish")
            external_call["exit", NoneType](Int32(2))
        print(comp, end="")
        return
    var app = App()
    app.strings_dir = config_home() + "/strings"
    app.trust_enable(state_dir() + "/trusted")
    app.bp_enable(state_dir() + "/breakpoints")
    app.load_config()
    var args = argv()
    if len(args) >= 2 and String(args[1]) == "--warm-docs":
        app.help_dir = state_dir() + "/help"
        if len(args) >= 3:
            app.doc_home = String(args[2])
        app.docs_index_ready()
        print("Warmed documentation index: " + String(len(app.doc_lib.pages)) + " pages, " + String(len(app.doc_index.entries)) + " entries in " + app.doc_home)
        return
    if len(args) >= 2 and String(args[1]) == "--screenshot":
        var sa = List[String]()
        for a in args:
            sa.append(String(a))
        external_call["exit", NoneType](Int32(screenshot(app, sa)))
    if len(args) == 2 and String(args[1]) == "--caps":
        # diagnostics: show what this terminal reports, then exit
        app.term.raw()
        var caps = app.term.probe(300, True)
        app.term.cooked()
        print("TurboMojo terminal capabilities")
        for line in caps.describe():
            print("  " + line)
        # the toolchain beside the terminal: is it the Mojo TurboMojo was built with?
        var mv = run_capture(app.compiler_cmd() + " --version 2>&1 < /dev/null")
        print("  mojo                : " + mojo_summary(MOJO_BUILT_WITH, bytes_to_str(mv.out)))
        var warn = mojo_mismatch(MOJO_BUILT_WITH, bytes_to_str(mv.out))
        if warn.byte_length() > 0:
            print("  " + warn)
        # the GPU a program will run on (the first the driver lists)
        print("  gpu                 : " + gpu_line(parse_gpus(bytes_to_str(run_capture("(" + GPU_QUERY + ") 2>/dev/null </dev/null").out))))
        return
    var lines = env_or("TERM", "") == "dumb"
    var reuse = False
    var vim_cli = len(args) > 0 and basename(String(args[0])) == "tmvim"
    var files = List[String]()
    for k in range(1, len(args)):
        var ak = String(args[k])
        if ak == "--lines":
            lines = True
        elif ak == "--reuse":
            reuse = True
        elif ak == "--vim" or (k == 1 and ak == "vim"):
            vim_cli = True
        else:
            files.append(ak)
    if reuse and not lines:
        if ipc_open_in_running_ide(state_dir() + "/ide-state.json", String(app.cwd), files):
            return
    if lines:
        # no cursor addressing: read commands as lines, answer in lines (src/linemode.mojo)
        app.reader = True
        for f in files:
            try:
                var loc = parse_file_loc(f)
                app.open_path(loc.path)
                if loc.line > 0 and app.top_editor() >= 0:
                    var ti = app.top_editor()
                    app.wins[ti].goto(loc.line - 1, max(0, loc.col - 1))
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
    app.agent_sessions_dir = state_dir() + "/agent-sessions"
    app.ide_state_path = state_dir() + "/ide-state.json"
    app.ipc_enable(state_dir() + "/ipc")
    app.plugins_dir = config_home() + "/plugins"
    app.plugins_log_dir = state_dir()
    if not vim_cli:
        app.whats_new_check(state_dir() + "/seen-version")
    for f in files:
        try:
            var loc = parse_file_loc(f)
            app.open_path(loc.path)
            if loc.line > 0 and app.top_editor() >= 0:
                var ti = app.top_editor()
                app.wins[ti].goto(loc.line - 1, max(0, loc.col - 1))
        except e:
            print("cannot open", f, ":", String(e))
    if len(files) == 0 and not vim_cli:
        # the very first start without a file asks which theme (not with files named:
        # what is typed then is meant for them)
        app.theme_marker = state_dir() + "/theme-asked"
    if len(files) == 0 and app.restore_session and not vim_cli:
        # started without a file: go on where this project was left
        app.session_dir = state_dir() + "/sessions"
        try:
            _ = app.session_restore()
        except e:
            print("cannot restore the session:", String(e))
    if app.top_editor() < 0 and (app.top() < 0 or app.wins[app.top()].kind != WK_HEX):
        if vim_cli:
            _ = app.new_editor("[No Name]", "")
        else:
            app.exec(CM_NEW)
    if vim_cli:
        app.enter_vim_zen(True)
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
