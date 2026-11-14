"""Codegen & kernel inspector (`Compile > Inspect generated code`, WK_CODEGEN) and GPU
kernel profiler (`Compile > Profile GPU kernels`): emits assembly or LLVM IR asynchronously
via `aux_job` (`mojo build --emit=asm|llvm`) and wraps `nsys` / `rocprofv3` profiling."""
from std.collections import List
from appstate import *
from window import Window, WK_CODEGEN, RM_NONE, RM_OK, RM_WARN, RM_DIM
from term import KEY_ESC
from signals import own_pid
from util import *
from codegen import CG_ASM, CG_LLVM, analyze_codegen, format_codegen_header
from app_jobs import *
from app_outline import *
from app_layout import *


__extension App:
    def codegen_index(self) -> Int:
        for i in range(len(self.wins)):
            if self.wins[i].kind == WK_CODEGEN:
                return i
        return -1

    def codegen_render_lines(mut self, lines: List[String], reset_pos: Bool = False):
        var ci = self.codegen_index()
        if ci < 0:
            return
        var text = List[Int]()
        var marks = List[Int]()
        for k in range(len(lines)):
            if k > 0:
                text.append(10)
            for cp in decode(lines[k]):
                text.append(cp)
            if lines[k].startswith("  [SPILL]"):
                marks.append(RM_WARN)
            elif lines[k].startswith("  [SIMD]"):
                marks.append(RM_OK)
            elif k < 2:
                marks.append(RM_DIM)
            else:
                marks.append(RM_NONE)
        var keep_cr = 0 if reset_pos else self.wins[ci].cr
        var keep_top = 0 if reset_pos else self.wins[ci].top
        self.wins[ci].buf.load(text)
        self.wins[ci].row_marks = marks^
        self.wins[ci].buf.modified = False
        self.wins[ci].cr = max(0, min(keep_cr, self.wins[ci].buf.count() - 1))
        self.wins[ci].top = max(0, min(keep_top, self.wins[ci].buf.count() - 1))

    def codegen_open(mut self) raises:
        """Open (or toggle/refresh) the Codegen Inspector side pane for the active editor."""
        var ci = self.codegen_index()
        var ti = self.top_editor()
        if ci >= 0 and self.top() == ci:
            _ = self.wins.pop(ci)
            self.layout_sync()
            return
        if ti < 0:
            self.info("Inspect Generated Code", "Open a Mojo file first.")
            return
        if not self.ensure_saved(ti):
            return
        var path = String(self.wins[ti].path)
        self.codegen_path = path
        if ci < 0:
            var dh = self.desk_h()
            var mi = self.msg_index()
            if mi >= 0:
                dh = max(8, self.wins[mi].y - 1)
            var w = min(68, max(42, self.scr.w // 2))
            var x = max(0, self.scr.w - w)
            var win = Window(WK_CODEGEN, "Codegen: " + basename(path), "", x, 1, w, dh, self.free_number())
            self.wins.append(win^)
            self.layout_sync()
        else:
            self.wins[ci].title = "Codegen: " + basename(path)
            self.focus(ci)
        self.codegen_refresh()

    def codegen_refresh(mut self) raises:
        if self.codegen_path.byte_length() == 0:
            var ti = self.top_editor()
            if ti < 0 or not self.ensure_saved(ti):
                return
            self.codegen_path = String(self.wins[ti].path)
        if self.aux_job.active:
            self.say("Background format/codegen job is already running")
            return
        var path = self.codegen_path
        var emit_kind = "asm" if self.codegen_mode == CG_ASM else "llvm"
        var ext = ".s" if self.codegen_mode == CG_ASM else ".ll"
        var out_file = env_or("TMPDIR", "/tmp") + "/turbomojo-codegen-" + String(own_pid()) + ext
        self.codegen_out_file = out_file
        var dir = dirname(path)
        var inner = "cd " + shell_quote(dir) + " && exec " + self.mojo_for(path) + " build --emit=" + emit_kind + self.include_flags() + " " + shell_quote(path) + " -o " + shell_quote(out_file)
        var cmd = self.with_env(path, inner) + " 2>&1"
        var loading = List[String]()
        loading.append("Codegen Inspector: " + basename(path))
        loading.append("Emitting " + emit_kind + " with mojo build --emit=" + emit_kind + " ...")
        self.codegen_render_lines(loading, True)
        if self.start_aux_job(JOB_CODEGEN, cmd, path, out_file):
            self.say("Emitting " + emit_kind + " for " + basename(path) + "...")

    def finish_codegen(mut self, status: Int):
        var out_file = self.codegen_out_file
        var path = self.codegen_path
        if self.aux_job.cancelled:
            if out_file.byte_length() > 0:
                delete_file(out_file)
            self.say("Codegen cancelled")
            return
        if status != 0 or not path_exists(out_file):
            var err_txt = bytes_to_str(self.aux_job.data)
            var lines = List[String]()
            lines.append("Codegen failed for " + basename(path) + ":")
            lines.append("")
            for l in err_txt.split("\n"):
                lines.append(String(l))
            self.codegen_render_lines(lines, True)
            if out_file.byte_length() > 0:
                delete_file(out_file)
            self.say("Codegen failed - see Codegen pane")
            return
        var raw = read_text(out_file)
        delete_file(out_file)
        var filt = self.codegen_filter
        var summary = analyze_codegen(raw, self.codegen_mode, filt)
        var rendered = format_codegen_header(basename(path), self.codegen_mode, summary, filt)
        self.codegen_render_lines(rendered, True)
        self.say("Codegen ready: " + String(summary.simd_ops) + " SIMD ops, " + String(summary.spill_ops) + " spills")

    def codegen_key(mut self, k: Int) raises -> Bool:
        if k == 97 or k == 65:          # a / A -> ASM
            if self.codegen_mode != CG_ASM:
                self.codegen_mode = CG_ASM
                self.codegen_refresh()
            return True
        if k == 108 or k == 76:         # l / L -> LLVM IR
            if self.codegen_mode != CG_LLVM:
                self.codegen_mode = CG_LLVM
                self.codegen_refresh()
            return True
        if k == 114 or k == 82:         # r / R -> refresh
            self.codegen_refresh()
            return True
        if k == KEY_ESC:
            var ci = self.codegen_index()
            if ci >= 0:
                _ = self.wins.pop(ci)
                self.layout_sync()
            return True
        return False

    def gpu_profile_command(mut self) raises:
        """Compile > Profile GPU kernels: wrap `nsys profile --stats=true` (NVIDIA) or
        `rocprofv3 --kernel-trace --stats` (AMD) on the active Mojo file into the Message pane."""
        if self.job_busy():
            return
        var i = self.top_editor()
        if i < 0:
            self.info("Profile GPU Kernels", "Open a Mojo file first.")
            return
        if not self.ensure_saved(i):
            return
        var path = String(self.wins[i].path)
        var nsys = which("nsys")
        var rocprof = which("rocprofv3")
        if rocprof.byte_length() == 0:
            rocprof = which("rocprof")
        if nsys.byte_length() == 0 and rocprof.byte_length() == 0:
            self.info("Profile GPU Kernels", "Neither `nsys` (NVIDIA Nsight Systems) nor `rocprofv3` (AMD ROCm) was found on PATH.")
            return
        var dir = dirname(path)
        var exe = join_path(dir, "build/" + stem(path))
        var prof_out = env_or("TMPDIR", "/tmp") + "/turbomojo-prof-" + String(own_pid())
        var prof_cmd: String
        var tool_name: String
        if nsys.byte_length() > 0:
            tool_name = "nsys"
            prof_cmd = shell_quote(nsys) + " profile --stats=true --force-overwrite=true -o " + shell_quote(prof_out) + " " + shell_quote(exe) + "; st=$?; rm -f " + shell_quote(prof_out) + "* 2>/dev/null; exit $st"
        else:
            tool_name = basename(rocprof)
            if tool_name == "rocprofv3":
                prof_cmd = shell_quote(rocprof) + " --kernel-trace --stats -- " + shell_quote(exe)
            else:
                prof_cmd = shell_quote(rocprof) + " --stats " + shell_quote(exe)
        var inner = "cd " + shell_quote(dir) + " && mkdir -p build && " + self.mojo_for(path) + " build" + self.include_flags() + " " + shell_quote(path) + " -o " + shell_quote(exe) + " && " + prof_cmd
        var cmd = self.with_env(path, inner) + " 2>&1 </dev/null"
        if self.start_job(JOB_TASK, cmd, dir, "profile:" + tool_name):
            self.task_output("Building & profiling GPU kernels with " + tool_name + "...")
            self.say("Profiling " + basename(path) + " with " + tool_name + " - Ctrl-F2 cancels")
