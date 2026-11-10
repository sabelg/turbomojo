"""User and project settings.

Files, later ones overriding earlier ones:
  1. $XDG_CONFIG_HOME/turbomojo/config.toml   (default ~/.config/turbomojo/config.toml)
  2. .turbomojo.toml in the working directory or the nearest parent that has one

Example:

    [ui]
    theme = "midnight"          # classic | midnight | amber
    line_numbers = true
    highlight_line = true
    clock = true
    show_whitespace = false

    [editor]
    auto_indent = true

    [tools]
    compiler = "mojo"

    [keys]
    "file.save" = ["F2", "Ctrl-S"]     # command name = one key or a list of keys
    "edit.duplicateLine" = "Ctrl-D"

Options changed from the Options menu are written back to the user file; everything else
in that file (comments, order, other keys) is left as it is."""
from std.collections import List
from toml import TomlDoc, toml_parse, T_STR, T_BOOL, T_LIST
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
    var line_numbers: Bool
    var auto_indent: Bool
    var highlight_line: Bool
    var clock: Bool
    var show_whitespace: Bool
    var compiler: String
    var key_commands: List[String]       # command names with custom bindings
    var key_names: List[List[String]]    # their key names, as written in the file
    var warnings: List[String]

    def __init__(out self):
        """The built-in defaults."""
        self.theme = 0
        self.line_numbers = True
        self.auto_indent = True
        self.highlight_line = True
        self.clock = True
        self.show_whitespace = False
        self.compiler = "mojo"
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

    def apply(mut self, doc: TomlDoc):
        """Overlay the values present in `doc`; invalid ones are reported and skipped."""
        for p in doc.problems:
            self.warnings.append(p)
        self.line_numbers = self.take_bool(doc, "ui.line_numbers", self.line_numbers)
        self.highlight_line = self.take_bool(doc, "ui.highlight_line", self.highlight_line)
        self.clock = self.take_bool(doc, "ui.clock", self.clock)
        self.show_whitespace = self.take_bool(doc, "ui.show_whitespace", self.show_whitespace)
        self.auto_indent = self.take_bool(doc, "editor.auto_indent", self.auto_indent)
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
        for name in doc.keys_in("keys"):
            var ki = doc.find("keys." + name)
            if doc.vals[ki].kind != T_STR and doc.vals[ki].kind != T_LIST:
                self.warnings.append("keys." + name + " must be a key name or a list of key names")
                continue
            self.key_commands.append(name)
            self.key_names.append(doc.get_list("keys." + name))
        # point out likely typos
        var known = List[String]()
        for k in ["ui.theme", "ui.line_numbers", "ui.highlight_line", "ui.clock", "ui.show_whitespace", "editor.auto_indent", "tools.compiler"]:
            known.append(String(k))
        for k in doc.keys:
            if k.startswith("keys."):
                continue
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
