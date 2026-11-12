"""Language server integration in the IDE (first slice: live diagnostics for one file)."""
from std.collections import List
from window import Window, WK_EDITOR, WK_MESSAGE, WK_OUTLINE, WK_EXPLORER
from window_search import *
from window_multi import *
from window_lines import *
from window_draw import *
from dialog import *
from util import *
from lsp import *
from buffer import Mark, Hint
from highlight import C_PARAM, C_DEF, C_PROP, C_TYPE, C_NS, C_SELF
from appstate import *
from app_notify import *
from app_problems import *
from app_files import *
from app_dialogs import *
from app_jobs import *
from app_lspextra import *

comptime LSP_DEBOUNCE_MS = 300     # quiet time after the last edit before the server is told



def semantic_class(name: String) -> Int:
    """The colour class for a semantic token type; -1 = leave the lexer's colour
    (plain variables, and kinds this editor has no colour for)."""
    if name == "parameter":
        return C_PARAM
    if name == "function" or name == "method" or name == "macro":
        return C_DEF
    if name == "property" or name == "enumMember":
        return C_PROP
    if name == "class" or name == "interface" or name == "type" or name == "struct" or name == "enum" or name == "typeParameter":
        return C_TYPE
    if name == "namespace":
        return C_NS
    if name == "specialVariable":
        return C_SELF
    return -1

__extension App:
    def lsp_server_command(mut self, path: String) -> String:
        """Command line of the language server, with include paths so that modules
        resolve: the file's folder, the working directory, and the project's own
        (`tools.include_paths`)."""
        var exe = String(self.lsp_server)
        return self.tool(exe) + " -I " + shell_quote(dirname(path)) + " -I " + shell_quote(self.cwd) + self.include_flags()

    def lsp_command(mut self):
        """Compile > Check with language server: start live diagnostics for the current
        file, or stop them when it is already the file being checked."""
        var i = self.top_editor()
        if i < 0:
            return
        if self.wins[i].path.byte_length() == 0:
            self.say("Save the file first: the language server needs its name")
            return
        if self.wins[i].buf.large:
            self.say("The language server is off in large-file mode")
            return
        var xk = self.extra_for(self.wins[i].path)
        if xk >= 0:
            self.extra_toggle(xk, i)            # a file of another language: its own server
            return
        if self.lsp_restart_due > 0 and self.lsp_restart_path == self.wins[i].path:
            # asked again while a restart was pending: that cancels it
            self.lsp_stop()
            self.say("Language server stopped")
            return
        self.lsp_crashes.clear()            # a deliberate start gets a fresh allowance
        if self.lsp.active() and self.lsp_path == self.wins[i].path:
            self.lsp_stop()
            self.say("Language server stopped")
            return
        self.lsp_track(i, now_ns())

    def lsp_track(mut self, i: Int, now: Int):
        """Make window i the file whose diagnostics are shown, starting the server if needed."""
        var path = self.wins[i].path
        if not self.lsp.active():
            var log = (dirname(self.log_path) + "/lsp.log") if self.log_path.byte_length() > 0 else String("/dev/null")
            self.lsp_reported_failure = False
            self.lsp_announced = False
            self.lsp_restart_due = 0
            if not self.lsp.start(self.lsp_server_command(path), self.cwd, log, own_pid(), now):
                self.say("Could not start the language server")
                return
        self.lsp_path = path
        self.lsp_uri = path_to_uri(path)
        # the server gets this file now rather than after the usual pause
        if self.lsp.find_doc(self.lsp_uri) < 0:
            self.lsp_open_doc(i)
        else:
            self.lsp_send_changes(i, now, True)
        self.lsp_sent_ns = now
        self.say("Language server: checking " + basename(path) + "...")

    # ---------------------------------------------------------- document sync
    def lsp_wants(self, i: Int) -> Bool:
        """Is window i a file the server should follow? Every open Mojo file, and the
        file being checked whatever its name; not untitled or very large buffers."""
        if self.wins[i].kind != WK_EDITOR or self.wins[i].path.byte_length() == 0 or self.wins[i].buf.large:
            return False
        var p = self.wins[i].path
        return p == self.lsp_path or p.endswith(".mojo") or p.endswith(".🔥")

    def lsp_open_doc(mut self, i: Int):
        """didOpen for window i; from here on its edits are recorded for the server."""
        var uri = path_to_uri(self.wins[i].path)
        if self.lsp.did_open(uri, bytes_to_str(self.wins[i].buf.lsp_bytes())):
            self.wins[i].buf.start_tracking()
            self.wins[i].lsp_sent_version = self.wins[i].buf.version
            self.wins[i].lsp_seen_version = self.wins[i].buf.version
            self.wins[i].lsp_due = 0

    def lsp_send_changes(mut self, i: Int, now: Int, always: Bool):
        """didChange for window i with what changed since the server was last told: the
        recorded edits as ranges when the server takes those, otherwise the whole text.
        `always` sends the text even if nothing changed (to have a file checked again)."""
        var uri = path_to_uri(self.wins[i].path)
        self.wins[i].lsp_due = 0
        if self.lsp.find_doc(uri) < 0:
            return
        var v = self.wins[i].buf.version
        if v == self.wins[i].lsp_sent_version and not always:
            return
        var sent = -1
        if self.lsp.table.sync_kind == SYNC_INCREMENTAL and not self.wins[i].buf.changes_lost and self.wins[i].buf.track:
            sent = self.lsp.did_change_ranges(uri, self.wins[i].buf.take_changes())
        if sent < 0:
            _ = self.lsp.did_change(uri, bytes_to_str(self.wins[i].buf.lsp_bytes()))
            self.wins[i].buf.start_tracking()
        self.wins[i].lsp_sent_version = v
        self.wins[i].lsp_seen_version = v
        if self.wins[i].path == self.lsp_path:
            self.lsp_sent_ns = now

    def lsp_note_saved(mut self, i: Int):
        """After a save: the server gets any pending edits first, then didSave."""
        if not self.lsp.active() or self.wins[i].path.byte_length() == 0:
            return
        var uri = path_to_uri(self.wins[i].path)
        if self.lsp.find_doc(uri) < 0:
            return
        self.lsp_send_changes(i, now_ns(), False)
        if self.lsp.table.sync_save:
            _ = self.lsp.did_save(uri)

    # ------------------------------------- semantic colours and inlay hints
    def decor_reset(mut self, colours: Bool, hints: Bool):
        """Forget what the server said (after a toggle, or when it stops); with the
        option on and a server running, everything is asked for again."""
        for i in range(len(self.wins)):
            if self.wins[i].kind != WK_EDITOR:
                continue
            if colours:
                self.wins[i].buf.sem.clear()
                self.wins[i].sem_version = -1
            if hints:
                self.wins[i].buf.hints.clear()
                self.wins[i].hint_version = -1
        if colours:
            self.sem_req_id = -1
        if hints:
            self.hint_req_id = -1

    def decor_tick(mut self, now: Int):
        """Ask for the colours and hints of files whose text the server has and whose
        answer is older than the text - one request of each kind at a time."""
        if self.lsp.state != LSP_READY or now < self.decor_wait_until:
            return
        if self.sem_req_id >= 0 and now - self.sem_req_ns > 5000000000:
            self.sem_req_id = -1                # never answered
        if self.hint_req_id >= 0 and now - self.hint_req_ns > 5000000000:
            self.hint_req_id = -1
        var want_sem = self.semantic_on and self.lsp.table.semantic_full and self.sem_req_id < 0
        var want_hint = self.hints_on and self.lsp.table.inlay_hint and self.hint_req_id < 0
        if not want_sem and not want_hint:
            return
        for i in range(len(self.wins)):
            if not self.lsp_wants(i):
                continue
            var v = self.wins[i].buf.version
            if self.wins[i].lsp_sent_version != v:
                continue                        # the server does not have this text yet
            var uri = path_to_uri(self.wins[i].path)
            if want_sem and self.wins[i].sem_version != v:
                var id = self.lsp.request_semantic(uri, now)
                if id >= 0:
                    self.sem_req_id = id
                    self.sem_req_path = self.wins[i].path
                    self.sem_req_version = v
                    self.sem_req_ns = now
                    self.wins[i].sem_version = v
                    want_sem = False
            if want_hint and self.wins[i].hint_version != v:
                var id = self.lsp.request_inlay(uri, self.wins[i].buf.count(), now)
                if id >= 0:
                    self.hint_req_id = id
                    self.hint_req_path = self.wins[i].path
                    self.hint_req_version = v
                    self.hint_req_ns = now
                    self.wins[i].hint_version = v
                    want_hint = False

    def semantic_arrived(mut self, m: RpcMessage, now: Int):
        self.sem_req_id = -1
        var i = self.find_editor(self.sem_req_path)
        if i < 0:
            return
        if m.kind == RPC_ERROR:
            # asked again a little later (the server may still be reading the edit)
            self.wins[i].sem_version = -1
            self.decor_wait_until = now + 300000000
            return
        if self.wins[i].buf.version != self.sem_req_version or not self.semantic_on:
            return                              # the text moved on; decor_tick asks again
        var toks = parse_semantic(m.doc, m.result())
        var classes = List[Int]()
        for name in self.lsp.table.token_types:
            classes.append(semantic_class(name))
        var sem = List[Int]()
        var row = -1
        var line = List[Int]()
        var ascii = True
        var count = self.wins[i].buf.count()
        for k in range(len(toks) // 4):
            var r = toks[k * 4]
            var kind = toks[k * 4 + 3]
            if r >= count or kind >= len(classes) or classes[kind] < 0:
                continue
            if r != row:
                row = r
                line = self.wins[i].buf.line(r)
                ascii = True
                for c in line:
                    if c >= 128:
                        ascii = False
                        break
            var a = toks[k * 4 + 1]
            var b = a + toks[k * 4 + 2]
            if not ascii:
                a = utf16_to_col(line, a)
                b = utf16_to_col(line, b)
            sem.append(r)
            sem.append(a)
            sem.append(b)
            sem.append(classes[kind])
        self.wins[i].buf.sem = sem^

    def hints_arrived(mut self, m: RpcMessage, now: Int):
        self.hint_req_id = -1
        var i = self.find_editor(self.hint_req_path)
        if i < 0:
            return
        if m.kind == RPC_ERROR:
            self.wins[i].hint_version = -1
            self.decor_wait_until = now + 300000000
            return
        if self.wins[i].buf.version != self.hint_req_version or not self.hints_on:
            return
        self.wins[i].buf.hints.clear()
        var count = self.wins[i].buf.count()
        for h in parse_inlay(m.doc, m.result()):
            if h.row < count:
                self.wins[i].buf.hints.append(Hint(h.row, utf16_to_col(self.wins[i].buf.line(h.row), h.col16), h.label, h.kind))

    def lsp_sync(mut self, now: Int):
        """Keep the server's set of documents equal to the open files, and send edits
        LSP_DEBOUNCE_MS after typing stops."""
        var keep = List[String]()
        for i in range(len(self.wins)):
            if self.lsp_wants(i):
                keep.append(path_to_uri(self.wins[i].path))
        var k = 0
        while k < len(self.lsp.docs):
            var uri = String(self.lsp.docs[k].uri)
            if uri in keep:
                k += 1
            else:
                self.lsp.did_close(uri)         # closed, or saved under another name
        var earliest = 0
        for i in range(len(self.wins)):
            if not self.lsp_wants(i):
                if self.wins[i].kind == WK_EDITOR and self.wins[i].buf.track:
                    self.wins[i].buf.stop_tracking()
                continue
            if self.lsp.find_doc(path_to_uri(self.wins[i].path)) < 0:
                self.lsp_open_doc(i)
                continue
            var v = self.wins[i].buf.version
            if v != self.wins[i].lsp_seen_version:
                self.wins[i].lsp_seen_version = v
                self.wins[i].lsp_due = now + LSP_DEBOUNCE_MS * 1000000
            if self.wins[i].lsp_due > 0 and now >= self.wins[i].lsp_due and self.lsp.state == LSP_READY:
                self.lsp_send_changes(i, now, False)
            if self.wins[i].lsp_due > 0 and (earliest == 0 or self.wins[i].lsp_due < earliest):
                earliest = self.wins[i].lsp_due
        self.lsp_change_due = earliest

    def lsp_stop(mut self):
        self.lsp.stop()
        for i in range(len(self.wins)):
            if self.wins[i].kind == WK_EDITOR:
                self.wins[i].buf.stop_tracking()
                self.wins[i].buf.marks.clear()
                self.wins[i].lsp_due = 0
        self.decor_reset(True, True)
        self.lsp_restart_due = 0
        self.lsp_restart_path = ""
        self.lsp_path = ""
        self.lsp_uri = ""
        self.lsp_change_due = 0
        self.lsp_sent_ns = 0

    def lsp_set_marks(mut self, i: Int):
        """Give window i the problems the server reported for its file, with the
        server's UTF-16 columns turned into character columns."""
        self.wins[i].buf.marks.clear()
        var count = self.wins[i].buf.count()
        for d in self.lsp.diagnostics(path_to_uri(self.wins[i].path)):
            var l1 = max(0, min(d.line, count - 1))
            var l2 = max(l1, min(d.end_line, count - 1))
            var c1 = utf16_to_col(self.wins[i].buf.line(l1), d.ch)
            var c2 = utf16_to_col(self.wins[i].buf.line(l2), d.end_ch)
            self.wins[i].buf.marks.append(Mark(l1, c1, l2, c2, d.severity, d.message))

    def lsp_show(mut self, latency_ms: Int):
        """New problems from the server: the Problems page (app_problems) with them,
        at the front unless another page was chosen."""
        self.problems_show(True)

    def lsp_tick(mut self, now: Int):
        """Called on every pass of the event loop while a language server is in use."""
        if self.lsp_restart_due > 0 and now >= self.lsp_restart_due:
            # time to bring a crashed server back for the file it was checking
            self.lsp_restart_due = 0
            var ri = self.find_editor(self.lsp_restart_path)
            self.lsp_restart_path = ""
            if ri >= 0:
                self.lsp_track(ri, now)
            return
        if not self.lsp.conn.proc.running:
            return
        self.lsp.poll()
        if self.lsp.state == LSP_READY and not self.lsp_announced:
            self.lsp_announced = True
            for line in self.lsp.table.describe():
                self.log_error("language server " + self.lsp.server_name + ": " + line)
        if self.lsp.state == LSP_FAILED:
            var crashed = self.lsp.was_ready        # it had been working: not a start-up problem
            _ = self.lsp.conn.stop()
            self.lsp.state = LSP_STOPPED
            self.log_error("language server: " + self.lsp.last_error)
            var why = self.lsp.last_error
            self.notify(NL_ERROR, "The language server " + ("crashed" if crashed else "did not start"), why)
            # forget crashes that are long ago, then decide whether to try again
            var recent = List[Int]()
            for t in self.lsp_crashes:
                if now - t < LSP_CRASH_WINDOW_S * 1000000000:
                    recent.append(t)
            self.lsp_crashes = recent^
            var tracked = String(self.lsp_path)
            self.lsp_path = ""
            self.lsp_uri = ""
            self.lsp_change_due = 0
            self.lsp_sent_ns = 0
            if crashed and tracked.byte_length() > 0 and len(self.lsp_crashes) < LSP_MAX_RESTARTS:
                self.lsp_crashes.append(now)
                var n = len(self.lsp_crashes)
                var wait_ms = self.lsp_restart_base_ms
                for _ in range(n - 1):
                    wait_ms *= 2
                self.lsp_restart_due = now + wait_ms * 1000000
                self.lsp_restart_path = tracked
                self.say("Language server stopped unexpectedly - restarting (" + String(n) + " of " + String(LSP_MAX_RESTARTS) + ")")
                return
            if not self.lsp_reported_failure:
                self.lsp_reported_failure = True
                if crashed:
                    self.say("Language server keeps stopping - press " + self.reg.key_label(CM_LSP) + " to try again")
                else:
                    self.say("Language server: " + self.lsp.last_error)
            return
        if self.comp_retry_due > 0 and now >= self.comp_retry_due:
            self.completion_retry(now)
        if self.hover_retry_due > 0 and now >= self.hover_retry_due:
            self.hover_retry_due = 0
            var hi = self.active_editor()
            if not self.hover_still_wanted() or not self.hover_request(hi):
                self.hover_req_id = -1
        if self.def_retry_due > 0 and now >= self.def_retry_due:
            self.def_retry_due = 0
            var di = self.active_editor()
            if not self.definition_still_wanted() or not self.definition_request(di):
                self.def_req_id = -1
        if self.ref_retry_due > 0 and now >= self.ref_retry_due:
            self.ref_retry_due = 0
            var ri = self.active_editor()
            if not self.references_still_wanted() or not self.references_request(ri):
                self.ref_req_id = -1
        if self.ren_retry_due > 0 and now >= self.ren_retry_due:
            self.ren_retry_due = 0
            self.rename_resend()
        if self.act_retry_due > 0 and now >= self.act_retry_due:
            self.act_retry_due = 0
            self.actions_resend()
        if self.sig_retry_due > 0 and now >= self.sig_retry_due:
            self.sig_retry_due = 0
            var si = self.active_editor()
            if si < 0 or not self.sig_request(si, "", self.sig_on):
                self.sig_close()
        for m in self.lsp.take_replies():
            if m.id == self.comp_req_id:
                self.completion_arrived(m)
            elif m.id == self.comp_resolve_id:
                self.resolve_arrived(m)
            elif m.id == self.hover_req_id and self.hover_srv < 0:
                self.hover_arrived(m)
            elif m.id == self.sig_req_id:
                self.sig_arrived(m)
            elif m.id == self.outline_req_id:
                self.outline_arrived(m)
            elif m.id == self.sem_req_id:
                self.semantic_arrived(m, now)
            elif m.id == self.hint_req_id:
                self.hints_arrived(m, now)
            elif m.id == self.act_req_id:
                self.actions_reply(m)
            elif m.id == self.ren_req_id:
                self.rename_reply(m)
            elif m.id == self.ref_req_id:
                self.references_arrived(m)
            elif m.id == self.def_req_id:
                try:
                    self.definition_arrived(m)
                except e:
                    self.say("Cannot open the definition: " + String(e))
        if len(self.lsp.asked_edits) > 0:
            self.server_edits()
        var i = self.find_editor(self.lsp_path) if self.lsp_path.byte_length() > 0 else -1
        if i < 0 and self.lsp_path.byte_length() > 0:
            # the window whose problems were shown is gone; other files stay in step
            self.lsp_path = ""
            self.lsp_uri = ""
        self.lsp_sync(now)
        self.decor_tick(now)
        var changed = False
        var latency = -1
        for uri in self.lsp.take_updated():
            changed = True
            var wi = self.find_editor(uri_to_path(uri))
            if wi >= 0:
                self.lsp_set_marks(wi)
                # the server has just analysed this text: an answer given before that
                # (the Mojo server sends "no tokens" while it is still reading) is replaced
                if len(self.wins[wi].buf.sem) == 0:
                    self.wins[wi].sem_version = -1
                if len(self.wins[wi].buf.hints) == 0:
                    self.wins[wi].hint_version = -1
            if uri == self.lsp_uri and self.lsp_sent_ns > 0:
                latency = (now - self.lsp_sent_ns) // 1000000
                self.lsp_last_latency_ms = latency
                self.lsp_sent_ns = 0
        if changed:
            self.lsp_show(latency)
