"""The response-time ladder on screen (src/progress.mojo has the stages): a build,
format, task, test run or documentation download, and an agent's turn, show nothing
for their first second, then a spinner and the time on the status line, and beyond
ten seconds what has been done so far and the key that stops it - for a job in the
Compiling box at the bottom right, which is drawn over the desktop but never takes the
keyboard (typing goes on in the editor); for the agent on the status line (its panel
shows the steps themselves).
"""
from std.collections import List
from appstate import *
from util import *
from progress import *
from commands import CM_CANCEL
from app_jobs import *


__extension App:
    def job_ms(self) -> Int:
        return (now_ns() - self.job.t0) // 1000000

    def job_stage(self) -> Int:
        if not self.job.active:
            return PS_QUIET
        return progress_stage(self.job_ms())

    def agent_turn_ms(self) -> Int:
        return (now_ns() - self.agent.prompt_ns) // 1000000

    def agent_stage(self) -> Int:
        if not self.agent.busy() or self.agent.prompt_ns == 0:
            return PS_QUIET
        return progress_stage(self.agent_turn_ms())

    def spinner_char(self) -> String:
        var sp = decode(SPINNER)
        var b = List[UInt8]()
        encode_cp(sp[0] if self.reduce_motion else sp[(now_ns() // (SPINNER_MS * 1000000)) % len(sp)], b)
        return bytes_to_str(b)

    def job_what(self) -> Tuple[String, String, String]:
        """(status word, the box's title, its subject)."""
        if self.job.kind == JOB_TASK:
            return ("Task ", "Running a task", self.job.exe)
        if self.job.kind == JOB_DOCS:
            return ("Downloading ", "Downloading", "documentation")
        if self.job.kind == JOB_TESTS:
            return ("", "Running tests", self.job.exe)
        if self.job.kind == JOB_FORMAT:
            return ("Formatting ", "Formatting", basename(self.job.path))
        if self.job.kind == JOB_DEBUG:
            return ("Building ", "Compiling for the debugger", basename(self.job.path))
        return ("Building ", "Compiling", basename(self.job.path))

    def progress_status(self) -> String:
        """What the status line says about work in progress ('' in its first second)."""
        var out = String("")
        if self.job_stage() >= PS_SPINNER:
            var w = self.job_what()
            out += self.spinner_char() + " " + w[0] + w[2] + " " + elapsed_text(self.job_ms()) + "  " + self.reg.key_label(CM_CANCEL) + " cancels  "
        var a = self.agent_stage()
        if a >= PS_SPINNER:
            out += (self.spinner_char() + " " if not self.job.active else String("")) + "Agent " + elapsed_text(self.agent_turn_ms())
            if a >= PS_BOX:
                var n = self.chat.turn_steps()
                out += ", " + String(n) + (" step" if n == 1 else " steps") + ", Esc in its panel stops"
            out += "  "
        return out

    def draw_progress_box(mut self):
        """Beyond ten seconds: the Compiling box, at the bottom right - what it works on,
        the time, the output so far and its last line, and the key that stops it."""
        if self.job_stage() < PS_BOX or self.reader:
            return
        var w = min(54, self.scr.w - 4)
        var h = 7                                   # five lines and the frame
        if w < 30 or self.scr.h < h + 4:
            return
        var p = self.pal.copy()
        var x = self.scr.w - w - 2
        var y = self.scr.h - 1 - h - 1
        var what = self.job_what()
        var lines = List[String]()
        lines.append((("Main file:  ") if self.job.kind == JOB_BUILD or self.job.kind == JOB_DEBUG or self.job.kind == JOB_FORMAT else String("Running:    ")) + what[2])
        lines.append("Elapsed:    " + elapsed_text(self.job_ms()))
        var n = output_lines(self.job.data)
        lines.append("Output:     " + String(n) + (" line" if n == 1 else " lines"))
        lines.append(last_output_line(self.job.data))
        lines.append(self.reg.key_label(CM_CANCEL) + " cancels - keep typing meanwhile")
        self.scr.fill(x, y, w, h, 32, p.dlg_fg, p.dlg_bg)
        self.scr.frame(x, y, w, h, False, p.dlg_frame, p.dlg_bg)
        var title = " " + what[1] + " "
        _ = self.scr.text(x + (w - cp_len(title)) // 2, y, title, p.dlg_title, p.dlg_bg)
        for r in range(len(lines)):
            self.scr.clip(x + 2, y + 1 + r, w - 4, 1)
            var fg = p.doc_dim if r == 3 else (p.dlg_hot if r == 4 else p.dlg_fg)
            _ = self.scr.text(x + 2, y + 1 + r, lines[r], fg, p.dlg_bg)
            self.scr.no_clip()
        self.scr.shadow(x, y, w, h, p.shadow_fg, p.shadow_bg)
