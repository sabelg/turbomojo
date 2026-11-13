"""Help > Check setup (P11-05): is everything TurboMojo uses there? Mojo (and is it the
release TurboMojo was built with), pixi, the language server, the debugger, the
documentation, the terminal's colours and keys - each with what fixes it when it is
missing. Most "it does not work" moments come from one of these, so the first run shows
the list by itself when Mojo, the language server or the debugger is missing.

This module only turns what was found (SetupFacts) into the list's lines; the IDE
gathers the facts (app_setup.mojo)."""
from std.collections import List
from mojover import mojo_version_of, mojo_mismatch
from caps import COLOR_TRUE, COLOR_256

comptime SC_OK = 0          # there, works
comptime SC_NOTE = 1        # works, but could be better / optional and not there
comptime SC_MISSING = 2     # missing: something will not work

comptime SC_FIX_NONE = 0     # nothing the IDE can do itself: the fix text is copied
comptime SC_FIX_PROJECT = 1  # File > New project (pixi install brings Mojo and its tools)
comptime SC_FIX_COMPILER = 2 # Compile > Compiler command
comptime SC_FIX_DOCS = 3     # Help > Download documentation


struct SetupFacts(Copyable, Movable):
    var mojo_out: String        # what `<compiler> --version` printed ('' if it did not run)
    var built_with: String      # version.MOJO_BUILT_WITH
    var compiler: String        # the compiler setting (for the messages)
    var pixi: String            # where pixi is ('' if not found)
    var lsp: String             # where the language server is ('' if not found)
    var lsp_name: String
    var dap: String             # the debug adapter's command ('' if not found)
    var dap_name: String
    var docs: Bool              # the documentation is downloaded
    var probed: Bool            # the terminal was asked (not in tests / screenshots)
    var color: Int              # COLOR_TRUE / COLOR_256 / COLOR_16
    var kitty_keys: Bool        # the kitty keyboard protocol: every key arrives
    var tmux: Bool              # inside tmux

    def __init__(out self):
        self.mojo_out = ""
        self.built_with = ""
        self.compiler = "mojo"
        self.pixi = ""
        self.lsp = ""
        self.lsp_name = "mojo-lsp-server"
        self.dap = ""
        self.dap_name = "mojo-lldb-dap"
        self.docs = False
        self.probed = False
        self.color = COLOR_TRUE
        self.kitty_keys = False
        self.tmux = False


struct SetupItem(Copyable, Movable):
    var name: String
    var level: Int              # SC_OK / SC_NOTE / SC_MISSING
    var detail: String          # what was found, short
    var fix: String             # what to do ('' when nothing is needed)
    var action: Int             # SC_FIX_*: what the Fix button does

    def __init__(out self, name: String, level: Int, detail: String, fix: String = "", action: Int = SC_FIX_NONE):
        self.name = name
        self.level = level
        self.detail = detail
        self.fix = fix
        self.action = action


def sc_mark(level: Int) -> String:
    """The mark before each line - a word too, not colour alone."""
    if level == SC_OK:
        return "ok  "
    if level == SC_NOTE:
        return "note"
    return "MISSING"


def setup_items(f: SetupFacts) -> List[SetupItem]:
    var out = List[SetupItem]()
    var get_mojo = String("File > New project installs it with pixi") if f.pixi.byte_length() > 0 else String("Install pixi (see below), then File > New project")
    var get_mojo_action = SC_FIX_PROJECT if f.pixi.byte_length() > 0 else SC_FIX_NONE
    # Mojo
    var v = mojo_version_of(f.mojo_out)
    if v.byte_length() == 0:
        out.append(SetupItem("Mojo", SC_MISSING, "`" + f.compiler + "` not found", get_mojo + " (or Compile > Compiler command names one)", get_mojo_action))
    else:
        var warn = mojo_mismatch(f.built_with, f.mojo_out)
        if warn.byte_length() > 0:
            out.append(SetupItem("Mojo", SC_NOTE, v + ", but TurboMojo was built with " + mojo_version_of(f.built_with), "Use Mojo " + mojo_version_of(f.built_with) + " (Compile > Compiler command), or rebuild TurboMojo with this one", SC_FIX_COMPILER))
        else:
            out.append(SetupItem("Mojo", SC_OK, v))
    # pixi
    if f.pixi.byte_length() > 0:
        out.append(SetupItem("pixi", SC_OK, f.pixi))
    else:
        out.append(SetupItem("pixi", SC_NOTE, "not found (it installs Mojo and runs tasks)", "curl -fsSL https://pixi.sh/install.sh | sh"))
    # the tools that come with Mojo
    var with_mojo = String("It comes with Mojo: ") + get_mojo
    if f.lsp.byte_length() > 0:
        out.append(SetupItem("Language server", SC_OK, f.lsp))
    else:
        out.append(SetupItem("Language server", SC_MISSING, f.lsp_name + " not found: no live errors, completion or go to definition", with_mojo + " (tools.lsp_server names another)", get_mojo_action))
    if f.dap.byte_length() > 0:
        out.append(SetupItem("Debugger", SC_OK, f.dap))
    else:
        out.append(SetupItem("Debugger", SC_MISSING, f.dap_name + " not found: no Run > Debug", with_mojo + " (tools.debug_adapter names another)", get_mojo_action))
    # documentation (optional)
    if f.docs:
        out.append(SetupItem("Documentation", SC_OK, "downloaded"))
    else:
        out.append(SetupItem("Documentation", SC_NOTE, "not downloaded (optional: offline docs, about 100 MB)", "Help > Download documentation", SC_FIX_DOCS))
    # the terminal
    if not f.probed:
        out.append(SetupItem("Terminal", SC_NOTE, "not asked (no terminal)"))
        return out^
    if f.color == COLOR_TRUE:
        out.append(SetupItem("Colours", SC_OK, "24-bit"))
    else:
        var depth = String("256 colours") if f.color == COLOR_256 else String("16 colours")
        out.append(SetupItem("Colours", SC_NOTE, depth + ": the themes adapt, but are made for 24-bit", "If your terminal has 24-bit colour, set COLORTERM=truecolor" + (" (and in tmux: set -as terminal-features ',*:RGB')" if f.tmux else String(""))))
    if f.kitty_keys:
        out.append(SetupItem("Keys", SC_OK, "every key arrives (kitty keyboard protocol)"))
    else:
        out.append(SetupItem("Keys", SC_NOTE, "a few keys may not arrive (Ctrl-Shift-letter, Ctrl-Enter...)", "kitty, WezTerm, Ghostty and foot send every key" + (" (in tmux: set -s extended-keys on)" if f.tmux else String(""))))
    return out^


def setup_needs_attention(items: List[SetupItem]) -> Bool:
    """Anything missing (not just a note): the first run shows the list then."""
    for it in items:
        if it.level == SC_MISSING:
            return True
    return False
