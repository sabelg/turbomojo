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
from appstate import *
from app_files import *
from app_dialogs import *
from app_jobs import *

comptime LSP_DEBOUNCE_MS = 300     # quiet time after the last edit before the server is told


__extension App:
    def lsp_server_command(mut self, path: String) -> String:
        """Command line of the language server, with include paths for the file's folder
        and the working directory so that sibling modules resolve."""
        var exe = env_or("TURBOMOJO_LSP", "mojo-lsp-server")
        return self.tool(exe) + " -I " + shell_quote(dirname(path)) + " -I " + shell_quote(self.cwd)

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
            if not self.lsp.start(self.lsp_server_command(path), self.cwd, log, own_pid(), now):
                self.say("Could not start the language server")
                return
        if self.lsp_path.byte_length() > 0 and self.lsp_path != path:
            self.lsp.did_close(self.lsp_uri)
        self.lsp_path = path
        self.lsp_uri = path_to_uri(path)
        var text = bytes_to_str(self.wins[i].buf.text_bytes())
        if not self.lsp.did_open(self.lsp_uri, text):
            _ = self.lsp.did_change(self.lsp_uri, text)
        self.lsp_sent_version = self.wins[i].buf.version
        self.lsp_seen_version = self.wins[i].buf.version
        self.lsp_sent_ns = now
        self.lsp_change_due = 0
        self.say("Language server: checking " + basename(path) + "...")

    def lsp_stop(mut self):
        self.lsp.stop()
        self.lsp_path = ""
        self.lsp_uri = ""
        self.lsp_change_due = 0
        self.lsp_sent_ns = 0

    def lsp_show(mut self, i: Int, latency_ms: Int):
        """Put the tracked file's diagnostics into the Message window in compiler format,
        so Enter and Alt-F8/F7 jump to them like build errors."""
        var path = self.wins[i].path
        var items = self.lsp.diagnostics(self.lsp_uri)
        var text = String("")
        for d in items:
            var line_text = List[Int]()
            if d.line >= 0 and d.line < self.wins[i].buf.count():
                line_text = self.wins[i].buf.line(d.line)
            text += diagnostic_line(path, line_text, d) + "\n"
            # remaining lines of a multi-line message, indented
            var first = True
            for part in d.message.split("\n"):
                if first:
                    first = False
                    continue
                text += "    " + String(part) + "\n"
        var footer = String("No problems found") if len(items) == 0 else String(len(items)) + " problem(s)"
        if latency_ms >= 0:
            footer += "  (server answered in " + String(latency_ms) + " ms)"
        if text.find("'std' is required") >= 0:
            footer += "\nThe Mojo standard library was not found: start TurboMojo with `pixi run`."
        _ = self.fill_messages("Language server diagnostics for " + path, str_bytes(text), footer)

    def lsp_tick(mut self, now: Int):
        """Called on every pass of the event loop while a language server is in use."""
        if not self.lsp.conn.proc.running:
            return
        self.lsp.poll()
        if self.lsp.state == LSP_FAILED:
            if not self.lsp_reported_failure:
                self.lsp_reported_failure = True
                self.say("Language server: " + self.lsp.last_error)
                self.log_error("language server: " + self.lsp.last_error)
            _ = self.lsp.conn.stop()
            self.lsp.state = LSP_STOPPED
            return
        var i = self.find_editor(self.lsp_path) if self.lsp_path.byte_length() > 0 else -1
        if i < 0:
            if self.lsp_path.byte_length() > 0:
                # the tracked window was closed
                self.lsp.did_close(self.lsp_uri)
                self.lsp_path = ""
                self.lsp_uri = ""
            return
        # debounce: tell the server LSP_DEBOUNCE_MS after typing stops
        var v = self.wins[i].buf.version
        if v != self.lsp_seen_version:
            self.lsp_seen_version = v
            self.lsp_change_due = now + LSP_DEBOUNCE_MS * 1000000
        if self.lsp_change_due > 0 and now >= self.lsp_change_due and self.lsp.state == LSP_READY:
            self.lsp_change_due = 0
            if v != self.lsp_sent_version:
                _ = self.lsp.did_change(self.lsp_uri, bytes_to_str(self.wins[i].buf.text_bytes()))
                self.lsp_sent_version = v
                self.lsp_sent_ns = now
        for uri in self.lsp.take_updated():
            if uri == self.lsp_uri:
                var latency = -1
                if self.lsp_sent_ns > 0:
                    latency = (now - self.lsp_sent_ns) // 1000000
                    self.lsp_last_latency_ms = latency
                    self.lsp_sent_ns = 0
                self.lsp_show(i, latency)
