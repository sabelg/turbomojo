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
from commands import Registry, Placement, parse_key, CM_NONE
from util import path_exists, run_capture, shell_quote, bytes_to_str
from config import read_text

comptime PL_STARTING = 1
comptime PL_READY = 2
comptime PL_STOPPED = 3

comptime PLUGIN_API = 1
comptime CM_PLUGIN0 = 10000         # plugin commands: CM_PLUGIN0 + 100 * plugin + command
comptime PLUGIN_CMDS_MAX = 100
comptime PLUGIN_INIT_MS = 10000     # a plugin that has not answered initialize by then is stopped


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
