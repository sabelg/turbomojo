# Source layout

Every module of TurboMojo, with the first line of its own description (made by
`scripts/gen_docs.py`). All Mojo; the only library linked in is libghostty-vt, the
terminal emulator of the integrated terminal. `app_*.mojo` files extend the `App`
struct of `appstate.mojo`, one area each.

| File | What it is |
|---|---|
| `src/acp.mojo` | A client of the Agent Client Protocol (ACP, protocol version 1): a coding agent runs as a child process and speaks JSON-RPC 2.0 over its stdin/stdout, one message per line (https://agentclientprotocol.com/protocol/transports). |
| `src/agentchat.mojo` | The agent panel's model: the conversation with a coding agent as entries (what you said, what the agent answered as it streams in, its thinking, tool calls, plans, notes) turned into Markdown for the panel; and the mentions in a prompt. |
| `src/agentexplain.mojo` | Grounded "explain" prompts for the coding agent: what TurboMojo knows locally (the code with its line numbers, the compiler's message, the built-in explanation of that message, the downloaded documentation of the names involved) is put into the prompt, with the request to answer from it and to name the pages used. |
| `src/agentsvc.mojo` | What the editor does for a coding agent (ACP): its terminals (`terminal/*`: a command on a pty, its output kept for the agent) and the files it proposes to write (`fs/write_text_file`: a proposal the user accepts or rejects in the diff view). |
| `src/app.mojo` | TurboMojo application entry: the event loop. |
| `src/app_agent.mojo` | The agent panel: a coding agent (ACP, src/acp.mojo) in a window at the right edge. |
| `src/app_agentexplain.mojo` | Help > Ask agent about this error / this code: the agent panel gets a grounded prompt (src/agentexplain.mojo) - the code with line numbers, the message, TurboMojo's explanation of it, and the downloaded documentation of the names involved - and is asked to answer from it and name the pages. |
| `src/app_agentsvc.mojo` | The editor's services to a coding agent (ACP): reading files through the editor, proposed writes to accept or reject, and terminals for its commands. |
| `src/app_debug.mojo` | Debugging: building a program with debug information, running it under Mojo's debug adapter and showing what happens (see dap.mojo). |
| `src/app_dialogs.mojo` | Dialog flow: opening dialogs and acting on their buttons and keys. |
| `src/app_docpane.mojo` | Help > Docs pane: the documentation of the name at the cursor in a window at the right edge, beside the code, kept up to date as the cursor moves - looked up when the cursor has rested on a name for a moment, never while typing. |
| `src/app_docs.mojo` | The documentation reader: the downloaded Mojo documentation as books with a table of contents, a rendered page, links, history and search - a full-screen mode. |
| `src/app_draw.mojo` | Drawing the desktop, status line, cursor and popups. |
| `src/app_exec.mojo` | Command dispatch: App.exec() and window arrangement. |
| `src/app_exercises.mojo` | Help > Exercises: an opt-in practice course in the style of Rustlings. |
| `src/app_explain.mojo` | F1 on an error: the explanation of a Mojo error message (src/errhelp.mojo) in a window beside the code, so the code with the error stays in view. |
| `src/app_explorer.mojo` | The file explorer window: the project's files as a tree at the left edge. |
| `src/app_files.mojo` | File handling: opening, saving, closing windows, quitting. |
| `src/app_git.mojo` | Git in the editor: changed-line markers in the gutter and `git status` colours in the file explorer. |
| `src/app_gitcmd.mojo` | git commands with dialogs and views: File > Commit, Branch, Blame. |
| `src/app_gitdiff.mojo` | The diff view and the change (hunk) commands: File > Diff of this file, Stage change, Revert change, Next / Previous change. |
| `src/app_gpu.mojo` | The GPU on the status line (P11-10a): with `ui.gpu_status` on (Options > GPU in the status line), GPU_QUERY runs once in the background through a non-blocking pipe - the main loop waits on it with the other descriptors - and its answer becomes a status item such as "GPU GB10". |
| `src/app_input.mojo` | Keyboard and paste input routing. |
| `src/app_jobs.mojo` | Compiler integration: background build/format jobs, messages, run. |
| `src/app_keybox.mojo` | After a prefix key (WordStar's Ctrl-K and Ctrl-Q, Emacs's C-x, any two-key binding): if the second key does not come within a moment, a box above the status line lists the keys that may follow, with their commands. |
| `src/app_keyecho.mojo` | The calm key echo (P7-07): after a command is run from a menu, the command palette or a click, the status line says which key does it - "Next time: Ctrl-K B" - in the keymap in use. |
| `src/app_layout.mojo` | The tiled layout in the application: panes with tabs that share the screen. |
| `src/app_links.mojo` | Hyperlinks (OSC 8) on the file:line references the IDE shows: every row of the Message window's pages (Message, Search, Problems) and of the agent panel. |
| `src/app_lsp.mojo` | Language server integration in the IDE (first slice: live diagnostics for one file). |
| `src/app_lspextra.mojo` | Language servers for other languages, by configuration ([lsp.<name>] in the config file: command, extensions, language). |
| `src/app_menus.mojo` | Menu bar navigation. |
| `src/app_mouse.mojo` | Mouse handling. |
| `src/app_nav.mojo` | Moving between places: go to definition, lists of places, the back/forward jump list. |
| `src/app_newproject.mojo` | File > New project (P11-04): asks for a folder, writes a Mojo project there (newproject.mojo has what goes in it), makes it the folder the IDE works in, opens hello.mojo and its test, and runs `pixi install` with its output on the Message page. |
| `src/app_notify.mojo` | Toasts and the notification centre (src/notify.mojo). |
| `src/app_outline.mojo` | The Outline window: the symbols of the file being edited, as a tree to jump from. |
| `src/app_pickers.mojo` | List pickers: command palette, symbols, keyboard reference, word completion. |
| `src/app_pkginstall.mojo` | Install what a program uses (P11-13): after a failed build or run, a library the output names as missing is looked up on the project's channels (`pixi search`) and, if it is there, offered; Install adds it (`pixi add`) and builds or runs again. |
| `src/app_plugins.mojo` | The plugin host in the IDE (src/plugins.mojo): start the plugins of the plugins folder, poll them with the event loop, answer what they ask, run their commands, send them the events they asked for, and show their status items. |
| `src/app_presets.mojo` | Options > Presets (P11-06): two ways to start, each in one choice - Turbo (Turbo Classic's blue desktop, overlapping windows) and Modern (your terminal's own colours, panes with tabs, the file explorer open, the keys of current editors). |
| `src/app_problems.mojo` | The bottom panel's Problems page, for every source: what the language server reports, the errors and warnings of the last build, and the tests that failed. |
| `src/app_progress.mojo` | The response-time ladder on screen (src/progress.mojo has the stages): a build, format, task, test run or documentation download, and an agent's turn, show nothing for their first second, then a spinner and the time on the status line, and beyond ten seconds what has been done so far and the key that stops it - for a job in the Compiling box at the bottom right, which is drawn over the desktop but never takes the keyboard (typing goes on in the editor); for the agent on the status line (its panel shows the steps themselves). |
| `src/app_report.mojo` | Help > Report a problem (P11-08): report.mojo makes the text; this gathers what goes in it, writes it to problem-report.md in the state folder, copies it to the clipboard and opens it, so it can be read and changed before it is posted. |
| `src/app_setup.mojo` | Help > Check setup (P11-05): the list of what TurboMojo uses and whether it is there (setupcheck.mojo makes the lines), with a Fix button for the marked line - it opens File > New project, Compile > Compiler command or Help > Download documentation, or copies the command that fixes it. |
| `src/app_swap.mojo` | Swap files in the running IDE: periodic writing, clean-up and recovery at startup. |
| `src/app_terminal.mojo` | The integrated terminal: a shell (Window > Terminal) and the program Run starts, each in a window of its own at the bottom, on a pty with libghostty-vt keeping the screen. |
| `src/app_tests.mojo` | The test explorer: the project's TestSuite files and their tests, run by file or one at a time, with the place of each failure (see testexp.mojo). |
| `src/app_tips.mojo` | The tips of src/tips.mojo in the IDE: the editor's keys and the Find dialog feed the rules; a tip comes as a notice, so while you type it waits for the pause (P7-12), and a screen reader hears it then. |
| `src/app_vim.mojo` | The vim interface's keys (Phase 12; see vim.mojo): Normal, Insert and Visual modes in front of TurboMojo's own bindings. |
| `src/app_watch.mojo` | Reacting to files that were changed by another program while open in the IDE. |
| `src/appstate.mojo` | Application state: the App struct, its fields and small shared helpers. |
| `src/breakpoints.mojo` | Breakpoints: where the debugger is to stop. |
| `src/buffer.mojo` | Text buffer: a rope of UTF-8 text addressed by (row, column in codepoints), with grouped undo/redo and the per-file settings (line endings, indentation, final newline). |
| `src/caps.mojo` | Terminal capabilities: what the terminal says it supports, and colour-depth handling. |
| `src/codequery.mojo` | What a search for help looks like, so one box can take code as well as words: a name (`append`), a dotted path (`List.append`, `std.collections.list`), or a pasted error line (`x.mojo:3:5: error: use of unknown declaration 'y'`), besides the finder's own syntax (words, "a phrase", @api, #heading, `code, in:book). |
| `src/commands.mojo` | Command registry: the single table of commands, their titles, hints and default keys. |
| `src/config.mojo` | User and project settings. |
| `src/contrast.mojo` | Contrast of a theme's colours, by two measures. |
| `src/cpuview.mojo` | What the CPU window shows: the machine code around the instruction the program is stopped at, the general purpose registers, and a piece of memory. |
| `src/crash.mojo` | Crash guard: restore the terminal and write a crash log when the IDE dies hard. |
| `src/dap.mojo` | Debug Adapter Protocol client. |
| `src/dbgview.mojo` | What the Debug window shows: the call stack of the stopped program and the variables of the chosen frame, as a tree that opens on request. |
| `src/dialog.mojo` | Modal Turbo Vision style dialogs: input lines, check boxes, list boxes, buttons. |
| `src/docfetch.mojo` | The documentation download script, carried inside the program so that an installed TurboMojo can run it without its source tree. |
| `src/doclib.mojo` | The documentation library: the folders `scripts/fetch-docs.sh` downloads, seen as books with a table of contents, and their pages cleaned up for the reader (front matter, includes, admonitions and web-only markup turned into plain Markdown). |
| `src/docpane.mojo` | The docs pane's text: the section of a documentation page that one heading starts (the way the finder's index names headings), so the pane shows what a declaration of the standard library says without the rest of its page. |
| `src/docs.mojo` | Documentation from `mojo doc`: reading its JSON and turning an entry into the Markdown the documentation window shows. |
| `src/editorconfig.mojo` | EditorConfig support (https://editorconfig.org). |
| `src/errhelp.mojo` | Explanations of Mojo error messages: what a message means, why Mojo says it, how to fix it, and a small program before and after the fix. |
| `src/errhelp_pages.mojo` | The explanations of Mojo error messages, made from help/errors/ by scripts/gen_errhelp.py - do not edit here. |
| `src/exercise_pages.mojo` | The exercises of Help > Exercises, made from help/exercises/ by scripts/gen_exercises.py - do not edit here. |
| `src/explorer.mojo` | The file explorer's model: the project folder as a tree of which only the opened folders are listed, and the file operations (create, rename, move, delete to trash). |
| `src/filestate.mojo` | What is remembered about a file between sessions: where the cursor was, how far it was scrolled, which blocks were folded (version 2) and the undo history. |
| `src/frecency.mojo` | Which files were opened how often and how recently ("frecency"), to rank the files in the quick-open palette. |
| `src/git.mojo` | Git, as the editor sees it: which repository a file is in, what `git status` says about the files (for the explorer), and the commands that ask git for them. |
| `src/gitdiff.mojo` | The diff view's model: a unified diff of two versions of a file, and what staging, unstaging or reverting one change (hunk) of it makes of them. |
| `src/glyphs.mojo` | Glyph tiers (`ui.glyphs`): which characters the IDE's own chrome is drawn with. |
| `src/gpuinfo.mojo` | Which GPU will the program run on? (P11-10a) Mojo programs that use a GPU take the first one the driver lists (CUDA_VISIBLE_DEVICES / HIP_VISIBLE_DEVICES change which), so TurboMojo asks the vendor's tool once - nvidia-smi for NVIDIA, rocm-smi for AMD - and shows the answer in `tmide --caps` and, when `ui.gpu_status` is on, on the status line. |
| `src/grapheme.mojo` | Grapheme clusters: what a user perceives as one character. |
| `src/grep.mojo` | Find in files: walks a folder and searches every text file, a little at a time so the editor stays responsive (call `step` from the event loop until `done`). |
| `src/helpbook.mojo` | TurboMojo's own help: the "TurboMojo" book of the documentation viewer (the guide, the cheat sheet, the keyboard reference, what's new) and the tutorial file. |
| `src/highlight.mojo` | Mojo syntax highlighter (line-based with triple-quoted string state). |
| `src/inflate.mojo` | Inflate: the zlib / DEFLATE decompressor (RFC 1950, 1951), for PNG pictures. |
| `src/json.mojo` | JSON reader and writer (RFC 8259). |
| `src/kittygfx.mojo` | Kitty graphics protocol, for pictures in the documentation reader (P10-22b). |
| `src/layout.mojo` | The tiled layout: a tree of splits whose leaves are tab groups. |
| `src/linediff.mojo` | Line diff: which lines of an old text became which lines of a new one. |
| `src/linemode.mojo` | The line mode (P10-14b): TurboMojo without cursor addressing, for TERM=dumb and `tmide --lines`. |
| `src/links.mojo` | Hyperlinks on file:line references (OSC 8). |
| `src/lsp.mojo` | Language Server Protocol client (first slice: lifecycle, document sync, diagnostics). |
| `src/lspextra.mojo` | Language servers for other languages ([lsp.<name>] in the config file): what one is, and making the list from the settings (src/app_lspextra.mojo does the rest). |
| `src/main.mojo` | TurboMojo - a Turbo C++ style TUI IDE for Mojo, written in Mojo. |
| `src/markdown.mojo` | Markdown to styled text lines, for hover windows and documentation panels. |
| `src/marks.mojo` | OSC 133 marks ("semantic prompts", FinalTerm's sequences) around a program run. |
| `src/menu.mojo` | Menu bar structures and drawing. |
| `src/mojover.mojo` | Is the Mojo found the one TurboMojo was built with? (P11-03) |
| `src/newproject.mojo` | File > New project (P11-04): a folder with what a Mojo project needs, so that a newcomer does not have to know pixi first - a pixi.toml (the Modular channel, `mojo` as its dependency, `hello` and `test` tasks), a hello.mojo, a test for it and a .gitignore. |
| `src/notify.mojo` | Notifications: short messages that show for a few seconds at the top right ("toasts") when something finishes or needs attention while you work elsewhere, and are kept in the notification centre (Help > Notifications) with what is running now. |
| `src/outline.mojo` | The outline of a file: its functions, structs, traits and constants as a tree. |
| `src/palette.mojo` | Colour themes. |
| `src/pkginstall.mojo` | Install what a program uses (P11-13). |
| `src/platform.mojo` | What differs between the systems TurboMojo is built for, chosen when it is compiled: the numbers of system calls' flags and signals, the layout of `struct termios`, and which Linux-only facilities exist. |
| `src/plugins.mojo` | Plugins: programs of their own that TurboMojo starts and talks to over JSON-RPC, one message per line on their standard input and output (the transport of the agent client). |
| `src/png.mojo` | PNG decoding to RGBA pixels, for sixel pictures in the docs reader (P10-22c). |
| `src/problems.mojo` | The Problems page's model: problems from every source (the language server, the last build, the test explorer's failed tests) in one list, and the filter that chooses which are shown (kinds, only the current file, a text). |
| `src/proc.mojo` | A child process with pipes in both directions, driven without blocking. |
| `src/progress.mojo` | The response-time ladder (Nielsen's limits: 0.1 s feels instant, 1 s keeps the flow of thought, 10 s keeps attention): work that ends within a second shows nothing - a spinner that flashes on and off is noise; from one second a spinner and the time on the status line; beyond ten seconds what has been done so far and the key that stops it, in a box that never takes the keyboard. |
| `src/project.mojo` | The project around the files being edited: where its `pixi.toml` is and which tasks that file defines. |
| `src/pty.mojo` | A program running on a pseudo-terminal: what the integrated terminal and the REPL run. |
| `src/puzzlecheck.mojo` | Check my answer for the Mojo GPU Puzzles (P11-10c), as Help > Exercise done? does for the exercises. |
| `src/pydocs.mojo` | The documentation of the Python libraries a Mojo program uses (P11-14). |
| `src/regex.mojo` | Regular expressions: a parser, a compiler to a small instruction set, and a Pike VM (Thompson NFA simulation that also tracks capture groups). |
| `src/report.mojo` | Help > Report a problem (P11-08): a ready-to-file issue text - what to describe, the versions, what the terminal can do (as `tmide --caps` shows), the last crash-log entry and the configuration with anything secret-looking removed. |
| `src/responsive.mojo` | Responsive layout, first part (P10-16a): what gives way when the terminal or a window is small. |
| `src/rope.mojo` | Rope: text stored as UTF-8 chunks in a B-tree whose nodes carry summaries. |
| `src/rpc.mojo` | JSON-RPC 2.0 over a child process's pipes, with `Content-Length` framing (LSP, DAP) or one message per line (ACP: `lines`, messages contain no raw line feeds). |
| `src/runconfig.mojo` | Run configurations: named ways of running the project (which file, with what arguments, environment and working directory, built first or not), kept in the project's .turbomojo.toml as tables [run.<name>]. |
| `src/runreport.mojo` | After Ctrl-F9 (P11-10b): one line in the Message window with how the run ended, how long it took and, for a program that uses the GPU, which GPU it ran on. |
| `src/screen.mojo` | Double-buffered cell screen with truecolor diff rendering. |
| `src/search.mojo` | What to search for: text or a regular expression, with the Find dialog's options. |
| `src/session.mojo` | A session: which files were open in a project, where the cursors were, and how the windows were arranged - written as a small text file and read back at the next start. |
| `src/setupcheck.mojo` | Help > Check setup (P11-05): is everything TurboMojo uses there? Mojo (and is it the release TurboMojo was built with), pixi, the language server, the debugger, the documentation, the terminal's colours and keys - each with what fixes it when it is missing. |
| `src/signals.mojo` | Signal handling for the event loop. |
| `src/sixel.mojo` | Sixel output, for pictures in the docs reader where the terminal has no kitty graphics (P10-22c): a decoded picture scaled to its cells, its colours put on the 6 x 6 x 6 cube (216 registers), sent band by band (six pixel rows each) with run-length counts. |
| `src/stdref.mojo` | The standard library reference: `mojo doc`'s JSON for the `std` package (made by scripts/fetch-docs.sh) turned into one Markdown page per module, with an index that the documentation library reads as a book. |
| `src/strings.mojo` | The UI's words outside the code: the menu titles and every command's title and hint (what the menus, the command palette, the status line and the keyboard reference show) can come from a strings file, so the IDE can be translated. |
| `src/svgshot.mojo` | The screen as an SVG picture (P11-02): `tmide --screenshot FILE.svg` draws the IDE as it would appear and writes what is in its cells - characters, colours, bold, underlines - as a grid of text, so the README can show it without a screen recorder. |
| `src/swap.mojo` | Swap files: periodic copies of unsaved buffers, used to recover work after a crash, a power cut or `kill -9`. |
| `src/symindex.mojo` | An index of the symbols (functions, structs, traits, constants) of every Mojo file of the project, built a slice at a time so the editor never waits for it. |
| `src/term.mojo` | Raw terminal I/O: termios, window size, key + SGR mouse + bracketed paste parsing. |
| `src/termkeys.mojo` | The bytes a key sends to a program in a terminal, as xterm sends them. |
| `src/termsession.mojo` | A terminal session: a program on a pty and the emulator keeping its screen (used by the Terminal and Run windows, see app_terminal.mojo). |
| `src/testexp.mojo` | The test explorer's model: test files of the project, their tests, and what a run of them reported. |
| `src/themes.mojo` | Colour themes as TOML files: the built-in ones beside Turbo Classic, Midnight Neon and Amber CRT (palette.mojo), and the user's own in $XDG_CONFIG_HOME/turbomojo/themes/. |
| `src/tips.mojo` | Tips that answer what you just did, instead of a random tip at start-up: a few rules watch the keys for a slow way of doing something there is a quick way for, and name the quick way once - at the next pause, never again after that, and not at all with ui.tips = false. |
| `src/toml.mojo` | A small TOML reader/writer for configuration files. |
| `src/trust.mojo` | Which project folders the user has said they trust. |
| `src/util.mojo` | Small helpers: UTF-8 codecs, byte buffers, processes and the filesystem. |
| `src/version.mojo` | TurboMojo's version: the one place it is written (the help book, the About box, `tmide --version`, the What's new notice and the conda package all take it from here). |
| `src/vim.mojo` | The vim interface (Phase 12): `ui.keymap = "vim"`. |
| `src/vt.mojo` | Terminal emulation for the integrated terminal: libghostty-vt (Ghostty's terminal core, MIT, from conda-forge) parses what a program writes - every CSI, SGR with 256 colours and truecolor, the alternate screen, scroll regions, cursor and keyboard modes, wide characters, scrollback - and keeps the screen. |
| `src/watch.mojo` | Detecting changes made to files by other programs. |
| `src/window.mojo` | Editor / message windows: state, cursor, selection and editing commands. |
| `src/window_draw.mojo` | Window drawing: frame, gutter, highlighted text, selection, scrollbars. |
| `src/window_lines.mojo` | Line operations (move, join, sort), case conversion and auto-closing pairs (extends Window). |
| `src/window_multi.mojo` | Multi-cursor editing (extends Window). |
| `src/window_search.mojo` | Window search: find, replace, word start and bracket matching. |
