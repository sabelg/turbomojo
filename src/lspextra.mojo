"""Language servers for other languages ([lsp.<name>] in the config file): what one is,
and making the list from the settings (src/app_lspextra.mojo does the rest)."""
from std.collections import List
from lsp import LspClient
from config import Settings


struct ExtraServer(Copyable, Movable):
    var name: String
    var command: String
    var exts: List[String]
    var client: LspClient
    var crashes: List[Int]
    var restart_due: Int
    var restart_base_ms: Int

    def __init__(out self, name: String, command: String, exts: List[String], language: String):
        self.name = name
        self.command = command
        self.exts = exts.copy()
        self.client = LspClient()
        self.client.language_id = language
        self.crashes = List[Int]()
        self.restart_due = 0
        self.restart_base_ms = 1000


def ends_with_any(path: String, exts: List[String]) -> Bool:
    for e in exts:
        if path.endswith(e):
            return True
    return False


def configure_servers(mut servers: List[ExtraServer], s: Settings):
    """The servers of the settings; running ones still configured the same way keep
    running, the others are stopped."""
    var out = List[ExtraServer]()
    var used = List[Bool](length=len(servers), fill=False)
    for j in range(len(s.lsp_names)):
        var kept = False
        for k in range(len(servers)):
            if not used[k] and servers[k].name == s.lsp_names[j] and servers[k].command == s.lsp_cmds[j]:
                used[k] = True
                var e = servers[k].copy()
                e.exts = s.lsp_exts[j].copy()
                e.client.language_id = s.lsp_langs[j]
                out.append(e^)
                kept = True
                break
        if not kept:
            out.append(ExtraServer(s.lsp_names[j], s.lsp_cmds[j], s.lsp_exts[j], s.lsp_langs[j]))
    for k in range(len(servers)):
        if not used[k] and (servers[k].client.active() or servers[k].client.conn.proc.running):
            servers[k].client.stop()
    servers = out^
