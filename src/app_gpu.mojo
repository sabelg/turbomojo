"""The GPU on the status line (P11-10a): with `ui.gpu_status` on (Options > GPU in the
status line), GPU_QUERY runs once in the background through a non-blocking pipe - the
main loop waits on it with the other descriptors - and its answer becomes a status item
such as "GPU GB10". Nothing runs while the setting is off."""
from std.collections import List
from std.ffi import external_call
from platform import make_nonblocking
from appstate import *
from util import *
from gpuinfo import GPU_QUERY, parse_gpus, gpu_short


__extension App:
    def gpu_start(mut self):
        """Ask once (again only after the setting is switched off and on)."""
        if self.gpu_asked or not self.gpu_status_on or self.gpu_fd >= 0:
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
        return out^

    def gpu_tick(mut self):
        if self.gpu_fd < 0:
            return
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
        if not eof:
            return
        _ = external_call["pclose", Int32](self.gpu_fp)
        self.gpu_fd = -1
        self.gpu_fp = 0
        self.gpu_item = gpu_short(parse_gpus(bytes_to_str(self.gpu_out)))

    def gpu_status_text(self) -> String:
        """The status item ("" when off, not known yet, or there is no GPU)."""
        if not self.gpu_status_on or self.gpu_item.byte_length() == 0:
            return ""
        return self.gpu_item + "  "
