"""Language servers for other languages, by configuration ([lsp.<name>] in the config
file: command, extensions, language). F7 on a file with one of a server's endings
starts that server (F7 needs a trusted folder, as for Mojo's server) and stops it
again; while it runs it follows every open file of its kind - opened, changed (the
whole text, after the usual pause), saved, closed - and its problems are underlined
and on the Problems page. Describe symbol (Alt-I) asks it about its files. The other
language features stay with the Mojo server.
"""
from std.collections import List
from appstate import *
from util import *
from lsp import LspClient, LSP_READY, LSP_FAILED, LSP_STOPPED, path_to_uri, uri_to_path, utf16_to_col
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
            self.extra_sync(k, now)
            var changed = self.lsp_extra[k].client.take_updated()
            if len(changed) > 0:
                for i in range(len(self.wins)):
                    if self.wins[i].kind == WK_EDITOR and path_to_uri(self.wins[i].path) in changed:
                        self.extra_marks(k, i)
                self.problems_show(True)
            for m in self.lsp_extra[k].client.take_replies():
                if m.id == self.hover_req_id and self.hover_srv == k:
                    self.hover_arrived(m)

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
