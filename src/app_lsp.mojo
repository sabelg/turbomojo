"""Language server integration in the IDE (first slice: live diagnostics for one file)."""
from std.collections import List
from window import Window, WK_EDITOR, WK_MESSAGE
from window_search import *
from window_multi import *
from window_lines import *
from window_draw import *
from dialog import *
from util import *
from lsp import *
from buffer import Mark
from appstate import *
from app_files import *
from app_dialogs import *
from app_jobs import *

comptime LSP_DEBOUNCE_MS = 300     # quiet time after the last edit before the server is told


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
        """The Problems list: every problem the server has reported, for all files, in
        the Message window in compiler format, so Enter and Alt-F8/F7 jump to them. The
        active file comes first."""
        var order = List[Int]()
        var top_uri = String("")
        var te = self.top_editor()
        if te >= 0 and self.wins[te].path.byte_length() > 0:
            top_uri = path_to_uri(self.wins[te].path)
        for k in range(len(self.lsp.diags)):
            if self.lsp.diags[k].uri == top_uri:
                order.append(k)
        for k in range(len(self.lsp.diags)):
            if self.lsp.diags[k].uri != top_uri:
                order.append(k)
        var text = String("")
        var total = 0
        var files = 0
        for k in order:
            if len(self.lsp.diags[k].items) == 0:
                continue
            files += 1
            var path = uri_to_path(self.lsp.diags[k].uri)
            var wi = self.find_editor(path)
            for d in self.lsp.diags[k].items:
                total += 1
                var line_text = List[Int]()
                if wi >= 0 and d.line >= 0 and d.line < self.wins[wi].buf.count():
                    line_text = self.wins[wi].buf.line(d.line)
                elif wi < 0:
                    # not open: the column is shown in the server's units
                    for _ in range(d.ch):
                        line_text.append(32)
                text += diagnostic_line(path, line_text, d) + "\n"
                # remaining lines of a multi-line message, indented
                var first = True
                for part in d.message.split("\n"):
                    if first:
                        first = False
                        continue
                    text += "    " + String(part) + "\n"
        var footer = String("No problems found")
        if total > 0:
            footer = String(total) + " problem(s)" + (" in " + String(files) + " files" if files > 1 else "")
        if latency_ms >= 0:
            footer += "  (server answered in " + String(latency_ms) + " ms)"
        if text.find("'std' is required") >= 0:
            footer += "\nThe Mojo standard library was not found: start TurboMojo with `pixi run`."
        _ = self.fill_messages("Problems reported by the language server", str_bytes(text), footer)
        var mi = self.msg_index()
        if mi >= 0:
            self.wins[mi].title = "Problems"

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
            elif m.id == self.hover_req_id:
                self.hover_arrived(m)
            elif m.id == self.sig_req_id:
                self.sig_arrived(m)
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
        var changed = False
        var latency = -1
        for uri in self.lsp.take_updated():
            changed = True
            var wi = self.find_editor(uri_to_path(uri))
            if wi >= 0:
                self.lsp_set_marks(wi)
            if uri == self.lsp_uri and self.lsp_sent_ns > 0:
                latency = (now - self.lsp_sent_ns) // 1000000
                self.lsp_last_latency_ms = latency
                self.lsp_sent_ns = 0
        if changed:
            self.lsp_show(latency)
