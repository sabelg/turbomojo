"""Language Server Protocol client (first slice: lifecycle, document sync, diagnostics).

The client is driven by the event loop: `start()` launches the server and sends
`initialize`; `handle()` processes whatever messages have arrived; documents opened before
the server is ready are queued and sent once it is. Positions on the wire are UTF-16 code
units (the Mojo server offers nothing else); `utf16_to_col` / `col_to_utf16` convert to and
from the editor's codepoint columns."""
from std.collections import List
from rpc import *
from json import Json, JsonWriter, json_quote, json_parse, J_ARR, J_OBJ, J_STR
from util import decode, to_str, encode_cp, bytes_to_str, str_bytes
from buffer import DocChange

comptime LSP_STOPPED = 0
comptime LSP_STARTING = 1      # initialize sent, waiting for the reply
comptime LSP_READY = 2
comptime LSP_FAILED = 3        # the server could not be started or died

comptime SEV_ERROR = 1
comptime SEV_WARNING = 2
comptime SEV_INFO = 3
comptime SEV_HINT = 4


# ------------------------------------------------------------------- helpers
def path_to_uri(path: String) -> String:
    """file:// URI for an absolute path, percent-encoding what must be encoded."""
    var hexd = str_bytes("0123456789ABCDEF")
    var out = str_bytes("file://")
    for b in path.as_bytes():
        var c = Int(b)
        var safe = (c >= 48 and c <= 57) or (c >= 65 and c <= 90) or (c >= 97 and c <= 122) or c == 47 or c == 45 or c == 46 or c == 95 or c == 126
        if safe:
            out.append(b)
        else:
            out.append(37)
            out.append(hexd[c >> 4])
            out.append(hexd[c & 15])
    return bytes_to_str(out)


def hex_value(c: Int) -> Int:
    if c >= 48 and c <= 57:
        return c - 48
    if c >= 65 and c <= 70:
        return c - 55
    if c >= 97 and c <= 102:
        return c - 87
    return -1


def uri_to_path(uri: String) -> String:
    """Path of a file:// URI ('' for other schemes)."""
    if not uri.startswith("file://"):
        return ""
    var b = str_bytes(uri)
    var out = List[UInt8]()
    var i = 7
    while i < len(b):
        if b[i] == 37 and i + 2 < len(b) and hex_value(Int(b[i + 1])) >= 0 and hex_value(Int(b[i + 2])) >= 0:
            out.append(UInt8(hex_value(Int(b[i + 1])) * 16 + hex_value(Int(b[i + 2]))))
            i += 3
        else:
            out.append(b[i])
            i += 1
    return bytes_to_str(out)


def utf16_units(cp: Int) -> Int:
    return 2 if cp >= 0x10000 else 1


def col_to_utf16(line: List[Int], col: Int) -> Int:
    """UTF-16 offset of codepoint column `col` in a line."""
    var n = 0
    for i in range(min(col, len(line))):
        n += utf16_units(line[i])
    return n


def utf16_to_col(line: List[Int], units: Int) -> Int:
    """Codepoint column for a UTF-16 offset (an offset inside a surrogate pair maps to
    the character that contains it; past the end maps to the line length)."""
    var n = 0
    for i in range(len(line)):
        if n >= units:
            return i
        n += utf16_units(line[i])
        if n > units:
            return i
    return len(line)


@fieldwise_init
struct Diag(Copyable, Movable):
    var line: Int          # 0-based
    var ch: Int            # UTF-16 units, 0-based (as received)
    var end_line: Int
    var end_ch: Int
    var severity: Int
    var message: String


struct DocDiags(Copyable, Movable):
    var uri: String
    var items: List[Diag]
    var version: Int       # document version the server reported them for (-1 if none)

    def __init__(out self, uri: String):
        self.uri = uri
        self.items = List[Diag]()
        self.version = -1


comptime SYNC_NONE = 0
comptime SYNC_FULL = 1
comptime SYNC_INCREMENTAL = 2


struct LspCaps(Copyable, Movable):
    """What the server said it can do, read once from the `initialize` result. Later
    features ask this table instead of digging through the JSON."""
    var sync_kind: Int                    # SYNC_NONE / SYNC_FULL / SYNC_INCREMENTAL
    var sync_open_close: Bool
    var sync_save: Bool                   # the server wants didSave
    var position_encoding: String         # "utf-16" unless the server chose another
    var completion: Bool
    var completion_resolve: Bool
    var completion_triggers: List[String]
    var hover: Bool
    var signature_help: Bool
    var signature_triggers: List[String]
    var definition: Bool
    var declaration: Bool
    var type_definition: Bool
    var implementation: Bool
    var references: Bool
    var document_highlight: Bool
    var rename: Bool
    var prepare_rename: Bool
    var code_action: Bool
    var document_symbol: Bool
    var workspace_symbol: Bool
    var formatting: Bool
    var folding_range: Bool
    var inlay_hint: Bool
    var semantic_tokens: Bool
    var semantic_full: Bool
    var semantic_range: Bool
    var token_types: List[String]         # the semantic token legend
    var token_modifiers: List[String]

    def __init__(out self):
        self.sync_kind = SYNC_NONE
        self.sync_open_close = False
        self.sync_save = False
        self.position_encoding = "utf-16"
        self.completion = False
        self.completion_resolve = False
        self.completion_triggers = List[String]()
        self.hover = False
        self.signature_help = False
        self.signature_triggers = List[String]()
        self.definition = False
        self.declaration = False
        self.type_definition = False
        self.implementation = False
        self.references = False
        self.document_highlight = False
        self.rename = False
        self.prepare_rename = False
        self.code_action = False
        self.document_symbol = False
        self.workspace_symbol = False
        self.formatting = False
        self.folding_range = False
        self.inlay_hint = False
        self.semantic_tokens = False
        self.semantic_full = False
        self.semantic_range = False
        self.token_types = List[String]()
        self.token_modifiers = List[String]()

    def describe(self) -> List[String]:
        """One line per feature the server offers, for the log and for people."""
        var out = List[String]()
        var sync = String("none")
        if self.sync_kind == SYNC_FULL:
            sync = "whole document"
        elif self.sync_kind == SYNC_INCREMENTAL:
            sync = "incremental"
        out.append("document sync: " + sync + (", save notifications" if self.sync_save else ""))
        out.append("positions: " + self.position_encoding)
        var names = List[String]()
        if self.completion:
            names.append("completion")
        if self.hover:
            names.append("hover")
        if self.signature_help:
            names.append("signature help")
        if self.definition:
            names.append("go to definition")
        if self.references:
            names.append("references")
        if self.document_highlight:
            names.append("highlights")
        if self.rename:
            names.append("rename")
        if self.code_action:
            names.append("code actions")
        if self.document_symbol:
            names.append("document symbols")
        if self.workspace_symbol:
            names.append("workspace symbols")
        if self.formatting:
            names.append("formatting")
        if self.folding_range:
            names.append("folding")
        if self.inlay_hint:
            names.append("inlay hints")
        if self.semantic_tokens:
            names.append("semantic tokens")
        var line = String("features: ")
        for i in range(len(names)):
            line += (", " if i > 0 else "") + names[i]
        if len(names) == 0:
            line += "none"
        out.append(line)
        return out^


def cap_on(caps: Json, key: String) -> Bool:
    """A capability counts if it is present and neither `false` nor null (servers may
    give `true` or an options object)."""
    var n = caps.get(0, key)
    if n < 0 or caps.is_null(n):
        return False
    if caps.kind(n) == 1:             # J_BOOL
        return caps.bool(n)
    return True


def string_items(doc: Json, node: Int) -> List[String]:
    var out = List[String]()
    if node < 0:
        return out^
    for c in doc.children(node):
        out.append(doc.str(c))
    return out^


def parse_caps(caps: Json) -> LspCaps:
    """Read the `capabilities` object of an initialize result."""
    var c = LspCaps()
    if not caps.valid(0):
        return c^
    var sync = caps.get(0, "textDocumentSync")
    if sync >= 0 and not caps.is_null(sync):
        if caps.kind(sync) == 2:      # J_NUMBER: just the kind
            c.sync_kind = caps.int(sync)
            c.sync_open_close = c.sync_kind != SYNC_NONE
        else:
            c.sync_kind = caps.int(caps.get(sync, "change"), SYNC_NONE)
            c.sync_open_close = caps.bool(caps.get(sync, "openClose"))
            var save = caps.get(sync, "save")
            if save >= 0 and not caps.is_null(save):
                c.sync_save = caps.bool(save) if caps.kind(save) == 1 else True
    if c.sync_kind < SYNC_NONE or c.sync_kind > SYNC_INCREMENTAL:
        c.sync_kind = SYNC_NONE
    var enc = caps.get(0, "positionEncoding")
    if enc >= 0 and caps.str(enc).byte_length() > 0:
        c.position_encoding = caps.str(enc)
    c.completion = cap_on(caps, "completionProvider")
    if c.completion:
        c.completion_resolve = caps.bool(caps.path(0, "completionProvider/resolveProvider"))
        c.completion_triggers = string_items(caps, caps.path(0, "completionProvider/triggerCharacters"))
    c.hover = cap_on(caps, "hoverProvider")
    c.signature_help = cap_on(caps, "signatureHelpProvider")
    if c.signature_help:
        c.signature_triggers = string_items(caps, caps.path(0, "signatureHelpProvider/triggerCharacters"))
    c.definition = cap_on(caps, "definitionProvider")
    c.declaration = cap_on(caps, "declarationProvider")
    c.type_definition = cap_on(caps, "typeDefinitionProvider")
    c.implementation = cap_on(caps, "implementationProvider")
    c.references = cap_on(caps, "referencesProvider")
    c.document_highlight = cap_on(caps, "documentHighlightProvider")
    c.rename = cap_on(caps, "renameProvider")
    if c.rename:
        c.prepare_rename = caps.bool(caps.path(0, "renameProvider/prepareProvider"))
    c.code_action = cap_on(caps, "codeActionProvider")
    c.document_symbol = cap_on(caps, "documentSymbolProvider")
    c.workspace_symbol = cap_on(caps, "workspaceSymbolProvider")
    c.formatting = cap_on(caps, "documentFormattingProvider")
    c.folding_range = cap_on(caps, "foldingRangeProvider")
    c.inlay_hint = cap_on(caps, "inlayHintProvider")
    c.semantic_tokens = cap_on(caps, "semanticTokensProvider")
    if c.semantic_tokens:
        var full = caps.path(0, "semanticTokensProvider/full")
        c.semantic_full = full >= 0 and not caps.is_null(full) and (caps.kind(full) != 1 or caps.bool(full))
        var rng = caps.path(0, "semanticTokensProvider/range")
        c.semantic_range = rng >= 0 and not caps.is_null(rng) and (caps.kind(rng) != 1 or caps.bool(rng))
        c.token_types = string_items(caps, caps.path(0, "semanticTokensProvider/legend/tokenTypes"))
        c.token_modifiers = string_items(caps, caps.path(0, "semanticTokensProvider/legend/tokenModifiers"))
    return c^


struct CompletionItem(Copyable, Movable):
    var label: String
    var insert: String      # the text to put in the buffer (the label unless the server says otherwise)
    var kind: Int           # LSP CompletionItemKind, 0 if not given
    var detail: String      # usually the signature or type
    var doc: String         # documentation as text (Markdown source if the server sent that)
    var sort: String        # the key the server wants the list ordered by
    var filter: String      # the text typed characters are matched against
    var raw: String         # the item as received, for completionItem/resolve

    def __init__(out self):
        self.label = ""
        self.insert = ""
        self.kind = 0
        self.detail = ""
        self.doc = ""
        self.sort = ""
        self.filter = ""
        self.raw = ""


struct CompletionList(Movable):
    var items: List[CompletionItem]
    var incomplete: Bool    # the server has more: ask again when more is typed

    def __init__(out self):
        self.items = List[CompletionItem]()
        self.incomplete = False


comptime COMPLETION_MAX = 1000     # more items than this are not kept


def doc_text(doc: Json, node: Int) -> String:
    """Documentation is a plain string or {kind, value}."""
    if node < 0 or doc.is_null(node):
        return ""
    var v = doc.get(node, "value")
    if v >= 0:
        return doc.str(v)
    return doc.str(node)


def parse_completion_item(doc: Json, node: Int) -> CompletionItem:
    var it = CompletionItem()
    it.label = doc.str(doc.get(node, "label"))
    it.kind = doc.int(doc.get(node, "kind"), 0)
    it.detail = doc.str(doc.get(node, "detail"))
    it.doc = doc_text(doc, doc.get(node, "documentation"))
    it.sort = doc.str(doc.get(node, "sortText"), it.label)
    it.filter = doc.str(doc.get(node, "filterText"), it.label)
    it.insert = it.label
    var ins = doc.get(node, "insertText")
    if ins >= 0 and doc.str(ins).byte_length() > 0:
        it.insert = doc.str(ins)
    var te = doc.path(node, "textEdit/newText")
    if te >= 0 and doc.str(te).byte_length() > 0:
        it.insert = doc.str(te)
    it.raw = doc.dump(node)
    return it^


def parse_completion(doc: Json, node: Int) -> CompletionList:
    """A completion result: an array of items, or {isIncomplete, items}; null is empty.
    Items come back ordered by their sort key (stable), at most COMPLETION_MAX."""
    var out = CompletionList()
    if node < 0 or doc.is_null(node):
        return out^
    var arr = node
    var inner = doc.get(node, "items")
    if inner >= 0:
        arr = inner
        out.incomplete = doc.bool(doc.get(node, "isIncomplete"))
    var found = List[CompletionItem]()
    for c in doc.children(arr):
        if len(found) >= COMPLETION_MAX:
            out.incomplete = True
            break
        var it = parse_completion_item(doc, c)
        if it.label.byte_length() > 0:
            found.append(it^)
    # stable merge sort on the sort keys
    var n = len(found)
    var idx = List[Int]()
    var tmp = List[Int]()
    for i in range(n):
        idx.append(i)
        tmp.append(0)
    var width = 1
    while width < n:
        var lo = 0
        while lo < n:
            var mid = min(lo + width, n)
            var hi = min(lo + 2 * width, n)
            var i = lo
            var j = mid
            var k = lo
            while i < mid and j < hi:
                if found[idx[j]].sort < found[idx[i]].sort:
                    tmp[k] = idx[j]
                    j += 1
                else:
                    tmp[k] = idx[i]
                    i += 1
                k += 1
            while i < mid:
                tmp[k] = idx[i]
                i += 1
                k += 1
            while j < hi:
                tmp[k] = idx[j]
                j += 1
                k += 1
            lo += 2 * width
        for q in range(n):
            idx[q] = tmp[q]
        width *= 2
    for i in range(n):
        out.items.append(found[idx[i]].copy())
    return out^


def marked_text(doc: Json, node: Int) -> String:
    """One piece of hover content as Markdown: a string, {kind, value}, or the older
    {language, value} which is a code block."""
    if node < 0 or doc.is_null(node):
        return ""
    var v = doc.get(node, "value")
    if v < 0:
        return doc.str(node)
    var lang = doc.get(node, "language")
    if lang >= 0:
        return "```" + doc.str(lang) + "\n" + doc.str(v) + "\n```"
    return doc.str(v)


def hover_markdown(doc: Json, result: Int) -> String:
    """The text of a hover result as Markdown ('' if the server had nothing)."""
    if result < 0 or doc.is_null(result):
        return ""
    var c = doc.get(result, "contents")
    if c < 0 or doc.is_null(c):
        return ""
    if doc.kind(c) == 4:              # J_ARRAY: several pieces
        var out = String("")
        for piece in doc.children(c):
            var t = marked_text(doc, piece)
            if t.byte_length() > 0:
                out += ("\n\n" if out.byte_length() > 0 else "") + t
        return out
    return marked_text(doc, c)


def retry_later(m: RpcMessage) -> Bool:
    """Is this error a "not now" answer (the server is re-reading the file after an
    edit, or the request was overtaken) rather than a failure?"""
    var code = m.error_code()
    return code == -32801 or code == -32802 or code == -32800 or m.error_message().find("outdated") >= 0


def kind_tag(kind: Int) -> String:
    """A three-letter tag for a completion item kind (LSP numbers)."""
    if kind == 2 or kind == 3 or kind == 4:
        return "fn "
    if kind == 5 or kind == 10 or kind == 20:
        return "fld"
    if kind == 6 or kind == 12:
        return "var"
    if kind == 7 or kind == 8 or kind == 13 or kind == 22 or kind == 25:
        return "typ"
    if kind == 9 or kind == 17 or kind == 19:
        return "mod"
    if kind == 14:
        return "kw "
    if kind == 21:
        return "con"
    if kind == 15:
        return "snp"
    return "   "


@fieldwise_init
struct OpenDoc(Copyable, Movable):
    var uri: String
    var version: Int
    var sent: Bool         # didOpen has gone out


struct LspClient(Copyable, Movable):
    var conn: RpcConn
    var state: Int
    var server_cmd: String
    var root_uri: String
    var init_id: Int
    var docs: List[OpenDoc]
    var queued_text: List[String]      # text of documents waiting for the server (same order as unsent docs)
    var diags: List[DocDiags]
    var updated: List[String]          # URIs whose diagnostics changed since last take_updated()
    var server_name: String
    var caps: Json                     # the server's capabilities object (empty until ready)
    var table: LspCaps                 # the same, as a typed table
    var was_ready: Bool                # this run of the server got through initialize
    var starts: Int                    # how many times a server has been launched
    var last_error: String
    var log: List[String]              # window/logMessage and showMessage texts (latest last)
    var replies: List[RpcMessage]      # answers to feature requests, waiting for the IDE to take them

    def __init__(out self):
        self.conn = RpcConn()
        self.state = LSP_STOPPED
        self.server_cmd = ""
        self.root_uri = ""
        self.init_id = -1
        self.docs = List[OpenDoc]()
        self.queued_text = List[String]()
        self.diags = List[DocDiags]()
        self.updated = List[String]()
        self.server_name = ""
        self.caps = Json()
        self.table = LspCaps()
        self.was_ready = False
        self.starts = 0
        self.last_error = ""
        self.log = List[String]()
        self.replies = List[RpcMessage]()

    # ------------------------------------------------------------ lifecycle
    def start(mut self, cmd: String, root_dir: String, stderr_path: String, pid: Int, now: Int) -> Bool:
        """Launch the server and send `initialize`."""
        if self.state == LSP_STARTING or self.state == LSP_READY:
            return True
        self.server_cmd = cmd
        self.root_uri = path_to_uri(root_dir)
        self.docs.clear()
        self.queued_text.clear()
        self.diags.clear()
        self.updated.clear()
        self.was_ready = False
        self.caps = Json()
        self.table = LspCaps()
        if not self.conn.start(cmd, stderr_path):
            self.state = LSP_FAILED
            self.last_error = "could not start " + cmd
            return False
        self.starts += 1
        var w = JsonWriter()
        w.begin_obj()
        w.kv_int("processId", pid)
        w.kv_str("rootUri", self.root_uri)
        w.key("workspaceFolders")
        w.begin_arr()
        w.begin_obj()
        w.kv_str("uri", self.root_uri)
        w.kv_str("name", "workspace")
        w.end_obj()
        w.end_arr()
        w.key("clientInfo")
        w.begin_obj()
        w.kv_str("name", "TurboMojo")
        w.end_obj()
        # what this client can take; kept to what is implemented, so the server does not
        # send things nobody handles
        w.key("capabilities")
        w.begin_obj()
        w.key("general")
        w.begin_obj()
        w.key("positionEncodings")
        w.begin_arr()
        w.str("utf-16")
        w.end_arr()
        w.end_obj()
        w.key("textDocument")
        w.begin_obj()
        w.key("synchronization")
        w.begin_obj()
        w.kv_bool("didSave", True)
        w.end_obj()
        w.key("hover")
        w.begin_obj()
        w.key("contentFormat")
        w.begin_arr()
        w.str("markdown")
        w.str("plaintext")
        w.end_arr()
        w.end_obj()
        w.key("completion")
        w.begin_obj()
        w.kv_bool("contextSupport", True)
        w.key("completionItem")
        w.begin_obj()
        w.kv_bool("snippetSupport", False)
        w.key("documentationFormat")
        w.begin_arr()
        w.str("plaintext")
        w.str("markdown")
        w.end_arr()
        w.end_obj()
        w.end_obj()
        w.key("publishDiagnostics")
        w.begin_obj()
        w.kv_bool("relatedInformation", False)
        w.kv_bool("versionSupport", True)
        w.end_obj()
        w.end_obj()
        w.end_obj()
        w.end_obj()
        self.init_id = self.conn.request("initialize", w.text(), now)
        self.state = LSP_STARTING
        return True

    def stop(mut self):
        """Polite shutdown, then make sure the process is gone."""
        if self.state == LSP_READY:
            _ = self.conn.request("shutdown", "")
            self.conn.notify("exit", "")
            _ = self.conn.poll()
        if self.conn.proc.running:
            _ = self.conn.stop()
        self.state = LSP_STOPPED

    def fd(self) -> Int:
        return self.conn.fd() if self.conn.proc.running else -1

    def active(self) -> Bool:
        return self.state == LSP_STARTING or self.state == LSP_READY

    def supports(self, capability: String) -> Bool:
        """Whether the server advertised a capability (present and not `false`)."""
        var n = self.caps.get(0, capability)
        if n < 0:
            return False
        if self.caps.kind(n) == 1:        # J_BOOL
            return self.caps.bool(n)
        return not self.caps.is_null(n)

    # ------------------------------------------------------------ documents
    def find_doc(self, uri: String) -> Int:
        for i in range(len(self.docs)):
            if self.docs[i].uri == uri:
                return i
        return -1

    def send_open(mut self, uri: String, version: Int, text: String):
        var w = JsonWriter()
        w.begin_obj()
        w.key("textDocument")
        w.begin_obj()
        w.kv_str("uri", uri)
        w.kv_str("languageId", "mojo")
        w.kv_int("version", version)
        w.kv_str("text", text)
        w.end_obj()
        w.end_obj()
        self.conn.notify("textDocument/didOpen", w.text())

    def did_open(mut self, uri: String, text: String) -> Bool:
        """Tell the server about a document (queued until the server is ready)."""
        if not self.active() or self.find_doc(uri) >= 0:
            return False
        if self.state == LSP_READY:
            self.docs.append(OpenDoc(uri, 1, True))
            self.send_open(uri, 1, text)
        else:
            self.docs.append(OpenDoc(uri, 1, False))
            self.queued_text.append(text)
        return True

    def did_change(mut self, uri: String, text: String) -> Int:
        """Send the whole new text of an open document. Returns the new version (-1 if
        the document is not open or the server is not ready yet)."""
        var i = self.find_doc(uri)
        if i < 0:
            return -1
        if not self.docs[i].sent:
            # still queued for didOpen: just replace the queued text
            var q = 0
            for k in range(i):
                if not self.docs[k].sent:
                    q += 1
            self.queued_text[q] = text
            return -1
        self.docs[i].version += 1
        var w = JsonWriter()
        w.begin_obj()
        w.key("textDocument")
        w.begin_obj()
        w.kv_str("uri", uri)
        w.kv_int("version", self.docs[i].version)
        w.end_obj()
        w.key("contentChanges")
        w.begin_arr()
        w.begin_obj()
        w.kv_str("text", text)
        w.end_obj()
        w.end_arr()
        w.end_obj()
        self.conn.notify("textDocument/didChange", w.text())
        return self.docs[i].version

    def did_change_ranges(mut self, uri: String, changes: List[DocChange]) -> Int:
        """Send edits as ranges (for servers with incremental sync). Returns the new
        version, or -1 if the document is not open on a ready server; in that case
        nothing was sent and the caller should send the whole text instead."""
        var i = self.find_doc(uri)
        if i < 0 or not self.docs[i].sent or self.state != LSP_READY or len(changes) == 0:
            return -1
        self.docs[i].version += 1
        var w = JsonWriter()
        w.begin_obj()
        w.key("textDocument")
        w.begin_obj()
        w.kv_str("uri", uri)
        w.kv_int("version", self.docs[i].version)
        w.end_obj()
        w.key("contentChanges")
        w.begin_arr()
        for ch in changes:
            w.begin_obj()
            w.key("range")
            w.begin_obj()
            w.key("start")
            w.begin_obj()
            w.kv_int("line", ch.sl)
            w.kv_int("character", ch.sc)
            w.end_obj()
            w.key("end")
            w.begin_obj()
            w.kv_int("line", ch.el)
            w.kv_int("character", ch.ec)
            w.end_obj()
            w.end_obj()
            w.kv_str("text", to_str(ch.text))
            w.end_obj()
        w.end_arr()
        w.end_obj()
        self.conn.notify("textDocument/didChange", w.text())
        return self.docs[i].version

    def did_save(mut self, uri: String) -> Bool:
        """Tell the server the document was written to disk (if it is open there)."""
        var i = self.find_doc(uri)
        if i < 0 or not self.docs[i].sent or self.state != LSP_READY:
            return False
        self.conn.notify("textDocument/didSave", "{\"textDocument\":{\"uri\":" + json_quote(uri) + "}}")
        return True

    def take_replies(mut self) -> List[RpcMessage]:
        """Answers to feature requests that have arrived since the last call."""
        var out = self.replies.copy()
        self.replies.clear()
        return out^

    def position_params(self, uri: String, line: Int, character: Int) -> String:
        """The start of a TextDocumentPositionParams object (without the closing brace)."""
        return "{\"textDocument\":{\"uri\":" + json_quote(uri) + "},\"position\":{\"line\":" + String(line) + ",\"character\":" + String(character) + "}"

    def request_completion(mut self, uri: String, line: Int, character: Int, trigger: String, now: Int) -> Int:
        """Ask for completions at a position (UTF-16 column). `trigger` is the character
        that caused it ('' when the user asked). Returns the request id, -1 if the server
        cannot be asked now."""
        if self.state != LSP_READY or not self.table.completion or self.find_doc(uri) < 0:
            return -1
        var p = self.position_params(uri, line, character)
        if trigger.byte_length() > 0:
            p += ",\"context\":{\"triggerKind\":2,\"triggerCharacter\":" + json_quote(trigger) + "}}"
        else:
            p += ",\"context\":{\"triggerKind\":1}}"
        return self.conn.request("textDocument/completion", p, now)

    def request_hover(mut self, uri: String, line: Int, character: Int, now: Int) -> Int:
        """Ask what the server knows about the symbol at a position. -1 if it cannot be
        asked now."""
        if self.state != LSP_READY or not self.table.hover or self.find_doc(uri) < 0:
            return -1
        return self.conn.request("textDocument/hover", self.position_params(uri, line, character) + "}", now)

    def request_resolve(mut self, raw_item: String, now: Int) -> Int:
        """Ask for the missing details (documentation) of a completion item."""
        if self.state != LSP_READY or not self.table.completion_resolve or raw_item.byte_length() == 0:
            return -1
        return self.conn.request("completionItem/resolve", raw_item, now)

    def doc_version(self, uri: String) -> Int:
        var i = self.find_doc(uri)
        return self.docs[i].version if i >= 0 else -1

    def did_close(mut self, uri: String):
        var i = self.find_doc(uri)
        if i < 0:
            return
        if self.docs[i].sent and self.state == LSP_READY:
            self.conn.notify("textDocument/didClose", "{\"textDocument\":{\"uri\":" + json_quote(uri) + "}}")
        else:
            var q = 0
            for k in range(i):
                if not self.docs[k].sent:
                    q += 1
            if q < len(self.queued_text) and not self.docs[i].sent:
                _ = self.queued_text.pop(q)
        _ = self.docs.pop(i)

    # ---------------------------------------------------------- diagnostics
    def diags_index(self, uri: String) -> Int:
        for i in range(len(self.diags)):
            if self.diags[i].uri == uri:
                return i
        return -1

    def diagnostics(self, uri: String) -> List[Diag]:
        var i = self.diags_index(uri)
        if i < 0:
            return List[Diag]()
        return self.diags[i].items.copy()

    def take_updated(mut self) -> List[String]:
        """URIs whose diagnostics changed since the last call."""
        var out = self.updated.copy()
        self.updated.clear()
        return out^

    def on_publish(mut self, m: RpcMessage):
        var p = m.params()
        var uri = m.doc.str(m.doc.get(p, "uri"))
        if uri.byte_length() == 0:
            return
        var i = self.diags_index(uri)
        if i < 0:
            self.diags.append(DocDiags(uri))
            i = len(self.diags) - 1
        self.diags[i].items.clear()
        self.diags[i].version = m.doc.int(m.doc.get(p, "version"), -1)
        for d in m.doc.children(m.doc.get(p, "diagnostics")):
            self.diags[i].items.append(Diag(
                m.doc.int(m.doc.path(d, "range/start/line")),
                m.doc.int(m.doc.path(d, "range/start/character")),
                m.doc.int(m.doc.path(d, "range/end/line")),
                m.doc.int(m.doc.path(d, "range/end/character")),
                m.doc.int(m.doc.get(d, "severity"), SEV_ERROR),
                m.doc.str(m.doc.get(d, "message")),
            ))
        if not (uri in self.updated):
            self.updated.append(uri)

    # -------------------------------------------------------------- messages
    def handle(mut self, msgs: List[RpcMessage]):
        for m in msgs:
            if m.kind == RPC_RESPONSE and m.id == self.init_id and self.state == LSP_STARTING:
                self.caps = Json()
                var c = m.doc.path(0, "result/capabilities")
                if c >= 0:
                    self.caps = json_subtree(m.doc, c)
                self.table = parse_caps(self.caps)
                self.was_ready = True
                self.server_name = m.doc.str(m.doc.path(0, "result/serverInfo/name"), "language server")
                self.state = LSP_READY
                self.conn.notify("initialized", "{}")
                # documents that were opened while the server was starting
                var q = 0
                for k in range(len(self.docs)):
                    if not self.docs[k].sent:
                        var uri = String(self.docs[k].uri)
                        var text = String(self.queued_text[q])
                        self.send_open(uri, self.docs[k].version, text)
                        self.docs[k].sent = True
                        q += 1
                self.queued_text.clear()
            elif (m.kind == RPC_RESPONSE or m.kind == RPC_ERROR) and m.id != self.init_id and self.state == LSP_READY:
                # an answer to something the IDE asked: kept until it is fetched
                self.replies.append(m.copy())
                if len(self.replies) > 64:
                    _ = self.replies.pop(0)
            elif m.kind == RPC_ERROR and m.id == self.init_id:
                self.state = LSP_FAILED
                self.last_error = "initialize failed: " + m.error_message()
            elif m.kind == RPC_NOTIFICATION:
                if m.method == "textDocument/publishDiagnostics":
                    self.on_publish(m)
                elif m.method == "window/logMessage" or m.method == "window/showMessage":
                    self.log.append(m.doc.str(m.doc.path(m.params(), "message")))
                    if len(self.log) > 200:
                        _ = self.log.pop(0)
            elif m.kind == RPC_REQUEST:
                # requests we can satisfy with "nothing" get null; the rest are refused
                if m.method == "client/registerCapability" or m.method == "client/unregisterCapability" or m.method == "window/workDoneProgress/create":
                    self.conn.respond(m.id_json, "null")
                elif m.method == "workspace/configuration":
                    var n = m.doc.size(m.doc.get(m.params(), "items"))
                    var arr = String("[")
                    for k in range(n):
                        arr += "null" if k == 0 else ",null"
                    self.conn.respond(m.id_json, arr + "]")
                else:
                    self.conn.respond_error(m.id_json, -32601, "not supported by TurboMojo: " + m.method)

    def poll(mut self):
        """Read and process everything that has arrived; notice a dead server."""
        if not self.conn.proc.running:
            return
        self.handle(self.conn.poll())
        if self.active() and self.conn.ended():
            self.state = LSP_FAILED
            self.last_error = "the language server exited"


def json_subtree(doc: Json, node: Int) -> Json:
    """A new document holding a copy of one node and everything below it."""
    return json_parse(doc.dump(node))


# ---------------------------------------------------------------- formatting
def severity_word(sev: Int) -> String:
    if sev == SEV_ERROR:
        return "error"
    if sev == SEV_WARNING:
        return "warning"
    return "note"


def diagnostic_line(path: String, line_text: List[Int], d: Diag) -> String:
    """`path:line:col: severity: message` with a 1-based line and codepoint column, the
    format the Message window already knows how to jump from. Only the first line of a
    multi-line message is used."""
    var first = List[Int]()
    for c in decode(d.message):
        if c == 10:
            break
        first.append(c)
    return path + ":" + String(d.line + 1) + ":" + String(utf16_to_col(line_text, d.ch) + 1) + ": " + severity_word(d.severity) + ": " + to_str(first)
