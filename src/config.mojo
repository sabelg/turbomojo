"""User and project settings.

Files, later ones overriding earlier ones:
  1. $XDG_CONFIG_HOME/turbomojo/config.toml   (default ~/.config/turbomojo/config.toml)
  2. .turbomojo.toml in the working directory or the nearest parent that has one

Example:

    [ui]
    theme = "midnight"          # classic | midnight | amber
    keymap = "modern"           # modern | turbo (WordStar keys) | emacs
    layout = "classic"          # classic (overlapping windows) | tiled (panes with tabs, splits)
    restore_session = true      # started without a file: open what was open in this project last time
    line_numbers = true
    highlight_line = true
    clock = true
    run_in_terminal = true      # Run shows the program in a terminal window; false: on the user screen
    show_whitespace = false

    [editor]
    auto_indent = true
    soft_wrap = false           # continue long lines on the next screen row
    semantic_colors = true      # colours from the language server over the built-in ones
    inlay_hints = true          # the language server's notes (inferred types) after the line
    persistent_undo = true      # keep undo history and cursor position between sessions
    auto_pairs = true           # typing ( [ { " ' also inserts the closing one
    highlight_word = true       # show the other uses of the word the cursor is on
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
                                # (e.g. "claude-code-acp", "gemini --experimental-acp", "codex-acp")
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
    var theme: Int
    var keymap: Int      # 0 modern, 1 turbo, 2 emacs
    var tiled: Bool      # ui.layout = "tiled"
    var restore_session: Bool
    var line_numbers: Bool
    var auto_indent: Bool
    var highlight_line: Bool
    var clock: Bool
    var run_in_terminal: Bool
    var show_whitespace: Bool
    var soft_wrap: Bool
    var semantic_colors: Bool
    var inlay_hints: Bool
    var auto_pairs: Bool
    var highlight_word: Bool
    var persistent_undo: Bool
    var trim_trailing: Bool
    var rulers: List[Int]
    var compiler: String
    var lsp_server: String
    var debug_adapter: String
    var agent: String
    var include_paths: List[String]
    var docs_paths: List[String]
    var docs_home: String
    var tab_width: Int
    var indent_size: Int
    var large_file_mb: Int
    var key_commands: List[String]       # command names with custom bindings
    var key_names: List[List[String]]    # their key names, as written in the file
    var warnings: List[String]

    def __init__(out self):
        """The built-in defaults."""
        self.theme = 0
        self.keymap = 0
        self.tiled = False
        self.restore_session = True
        self.line_numbers = True
        self.auto_indent = True
        self.highlight_line = True
        self.clock = True
        self.run_in_terminal = True
        self.show_whitespace = False
        self.soft_wrap = False
        self.semantic_colors = True
        self.inlay_hints = True
        self.auto_pairs = True
        self.highlight_word = True
        self.persistent_undo = True
        self.trim_trailing = False
        self.rulers = List[Int]()
        self.compiler = "mojo"
        self.lsp_server = "mojo-lsp-server"
        self.debug_adapter = "mojo-lldb-dap"
        self.agent = ""
        self.include_paths = List[String]()
        self.docs_paths = List[String]()
        self.docs_home = ""
        self.tab_width = 4
        self.indent_size = 4
        self.large_file_mb = 50
        self.key_commands = List[String]()
        self.key_names = List[List[String]]()
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
        self.run_in_terminal = self.take_bool(doc, "ui.run_in_terminal", self.run_in_terminal)
        self.show_whitespace = self.take_bool(doc, "ui.show_whitespace", self.show_whitespace)
        self.soft_wrap = self.take_bool(doc, "editor.soft_wrap", self.soft_wrap)
        self.semantic_colors = self.take_bool(doc, "editor.semantic_colors", self.semantic_colors)
        self.inlay_hints = self.take_bool(doc, "editor.inlay_hints", self.inlay_hints)
        self.auto_pairs = self.take_bool(doc, "editor.auto_pairs", self.auto_pairs)
        self.highlight_word = self.take_bool(doc, "editor.highlight_word", self.highlight_word)
        self.persistent_undo = self.take_bool(doc, "editor.persistent_undo", self.persistent_undo)
        self.trim_trailing = self.take_bool(doc, "editor.trim_trailing_whitespace", self.trim_trailing)
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
                self.warnings.append("ui.keymap must be \"modern\", \"turbo\" or \"emacs\"")
            else:
                self.keymap = km
        var ti = doc.find("ui.theme")
        if ti >= 0:
            var t = theme_from_name(doc.vals[ti].s) if doc.vals[ti].kind == T_STR else -1
            if t < 0:
                self.warnings.append("ui.theme must be \"classic\", \"midnight\" or \"amber\"")
            else:
                self.theme = t
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
        # point out likely typos
        var known = List[String]()
        for k in ["ui.theme", "ui.keymap", "ui.layout", "ui.restore_session", "ui.line_numbers", "ui.highlight_line", "ui.clock", "ui.run_in_terminal", "ui.show_whitespace", "editor.auto_indent", "editor.soft_wrap", "editor.semantic_colors", "editor.inlay_hints", "editor.auto_pairs", "editor.highlight_word", "editor.persistent_undo", "editor.trim_trailing_whitespace", "editor.rulers", "editor.tab_width", "editor.indent_size", "editor.large_file_mb", "tools.compiler", "tools.lsp_server", "tools.debug_adapter", "tools.agent", "tools.include_paths", "tools.docs_paths", "tools.docs_home"]:
            known.append(String(k))
        for k in doc.keys:
            if k.startswith("keys.") or k.startswith("run."):
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
