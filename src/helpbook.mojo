"""TurboMojo's own help: the "TurboMojo" book of the documentation viewer (the guide, the
cheat sheet, the keyboard reference, what's new) and the tutorial file.

The pages are the files in help/ of the repository, built in here (tests/test_help.mojo
checks that they are the same) and written to the state folder when the viewer opens,
so the viewer and its finder treat them like the Mojo documentation. The keyboard page
is made from the command registry each time, so it shows the keys of your keymap.
"""
from std.collections import List
from util import write_file, str_bytes, path_exists, run_system, shell_quote
from errhelp import errors_book
from commands import Registry, plain, build_registry, apply_keymap, keymap_name, CM_SAVE, CM_OPEN, CM_CLOSE, CM_QUICK, CM_PALETTE, CM_FIND, CM_REPLACE, CM_AGAIN, CM_FINDFILES, CM_GOTO, CM_UNDO, CM_REDO, CM_CUT, CM_COPY, CM_PASTE, CM_COMMENT, CM_DUPLINE, CM_LINEUP, CM_LINEDOWN, CM_DEFINITION, CM_REFERENCES, CM_RENAME, CM_BUILD, CM_RUN, CM_DEBUG, CM_BP_TOGGLE, CM_TERMINAL, CM_EXPLORER

comptime TURBOMOJO_VERSION = "1.8"

comptime HELP_GUIDE = "# TurboMojo user guide\n\nTurboMojo is an editor and IDE for Mojo in the terminal, in the style of Turbo C++ 3.0.\nEverything is reached from the menu bar (**F10**, or **Alt** and a menu's letter) and\nfrom the command palette (**Ctrl-P**), which finds every command by name.\n\n## Windows\n\n- Edit windows overlap like on a desk; **Alt-1** to **Alt-9** go to a window by its\n  number, **F6** to the next one, **F5** zooms one. Window > Tiled layout puts them side\n  by side in panes with tabs instead.\n- The **bottom panel** has three pages: Message (compiler and program output), Search\n  (results and lists of places) and Problems (from the language server, the last build\n  and failed tests). Left / Right switch pages; Enter goes to the place a line names.\n- At the left the **file explorer** (Ctrl-E), at the right the **outline**, the **test\n  explorer** or the **agent panel**.\n\n## Editing\n\nThe keys follow your keymap (Options): Modern (Ctrl-C/X/V/Z), Turbo (WordStar Ctrl-K\nblocks) or Emacs. After a prefix key such as Ctrl-K, wait a moment and a box lists\nthe keys that may follow. Multiple cursors, column selection, folding by indentation, soft\nwrap, macros (Ctrl-F5 records), find and replace with regular expressions, and Find in\nFiles are in the Edit, Text and Search menus.\n\n## Mojo\n\n- **F7** starts the language server: problems underlined as you type, completion,\n  hover (Alt-I), go to definition (F12), references, rename, code actions.\n- **F9** builds, **Ctrl-F9** runs (in the terminal window if `run_in_terminal`).\n- **F1** on a problem (a row of the Problems page, or its line in the editor) explains\n  the message beside the code: what it means, how to fix it, a program before and\n  after. Help > Error messages has them all.\n- **Shift-F5** debugs: breakpoints (Ctrl-F8), stepping (F7, F8, Shift-F8), the Debug\n  window (Ctrl-F3) with variables and watches, the CPU window (Alt-F2).\n- Run > Test explorer runs `std.testing` suites and shows what failed where.\n- **Ctrl-F1** shows the documentation of the name at the cursor; Help > Mojo\n  documentation reads the manual, the reference and the standard library.\n- Help > Docs pane keeps that documentation beside the code, following the cursor;\n  Ctrl-F1 and Alt-I answer there while it is open, Enter opens the full page.\n\n## Git\n\nIn a repository (in a trusted folder) the gutter marks lines changed since the index,\nthe explorer colours files by their status, and the File menu has Diff (stage, revert\nor unstage one change), Commit, Branch and Blame.\n\n## Coding agents\n\nFile > Agent panel (Ctrl-F11) talks to an agent that speaks the Agent Client Protocol,\nnamed by `agent` under `[tools]`. It asks before every change and command unless you\nallow it for the session; `@file:12-20` in a prompt sends those lines along. Help >\nAsk agent about this error (or this code) sends the code with the local explanation\nand documentation pages, and checks the imports of the answer.\n\n## Settings\n\n`~/.config/turbomojo/config.toml` (and a project's `.turbomojo.toml`): Options writes\nthere for you. Themes: Options > Colour theme; your own themes are TOML files in\n`~/.config/turbomojo/themes/`.\n\n## More help\n\n- Help > Keyboard reference (F1): every key, as your keymap has it.\n- Help > Cheat sheet: the keys used most.\n- Help > Tutorial: a file to practise in.\n- Help > Exercises: small programs that are wrong until you fix them; Help >\n  Exercise done? checks yours.\n- Help > Coming from Python: what is different, and the keys next to VS Code's.\n- Help > What's new.\n- In this viewer **/** searches every page, the Mojo documentation too. Find in\n  documentation (Alt-F1) also takes a name, a dotted path (`List.append`) or a pasted\n  error line; `?` in the palette (Ctrl-P) hands the text to it.\n"
comptime HELP_CHEATSHEET = "# Cheat sheet\n\nThe keys used most, with the Modern keymap (the default). Help > Keyboard reference\n(F1) lists every key as your keymap has it.\n\n| Keys | What they do |\n|---|---|\n| F10, Alt-letter | Menus |\n| Ctrl-P | Command palette: every command by name |\n| Alt-G | Go to file; `@` symbols, `#` project symbols, `:` line |\n| F2 / F3 | Save / open |\n| Ctrl-W, Alt-F3 | Close the window |\n| F6, Alt-1..9 | Next window, window by number |\n| Ctrl-E | File explorer |\n| Ctrl-F / Ctrl-R / Ctrl-L | Find / replace / again |\n| Shift-F3 | Find in files |\n| Ctrl-G | Go to line |\n| Ctrl-D | Duplicate line |\n| Alt-- / Alt-= | Fold or unfold the block / expand all |\n| Ctrl-Z / Ctrl-Y | Undo / redo |\n| F7 | Language server on / off |\n| F12, Shift-F12 | Go to definition, find references |\n| Alt-I | Describe the symbol at the cursor |\n| F9 / Ctrl-F9 | Build / run |\n| Shift-F5 | Debug; continue |\n| Ctrl-F8 | Toggle a breakpoint |\n| F7 / F8 / Shift-F8 | (debugging) step in / over / out |\n| Alt-F11 | Terminal |\n| Ctrl-F10 | Send the selection to the Mojo REPL |\n| Alt-N / Alt-B | Next / previous changed block (git) |\n| Ctrl-F11 | Agent panel |\n| Shift-F10 | Notifications and what is running |\n| Ctrl-F1 | Documentation of the name at the cursor |\n"
comptime HELP_WHATS_NEW = "# What's new\n\n## 1.8 (in progress)\n\n- **Themes as files**: Paper Light, High Contrast and Hacker Matrix besides Turbo\n  Classic, Midnight Neon and Amber CRT; your own in `~/.config/turbomojo/themes/`;\n  `theme = \"auto\"` follows the terminal's (or GNOME's) light or dark.\n- **Notifications**: toasts when a build, tests, a commit or the agent finish while you\n  are elsewhere; Help > Notifications (Shift-F10) shows what is running. Toasts that\n  come while you type wait for a pause, a save or the debugger stopping; your own\n  build, tests and commits come at once and first.\n- **Coming from Python**: Help > Coming from Python lists what is different in Mojo\n  1.x, and the book has VS Code's keys next to TurboMojo's; explanations of Python\n  habits link to it (P).\n- **Exercises**: Help > Exercises - eight small Mojo programs that are wrong until\n  you fix them; Help > Exercise done? checks yours. Opt-in; nothing starts by itself.\n- **Tips when they help**: paging to a function, a long run of arrows or Backspace,\n  or Find again and again brings one tip, once, at a pause; Help > No more tips stops\n  them.\n- **Ask the agent, with local help**: Help > Ask agent about this error / this code\n  sends the code, the message, TurboMojo's explanation and the documentation pages\n  that fit, and asks for an answer that names its pages; imports in the answer are\n  built with your Mojo, and made-up ones are reported.\n- **One search box**: Find in documentation (Alt-F1) takes a name, `List.append` or\n  a pasted error line, answers in one line, and lists the commands that fit; `?`\n  in the palette hands the text over.\n- **Key boxes**: after a prefix key (Ctrl-K, Ctrl-Q, Emacs Ctrl-X), a pause shows\n  the keys that may follow and their commands.\n- **Docs pane**: Help > Docs pane shows the documentation of the name at the cursor\n  beside the code and follows the cursor.\n- **Error explanations**: F1 on a problem explains the Mojo message beside the code,\n  with a program before and after the fix; Help > Error messages lists them.\n- **Key echo**: a command picked from a menu or the palette names its key on the\n  status line, until you have used the key a few times.\n- **Help**: this book - the guide, the cheat sheet, a tutorial file, what's new - and\n  the finder (/) searches it with the Mojo documentation.\n\n## 1.7: coding agents\n\nThe agent panel (Ctrl-F11) for any agent that speaks the Agent Client Protocol (for\nexample Claude Code's `claude-agent-acp`): streamed answers, @file mentions, reads\nthrough the editor, changes as proposals, commands after a yes, and a permission\nprompt for everything, with an allow list for the session.\n\n## 1.6: terminal, tests, git\n\nIntegrated terminals (a shell, the program you run, the Mojo REPL), the test\nexplorer, git markers in the gutter, the diff view with staging one change at a time,\ncommit, branches, blame, and one Problems page for the language server, builds and\ntests.\n\n## 1.5: debugger\n\nDebugging with `mojo-lldb-dap`: breakpoints with conditions and log messages, stepping,\nthe Debug window, watches, Evaluate, the CPU window.\n\n## 1.4 and before\n\nThe workspace (explorer, project search, sessions, folder trust, pixi tasks), the\nlanguage server, and the editor core: tiled panes, multiple cursors, folding, macros,\nkeymaps, large files, recovery after a crash.\n"
comptime HELP_PYTHON = "# Coming from Python\n\nMojo looks like Python, and much of what you know carries over: indentation, `for` and\n`while`, `if`/`elif`/`else`, `print`, lists and dictionaries, `try`/`except`. These are\nthe places where Python habits trip you up in Mojo 1.x. Every Mojo example on this page\nbuilds as it is.\n\nThe keys of TurboMojo next to VS Code's are on the page **Coming from other editors**.\n\n## A program starts at `main`\n\nPython runs a file from the top. Mojo runs `def main()`; only declarations may stand at\nthe top level of a file.\n\n```mojo\ndef main():\n    print(\"hello\")\n```\n\n## Functions are `def`; `raises` says it can fail\n\nThere is no `fn` any more. A `def` that can raise an error says so with `raises`, and a\nfunction that calls it must handle the error or say `raises` too.\n\n```mojo\ndef parse(text: String) raises -> Int:\n    return Int(text)\n\n\ndef main() raises:\n    print(parse(\"42\") + 1)\n```\n\n## New names need `var`\n\nAssigning to a new name does not create it: `var` does. The type can be written or\nleft to Mojo.\n\n```mojo\ndef main():\n    var count = 0\n    var name: String = \"Mojo\"\n    count += 1\n    print(name, count)\n```\n\n## Arguments are read-only by default\n\nA function cannot change its arguments unless they are `mut` (the caller's variable\nchanges) or `var` (the function gets its own copy).\n\n```mojo\ndef bump(mut n: Int):\n    n += 1\n\n\ndef main():\n    var x = 1\n    bump(x)\n    print(x)\n```\n\n## Copying is asked for\n\n`b = a` copies a Python list's reference; in Mojo a `List` is a value and is not copied\nbehind your back. Write `a.copy()` to copy, or `a^` to move it (then `a` cannot be used).\n\n```mojo\ndef main():\n    var a: List[Int] = [1, 2, 3]\n    var b = a.copy()\n    b.append(4)\n    print(len(a), len(b))\n```\n\n## `struct` instead of `class`\n\nThere are no classes (\"classes are not supported yet\"). A `struct` declares its fields\nwith `var`; its constructor takes `out self`; a method that changes it takes `mut self`.\nInstead of inheritance, a struct implements traits.\n\n```mojo\nstruct Counter:\n    var count: Int\n\n    def __init__(out self):\n        self.count = 0\n\n    def bump(mut self):\n        self.count += 1\n\n\ndef main():\n    var c = Counter()\n    c.bump()\n    print(c.count)\n```\n\n## Strings: no `len()`, no f-strings\n\n`len(s)` is not allowed, because \"length\" could mean bytes or characters: write\n`s.byte_length()` or `len(s.codepoints())`. There are no f-strings; build text with `+`\nand `String(x)`, or give `print` several values.\n\n```mojo\ndef main():\n    var s = String(\"héllo\")\n    var n = 3\n    print(s.byte_length(), len(s.codepoints()))\n    print(\"n = \" + String(n), \"and\", n)\n```\n\n## Imports start with `std.`\n\nThe standard library is imported as `std.collections`, `std.os` and so on. Python\nmodules are still at hand through `std.python`.\n\n```mojo\nfrom std.collections import Dict\nfrom std.python import Python\n\n\ndef main() raises:\n    var d = Dict[String, Int]()\n    d[\"a\"] = 1\n    var math = Python.import_module(\"math\")\n    print(d[\"a\"], math.sqrt(16.0))\n```\n\n## `None` is `Optional`\n\nA function that may return nothing returns an `Optional`; test it, then take\n`.value()`.\n\n```mojo\ndef find(xs: List[Int], v: Int) -> Optional[Int]:\n    for i in range(len(xs)):\n        if xs[i] == v:\n            return i\n    return None\n\n\ndef main():\n    var xs: List[Int] = [5, 6]\n    var r = find(xs, 6)\n    if r:\n        print(r.value())\n```\n\n## Constants are `comptime`\n\nA value known when the program is built is a `comptime` constant (there is no\n`alias` any more).\n\n```mojo\ncomptime SIZE = 8\n\n\ndef main():\n    print(SIZE * 2)\n```\n\n## When something goes wrong\n\n**F1** on a problem explains the message, with a program before and after the fix;\nHelp > Error messages lists them all; Help > Exercises has small programs to practise\nthese differences on.\n"
comptime HELP_TUTORIAL = "# TurboMojo tutorial\n#\n# This is your own copy: change anything, nothing breaks. Work down the file.\n# (Help > Tutorial makes a fresh copy at any time.)\n#\n# LESSON 1 - moving\n#   Arrows move the cursor; Ctrl-Left / Ctrl-Right jump by words; Home / End go to\n#   the start and end of a line; Ctrl-Home / Ctrl-End to the start and end of the file.\n#   Try: go to the word HERE on the next line, select it (hold Shift and press Right\n#   four times) and press Delete.\n#       delete the word HERE please\n#\n# LESSON 2 - selecting, copying, undoing\n#   Hold Shift while moving to select. Ctrl-C copies, Ctrl-X cuts, Ctrl-V pastes,\n#   Ctrl-Z undoes and Ctrl-Y redoes. Ctrl-D duplicates the line you are on.\n#   Try: duplicate this line three times, then undo twice.\n#\n# LESSON 3 - the menus and the palette\n#   F10 opens the menu bar; Alt and a highlighted letter opens that menu (Alt-S:\n#   Search). Ctrl-P opens the command palette: type \"sort\" and press Enter to sort\n#   the selected lines below.\n#       cherry\n#       apple\n#       banana\n#\n# LESSON 4 - finding\n#   Ctrl-F finds, Ctrl-L finds again, Ctrl-R replaces. Try: replace every \"colour\"\n#   in the program below with \"color\".\n#\n# LESSON 5 - running Mojo\n#   F7 starts the language server: break the program below (remove a closing\n#   bracket) and watch the problem appear. Put it back, then Ctrl-F9 runs it; F9\n#   builds it. Errors are listed in the bottom panel: Enter goes to one.\n#\n# LESSON 6 - debugging\n#   Put the cursor on the line with \"total +=\" and press Ctrl-F8 for a breakpoint.\n#   Shift-F5 starts the debugger; F8 steps; Ctrl-F3 shows the variables.\n#\n# LESSON 7 - more\n#   Help > Cheat sheet lists the keys used most; Help > Keyboard reference all of\n#   them; Help > TurboMojo guide the rest. Esc closes a menu or a dialog.\n\n\ndef main():\n    var colour = \"green\"\n    var total = 0\n    for i in range(1, 6):\n        total += i\n    print(\"The sum of 1 to 5 is\", total, \"and the colour is\", colour)\n"


def help_pages() -> List[String]:
    """The book's pages: file name, then title, in the order of the contents."""
    var out = List[String]()
    for s in ["guide.md", "TurboMojo guide", "cheatsheet.md", "Cheat sheet", "keys.md", "Keyboard reference", "errors.md", "Mojo error messages", "coming-from-python.md", "Coming from Python", "coming-from-editors.md", "Coming from other editors", "whats-new.md", "What's new"]:
        out.append(String(s))
    return out^


def write_help(dir: String, keys_md: String) -> Bool:
    """Put the help pages into `dir` (as this version has them)."""
    if not path_exists(dir):
        _ = run_system("mkdir -p " + shell_quote(dir))
    var ok = write_file(dir + "/guide.md", str_bytes(HELP_GUIDE))
    ok = write_file(dir + "/cheatsheet.md", str_bytes(HELP_CHEATSHEET)) and ok
    ok = write_file(dir + "/whats-new.md", str_bytes(HELP_WHATS_NEW)) and ok
    ok = write_file(dir + "/errors.md", str_bytes(errors_book())) and ok
    ok = write_file(dir + "/coming-from-python.md", str_bytes(HELP_PYTHON)) and ok
    ok = write_file(dir + "/coming-from-editors.md", str_bytes(editors_markdown())) and ok
    ok = write_file(dir + "/keys.md", str_bytes(keys_md)) and ok
    return ok


def vscode_key(cmd: Int) -> String:
    """The key VS Code (default keymap, Linux) has for the same thing."""
    if cmd == CM_SAVE:
        return "Ctrl-S"
    if cmd == CM_OPEN:
        return "Ctrl-O"
    if cmd == CM_CLOSE:
        return "Ctrl-W"
    if cmd == CM_QUICK:
        return "Ctrl-P"
    if cmd == CM_PALETTE:
        return "Ctrl-Shift-P"
    if cmd == CM_FIND:
        return "Ctrl-F"
    if cmd == CM_REPLACE:
        return "Ctrl-H"
    if cmd == CM_AGAIN:
        return "F3"
    if cmd == CM_FINDFILES:
        return "Ctrl-Shift-F"
    if cmd == CM_GOTO:
        return "Ctrl-G"
    if cmd == CM_UNDO:
        return "Ctrl-Z"
    if cmd == CM_REDO:
        return "Ctrl-Y"
    if cmd == CM_CUT:
        return "Ctrl-X"
    if cmd == CM_COPY:
        return "Ctrl-C"
    if cmd == CM_PASTE:
        return "Ctrl-V"
    if cmd == CM_COMMENT:
        return "Ctrl-/"
    if cmd == CM_DUPLINE:
        return "Ctrl-Shift-Alt-Down"
    if cmd == CM_LINEUP:
        return "Alt-Up"
    if cmd == CM_LINEDOWN:
        return "Alt-Down"
    if cmd == CM_DEFINITION:
        return "F12"
    if cmd == CM_REFERENCES:
        return "Shift-F12"
    if cmd == CM_RENAME:
        return "F2"
    if cmd == CM_BUILD:
        return "Ctrl-Shift-B"
    if cmd == CM_RUN:
        return "Ctrl-F5"
    if cmd == CM_DEBUG:
        return "F5"
    if cmd == CM_BP_TOGGLE:
        return "F9"
    if cmd == CM_TERMINAL:
        return "Ctrl-`"
    if cmd == CM_EXPLORER:
        return "Ctrl-Shift-E"
    return ""


def editors_markdown() -> String:
    """Coming from other editors: VS Code's keys next to TurboMojo's in each keymap,
    made from the command registry (so it is right for this version)."""
    var cmds = [CM_SAVE, CM_OPEN, CM_CLOSE, CM_QUICK, CM_PALETTE, CM_FIND, CM_REPLACE, CM_AGAIN, CM_FINDFILES, CM_GOTO, CM_UNDO, CM_REDO, CM_CUT, CM_COPY, CM_PASTE, CM_COMMENT, CM_DUPLINE, CM_LINEUP, CM_LINEDOWN, CM_DEFINITION, CM_REFERENCES, CM_RENAME, CM_BUILD, CM_RUN, CM_DEBUG, CM_BP_TOGGLE, CM_TERMINAL, CM_EXPLORER]
    var regs = List[Registry]()
    for m in range(3):
        var r = build_registry()
        apply_keymap(r, m)
        regs.append(r^)
    var out = String("# Coming from other editors\n\nThe same things in VS Code (its default keys on Linux) and in TurboMojo's three keymaps (Options > Keys:\nModern is the default; Turbo is WordStar's, as in Turbo C++; Emacs). A dash: no key -\nthe menus and the command palette (Ctrl-P, then >) have every command.\n\n| | VS Code | Modern | Turbo | Emacs |\n|---|---|---|---|---|\n")
    for c in cmds:
        var ci = regs[0].index_of(c)
        if ci < 0:
            continue
        var row = "| " + plain(regs[0].cmds[ci].title) + " | " + vscode_key(c)
        for m in range(3):
            var k = regs[m].key_label(c)
            row += " | " + (k if k.byte_length() > 0 else String("-"))
        out += row + " |\n"
    out += "\nThe keys of your keymap, all of them: Help > Keyboard reference (F1).\n"
    return out^
