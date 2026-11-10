"""Detecting changes made to files by other programs.

`file_sig` reads a file's size and modification time with statx(2), whose layout is the
same on every Linux architecture. `Watcher` wraps inotify: it watches the directories of
open files and becomes readable when something in them changes. The watcher is only a
wake-up call; what actually changed is decided by comparing signatures, so the logic also
works by plain periodic checking when inotify is unavailable."""
from std.ffi import external_call
from std.collections import List

comptime IN_FLAGS = 0x80800                 # IN_NONBLOCK | IN_CLOEXEC
comptime IN_MASK = 0x8 | 0x40 | 0x80 | 0x100 | 0x200   # CLOSE_WRITE, MOVED_FROM, MOVED_TO, CREATE, DELETE
comptime STATX_WANT = 0x40 | 0x200          # STATX_MTIME | STATX_SIZE
comptime WATCH_POLL_MS = 2000               # checking interval when inotify is not available


struct FileSig(Copyable, Movable):
    var exists: Bool
    var size: Int
    var mtime_s: Int
    var mtime_ns: Int

    def __init__(out self):
        self.exists = False
        self.size = 0
        self.mtime_s = 0
        self.mtime_ns = 0

    def same(self, other: FileSig) -> Bool:
        if self.exists != other.exists:
            return False
        if not self.exists:
            return True
        return self.size == other.size and self.mtime_s == other.mtime_s and self.mtime_ns == other.mtime_ns


def u64_at(b: List[UInt8], off: Int) -> Int:
    var v = 0
    for i in range(8):
        v |= Int(b[off + i]) << (8 * i)
    return v


def u32_at(b: List[UInt8], off: Int) -> Int:
    var v = 0
    for i in range(4):
        v |= Int(b[off + i]) << (8 * i)
    return v


def file_sig(path: String) -> FileSig:
    """Size and modification time of a file (exists = False if it cannot be examined)."""
    var sig = FileSig()
    if path.byte_length() == 0:
        return sig^
    var p = String(path)
    var buf = List[UInt8](length=256, fill=0)
    # statx(AT_FDCWD, path, flags=0, mask, &buf)
    var r = external_call["statx", Int32](Int32(-100), p.as_c_string_span(), Int32(0), UInt32(STATX_WANT), buf.unsafe_ptr())
    if Int(r) != 0:
        return sig^
    sig.exists = True
    sig.size = u64_at(buf, 40)
    sig.mtime_s = u64_at(buf, 112)
    sig.mtime_ns = u32_at(buf, 120)
    return sig^


struct Watcher(Copyable, Movable):
    var fd: Int
    var dirs: List[String]

    def __init__(out self):
        self.fd = -1
        self.dirs = List[String]()

    def active(self) -> Bool:
        return self.fd >= 0

    def open(mut self) -> Bool:
        if self.fd >= 0:
            return True
        self.fd = Int(external_call["inotify_init1", Int32](Int32(IN_FLAGS)))
        if self.fd < 0:
            self.fd = -1
            return False
        # directories registered before the watcher was opened
        var pending = self.dirs.copy()
        self.dirs.clear()
        for d in pending:
            _ = self.watch_dir(d)
        return True

    def watch_dir(mut self, dir: String) -> Bool:
        """Start watching a directory (once). Remembered even while the watcher is closed."""
        if dir in self.dirs:
            return True
        if self.fd < 0:
            self.dirs.append(dir)
            return False
        var d = String(dir)
        var wd = external_call["inotify_add_watch", Int32](Int32(self.fd), d.as_c_string_span(), UInt32(IN_MASK))
        if Int(wd) < 0:
            return False
        self.dirs.append(dir)
        return True

    def drain(self) -> Bool:
        """Discard queued events. True if there were any."""
        if self.fd < 0:
            return False
        var buf = List[UInt8](length=4096, fill=0)
        var any = False
        while True:
            var n = external_call["read", Int](Int32(self.fd), buf.unsafe_ptr(), Int(4096))
            if n <= 0:
                break
            any = True
        return any

    def close(mut self):
        if self.fd >= 0:
            _ = external_call["close", Int32](Int32(self.fd))
            self.fd = -1
            self.dirs.clear()
