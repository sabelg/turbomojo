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

    def __init__(out self, name: String, command: String, exts: List[String], language: String):
        self.name = name
        self.command = command
        self.exts = exts.copy()
        self.client = LspClient()
        self.client.language_id = language


def ends_with_any(path: String, exts: List[String]) -> Bool:
    for e in exts:
        if path.endswith(e):
            return True
    return False


def configure_servers(mut servers: List[ExtraServer], s: Settings):
    """The servers of the settings; running ones still configured the same way keep
    running, the others are stopped."""
    var out = List[ExtraServer]()
    for j in range(len(s.lsp_names)):
        var kept = False
        for k in range(len(servers)):
            if servers[k].name == s.lsp_names[j] and servers[k].command == s.lsp_cmds[j]:
                var e = servers[k].copy()
                e.exts = s.lsp_exts[j].copy()
                e.client.language_id = s.lsp_langs[j]
                out.append(e^)
                kept = True
        if not kept:
            out.append(ExtraServer(s.lsp_names[j], s.lsp_cmds[j], s.lsp_exts[j], s.lsp_langs[j]))
    for k in range(len(servers)):
        var still = False
        for e in out:
            if e.name == servers[k].name and e.command == servers[k].command:
                still = True
        if not still and servers[k].client.active():
            servers[k].client.stop()
    servers = out^
