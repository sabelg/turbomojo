"""Help > Report a problem (P11-08): report.mojo makes the text; this gathers what goes
in it, writes it to problem-report.md in the state folder, copies it to the clipboard
and opens it, so it can be read and changed before it is posted. Nothing is sent."""
from std.collections import List
from appstate import *
from util import *
from version import TURBOMOJO_VERSION, MOJO_BUILT_WITH
from report import report_text, redact_config, home_as_tilde, last_crash_entry, REPORT_ISSUES_URL
from mojover import mojo_version_of
from app_files import *


__extension App:
    def report_compose(mut self) -> String:
        var found = String("")
        if which(self.compiler).byte_length() > 0 or self.compiler.find("/") >= 0:
            found = String(bytes_to_str(run_capture(self.compiler_cmd() + " --version 2>&1 < /dev/null").out).strip())
        if mojo_version_of(found).byte_length() == 0:
            found = ""
        var system = String(bytes_to_str(run_capture("uname -srm 2>/dev/null").out).strip())
        var term = env_or("TERM", "(unset)")
        if env_or("COLORTERM", "").byte_length() > 0:
            term += ", COLORTERM=" + env_or("COLORTERM", "")
        if env_or("TMUX", "").byte_length() > 0:
            term += ", in tmux"
        if env_or("SSH_CONNECTION", "").byte_length() > 0:
            term += ", over SSH"
        var caps = self.caps_lines.copy()
        if len(caps) == 0:
            caps.append("(not asked: no terminal)")
        var crash = last_crash_entry(read_text(self.log_path)) if self.log_path.byte_length() > 0 else String("")
        var config = redact_config(read_text(self.config_path)) if self.config_path.byte_length() > 0 else String("")
        var text = report_text(TURBOMOJO_VERSION, MOJO_BUILT_WITH, found, system, term, caps, crash, config)
        return home_as_tilde(text, env_or("HOME", ""))

    def report_problem(mut self) raises:
        var text = self.report_compose()
        var path = self.report_path
        if path.byte_length() == 0:
            path = state_dir() + "/problem-report.md"
        _ = run_system("mkdir -p " + shell_quote(dirname(path)))
        if not write_file(path, str_bytes(text)):
            self.say("Could not write " + path)
            return
        self.clipboard = decode(text)
        self.osc52(self.clipboard.copy())
        var i = self.find_editor(path)
        if i >= 0:
            self.remove_window(i)           # (an older one: the new text replaces it)
        self.open_path(path)
        self.say("A problem report, copied too - nothing was sent. Read it, then paste it at " + REPORT_ISSUES_URL)
