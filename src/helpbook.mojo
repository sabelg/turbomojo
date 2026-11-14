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
from vim import vim_keys_markdown
from commands import Registry, plain, build_registry, apply_keymap, CM_NONE, keymap_name, CM_SAVE, CM_OPEN, CM_CLOSE, CM_QUICK, CM_PALETTE, CM_FIND, CM_REPLACE, CM_AGAIN, CM_FINDFILES, CM_GOTO, CM_UNDO, CM_REDO, CM_CUT, CM_COPY, CM_PASTE, CM_COMMENT, CM_DUPLINE, CM_LINEUP, CM_LINEDOWN, CM_DEFINITION, CM_REFERENCES, CM_RENAME, CM_BUILD, CM_RUN, CM_DEBUG, CM_BP_TOGGLE, CM_TERMINAL, CM_EXPLORER

from version import TURBOMOJO_VERSION

comptime HELP_GUIDE = "# TurboMojo user guide\n\nTurboMojo is an editor and IDE for Mojo in the terminal, in the style of Turbo C++ 3.0.\nEverything is reached from the menu bar (**F10**, or **Alt** and a menu's letter) and\nfrom the command palette (**Ctrl-P**), which finds every command by name.\n\n## Windows\n\n- Edit windows overlap like on a desk; **Alt-1** to **Alt-9** go to a window by its\n  number, **F6** to the next one, **F5** zooms one. Window > Tiled layout puts them side\n  by side in panes with tabs instead.\n- The **bottom panel** has three pages: Message (compiler and program output), Search\n  (results and lists of places) and Problems (from the language server, the last build\n  and failed tests). Left / Right switch pages; Enter goes to the place a line names.\n- At the left the **file explorer** (Ctrl-E), at the right the **outline**, the **docs\n  pane**, the **test explorer** or the **agent panel**.\n\n## Editing\n\nThe keys follow your keymap (Options): Modern (Ctrl-C/X/V/Z), Turbo (WordStar Ctrl-K\nblocks), Emacs or Vim. After a prefix key such as Ctrl-K, wait a moment and a box lists\nthe keys that may follow. Multiple cursors, column selection, folding by indentation, soft\nwrap, macros (Ctrl-F5 records), find and replace with regular expressions, and Find in\nFiles are in the Edit, Text and Search menus.\n\n## Mojo\n\n- **F7** starts the language server: problems underlined as you type, completion,\n  hover (Alt-I), go to definition (F12), references, rename, code actions.\n- **F9** builds, **Ctrl-F9** runs (in the terminal window if `run_in_terminal`).\n- **F1** on a problem (a row of the Problems page, or its line in the editor) explains\n  the message beside the code with syntax-coloured Before / After programs: **C** copies\n  the fixed code, **T** opens it in a scratch buffer, **A** asks the coding agent, and\n  **?** searches the docs. Help > Error messages has all 27 pages.\n- **Shift-F5** debugs: breakpoints (Ctrl-F8), stepping (F7, F8, Shift-F8), the Debug\n  window (Ctrl-F3) with variables and watches, the CPU window (Alt-F2).\n- Run > Test explorer runs `std.testing` suites and shows what failed where.\n- **Ctrl-F1** shows the documentation of the name at the cursor (understanding receiver\n  chains like `items.append` and `Python.import_module`); **Shift-F1** (Help > Mojo\n  documentation) reads the manual, the language reference, the standard library and\n  Modular's courses.\n- Help > Docs pane keeps rich syntax-coloured documentation beside the code, following\n  the cursor; **Enter** opens the full page, **C** copies a code example, **T** tries it\n  in a scratch buffer.\n\n## Git\n\nIn a repository (in a trusted folder) the gutter marks lines changed since the index,\nthe explorer colours files by their status, and the File menu has Diff (stage, revert\nor unstage one change), Commit, Branch and Blame.\n\n## Coding agents\n\nFile > Agent panel (Ctrl-F11) talks to an agent that speaks the Agent Client Protocol,\nnamed by `agent` under `[tools]` (`agent_mode` chooses `ask`, `accept-edits`, or `auto`).\nInside the agent panel: **Alt-M** cycles permission mode, **Alt-O** switches model,\n**Alt-T** cycles thinking level, **Tab** completes `@file` mentions, and **Alt-Up** /\n**Alt-Down** step prompt history. Help > Ask agent about this error (or this code) and\nFile > Send diagnostics to agent ground the prompt with your code, diagnostics, and\nMojo 1.2 documentation excerpts, and verify imports in the agent's answer.\n\n## Settings\n\n`~/.config/turbomojo/config.toml` (and a project's `.turbomojo.toml`): Options writes\nthere for you. Themes: Options > Colour theme; your own themes are TOML files in\n`~/.config/turbomojo/themes/`.\n\n## More help\n\n- Help > Keyboard reference (F1): every key, as your keymap has it.\n- Help > Cheat sheet: the keys used most.\n- Help > Tutorial: a file to practise in.\n- Help > Exercises: 13 small Mojo 1.2 programs that are wrong until you fix them; Help >\n  Exercise done? checks yours - and your copy of a Mojo GPU Puzzle (**O** on its program\n  in the documentation reader makes one, offering to run `pixi install` the first time).\n- Help > Coming from Python: what is different, and the keys next to VS Code's.\n- Help > What's new.\n- In this viewer **/** searches every page (**Alt-F1** from anywhere, including dotted\n  module paths like `std.collections.list`), **Ctrl-F** searches on the current page\n  (**F3** / **Shift-F3** next / previous), **G** jumps to a heading on the page, **C**\n  copies the visible code block, and **T** opens it in a scratch buffer.\n"
comptime HELP_CHEATSHEET = "# Cheat sheet\n\nThe keys used most, with the Modern keymap (the default). Help > Keyboard reference\n(F1) lists every key as your keymap has it.\n\n| Keys | What they do |\n|---|---|\n| F10, Alt-letter | Menus |\n| Ctrl-P | Command palette: every command by name |\n| Alt-G | Go to file; `@` symbols, `#` project symbols, `:` line |\n| F2 / F3 | Save / open |\n| Ctrl-W, Alt-F3 | Close the window |\n| F6, Alt-1..9 | Next window, window by number |\n| Ctrl-E | File explorer |\n| Ctrl-F / Ctrl-R / Ctrl-L | Find / replace / again |\n| Shift-F3 | Find in files |\n| Ctrl-G | Go to line |\n| Ctrl-D | Duplicate line |\n| Alt-- / Alt-= | Fold or unfold the block / expand all |\n| Ctrl-Z / Ctrl-Y | Undo / redo |\n| F7 | Language server on / off |\n| F12, Shift-F12 | Go to definition, find references |\n| Alt-I | Describe the symbol at the cursor |\n| F9 / Ctrl-F9 | Build / run |\n| Shift-F5 | Debug; continue |\n| Ctrl-F8 | Toggle a breakpoint |\n| F7 / F8 / Shift-F8 | (debugging) step in / over / out |\n| Alt-F11 | Terminal |\n| Ctrl-F10 | Send the selection to the Mojo REPL |\n| Alt-N / Alt-B | Next / previous changed block (git) |\n| Ctrl-F11 / Shift-F11 | Agent panel / mention selection in prompt |\n| Shift-F10 | Notifications and what is running |\n| F1 / Ctrl-F1 | Explain error or keys / docs of name at cursor |\n| Shift-F1 / Alt-F1 | Mojo documentation reader / search all docs |\n\nIn the **documentation reader** (Shift-F1): **/** searches all books, **Ctrl-F** (**F3** /\n**Shift-F3**) searches on the page, **G** jumps to a heading on the page, **C** copies a\ncode block, **T** opens it in a scratch buffer, and **O** opens your own practice copy.\nIn the **agent panel** (Ctrl-F11): **Alt-M** cycles mode (`ask` / `accept-edits` /\n`auto`), **Alt-O** picks the model, **Alt-T** sets thinking, **Tab** completes `@file`,\nand **Alt-Up** / **Alt-Down** recall prompts.\n"
comptime HELP_WHATS_NEW = "# What's new\n\n## 2.3 (in progress): a vim interface\n\n- Options > Keys: Vim (`keymap = \"vim\"`) gives the editor vim's modes. Normal mode\n  (NORMAL in the status line, a block cursor) has vim's motions (w b e, 0 ^ $, gg G,\n  f t ; ,, %, { } and the rest), its operators with motions, counts and text objects\n  (dw, 3dd, cw, yy, di(, ci\", dap), x r J p P, `.` to repeat a change, u and Ctrl-R,\n  and Visual mode with v and V; Esc goes back from Insert mode (a bar cursor). Ctrl\n  and Alt keys, the F-keys and the menus stay TurboMojo's in every mode. / ? n N * #\n  search with vim's patterns, and `:` opens vim's command line on the status row -\n  :w :q :wq :x :e :42 :%s/a/b/g and TurboMojo's own commands by name (:build, :run).\n  Registers too: \"a to \"z (\"A adds), \"0 the last copy, \"_ none, and \"+ the clipboard,\n  which reaches the terminal's clipboard over SSH as well.\n- A Vim preset (Options > Presets, and **Vim start** in the first run's question): the\n  Modern look with vim's keys and relative line numbers. Options > Relative numbers\n  (`editor.relative_numbers`) shows each line's distance from the cursor's line in the\n  gutter, for 5j and 3dk. F10 and Alt still open the menus.\n- Documentation & Help upgrades: instant warm disk cache for the 1,600+ page offline\n  Mojo library (`tmide --warm-docs`), full syntax colouring on fenced blocks with\n  attributes (`mojo no-test`, `title=\"...\"`) and in the Docs & Error Explanation panes,\n  dotted module search (`std.collections.list`), receiver-aware method lookup\n  (`items.append`), in-page search (`Ctrl-F` / `F3`), heading jump (`G`), collapsible\n  chapter headings, `C` / `T` to copy or try any code block, Mojo 1.2 legacy-syntax\n  banners on older course pages, 27 built-in Mojo 1.2 error pages, 13 interactive\n  exercises, and one-click background `pixi install` for the Mojo GPU Puzzles.\n- Coding agent upgrades: `auto`, `accept-edits`, and `ask` permission modes (`Alt-M`),\n  model & thinking selectors (`Alt-O`, `Alt-T`), `@file` Tab-completion, `Alt-Up` /\n  `Alt-Down` prompt history, persistent sessions, Send diagnostics to agent, and a\n  built-in MCP workspace server (`scripts/mcp_server.py`).\n- Full IDE audit & Mojo 1.2 GPU/SIMD upgrades:\n  - **Vim power suite**: `Ctrl-D`/`U`/`F`/`B` scrolling, `Ctrl-O`/`I` jumplist, `Ctrl-W`\n    pane navigation, `Ctrl-V` Visual-Block column editing, `q<reg>`/`@<reg>`/`@@`\n    register macros, `gd`/`gr`/`K` LSP navigation, and `:sp`/`:vsp` synchronized split\n    views of the same file (also Window > Split joint view).\n  - **Search & Git**: Search > Replace in files... with file globs and atomic multi-file\n    undo; File > Git status panel (`s`/`u`/`a`/`r`/`d`/`c`), Git stash / pop, remote\n    branch tracking checkout, Options > Inline git blame, untracked-file hunk staging,\n    and instant `inotify` `.git` index refresh.\n  - **LSP, Formatting, Testing & Debugging**: Options > Pixi environment selector +\n    warm 2-server LSP pool, automatic LSP start (`[tools] lsp_auto_start`), `textDocument/typeDefinition`,\n    `completionItem/resolve`, viewport-chunked inlay hints, diff-hunk `mojo format` +\n    Format on save, inline `[PASS]`/`[FAIL]` test lens + Run > Quick-run test at cursor,\n    live inline debugger variable ghosts, and CPU window SIMD lane formatting (`v`/`V`).\n  - **GPU & Codegen**: Window > GPU queue & monitor (live compute/VRAM sparklines,\n    temperature, power, active processes), Compile > Inspect generated code (ASM / LLVM\n    IR with `[SIMD]` and `[SPILL]` badges), Compile > Profile GPU kernels (`nsys` /\n    `rocprofv3`), `gpu_sync = true` run configuration support, and 4 New Project\n    templates (App, Library, GPU Kernel, Python Extension).\n\n## 2.2: ready for other people\n- A program that uses a library which is not installed (`unable to locate module\n  'max'`, `No module named 'numpy'`): TurboMojo finds its package on the project's\n  channels and offers to install it with `pixi add`, then builds or runs again; with no\n  `pixi.toml` it offers to make the project first. Nothing is installed without a yes.\n- F1 on a name of a Python library your program imports (`np.zeros`) shows its\n  documentation, from the project's own Python. The language server runs in the\n  project's environment, so it knows the Mojo packages installed there (MAX and others),\n  and starts again in another project's when one of its files comes to the front.\n- `pixi run bundle` makes a tar file to copy to a server: TurboMojo and the libraries\n  it needs, which runs there after unpacking, without pixi.\n- Help > Exercise done? checks your answer to a Mojo GPU Puzzle too: it runs your copy\n  in each of the puzzle's modes, as the course's own tests do.\n- After Ctrl-F9 the Message window says how the run ended, how long it took and, for a\n  program that uses the GPU, which GPU it ran on.\n- Options > GPU in the status line shows the GPU your programs will run on (asked once\n  from nvidia-smi or rocm-smi, in the background); `tmide --caps` names it, with its\n  memory and driver.\n- Help > Report a problem... writes a ready-to-file issue text (versions, the terminal,\n  the last crash, your settings without secrets), copies it and opens it; nothing is\n  sent.\n- A guide to working on a remote machine over SSH and in tmux (the user guide: copying\n  to your own clipboard, the mouse, colours, keys, pictures); copying through tmux with\n  no X11, Wayland or clipboard program on the server is now tested.\n- Options > Presets...: Turbo (the blue desktop, overlapping windows) or Modern (your\n  terminal's colours, panes with tabs, the explorer open, the Modern keys) in one\n  choice; the first run's theme question offers Modern at its top. `ui.explorer = true`\n  opens the explorer at each start.\n- Help > Check setup... lists what TurboMojo uses (Mojo and its release, pixi, the\n  language server, the debugger, the docs, the terminal's colours and keys), marks what\n  is missing, and Fix helps with it; the first start shows it when something is missing.\n- File > New project... makes a Mojo project - a `pixi.toml` with Mojo, `hello.mojo` and\n  a test - opens it and installs Mojo with `pixi install`; the first start in a folder\n  with no project offers it.\n- If the Mojo found is another release than the one TurboMojo was built with, the status\n  line says so at start-up, instead of the language server or builds failing without\n  saying why; `tmide --caps` shows both versions.\n- `tmide --screenshot OUT.svg` draws the IDE without a terminal and saves the screen as\n  an SVG picture (`--size`, `--theme`, `--command` to open the palette, the explorer...);\n  it changes none of your settings.\n\n## 2.1: UI clarity and calm\n\n- The window with the focus is shown more ways (bold title); the others keep their\n  selection and cursor, muted; the shown tab is in brackets.\n- Problems are marked E, W or i in the gutter, and their underlines are wavy, dashed\n  or dotted - not by colour alone.\n- Terminal ANSI and Terminal Mono themes: your terminal's own colours; `NO_COLOR`\n  is honoured.\n- Okabe-Ito, a dark theme for colour-blind eyes: errors, warnings, notes, git markers\n  and the main code colours stay apart with each of the three common kinds of colour\n  blindness (checked in the tests).\n- Themes look as designed in terminals with 256 or 16 colours too: every built-in theme\n  keeps its text readable there (Amber CRT and Hacker Matrix lost it before). Theme\n  files can set colours by role (`[roles]`) and for each depth (`[colors256]`,\n  `[colors16]`).\n- Every theme keeps errors, warnings, git markers and the main code colours apart for\n  colour-blind eyes too; a few colours changed for it (Paper Light's errors are\n  raspberry and its additions blue, Classic's strings light orange, Midnight's numbers\n  pink and definitions yellow).\n- Options > Quiet code colours: four code colours (text, comments, strings,\n  definitions), so that errors and search hits stand out most.\n- Turbo Muted, Turbo Classic in calm, less saturated colours; `theme = \"auto\"` follows\n  terminals that only tell their background colour live too.\n- Options > Colour theme shows each theme as you move through the list; the first run\n  asks which one, once.\n- Emoji line up in more terminals: the IDE measures at start-up how wide the terminal\n  draws a few doubtful glyphs (shown by `tmide --caps`) and lays them out to match; a\n  width it still gets wrong spoils one cell, no longer the rest of the line.\n- Pictures in the Mojo documentation show as \"[image: ...]\" links that name the\n  picture's file, and in kitty, Ghostty and other terminals with the kitty graphics\n  protocol the PNGs themselves, also inside tmux (`[ui] images`); terminals with\n  sixel (foot, xterm, tmux 3.4) get them as sixel.\n- Translated menus can have hot letters in any script (\"~\u0424~\u0430\u0439\u043b\", \"~\u00d6~ffnen\"):\n  small or capital, they open the menu, choose the item and press the button.\n\n## 2.0: release\n\n- `tmide --version` and `tmide --help`; a conda package (`pixi run package`).\n- A user guide, a keymap reference for all three keymaps and a changelog\n  (docs/USER_GUIDE.md, docs/KEYMAP.md, CHANGELOG.md).\n- Checked on every change: fuzzing of the key, JSON, text and terminal parsers,\n  performance budgets (start-up, keys, a 1,000,000-line file, idle CPU) and a soak test\n  of long editing that watches the memory.\n\n## 1.9: help that keeps you working, plugins, other languages\n\n- **Themes as files**: Paper Light, High Contrast and Hacker Matrix besides Turbo\n  Classic, Midnight Neon and Amber CRT; your own in `~/.config/turbomojo/themes/`;\n  `theme = \"auto\"` follows the terminal's (or GNOME's) light or dark.\n- **Notifications**: toasts when a build, tests, a commit or the agent finish while you\n  are elsewhere; Help > Notifications (Shift-F10) shows what is running. Toasts that\n  come while you type wait for a pause, a save or the debugger stopping; your own\n  build, tests and commits come at once and first.\n- **Plugins and other languages**: plugins in `~/.config/turbomojo/plugins` add\n  commands, status items and panels (docs/PLUGINS.md); `[lsp.<name>]` in the config\n  file adds a language server for other files (F7 starts it).\n- **Coming from Python**: Help > Coming from Python lists what is different in Mojo\n  1.x, and the book has VS Code's keys next to TurboMojo's; explanations of Python\n  habits link to it (P).\n- **Exercises**: Help > Exercises - eight small Mojo programs that are wrong until\n  you fix them; Help > Exercise done? checks yours. Opt-in; nothing starts by itself.\n- **Tips when they help**: paging to a function, a long run of arrows or Backspace,\n  or Find again and again brings one tip, once, at a pause; Help > No more tips stops\n  them.\n- **Ask the agent, with local help**: Help > Ask agent about this error / this code\n  sends the code, the message, TurboMojo's explanation and the documentation pages\n  that fit, and asks for an answer that names its pages; imports in the answer are\n  built with your Mojo, and made-up ones are reported.\n- **One search box**: Find in documentation (Alt-F1) takes a name, `List.append` or\n  a pasted error line, answers in one line, and lists the commands that fit; `?`\n  in the palette hands the text over.\n- **Key boxes**: after a prefix key (Ctrl-K, Ctrl-Q, Emacs Ctrl-X), a pause shows\n  the keys that may follow and their commands.\n- **Docs pane**: Help > Docs pane shows the documentation of the name at the cursor\n  beside the code and follows the cursor.\n- **Error explanations**: F1 on a problem explains the Mojo message beside the code,\n  with a program before and after the fix; Help > Error messages lists them.\n- **Key echo**: a command picked from a menu or the palette names its key on the\n  status line, until you have used the key a few times.\n- **Help**: this book - the guide, the cheat sheet, a tutorial file, what's new - and\n  the finder (/) searches it with the Mojo documentation.\n\n## 1.7: coding agents\n\nThe agent panel (Ctrl-F11) for any agent that speaks the Agent Client Protocol (for\nexample Claude Code's `claude-agent-acp`): streamed answers, @file mentions, reads\nthrough the editor, changes as proposals, commands after a yes, and a permission\nprompt for everything, with an allow list for the session.\n\n## 1.6: terminal, tests, git\n\nIntegrated terminals (a shell, the program you run, the Mojo REPL), the test\nexplorer, git markers in the gutter, the diff view with staging one change at a time,\ncommit, branches, blame, and one Problems page for the language server, builds and\ntests.\n\n## 1.5: debugger\n\nDebugging with `mojo-lldb-dap`: breakpoints with conditions and log messages, stepping,\nthe Debug window, watches, Evaluate, the CPU window.\n\n## 1.4 and before\n\nThe workspace (explorer, project search, sessions, folder trust, pixi tasks), the\nlanguage server, and the editor core: tiled panes, multiple cursors, folding, macros,\nkeymaps, large files, recovery after a crash.\n"
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


def keymap_markdown() -> String:
    """docs/KEYMAP.md: every command that has a key in one of the three keymaps, menu by
    menu, then those that are only in the palette - made from the command registry, so
    `tmide --keys` always prints the keys of this version."""
    var regs = List[Registry]()
    for m in range(3):
        var r = build_registry()
        apply_keymap(r, m)
        regs.append(r^)
    var out = String("# TurboMojo keymap reference\n\nThe keys of every command in the three keymaps (Options > Keys: Modern, the default;\nTurbo, WordStar's as in Turbo C++; Emacs). Two keys with a space between are pressed one\nafter the other (Ctrl-K B). A dash: no key in that keymap - the menus and the command\npalette (Ctrl-P, then >) have every command. Your own keys (`[keys]` in the config file)\ncome on top; Help > Keyboard reference (F1) shows the keys as you have them.\n\nThis file is made by `tmide --keys` (TurboMojo " + TURBOMOJO_VERSION + ").\n")
    var listed = List[Int]()
    for mi in range(len(regs[0].menu_titles)):
        var rows = String("")
        for p in regs[0].layout:
            if p.menu != mi or p.cmd == CM_NONE or p.cmd in listed:
                continue
            var row = keymap_row(regs, p.cmd)
            if row.byte_length() > 0:
                rows += row
                listed.append(p.cmd)
        if rows.byte_length() > 0:
            var title = plain(regs[0].menu_titles[mi])
            out += "\n## " + ("System (≡)" if title == "≡" else title) + "\n\n| Command | Modern | Turbo | Emacs |\n|---|---|---|---|\n" + rows
    var rest = String("")
    for c in regs[0].cmds:
        if c.id in listed:
            continue
        var row = keymap_row(regs, c.id)
        if row.byte_length() > 0:
            rest += row
            listed.append(c.id)
    if rest.byte_length() > 0:
        out += "\n## Not in a menu\n\n| Command | Modern | Turbo | Emacs |\n|---|---|---|---|\n" + rest
    out += "\n## Always\n\n| Key | What it does |\n|---|---|\n| F10 | The menu bar |\n| Alt and a menu's letter | That menu |\n| Alt-1 to Alt-9 | The window with that number |\n| Esc | Close a menu, a dialog or a box; cancel a key sequence |\n| F1 on a problem | Its explanation |\n"
    out += vim_keys_markdown()
    return out^


def keymap_row(regs: List[Registry], cmd: Int) -> String:
    var keys = List[String]()
    var any = False
    for m in range(3):
        var k = regs[m].all_keys_label(cmd)
        if k.byte_length() > 0:
            any = True
        keys.append(k.replace("|", "\\|") if k.byte_length() > 0 else String("-"))
    if not any:
        return ""
    var ci = regs[0].index_of(cmd)
    var title = plain(regs[0].cmds[ci].title)
    if title.endswith("..."):
        var short = String(title[byte=0:title.byte_length() - 3])
        title = short
    return "| " + title + " | " + keys[0] + " | " + keys[1] + " | " + keys[2] + " |\n"
