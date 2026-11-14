"""User and project settings.

Files, later ones overriding earlier ones:
  1. $XDG_CONFIG_HOME/turbomojo/config.toml   (default ~/.config/turbomojo/config.toml)
  2. .turbomojo.toml in the working directory or the nearest parent that has one

Example:

    [ui]
    theme = "midnight"          # classic | midnight | amber | light | contrast | a file's name
                                # in ~/.config/turbomojo/themes/ | "auto" (follow the terminal)
    theme_dark = "midnight"     # with "auto": on a dark terminal
    theme_light = "light"       #   and on a light one
    # scanlines = false         # every other row darker (a CRT look); unset: as the theme has it
    screen_reader = false       # plain, linear screen for screen readers (also TURBOMOJO_SCREEN_READER=1)
    language = ""               # the UI's words from strings/<language>.toml ("" = from LANG)
    key_hints = true            # "Next time: <key>" on the status line after a menu or the palette
    tips = true                 # a tip, once, when a slow way is used where there is a quick one
    reduced_motion = "auto"     # no spinner animation; "auto": as the desktop's animations setting
    keymap = "modern"           # modern | turbo (WordStar keys) | emacs | vim
    layout = "classic"          # classic (overlapping windows) | tiled (panes with tabs, splits)
    explorer = false            # the file explorer open at start (the Modern preset sets it)
    gpu_status = false          # the GPU programs run on, on the status line (asked once, in the background)
    restore_session = true      # started without a file: open what was open in this project last time
    line_numbers = true
    highlight_line = true
    clock = true
    run_in_terminal = true      # Run shows the program in a terminal window; false: on the user screen
    show_whitespace = false
    hyperlinks = true           # file:line in the Message window and the agent panel as links (OSC 8)
    hyperlink_format = "file://{host}{path}"   # or e.g. "vscode://file{path}:{line}:{column}"
    glyphs = "unicode"          # unicode (box drawing, arrows) | ascii (only ASCII) | nerd (+ Nerd Font icons)
    images = "auto"             # pictures in the documentation: auto | kitty | sixel | off (else "[image: ...]")
    dim_unfocused = true        # dim the screen while the terminal window does not have the focus

    [editor]
    auto_indent = true
    soft_wrap = false           # continue long lines on the next screen row
    semantic_colors = true      # colours from the language server over the built-in ones
    quiet_colors = false        # four code colours; errors and search hits stand out most
    inlay_hints = true          # the language server's notes (inferred types) after the line
    persistent_undo = true      # keep undo history and cursor position between sessions
    auto_pairs = true           # typing ( [ { " ' also inserts the closing one
    breadcrumbs = true          # the title shows where the cursor is: file › struct › def
    sticky_scroll = true        # the headers of the scopes scrolled away stay on the top rows
    minimap = false             # the whole file in braille dots at the right edge
    minimap_style = "auto"      # braille | blocks (half blocks, for fonts without braille); auto: blocks on the Linux console
    highlight_word = true       # show the other uses of the word the cursor is on
    relative_numbers = false    # the gutter counts lines from the cursor's (vim's relativenumber)
    trim_trailing_whitespace = false   # on save (.editorconfig overrides)
    rulers = []                 # e.g. [80, 100]: vertical guides after these columns
    tab_width = 4               # display width of a tab character
    indent_size = 4             # spaces per indent level (.editorconfig overrides both)
    large_file_mb = 50          # files above this size open in large-file mode

    [tools]
    compiler = "mojo"
    lsp_server = "mojo-lsp-server"
    debug_adapter = "mojo-lldb-dap"     # Run > Debug; a command with arguments is used as it is
    agent = ""                  # a coding agent that speaks ACP, for File > Agent panel
    plugins = true              # start the plugins in ~/.config/turbomojo/plugins

# Language servers for other languages: F7 on such a file starts its server (in a
# trusted folder), for problems as you type and Describe symbol (Alt-I).
# [lsp.python]
# command = "ruff server"
# extensions = [".py"]
                                # (e.g. "claude-agent-acp", "gemini --experimental-acp", "codex-acp")
    include_paths = []          # extra -I folders for the compiler and the language server;
                                # relative ones are taken from the folder of the config file
    docs_paths = []             # folders with Mojo sources of libraries: their documentation
                                # is found by Ctrl-F1 too (e.g. a checkout of the standard library)
    docs_home = ""              # where Help > Mojo documentation keeps its download
                                # (empty: ~/.local/share/turbomojo/docs)

    [keys]
    "file.save" = ["F2", "Ctrl-S"]     # command name = one key or a list of keys
    "edit.duplicateLine" = "Ctrl-D"

Options changed from the Options menu are written back to the user file; everything else
in that file (comments, order, other keys) is left as it is."""
from glyphs import glyphs_of
from std.collections import List
from commands import keymap_from_name
from toml import TomlDoc, toml_parse, T_STR, T_BOOL, T_LIST, T_INT
from util import env_or, path_exists, dirname, join_path

comptime PROJECT_CONFIG_NAME = ".turbomojo.toml"


def theme_names() -> List[String]:
    var out = List[String]()
    for n in ["classic", "midnight", "amber"]:
        out.append(String(n))
    return out^


def theme_from_name(name: String) -> Int:
    var names = theme_names()
    for i in range(len(names)):
        if names[i] == name:
            return i
    return -1


def theme_name(i: Int) -> String:
    var names = theme_names()
    if i < 0 or i >= len(names):
        return names[0]
    return names[i]


def config_home() -> String:
    var x = env_or("XDG_CONFIG_HOME", "")
    if x.byte_length() > 0:
        return x + "/turbomojo"
    return env_or("HOME", "/tmp") + "/.config/turbomojo"


def user_config_path() -> String:
    return config_home() + "/config.toml"


def find_project_config(start_dir: String) -> String:
    """Path of the nearest .turbomojo.toml at or above start_dir ('' if none)."""
    var d = String(start_dir)
    for _ in range(64):
        var p = join_path(d, PROJECT_CONFIG_NAME)
        if path_exists(p):
            return p
        if d == "/" or d == "." or d.byte_length() == 0:
            break
        d = dirname(d)
    return ""


def read_text(path: String) -> String:
    """File contents, or '' when the file is missing or unreadable."""
    if path.byte_length() == 0 or not path_exists(path):
        return ""
    try:
        var s: String
        with open(path, "r") as f:
            s = f.read()
        return s
    except:
        return ""


struct Settings(Copyable, Movable):
    var theme: String           # a theme id, or "auto"
    var theme_given: Bool       # ui.theme is in a config file (NO_COLOR does not override it)
    var theme_dark: String      # for "auto"
    var theme_light: String
    var scanlines: Int          # ui.scanlines: -1 as the theme has it, 0 off, 1 on
    var screen_reader: Bool     # ui.screen_reader: plain, linear drawing for screen readers
    var language: String        # ui.language ('' = from LANG)
    var key_hints: Bool         # ui.key_hints
    var tips: Bool              # ui.tips
    var plugins: Bool           # tools.plugins
    var lsp_names: List[String]         # [lsp.<name>]: other language servers
    var lsp_cmds: List[String]          #   their command
    var lsp_exts: List[List[String]]    #   the file endings they are for (".py")
    var lsp_langs: List[String]         #   the languageId they are told (default: the name)
    var reduced_motion: Int     # ui.reduced_motion: -1 auto (the desktop's setting), 0 off, 1 on
    var keymap: Int      # 0 modern, 1 turbo, 2 emacs
    var tiled: Bool      # ui.layout = "tiled"
    var restore_session: Bool
    var explorer: Bool          # ui.explorer: the file explorer open at start
    var gpu_status: Bool        # ui.gpu_status
    var line_numbers: Bool
    var auto_indent: Bool
    var highlight_line: Bool
    var clock: Bool
    var hyperlinks: Bool        # ui.hyperlinks
    var hyperlink_format: String    # ui.hyperlink_format: {host} {path} {line} {column}
    var glyphs: String              # ui.glyphs: unicode | ascii | nerd
    var images: String              # ui.images: auto | kitty | sixel | off
    var dim_unfocused: Bool         # ui.dim_unfocused
    var minimap_style: String       # editor.minimap_style: auto | braille | blocks
    var run_in_terminal: Bool
    var show_whitespace: Bool
    var soft_wrap: Bool
    var semantic_colors: Bool
    var quiet_colors: Bool
    var inlay_hints: Bool
    var auto_pairs: Bool
    var breadcrumbs: Bool
    var sticky_scroll: Bool
    var minimap: Bool
    var highlight_word: Bool
    var relative_numbers: Bool
    var persistent_undo: Bool
    var trim_trailing: Bool
    var rulers: List[Int]
    var compiler: String
    var lsp_server: String
    var debug_adapter: String
    var agent: String
    var agent_mode: String
    var include_paths: List[String]
    var docs_paths: List[String]
    var docs_home: String
    var tab_width: Int
    var indent_size: Int
    var large_file_mb: Int
    var key_commands: List[String]       # command names with custom bindings
    var key_names: List[List[String]]    # their key names, as written in the file
    var line_blame: Bool
    var format_on_save: Bool
    var pixi_env: String
    var lsp_auto_start: Bool
    var warnings: List[String]

    def __init__(out self):
        """The built-in defaults."""
        self.theme = "classic"
        self.theme_given = False
        self.theme_dark = "midnight"
        self.theme_light = "light"
        self.scanlines = -1
        self.screen_reader = False
        self.language = ""
        self.key_hints = True
        self.tips = True
        self.plugins = True
        self.lsp_names = List[String]()
        self.lsp_cmds = List[String]()
        self.lsp_exts = List[List[String]]()
        self.lsp_langs = List[String]()
        self.reduced_motion = -1
        self.keymap = 0
        self.tiled = False
        self.restore_session = True
        self.explorer = False
        self.gpu_status = False
        self.line_numbers = True
        self.auto_indent = True
        self.highlight_line = True
        self.clock = True
        self.hyperlinks = True
        self.hyperlink_format = "file://{host}{path}"
        self.glyphs = "unicode"
        self.images = "auto"
        self.dim_unfocused = True
        self.minimap_style = "auto"
        self.run_in_terminal = True
        self.show_whitespace = False
        self.soft_wrap = False
        self.semantic_colors = True
        self.quiet_colors = False
        self.inlay_hints = True
        self.auto_pairs = True
        self.breadcrumbs = True
        self.sticky_scroll = True
        self.minimap = False
        self.highlight_word = True
        self.relative_numbers = False
        self.persistent_undo = True
        self.trim_trailing = False
        self.rulers = List[Int]()
        self.compiler = "mojo"
        self.lsp_server = "mojo-lsp-server"
        self.debug_adapter = "mojo-lldb-dap"
        self.agent = ""
        self.agent_mode = "ask"
        self.include_paths = List[String]()
        self.docs_paths = List[String]()
        self.docs_home = ""
        self.tab_width = 4
        self.indent_size = 4
        self.large_file_mb = 50
        self.key_commands = List[String]()
        self.key_names = List[List[String]]()
        self.line_blame = False
        self.format_on_save = False
        self.pixi_env = "default"
        self.lsp_auto_start = True
        self.warnings = List[String]()

    def take_bool(mut self, doc: TomlDoc, key: String, current: Bool) -> Bool:
        var i = doc.find(key)
        if i < 0:
            return current
        if doc.vals[i].kind != T_BOOL:
            self.warnings.append(key + " must be true or false")
            return current
        return doc.vals[i].b

    def take_size(mut self, doc: TomlDoc, key: String, current: Int) -> Int:
        var i = doc.find(key)
        if i < 0:
            return current
        if doc.vals[i].kind != T_INT or doc.vals[i].i < 1 or doc.vals[i].i > 64:
            self.warnings.append(key + " must be a number from 1 to 64")
            return current
        return doc.vals[i].i

    def apply(mut self, doc: TomlDoc):
        """Overlay the values present in `doc`; invalid ones are reported and skipped."""
        for p in doc.problems:
            self.warnings.append(p)
        self.line_numbers = self.take_bool(doc, "ui.line_numbers", self.line_numbers)
        self.highlight_line = self.take_bool(doc, "ui.highlight_line", self.highlight_line)
        self.clock = self.take_bool(doc, "ui.clock", self.clock)
        self.hyperlinks = self.take_bool(doc, "ui.hyperlinks", self.hyperlinks)
        self.hyperlink_format = doc.get_str("ui.hyperlink_format", self.hyperlink_format)
        if self.hyperlink_format.find("{path}") < 0:
            self.warnings.append("ui.hyperlink_format must contain {path}")
            self.hyperlink_format = "file://{host}{path}"
        var im = doc.get_str("ui.images", self.images)
        if im != "auto" and im != "kitty" and im != "sixel" and im != "off":
            self.warnings.append("ui.images must be auto, kitty, sixel or off")
        else:
            self.images = im
        var g = doc.get_str("ui.glyphs", self.glyphs)
        if glyphs_of(g) < 0:
            self.warnings.append("ui.glyphs must be unicode, ascii or nerd")
        else:
            self.glyphs = g
        var ms = doc.get_str("editor.minimap_style", self.minimap_style)
        if ms != "auto" and ms != "braille" and ms != "blocks":
            self.warnings.append("editor.minimap_style must be auto, braille or blocks")
        else:
            self.minimap_style = ms
        self.run_in_terminal = self.take_bool(doc, "ui.run_in_terminal", self.run_in_terminal)
        self.dim_unfocused = self.take_bool(doc, "ui.dim_unfocused", self.dim_unfocused)
        self.show_whitespace = self.take_bool(doc, "ui.show_whitespace", self.show_whitespace)
        self.soft_wrap = self.take_bool(doc, "editor.soft_wrap", self.soft_wrap)
        self.semantic_colors = self.take_bool(doc, "editor.semantic_colors", self.semantic_colors)
        self.quiet_colors = self.take_bool(doc, "editor.quiet_colors", self.quiet_colors)
        self.inlay_hints = self.take_bool(doc, "editor.inlay_hints", self.inlay_hints)
        self.auto_pairs = self.take_bool(doc, "editor.auto_pairs", self.auto_pairs)
        self.key_hints = self.take_bool(doc, "ui.key_hints", self.key_hints)
        self.tips = self.take_bool(doc, "ui.tips", self.tips)
        self.plugins = self.take_bool(doc, "tools.plugins", self.plugins)
        self.breadcrumbs = self.take_bool(doc, "editor.breadcrumbs", self.breadcrumbs)
        self.sticky_scroll = self.take_bool(doc, "editor.sticky_scroll", self.sticky_scroll)
        self.minimap = self.take_bool(doc, "editor.minimap", self.minimap)
        self.highlight_word = self.take_bool(doc, "editor.highlight_word", self.highlight_word)
        self.relative_numbers = self.take_bool(doc, "editor.relative_numbers", self.relative_numbers)
        self.persistent_undo = self.take_bool(doc, "editor.persistent_undo", self.persistent_undo)
        self.trim_trailing = self.take_bool(doc, "editor.trim_trailing_whitespace", self.trim_trailing)
        self.format_on_save = self.take_bool(doc, "editor.format_on_save", self.format_on_save)
        self.line_blame = self.take_bool(doc, "ui.line_blame", self.line_blame)
        self.lsp_auto_start = self.take_bool(doc, "tools.lsp_auto_start", self.lsp_auto_start)
        var pei = doc.find("tools.pixi_env")
        if pei >= 0:
            if doc.vals[pei].kind != T_STR or doc.vals[pei].s.byte_length() == 0:
                self.warnings.append("tools.pixi_env must be a non-empty environment name")
            else:
                self.pixi_env = doc.vals[pei].s
        var ri = doc.find("editor.rulers")
        if ri >= 0:
            var cols = List[Int]()
            var good = doc.vals[ri].kind == T_LIST or doc.vals[ri].kind == T_INT
            if doc.vals[ri].kind == T_INT:
                cols.append(doc.vals[ri].i)
            elif good:
                for item in doc.vals[ri].items:
                    try:
                        cols.append(atol(item))
                    except:
                        good = False
            for c in cols:
                if c < 1 or c > 1000:
                    good = False
            if good:
                self.rulers = cols^
            else:
                self.warnings.append("editor.rulers must be a list of column numbers from 1 to 1000")
        self.auto_indent = self.take_bool(doc, "editor.auto_indent", self.auto_indent)
        self.restore_session = self.take_bool(doc, "ui.restore_session", self.restore_session)
        self.explorer = self.take_bool(doc, "ui.explorer", self.explorer)
        self.gpu_status = self.take_bool(doc, "ui.gpu_status", self.gpu_status)
        var lay_i = doc.find("ui.layout")
        if lay_i >= 0:
            if doc.vals[lay_i].kind == T_STR and (doc.vals[lay_i].s == "classic" or doc.vals[lay_i].s == "tiled"):
                self.tiled = doc.vals[lay_i].s == "tiled"
            else:
                self.warnings.append("ui.layout must be \"classic\" or \"tiled\"")
        var ki2 = doc.find("ui.keymap")
        if ki2 >= 0:
            var km = keymap_from_name(doc.vals[ki2].s) if doc.vals[ki2].kind == T_STR else -1
            if km < 0:
                self.warnings.append("ui.keymap must be \"modern\", \"turbo\", \"emacs\" or \"vim\"")
            else:
                self.keymap = km
        # theme names are checked once the theme files are read (appstate)
        for tk in ["ui.theme", "ui.theme_dark", "ui.theme_light"]:
            var ti = doc.find(tk)
            if ti >= 0:
                if doc.vals[ti].kind != T_STR or doc.vals[ti].s.byte_length() == 0:
                    self.warnings.append(String(tk) + " must be the name of a theme")
                elif String(tk) == "ui.theme":
                    self.theme = doc.vals[ti].s
                    self.theme_given = True
                elif String(tk) == "ui.theme_dark":
                    self.theme_dark = doc.vals[ti].s
                else:
                    self.theme_light = doc.vals[ti].s
        var sli = doc.find("ui.scanlines")
        if sli >= 0:
            if doc.vals[sli].kind != T_BOOL:
                self.warnings.append("ui.scanlines must be true or false")
            else:
                self.scanlines = 1 if doc.vals[sli].b else 0
        var lgi = doc.find("ui.language")
        if lgi >= 0:
            if doc.vals[lgi].kind != T_STR:
                self.warnings.append("ui.language must be a language code such as \"de\"")
            else:
                self.language = doc.vals[lgi].s
        var sri = doc.find("ui.screen_reader")
        if sri >= 0:
            if doc.vals[sri].kind != T_BOOL:
                self.warnings.append("ui.screen_reader must be true or false")
            else:
                self.screen_reader = doc.vals[sri].b
        var rmi = doc.find("ui.reduced_motion")
        if rmi >= 0:
            if doc.vals[rmi].kind == T_BOOL:
                self.reduced_motion = 1 if doc.vals[rmi].b else 0
            elif doc.vals[rmi].kind == T_STR and doc.vals[rmi].s == "auto":
                self.reduced_motion = -1
            else:
                self.warnings.append("ui.reduced_motion must be true, false or \"auto\"")
        var ci = doc.find("tools.compiler")
        if ci >= 0:
            if doc.vals[ci].kind != T_STR or doc.vals[ci].s.byte_length() == 0:
                self.warnings.append("tools.compiler must be a non-empty string")
            else:
                self.compiler = doc.vals[ci].s
        var si = doc.find("tools.lsp_server")
        if si >= 0:
            if doc.vals[si].kind != T_STR or doc.vals[si].s.byte_length() == 0:
                self.warnings.append("tools.lsp_server must be a non-empty string")
            else:
                self.lsp_server = doc.vals[si].s
        var dai = doc.find("tools.debug_adapter")
        if dai >= 0:
            if doc.vals[dai].kind != T_STR or doc.vals[dai].s.byte_length() == 0:
                self.warnings.append("tools.debug_adapter must be a non-empty string")
            else:
                self.debug_adapter = doc.vals[dai].s
        var agi = doc.find("tools.agent")
        if agi >= 0:
            if doc.vals[agi].kind != T_STR:
                self.warnings.append("tools.agent must be a string (a command)")
            else:
                self.agent = doc.vals[agi].s
        var ami = doc.find("tools.agent_mode")
        if ami >= 0:
            if doc.vals[ami].kind != T_STR:
                self.warnings.append("tools.agent_mode must be a string")
            else:
                self.agent_mode = doc.vals[ami].s
        var ii = doc.find("tools.include_paths")
        if ii >= 0:
            if doc.vals[ii].kind == T_STR and doc.vals[ii].s.byte_length() > 0:
                self.include_paths = List[String]()
                self.include_paths.append(doc.vals[ii].s)
            elif doc.vals[ii].kind == T_LIST:
                self.include_paths = doc.vals[ii].items.copy()
            else:
                self.warnings.append("tools.include_paths must be a folder or a list of folders")
        self.docs_home = doc.get_str("tools.docs_home", self.docs_home)
        var di = doc.find("tools.docs_paths")
        if di >= 0:
            if doc.vals[di].kind == T_STR and doc.vals[di].s.byte_length() > 0:
                self.docs_paths = List[String]()
                self.docs_paths.append(doc.vals[di].s)
            elif doc.vals[di].kind == T_LIST:
                self.docs_paths = doc.vals[di].items.copy()
            else:
                self.warnings.append("tools.docs_paths must be a folder or a list of folders")
        self.tab_width = self.take_size(doc, "editor.tab_width", self.tab_width)
        self.indent_size = self.take_size(doc, "editor.indent_size", self.indent_size)
        var li = doc.find("editor.large_file_mb")
        if li >= 0:
            if doc.vals[li].kind != T_INT or doc.vals[li].i < 1 or doc.vals[li].i > 100000:
                self.warnings.append("editor.large_file_mb must be a number from 1 to 100000")
            else:
                self.large_file_mb = doc.vals[li].i
        for name in doc.keys_in("keys"):
            var ki = doc.find("keys." + name)
            if doc.vals[ki].kind != T_STR and doc.vals[ki].kind != T_LIST:
                self.warnings.append("keys." + name + " must be a key name or a list of key names")
                continue
            self.key_commands.append(name)
            self.key_names.append(doc.get_list("keys." + name))
        # [lsp.<name>]: language servers for other languages
        var seen = List[String]()
        for key in doc.keys_in("lsp"):
            var dot = key.find(".")
            if dot <= 0:
                self.warnings.append("lsp." + key + ": a language server is a table, [lsp." + key + "]")
                continue
            var name = String(key[byte=0:dot])
            var field = String(key[byte=dot + 1:])
            if field != "command" and field != "extensions" and field != "language":
                self.warnings.append("unknown setting lsp." + key + " (a server has command, extensions and language)")
            if name in seen:
                continue
            seen.append(name)
            var cmd = doc.get_str("lsp." + name + ".command", "")
            var exts = doc.get_list("lsp." + name + ".extensions")
            if cmd.byte_length() == 0 or len(exts) == 0:
                self.warnings.append("lsp." + name + " needs a command and extensions (for example extensions = [\".py\"])")
                continue
            var at = -1
            for j in range(len(self.lsp_names)):
                if self.lsp_names[j] == name:
                    at = j
            var lang = doc.get_str("lsp." + name + ".language", name)
            if at >= 0:                 # (the project's file overrides the user's)
                self.lsp_cmds[at] = cmd
                self.lsp_exts[at] = exts.copy()
                self.lsp_langs[at] = lang
            else:
                self.lsp_names.append(name)
                self.lsp_cmds.append(cmd)
                self.lsp_exts.append(exts.copy())
                self.lsp_langs.append(lang)
        # point out likely typos
        var known = List[String]()
        for k in ["ui.theme", "ui.theme_dark", "ui.theme_light", "ui.scanlines", "ui.screen_reader", "ui.reduced_motion", "ui.language", "ui.key_hints", "ui.tips", "ui.keymap", "ui.layout", "ui.restore_session", "ui.explorer", "ui.gpu_status", "ui.line_blame", "ui.line_numbers", "ui.highlight_line", "ui.clock", "ui.hyperlinks", "ui.hyperlink_format", "ui.glyphs", "ui.images", "ui.dim_unfocused", "ui.run_in_terminal", "ui.show_whitespace", "editor.auto_indent", "editor.soft_wrap", "editor.semantic_colors", "editor.quiet_colors", "editor.inlay_hints", "editor.auto_pairs", "editor.breadcrumbs", "editor.sticky_scroll", "editor.minimap", "editor.minimap_style", "editor.highlight_word", "editor.relative_numbers", "editor.persistent_undo", "editor.trim_trailing_whitespace", "editor.format_on_save", "editor.rulers", "editor.tab_width", "editor.indent_size", "editor.large_file_mb", "tools.compiler", "tools.lsp_server", "tools.lsp_auto_start", "tools.pixi_env", "tools.debug_adapter", "tools.agent", "tools.agent_mode", "tools.plugins", "tools.include_paths", "tools.docs_paths", "tools.docs_home"]:
            known.append(String(k))
        for k in doc.keys:
            if k.startswith("keys.") or k.startswith("run.") or k.startswith("lsp."):
                continue                # [run.<name>] tables are the run configurations
            if not (k in known):
                var msg = "unknown setting " + k
                if not (msg in self.warnings):
                    self.warnings.append(msg)


def load_settings(user_text: String, project_text: String) -> Settings:
    """Defaults, then the user file, then the project file."""
    var s = Settings()
    if user_text.byte_length() > 0:
        s.apply(toml_parse(user_text))
    if project_text.byte_length() > 0:
        s.apply(toml_parse(project_text))
    return s^
