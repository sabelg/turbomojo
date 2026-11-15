"""The GPU on the status line (P11-10a) and the live GPU telemetry monitor (`Window > GPU
queue & monitor`, WK_GPU). With `ui.gpu_status` on, GPU_QUERY runs once in the background
through a non-blocking pipe; while WK_GPU is open, GPU_TELEMETRY_QUERY polls every 1.5 s
asynchronously and renders compute/VRAM bars, sparklines, sensors, and active PIDs."""
from std.collections import List
from std.ffi import external_call
from platform import make_nonblocking
from appstate import *
from app_layout import *
from window import Window, WK_GPU, RM_NONE, RM_OK, RM_DIM
from term import KEY_ESC
from util import *
from gpuinfo import (
    GPU_QUERY, GPU_TELEMETRY_QUERY, GpuSample, parse_gpus, gpu_short,
    parse_gpu_samples, format_gpu_monitor,
)


comptime GPU_MON_INTERVAL_NS = 1500000000       # 1.5 s while WK_GPU is open


__extension App:
    def gpu_start(mut self, wanted: Bool = False):
        """Ask once (again only after the setting is switched off and on): for the
        status line, or `wanted` for a run that uses the GPU (P11-10b)."""
        if self.gpu_asked or not (self.gpu_status_on or wanted) or self.gpu_fd >= 0:
            return
        self.gpu_asked = True
        var fp = popen_read("(" + self.gpu_query + ") 2>/dev/null </dev/null")
        if fp == 0:
            return
        self.gpu_fp = fp
        self.gpu_fd = Int(external_call["fileno", Int32](fp))
        make_nonblocking(self.gpu_fd)
        self.gpu_out.clear()

    def gpu_fds(self) -> List[Int]:
        var out = List[Int]()
        if self.gpu_fd >= 0:
            out.append(self.gpu_fd)
        if self.gpu_mon_fd >= 0:
            out.append(self.gpu_mon_fd)
        return out^

    def gpu_tick(mut self):
        if self.gpu_fd >= 0:
            var buf = List[UInt8](length=4096, fill=0)
            var eof = False
            for _ in range(16):
                var n = external_call["read", Int](Int32(self.gpu_fd), buf.unsafe_ptr(), Int(4096))
                if n > 0:
                    for k in range(n):
                        self.gpu_out.append(buf[k])
                else:
                    eof = n == 0
                    break
            if eof:
                _ = external_call["pclose", Int32](self.gpu_fp)
                self.gpu_fd = -1
                self.gpu_fp = 0
                self.gpu_item = gpu_short(parse_gpus(bytes_to_str(self.gpu_out)))
        self.gpu_mon_tick(now_ns())

    def gpu_known(self) -> Bool:
        return self.gpu_asked and self.gpu_fd < 0

    def gpu_status_text(self) -> String:
        """The status item ("" when off, not known yet, or there is no GPU)."""
        if not self.gpu_status_on or self.gpu_item.byte_length() == 0:
            return ""
        return self.gpu_item + "  "

    # ======================================================= live GPU monitor (WK_GPU)
    def gpuwin_index(self) -> Int:
        for i in range(len(self.wins)):
            if self.wins[i].kind == WK_GPU:
                return i
        return -1

    def gpu_probe_stop(mut self):
        if self.gpu_fd >= 0:
            _ = external_call["pclose", Int32](self.gpu_fp)
            self.gpu_fd = -1
            self.gpu_fp = 0
            self.gpu_out.clear()

    def gpu_mon_stop(mut self):
        if self.gpu_mon_fd >= 0:
            _ = external_call["pclose", Int32](self.gpu_mon_fp)
            self.gpu_mon_fd = -1
            self.gpu_mon_fp = 0
            self.gpu_mon_out.clear()

    def gpu_mon_poll_start(mut self):
        if self.gpu_mon_fd >= 0:
            return
        var fp = popen_read("(" + self.gpu_mon_query + ") 2>/dev/null </dev/null")
        if fp == 0:
            return
        self.gpu_mon_fp = fp
        self.gpu_mon_fd = Int(external_call["fileno", Int32](fp))
        make_nonblocking(self.gpu_mon_fd)
        self.gpu_mon_out.clear()
        self.gpu_mon_last_ns = now_ns()

    def gpu_mon_tick(mut self, now: Int):
        var gi = self.gpuwin_index()
        if gi < 0:
            self.gpu_mon_stop()
            return
        if self.gpu_mon_fd >= 0:
            var buf = List[UInt8](length=4096, fill=0)
            var eof = False
            for _ in range(16):
                var n = external_call["read", Int](Int32(self.gpu_mon_fd), buf.unsafe_ptr(), Int(4096))
                if n > 0:
                    for k in range(n):
                        self.gpu_mon_out.append(buf[k])
                else:
                    eof = n == 0
                    break
            if not eof:
                return
            _ = external_call["pclose", Int32](self.gpu_mon_fp)
            self.gpu_mon_fd = -1
            self.gpu_mon_fp = 0
            var parsed = parse_gpu_samples(bytes_to_str(self.gpu_mon_out))
            while len(self.gpu_mon_hist) < len(parsed[0]):
                self.gpu_mon_hist.append(List[Int]())
            for i in range(len(parsed[0])):
                self.gpu_mon_hist[i].append(parsed[0][i].util_pct)
                if len(self.gpu_mon_hist[i]) > 20:
                    _ = self.gpu_mon_hist[i].pop(0)
            self.gpuwin_render(format_gpu_monitor(parsed[0], parsed[1], self.gpu_mon_hist))
            return
        if now - self.gpu_mon_last_ns >= GPU_MON_INTERVAL_NS:
            self.gpu_mon_poll_start()

    def gpuwin_render(mut self, lines: List[String]):
        var gi = self.gpuwin_index()
        if gi < 0:
            return
        var text = List[Int]()
        var marks = List[Int]()
        for k in range(len(lines)):
            if k > 0:
                text.append(10)
            for cp in decode(lines[k]):
                text.append(cp)
            if lines[k].startswith("GPU ") and not lines[k].startswith("GPU Telemetry"):
                marks.append(RM_OK)
            elif k == 0 or lines[k].startswith("Active Compute Processes"):
                marks.append(RM_DIM)
            else:
                marks.append(RM_NONE)
        var keep_cr = self.wins[gi].cr
        var keep_top = self.wins[gi].top
        self.wins[gi].buf.load(text)
        self.wins[gi].row_marks = marks^
        self.wins[gi].buf.modified = False
        self.wins[gi].cr = max(0, min(keep_cr, self.wins[gi].buf.count() - 1))
        self.wins[gi].top = max(0, min(keep_top, self.wins[gi].buf.count() - 1))

    def gpuwin_toggle(mut self):
        var gi = self.gpuwin_index()
        if gi >= 0:
            self.gpu_mon_stop()
            _ = self.wins.pop(gi)
            self.layout_sync()
            return
        var dh = self.desk_h()
        var mi = self.msg_index()
        if mi >= 0:
            dh = max(8, self.wins[mi].y - 1)
        var w = min(56, max(38, self.scr.w * 2 // 5))
        var x = max(0, self.scr.w - w)
        var win = Window(WK_GPU, "GPU Monitor", "", x, 1, w, dh, self.free_number())
        self.wins.append(win^)
        var init_lines = List[String]()
        init_lines.append("GPU Telemetry   (r: refresh now, Esc: close)")
        init_lines.append("")
        init_lines.append("  Querying GPU telemetry...")
        self.gpuwin_render(init_lines)
        self.layout_sync()
        self.gpu_mon_poll_start()

    def gpuwin_key(mut self, k: Int) -> Bool:
        if k == 114 or k == 82:     # r / R: immediate refresh
            self.gpu_mon_stop()
            self.gpu_mon_poll_start()
            self.say("Refreshing GPU telemetry...")
            return True
        if k == KEY_ESC:
            var gi = self.gpuwin_index()
            if gi >= 0:
                self.gpu_mon_stop()
                _ = self.wins.pop(gi)
                self.layout_sync()
            return True
        return False
