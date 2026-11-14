"""Language servers for other languages ([lsp.<name>] in configuration or auto-discovered).

F7 on a non-Mojo file starts its configured `[lsp.<name>]` server (or auto-discovers
`pyright-langserver` / `ruff server` for Python and `clangd` for C/C++/CUDA) and stops
it again. While running, it syncs open files of its kind and provides diagnostics,
hover (`Alt-I`), completion (`Ctrl-Space`), signature help (`Alt-P`), go to definition
(`F12`), type definition, references (`Shift-F12`), rename (`Shift-F2`), and quick fixes
(`Alt-Enter`)."""
from std.collections import List
from appstate import *
from util import *
from json import json_parse
from lsp import LspClient, LSP_READY, LSP_FAILED, LSP_STOPPED, path_to_uri, uri_to_path, utf16_to_col, parse_workspace_edit
from buffer import Mark
from window import WK_EDITOR
from notify import NL_ERROR
from signals import own_pid
from app_notify import *
from app_problems import *
from lspextra import ExtraServer, ends_with_any


__extension App:
    def extra_for(self, path: String) -> Int:
        """The configured server for a file (by its ending), or -1."""
        if path.byte_length() == 0:
            return -1
        for k in range(len(self.lsp_extra)):
            if ends_with_any(path, self.lsp_extra[k].exts):
                return k
        return -1

    def extra_auto_probe(mut self, path: String) -> Int:
        """If no `[lsp.<name>]` matches `path`, probe standard Python or C/C++/CUDA servers."""
        var existing = self.extra_for(path)
        if existing >= 0:
            return existing
        var low = lower_str(basename(path))
        if low.endswith(".py") or low.endswith(".pyi"):
            var cmd = String("")
            var sname = String("python")
            if which("pyright-langserver").byte_length() > 0:
                cmd = "pyright-langserver --stdio"
                sname = "pyright"
            elif which("basedpyright-langserver").byte_length() > 0:
                cmd = "basedpyright-langserver --stdio"
                sname = "basedpyright"
            elif which("ruff").byte_length() > 0:
                cmd = "ruff server"
                sname = "ruff"
            if cmd.byte_length() > 0:
                var exts = List[String]()
                exts.append(".py")
                exts.append(".pyi")
                self.lsp_extra.append(ExtraServer(sname, cmd, exts, "python"))
                return len(self.lsp_extra) - 1
        for cext in [".c", ".h", ".cpp", ".hpp", ".cc", ".cxx", ".hxx", ".cu", ".cuh"]:
            if low.endswith(String(cext)):
                if which("clangd").byte_length() > 0:
                    var exts = List[String]()
                    for ce in [".c", ".h", ".cpp", ".hpp", ".cc", ".cxx", ".hxx", ".cu", ".cuh"]:
                        exts.append(String(ce))
                    self.lsp_extra.append(ExtraServer("clangd", "clangd", exts, "cpp"))
                    return len(self.lsp_extra) - 1
                break
        return -1

    def extra_fds(self) -> List[Int]:
        var out = List[Int]()
        for e in self.lsp_extra:
            if e.client.active() and e.client.conn.fd() >= 0:
                out.append(e.client.conn.fd())
        return out^

    def extra_active(self) -> Bool:
        for e in self.lsp_extra:
            if e.client.active():
                return True
        return False

    def extra_toggle(mut self, k: Int, i: Int):
        """F7 on a file of server k: start it, or stop it when it runs."""
        if self.lsp_extra[k].client.active():
            self.extra_stop(k)
            self.say("Language server " + self.lsp_extra[k].name + " stopped")
            return
        var log = (dirname(self.log_path) + "/lsp-" + self.lsp_extra[k].name + ".log") if self.log_path.byte_length() > 0 else String("/dev/null")
        if not self.lsp_extra[k].client.start(self.lsp_extra[k].command, self.cwd, log, own_pid(), now_ns()):
            self.say("Could not start the language server " + self.lsp_extra[k].name + " (" + self.lsp_extra[k].command + ")")
            return
        self.say("Language server " + self.lsp_extra[k].name + ": checking " + basename(self.wins[i].path) + "...")
        self.extra_sync(k, now_ns())

    def extra_stop(mut self, k: Int):
        self.lsp_extra[k].client.stop()
        for i in range(len(self.wins)):
            if self.wins[i].kind == WK_EDITOR and ends_with_any(self.wins[i].path, self.lsp_extra[k].exts):
                self.wins[i].buf.marks.clear()
                self.wins[i].lsp_due = 0
        self.problems_show(False)

    def extra_stop_all(mut self):
        for k in range(len(self.lsp_extra)):
            if self.lsp_extra[k].client.active():
                self.lsp_extra[k].client.stop()

    def extra_wants(self, k: Int, i: Int) -> Bool:
        return self.wins[i].kind == WK_EDITOR and not self.wins[i].buf.large and ends_with_any(self.wins[i].path, self.lsp_extra[k].exts)

    def extra_send_now(mut self, k: Int, ai: Int):
        """Flush any unsent buffer edits immediately to extra server `k` before a request."""
        if k < 0 or k >= len(self.lsp_extra) or ai < 0 or ai >= len(self.wins):
            return
        if self.lsp_extra[k].client.state != LSP_READY:
            return
        var uri = path_to_uri(self.wins[ai].path)
        var v = self.wins[ai].buf.version
        if self.lsp_extra[k].client.find_doc(uri) < 0:
            if self.lsp_extra[k].client.did_open(uri, bytes_to_str(self.wins[ai].buf.lsp_bytes())):
                self.wins[ai].lsp_sent_version = v
                self.wins[ai].lsp_seen_version = v
                self.wins[ai].lsp_due = 0
            return
        if v != self.wins[ai].lsp_sent_version:
            _ = self.lsp_extra[k].client.did_change(uri, bytes_to_str(self.wins[ai].buf.lsp_bytes()))
            self.wins[ai].lsp_sent_version = v
            self.wins[ai].lsp_seen_version = v
            self.wins[ai].lsp_due = 0

    def extra_sync(mut self, k: Int, now: Int):
        """Server k's documents are the open files of its kind; changes go after the
        usual pause, as whole texts."""
        var keep = List[String]()
        for i in range(len(self.wins)):
            if self.extra_wants(k, i):
                keep.append(path_to_uri(self.wins[i].path))
        var d = 0
        while d < len(self.lsp_extra[k].client.docs):
            var uri = String(self.lsp_extra[k].client.docs[d].uri)
            if uri in keep:
                d += 1
            else:
                self.lsp_extra[k].client.did_close(uri)
        for i in range(len(self.wins)):
            if not self.extra_wants(k, i):
                continue
            var uri = path_to_uri(self.wins[i].path)
            var v = self.wins[i].buf.version
            if self.lsp_extra[k].client.find_doc(uri) < 0:
                if self.lsp_extra[k].client.did_open(uri, bytes_to_str(self.wins[i].buf.lsp_bytes())):
                    self.wins[i].lsp_sent_version = v
                    self.wins[i].lsp_seen_version = v
                continue
            if v != self.wins[i].lsp_seen_version:
                self.wins[i].lsp_seen_version = v
                self.wins[i].lsp_due = now + LSP_DEBOUNCE_MS * 1000000
            if self.wins[i].lsp_due > 0 and now >= self.wins[i].lsp_due and self.lsp_extra[k].client.state == LSP_READY:
                self.wins[i].lsp_due = 0
                _ = self.lsp_extra[k].client.did_change(uri, bytes_to_str(self.wins[i].buf.lsp_bytes()))
                self.wins[i].lsp_sent_version = v
            if self.wins[i].lsp_due > 0 and (self.lsp_change_due == 0 or self.wins[i].lsp_due < self.lsp_change_due):
                self.lsp_change_due = self.wins[i].lsp_due

    def extra_tick(mut self, now: Int):
        for k in range(len(self.lsp_extra)):
            if not self.lsp_extra[k].client.active():
                continue
            self.lsp_extra[k].client.poll()
            if self.lsp_extra[k].client.state == LSP_FAILED:
                var why = self.lsp_extra[k].client.last_error
                _ = self.lsp_extra[k].client.conn.stop()
                self.lsp_extra[k].client.state = LSP_STOPPED
                self.notify_as("lsp", NL_ERROR, "The language server " + self.lsp_extra[k].name + " stopped", why)
                self.extra_stop(k)
                continue
            if self.comp_retry_due > 0 and now >= self.comp_retry_due and self.comp_srv_extra == k:
                self.completion_retry(now)
            if self.hover_retry_due > 0 and now >= self.hover_retry_due and self.hover_srv == k:
                self.hover_retry_due = 0
                var hi = self.active_editor()
                if not self.hover_still_wanted() or hi < 0 or not self.extra_hover(k, hi):
                    self.hover_req_id = -1
            if self.def_retry_due > 0 and now >= self.def_retry_due and self.def_srv == k:
                self.def_retry_due = 0
                var di = self.active_editor()
                var def_ok = di >= 0 and (self.typedef_request(di) if self.def_is_type else self.definition_request(di))
                if not self.definition_still_wanted() or not def_ok:
                    self.def_req_id = -1
            if self.ref_retry_due > 0 and now >= self.ref_retry_due and self.ref_srv == k:
                self.ref_retry_due = 0
                var ri = self.active_editor()
                if not self.references_still_wanted() or ri < 0 or not self.references_request(ri):
                    self.ref_req_id = -1
            if self.ren_retry_due > 0 and now >= self.ren_retry_due and self.ren_srv == k:
                self.ren_retry_due = 0
                self.rename_resend()
            if self.act_retry_due > 0 and now >= self.act_retry_due and self.act_srv == k:
                self.act_retry_due = 0
                self.actions_resend()
            if self.sig_retry_due > 0 and now >= self.sig_retry_due and self.sig_srv == k:
                self.sig_retry_due = 0
                var si = self.active_editor()
                if si < 0 or not self.sig_request(si, "", self.sig_on):
                    self.sig_close()
            self.extra_sync(k, now)
            var changed = self.lsp_extra[k].client.take_updated()
            if len(changed) > 0:
                for i in range(len(self.wins)):
                    if self.wins[i].kind == WK_EDITOR and path_to_uri(self.wins[i].path) in changed:
                        self.extra_marks(k, i)
                self.problems_show(True)
            for m in self.lsp_extra[k].client.take_replies():
                if m.id == self.comp_req_id and self.comp_srv_extra == k:
                    self.completion_arrived(m)
                elif m.id == self.comp_resolve_id and self.comp_srv_extra == k:
                    self.resolve_arrived(m)
                elif m.id == self.hover_req_id and self.hover_srv == k:
                    self.hover_arrived(m)
                elif m.id == self.sig_req_id and self.sig_srv == k:
                    self.sig_arrived(m)
                elif m.id == self.act_req_id and self.act_srv == k:
                    self.actions_reply(m)
                elif m.id == self.ren_req_id and self.ren_srv == k:
                    self.rename_reply(m)
                elif m.id == self.ref_req_id and self.ref_srv == k:
                    self.references_arrived(m)
                elif m.id == self.def_req_id and self.def_srv == k:
                    try:
                        self.definition_arrived(m)
                    except e:
                        self.say("Cannot open the definition: " + String(e))
            if len(self.lsp_extra[k].client.asked_edits) > 0:
                var pending = self.lsp_extra[k].client.take_asked_edits()
                var labels = self.lsp_extra[k].client.asked_labels.copy()
                self.lsp_extra[k].client.asked_labels.clear()
                for q in range(len(pending)):
                    if self.mode != M_NORMAL:
                        continue
                    var label = labels[q] if q < len(labels) and labels[q].byte_length() > 0 else String("Edit from " + self.lsp_extra[k].name)
                    var doc = json_parse(pending[q])
                    if doc.ok:
                        self.offer_edit(parse_workspace_edit(doc, 0), "Quick fix", "Quick Fix", label, "Applied: " + label)

    def extra_marks(mut self, k: Int, i: Int):
        self.wins[i].buf.marks.clear()
        var count = self.wins[i].buf.count()
        for d in self.lsp_extra[k].client.diagnostics(path_to_uri(self.wins[i].path)):
            var l1 = max(0, min(d.line, count - 1))
            var l2 = max(l1, min(d.end_line, count - 1))
            var c1 = utf16_to_col(self.wins[i].buf.line(l1), d.ch)
            var c2 = utf16_to_col(self.wins[i].buf.line(l2), d.end_ch)
            self.wins[i].buf.marks.append(Mark(l1, c1, l2, c2, d.severity, d.message))

    def extra_hover(mut self, k: Int, ai: Int) -> Bool:
        """Describe symbol on a file of server k."""
        self.extra_send_now(k, ai)
        ref c = self.lsp_extra[k].client
        if c.state != LSP_READY or not c.table.hover:
            return False
        var uri = path_to_uri(self.wins[ai].path)
        if c.find_doc(uri) < 0:
            return False
        var id = c.request_hover(uri, self.wins[ai].cr, self.wins[ai].buf.utf16_col(self.wins[ai].cr, self.wins[ai].cc), now_ns())
        if id < 0:
            return False
        self.hover_req_id = id
        self.hover_srv = k
        self.hover_req_path = self.wins[ai].path
        self.hover_req_row = self.wins[ai].cr
        self.hover_req_col = self.wins[ai].cc
        self.hover_retry_due = 0
        return True
