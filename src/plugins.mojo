"""Plugins: programs of their own that TurboMojo starts and talks to over JSON-RPC,
one message per line on their standard input and output (the transport of the agent
client). A plugin that crashes or hangs cannot take the IDE down: it is marked as
stopped and its commands say so.

A plugin is a folder in ~/.config/turbomojo/plugins/ (never in a project: opening a
folder must not run its code) with a `plugin.toml`:

    name = "wordcount"
    command = "python3 plugin.py"      # started in the plugin's folder

The conversation (docs/PLUGINS.md has the whole API):
- TurboMojo asks `initialize` {api, version, root}; the plugin answers with what it
  adds: {"commands": [{"id", "title", "hint"?, "key"?}], "events": ["open", "save",
  "build"]}.
- Its commands are in the ≡ menu (below a line) and the palette; a key is given only
  if no command has it. Running one sends the request `command` {"id"}.
- Events come as the notification `event` {"name", "path"?, "ok"?}.
- The plugin may ask `editor/get` (path, text, line, column, selection of the editor in
  front), `editor/insert` {"text"} (at the cursor, undoable), `ui/message` {"text"},
  `ui/notify` {"level", "title", "text"} and `status/set` {"text"} (its item on the
  status line).
"""
from std.collections import List
from rpc import RpcConn
from toml import toml_parse
from json import json_parse, J_ARR
from commands import Registry, Placement, parse_key, CM_NONE
from signals import own_pid
from toml import toml_quote
from util import path_exists, run_capture, run_system, shell_quote, bytes_to_str, write_file, str_bytes, env_or, basename
from config import read_text

comptime PL_STARTING = 1
comptime PL_READY = 2
comptime PL_STOPPED = 3

comptime PLUGIN_API = 2
comptime CM_PLUGIN0 = 10000         # plugin commands: CM_PLUGIN0 + 100 * plugin + command
comptime PLUGIN_CMDS_MAX = 100
comptime PLUGIN_INIT_MS = 10000     # a plugin that has not answered initialize by then is stopped


@fieldwise_init
struct PluginRangeEdit(Copyable, Movable):
    var start_line: Int
    var start_col: Int
    var end_line: Int
    var end_col: Int
    var text: String


def parse_plugin_edits_json(json_str: String) -> List[PluginRangeEdit]:
    var out = List[PluginRangeEdit]()
    var doc = json_parse(json_str)
    if not doc.ok:
        return out^
    var arr = doc.get(0, "edits")
    if doc.kind(arr) != J_ARR:
        return out^
    for enode in doc.children(arr):
        var sl = doc.int(doc.get(enode, "start_line"), 1)
        var sc = doc.int(doc.get(enode, "start_col"), 1)
        var el = doc.int(doc.get(enode, "end_line"), sl)
        var ec = doc.int(doc.get(enode, "end_col"), sc)
        var txt = doc.str(doc.get(enode, "text"), "")
        out.append(PluginRangeEdit(sl, sc, el, ec, txt))
    return out^


struct PluginCmd(Copyable, Movable):
    var id: String          # the plugin's own name for it
    var title: String
    var hint: String
    var key: String         # as the plugin wrote it ("Ctrl-Alt-W"), '' for none

    def __init__(out self, id: String, title: String, hint: String, key: String):
        self.id = id
        self.title = title
        self.hint = hint
        self.key = key


struct Plugin(Copyable, Movable):
    var name: String
    var dir: String
    var command: String
    var conn: RpcConn
    var state: Int
    var why: String         # why it stopped
    var init_id: Int
    var started_ns: Int
    var cmds: List[PluginCmd]
    var events: List[String]
    var status: String      # its status-line item

    def __init__(out self, name: String, dir: String, command: String):
        self.name = name
        self.dir = dir
        self.command = command
        self.conn = RpcConn()
        self.conn.lines = True
        self.state = PL_STOPPED
        self.why = "not started"
        self.init_id = -1
        self.started_ns = 0
        self.cmds = List[PluginCmd]()
        self.events = List[String]()
        self.status = ""


def find_plugins(dir: String, mut warnings: List[String]) -> List[Plugin]:
    """The plugins in `dir`, one per folder with a plugin.toml, by folder name."""
    var out = List[Plugin]()
    if dir.byte_length() == 0 or not path_exists(dir):
        return out^
    var r = run_capture("ls -1 " + shell_quote(dir) + " 2>/dev/null")
    for raw in bytes_to_str(r.out).split("\n"):
        var sub = String(String(raw).strip())
        if sub.byte_length() == 0:
            continue
        var pdir = dir + "/" + sub
        var manifest = pdir + "/plugin.toml"
        if not path_exists(manifest):
            continue
        var doc = toml_parse(read_text(manifest))
        for p in doc.problems:
            warnings.append("plugins/" + sub + "/plugin.toml: " + p)
        var command = doc.get_str("command", "")
        if command.byte_length() == 0:
            if doc.get_str("kind", "") == "snippets" or path_exists(pdir + "/snippets.toml"):
                continue
            warnings.append("plugins/" + sub + "/plugin.toml: no command to start")
            continue
        out.append(Plugin(doc.get_str("name", sub), pdir, command))
    return out^


def plugin_cmd_id(p: Int, c: Int) -> Int:
    return CM_PLUGIN0 + p * PLUGIN_CMDS_MAX + c


def register_plugins(mut reg: Registry, plugins: List[Plugin]) -> List[String]:
    """Put the commands of the running plugins into the registry, in the ≡ menu below a
    line; a key only where no command has it. Returns what could not be done."""
    var warn = List[String]()
    var any = False
    for p in range(len(plugins)):
        if plugins[p].state != PL_READY:
            continue
        for c in range(min(len(plugins[p].cmds), PLUGIN_CMDS_MAX)):
            ref pc = plugins[p].cmds[c]
            var keys = List[Int]()
            if pc.key.byte_length() > 0:
                var k = parse_key(pc.key)
                if k == 0:
                    warn.append("plugin " + plugins[p].name + ": unknown key \"" + pc.key + "\"")
                elif reg.find_key(k) != CM_NONE:
                    warn.append("plugin " + plugins[p].name + ": " + pc.key + " is taken, so " + pc.title + " has no key")
                else:
                    keys.append(k)
            var id = plugin_cmd_id(p, c)
            reg.cmd(id, "plugin." + plugins[p].name + "." + pc.id, pc.title, pc.hint if pc.hint.byte_length() > 0 else String("A command of the plugin " + plugins[p].name), keys^)
            if not any:
                reg.layout.append(Placement(0, CM_NONE))
                any = True
            reg.layout.append(Placement(0, id))
    return warn^


# ------------------------------------------------------------------ panels
comptime PANEL_COL_MAX = 40         # the widest a table column is shown


struct PluginPanel(Copyable, Movable):
    """A plugin's panel: a list (one text per row) or a table (cells under columns)."""
    var plugin: Int
    var id: String
    var title: String
    var table: Bool
    var columns: List[String]
    var cells: List[List[String]]   # per row (a list's row has one cell)
    var styles: List[Int]           # per row: RM_*
    var data: List[String]          # per row: given back to the plugin when it is chosen
    var x: Int                      # where its window was docked (to give the room back)
    var w: Int

    def __init__(out self, plugin: Int, id: String):
        self.plugin = plugin
        self.id = id
        self.title = id
        self.table = False
        self.columns = List[String]()
        self.cells = List[List[String]]()
        self.styles = List[Int]()
        self.data = List[String]()
        self.x = 0
        self.w = 0

    def header_rows(self) -> Int:
        """Lines above the first row (a table's column titles and the line under them)."""
        return 2 if self.table and len(self.columns) > 0 else 0


def style_mark(s: String) -> Int:
    if s == "error":
        return 1        # RM_ERROR
    if s == "warn":
        return 2        # RM_WARN
    if s == "ok":
        return 3        # RM_OK
    if s == "dim":
        return 4        # RM_DIM
    return 0


def pad_cell(s: String, w: Int) -> String:
    """`s` in exactly `w` columns: cut with "…" when longer, blanks after when shorter."""
    var cps = List[Int]()
    for c in s.codepoints():
        cps.append(Int(c))
    var out = String("")
    if len(cps) > w:
        for k in range(max(0, w - 1)):
            out += chr(cps[k])
        if w > 0:
            out += "…"
        return out^
    out = s
    for _ in range(w - len(cps)):
        out += " "
    return out^


def panel_lines(p: PluginPanel) -> List[String]:
    """The panel as text lines: a list's rows as they are; a table's cells in columns as
    wide as their widest cell (at most PANEL_COL_MAX), with the column titles on top."""
    var out = List[String]()
    if not p.table:
        for row in p.cells:
            out.append(row[0] if len(row) > 0 else String(""))
        return out^
    var ncol = len(p.columns)
    for row in p.cells:
        ncol = max(ncol, len(row))
    var widths = List[Int]()
    for c in range(ncol):
        var w = 0
        if c < len(p.columns):
            w = len(p.columns[c].codepoints())
        for row in p.cells:
            if c < len(row):
                w = max(w, len(row[c].codepoints()))
        widths.append(min(w, PANEL_COL_MAX))
    if len(p.columns) > 0:
        var head = String("")
        var rule = String("")
        for c in range(ncol):
            var last = c == ncol - 1
            head += (pad_cell(p.columns[c], widths[c]) if c < len(p.columns) else pad_cell("", widths[c])) + ("" if last else "  ")
            for _ in range(widths[c]):
                rule += "-"
            if not last:
                rule += "  "
        out.append(String(head.rstrip()))
        out.append(rule)
    for row in p.cells:
        var line = String("")
        for c in range(ncol):
            var cell = row[c] if c < len(row) else String("")
            line += pad_cell(cell, widths[c]) + ("" if c == ncol - 1 else "  ")
        out.append(String(line.rstrip()))
    return out^


@fieldwise_init
struct PluginInstallInfo(Copyable, Movable):
    var ok: Bool
    var message: String
    var name: String
    var version: String
    var install_dir: String
    var source: String
    var pinned_ref: String
    var has_snippets: Bool


@fieldwise_init
struct PluginSnippet(Copyable, Movable):
    var prefix: String
    var description: String
    var body: String


def _valid_plugin_slug(name: String) -> Bool:
    if name.byte_length() == 0 or name == "." or name == "..":
        return False
    if name.find("/") >= 0 or name.find("\\") >= 0 or name.find("..") >= 0 or name.find(" ") >= 0:
        return False
    return True


def parse_plugin_source_spec(spec: String) -> Tuple[String, String]:
    """Split `url_or_path[@pinned_ref]` safely without breaking `git@host:org/repo` SSH URLs."""
    var s = String(spec.strip())
    var last_at = -1
    var bs = s.as_bytes()
    for i in range(len(bs)):
        if Int(bs[i]) == 64:
            last_at = i
    if last_at > 0:
        var after = String(s[byte=last_at + 1:])
        if after.byte_length() > 0 and after.find(":") < 0 and after.find("/") < 0:
            var base = String(s[byte=0:last_at])
            return (base, after)
    return (s, "")


def validate_plugin_dir(dir: String) -> PluginInstallInfo:
    """Validate `plugin.toml` (and optional `snippets.toml`) in a candidate plugin folder."""
    var manifest = dir + "/plugin.toml"
    if not path_exists(manifest):
        return PluginInstallInfo(False, "Missing plugin.toml manifest in " + dir, "", "", "", "", "", False)
    var doc = toml_parse(read_text(manifest))
    if len(doc.problems) > 0:
        return PluginInstallInfo(False, "Invalid plugin.toml: " + doc.problems[0], "", "", "", "", "", False)
    var fallback_slug = basename(dir)
    var name = String(doc.get_str("name", fallback_slug).strip())
    if not _valid_plugin_slug(name):
        return PluginInstallInfo(False, "Invalid plugin name '" + name + "' in plugin.toml", "", "", "", "", "", False)
    var ver = String(doc.get_str("version", "0.1.0").strip())
    var cmd = String(doc.get_str("command", "").strip())
    var has_snips = path_exists(dir + "/snippets.toml") or doc.get_str("kind", "") == "snippets"
    if cmd.byte_length() == 0 and not has_snips:
        return PluginInstallInfo(False, "plugin.toml must define `command` or include `snippets.toml`", name, ver, "", "", "", False)
    return PluginInstallInfo(True, "ok", name, ver, dir, "", "", has_snips)


def install_plugin(spec: String, plugins_dir: String) -> PluginInstallInfo:
    """Install a plugin or snippet pack from a local folder or Git repository (with optional `@ref` pin)."""
    var parsed = parse_plugin_source_spec(spec)
    var src = parsed[0]
    var pin = parsed[1]
    if src.byte_length() == 0 or plugins_dir.byte_length() == 0:
        return PluginInstallInfo(False, "Provide a Git URL or local plugin directory path", "", "", "", src, pin, False)
    var stage = env_or("TMPDIR", "/tmp") + "/tm-plugin-stage-" + String(own_pid())
    _ = run_system("rm -rf " + shell_quote(stage))
    var is_local = path_exists(src)
    if is_local:
        var cp_rc = run_system("mkdir -p " + shell_quote(stage) + " && cp -R " + shell_quote(src) + "/. " + shell_quote(stage) + "/")
        if cp_rc != 0:
            _ = run_system("rm -rf " + shell_quote(stage))
            return PluginInstallInfo(False, "Failed copying local plugin folder: " + src, "", "", "", src, pin, False)
        if pin.byte_length() > 0 and path_exists(stage + "/.git"):
            var co = run_capture("git -C " + shell_quote(stage) + " checkout " + shell_quote(pin) + " 2>&1")
            if co.status != 0:
                _ = run_system("rm -rf " + shell_quote(stage))
                return PluginInstallInfo(False, "Could not checkout pinned ref '" + pin + "'", "", "", "", src, pin, False)
    else:
        var clone_cmd = "git clone --depth 1 " + (("--branch " + shell_quote(pin) + " ") if pin.byte_length() > 0 else String("")) + shell_quote(src) + " " + shell_quote(stage) + " 2>&1"
        var cl = run_capture(clone_cmd)
        if cl.status != 0 and pin.byte_length() > 0:
            _ = run_system("rm -rf " + shell_quote(stage))
            var cl_full = run_capture("git clone " + shell_quote(src) + " " + shell_quote(stage) + " 2>&1 && git -C " + shell_quote(stage) + " checkout " + shell_quote(pin) + " 2>&1")
            if cl_full.status != 0:
                _ = run_system("rm -rf " + shell_quote(stage))
                return PluginInstallInfo(False, "Git clone/pin failed: " + String(bytes_to_str(cl_full.out).strip()), "", "", "", src, pin, False)
        elif cl.status != 0:
            _ = run_system("rm -rf " + shell_quote(stage))
            return PluginInstallInfo(False, "Git clone failed: " + String(bytes_to_str(cl.out).strip()), "", "", "", src, pin, False)

    var info = validate_plugin_dir(stage)
    if not info.ok:
        _ = run_system("rm -rf " + shell_quote(stage))
        return info^

    var dest = plugins_dir + "/" + info.name
    _ = run_system("mkdir -p " + shell_quote(plugins_dir) + " && rm -rf " + shell_quote(dest) + " && mv " + shell_quote(stage) + " " + shell_quote(dest))
    var rev = String("")
    if path_exists(dest + "/.git"):
        rev = String(bytes_to_str(run_capture("git -C " + shell_quote(dest) + " rev-parse --short HEAD 2>/dev/null").out).strip())
    var meta = (
        "source = " + toml_quote(src) + "\n"
        + "pinned_ref = " + toml_quote(pin) + "\n"
        + "installed_rev = " + toml_quote(rev) + "\n"
        + "version = " + toml_quote(info.version) + "\n"
    )
    _ = write_file(dest + "/.install.toml", str_bytes(meta))
    return PluginInstallInfo(
        True,
        "Installed plugin '" + info.name + "' v" + info.version + ((" @" + pin) if pin.byte_length() > 0 else String("")),
        info.name,
        info.version,
        dest,
        src,
        pin,
        info.has_snippets,
    )


def update_plugin(name: String, plugins_dir: String) -> Tuple[Bool, String]:
    """Update an installed plugin unless pinned to a specific `@ref`."""
    if not _valid_plugin_slug(name):
        return (False, "Invalid plugin name")
    var dest = plugins_dir + "/" + name
    if not path_exists(dest):
        return (False, "Plugin '" + name + "' is not installed")
    var meta_path = dest + "/.install.toml"
    var src = String("")
    var pin = String("")
    if path_exists(meta_path):
        var doc = toml_parse(read_text(meta_path))
        src = doc.get_str("source", "")
        pin = doc.get_str("pinned_ref", "")
    if pin.byte_length() > 0:
        return (False, "Plugin '" + name + "' is pinned at @" + pin + " (reinstall without @ref to unpin)")
    if path_exists(dest + "/.git"):
        var pull = run_capture("git -C " + shell_quote(dest) + " pull --ff-only 2>&1")
        if pull.status != 0:
            return (False, "Update failed: " + String(bytes_to_str(pull.out).strip()))
        return (True, "Updated plugin '" + name + "'")
    if src.byte_length() > 0 and path_exists(src):
        var res = install_plugin(src, plugins_dir)
        return (res.ok, ("Updated plugin '" + name + "'") if res.ok else res.message)
    return (False, "Plugin '" + name + "' has no upstream git repository or source folder recorded")


def remove_plugin(name: String, plugins_dir: String) -> Tuple[Bool, String]:
    """Uninstall a plugin directory from `plugins_dir`."""
    if not _valid_plugin_slug(name) or plugins_dir.byte_length() == 0:
        return (False, "Invalid plugin name")
    var dest = plugins_dir + "/" + name
    if not path_exists(dest):
        return (False, "Plugin '" + name + "' is not installed")
    var rc = run_system("rm -rf " + shell_quote(dest))
    if rc != 0 or path_exists(dest):
        return (False, "Could not remove " + dest)
    return (True, "Removed plugin '" + name + "'")


def load_plugin_snippets(plugins_dir: String) -> List[PluginSnippet]:
    """Scan `plugins_dir/*/snippets.toml` (`[snippets.<prefix>]` tables) for custom snippet packs."""
    var out = List[PluginSnippet]()
    if plugins_dir.byte_length() == 0 or not path_exists(plugins_dir):
        return out^
    var r = run_capture("ls -1 " + shell_quote(plugins_dir) + " 2>/dev/null")
    for raw in bytes_to_str(r.out).split("\n"):
        var sub = String(String(raw).strip())
        if not _valid_plugin_slug(sub):
            continue
        var spath = plugins_dir + "/" + sub + "/snippets.toml"
        if not path_exists(spath):
            continue
        var doc = toml_parse(read_text(spath))
        var seen = List[String]()
        for key in doc.keys_in("snippets"):
            var dot = key.find(".")
            if dot <= 0:
                continue
            var pref = String(key[byte=0:dot])
            if pref in seen:
                continue
            seen.append(pref)
            var body = doc.get_str("snippets." + pref + ".body", "")
            if body.byte_length() == 0:
                continue
            var desc = doc.get_str("snippets." + pref + ".description", "Snippet from " + sub)
            out.append(PluginSnippet(pref, desc, body))
    return out^
