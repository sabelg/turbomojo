"""Run configurations: named ways of running the project (which file, with what
arguments, environment and working directory, built first or not), kept in the
project's .turbomojo.toml as tables [run.<name>]."""
from std.collections import List
from toml import TomlDoc, toml_quote, toml_set, toml_bool, split_lines, join_lines, line_table
from util import decode, to_str, shell_quote, abs_path, dirname, basename, join_path, stem


struct RunConfig(Copyable, Movable):
    var name: String
    var file: String            # the program; relative to the project folder; '' = the file being edited
    var args: String            # as typed, handed to the shell
    var env: List[String]       # "NAME=value"
    var cwd: String             # where it runs; '' = the folder of the file
    var build: Bool             # compile first and run the result (else `mojo run`)

    def __init__(out self, name: String):
        self.name = name
        self.file = ""
        self.args = ""
        self.env = List[String]()
        self.cwd = ""
        self.build = False


def config_name_problem(name: String) -> String:
    """'' if `name` can name a configuration, else what is wrong."""
    if name.byte_length() == 0:
        return "A name is needed"
    if name == "active":
        return "\"active\" is used by the file itself; choose another name"
    for c in decode(name):
        if not ((c >= 48 and c <= 57) or (c >= 65 and c <= 90) or (c >= 97 and c <= 122) or c == 95 or c == 45):
            return "A name may have letters, digits, - and _ only"
    return ""


def parse_env(text: String) -> Tuple[List[String], String]:
    """Split "A=1 B='two words'" into ["A=1", "B=two words"]. The second result is ''
    or what is wrong."""
    var out = List[String]()
    var cps = decode(text)
    var i = 0
    var n = len(cps)
    while i < n:
        while i < n and cps[i] == 32:
            i += 1
        if i >= n:
            break
        var name = List[Int]()
        while i < n and cps[i] != 61 and cps[i] != 32:
            name.append(cps[i])
            i += 1
        if i >= n or cps[i] != 61 or len(name) == 0:
            return (List[String](), "The environment is written NAME=value NAME=value; \"" + to_str(name) + "\" has no =")
        for k in range(len(name)):
            var c = name[k]
            if not ((c >= 65 and c <= 90) or (c >= 97 and c <= 122) or c == 95 or (c >= 48 and c <= 57 and k > 0)):
                return (List[String](), "\"" + to_str(name) + "\" cannot be the name of an environment variable")
        i += 1
        var value = List[Int]()
        if i < n and (cps[i] == 39 or cps[i] == 34):
            var q = cps[i]
            i += 1
            while i < n and cps[i] != q:
                value.append(cps[i])
                i += 1
            if i >= n:
                return (List[String](), "A quote in the environment is not closed")
            i += 1
        else:
            while i < n and cps[i] != 32:
                value.append(cps[i])
                i += 1
        out.append(to_str(name) + "=" + to_str(value))
    return (out^, String(""))


def env_text(env: List[String]) -> String:
    """The environment as it is typed: values with blanks in quotes."""
    var s = String("")
    for e in env:
        var eq = e.find("=")
        var name = String(e[byte=0:eq]) if eq > 0 else e
        var value = String(e[byte=eq + 1:]) if eq > 0 else String("")
        var quoted = value
        if value.find(" ") >= 0 or value.byte_length() == 0:
            quoted = ("\"" + value + "\"") if value.find("\"") < 0 else ("'" + value + "'")
        s += (" " if s.byte_length() > 0 else "") + name + "=" + quoted
    return s


def load_run_configs(doc: TomlDoc) -> List[RunConfig]:
    """The configurations of a parsed project file, in the order they are written."""
    var out = List[RunConfig]()
    var names = List[String]()
    for k in doc.keys_in("run"):
        var dot = k.find(".")
        if dot <= 0:
            continue                    # run.active and the like
        var name = String(k[byte=0:dot])
        if not (name in names) and config_name_problem(name).byte_length() == 0:
            names.append(name)
    for name in names:
        var c = RunConfig(name)
        var base = "run." + name + "."
        c.file = doc.get_str(base + "file", "")
        c.args = doc.get_str(base + "args", "")
        c.cwd = doc.get_str(base + "cwd", "")
        c.build = doc.get_bool(base + "build", False)
        for e in doc.get_list(base + "env"):
            if e.find("=") > 0:
                c.env.append(e)
        out.append(c^)
    return out^


def active_run_config(doc: TomlDoc) -> String:
    return doc.get_str("run.active", "")


def remove_table(text: String, table: String) -> String:
    """`text` without the table `[table]` and its lines (comments right above the next
    table stay with that table)."""
    var lines = split_lines(text)
    var had_newline = len(lines) > 0 and len(lines[len(lines) - 1]) == 0
    if had_newline:
        _ = lines.pop()
    var out = List[List[Int]]()
    var skipping = False
    for l in lines:
        var t = line_table(l)
        if t.byte_length() > 0:
            skipping = t == table
        if not skipping:
            out.append(l.copy())
    # no heap of blank lines where the table was
    var tidy = List[List[Int]]()
    var blank_run = 0
    for l in out:
        var blank = True
        for c in l:
            if c != 32 and c != 9:
                blank = False
        blank_run = blank_run + 1 if blank else 0
        if blank_run <= 1:
            tidy.append(l.copy())
    while len(tidy) > 0 and len(tidy[len(tidy) - 1]) == 0:
        _ = tidy.pop()
    return join_lines(tidy)


def save_run_config(text: String, c: RunConfig) -> String:
    """`text` (a project file) with the configuration written as [run.<name>],
    replacing one of the same name. Everything else in the file is left as it is."""
    var t = remove_table(text, "run." + c.name)
    var table = "run." + c.name
    t = toml_set(t, table, "file", toml_quote(c.file))
    if c.args.byte_length() > 0:
        t = toml_set(t, table, "args", toml_quote(c.args))
    if len(c.env) > 0:
        var lit = String("[")
        for k in range(len(c.env)):
            lit += (", " if k > 0 else "") + toml_quote(c.env[k])
        t = toml_set(t, table, "env", lit + "]")
    if c.cwd.byte_length() > 0:
        t = toml_set(t, table, "cwd", toml_quote(c.cwd))
    if c.build:
        t = toml_set(t, table, "build", toml_bool(True))
    return t


def set_active_config(text: String, name: String) -> String:
    return toml_set(text, "run", "active", toml_quote(name))


def run_core_command(c: RunConfig, root: String, current: String, compiler: String, include_flags: String) -> String:
    """The shell command that runs a configuration (without the screen handling
    around it): change folder, set the environment, then either `mojo run file args`
    or build and run the result. `current` is the file being edited, used when the
    configuration names no file. '' if there is no file to run."""
    var file = current
    if c.file.byte_length() > 0:
        file = abs_path(root, c.file)
    if file.byte_length() == 0:
        return ""
    var cwd = dirname(file)
    if c.cwd.byte_length() > 0:
        cwd = abs_path(root, c.cwd)
    var cmd = "cd " + shell_quote(cwd) + " && "
    for e in c.env:
        var eq = e.find("=")
        if eq > 0:
            cmd += "export " + String(e[byte=0:eq]) + "=" + shell_quote(String(e[byte=eq + 1:])) + " && "
    if c.build:
        var exe = join_path(dirname(file), "build/" + stem(file))
        cmd += "mkdir -p " + shell_quote(dirname(exe)) + " && " + compiler + " build" + include_flags + " " + shell_quote(file) + " -o " + shell_quote(exe) + " && " + shell_quote(exe)
    else:
        cmd += compiler + " run" + include_flags + " " + shell_quote(file)
    if c.args.byte_length() > 0:
        cmd += " " + c.args
    return cmd
