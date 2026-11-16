"""Detecting changes made to files by other programs.

`file_sig` reads a file's size and modification time with statx(2), whose layout is the
same on every Linux architecture. `Watcher` wraps inotify: it watches the directories of
open files and becomes readable when something in them changes. The watcher is only a
wake-up call; what actually changed is decided by comparing signatures, so the logic also
works by plain periodic checking when inotify is unavailable."""
from platform import stat_size_mtime, HAVE_INOTIFY, IS_MACOS
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
    var st = stat_size_mtime(path)          # (statx on Linux, stat on macOS: platform.mojo)
    if not st[0]:
        return sig^
    sig.exists = True
    sig.size = st[1]
    sig.mtime_s = st[2]
    sig.mtime_ns = st[3]
    return sig^


struct Watcher(Copyable, Movable):
    var fd: Int
    var dirs: List[String]
    var dir_fds: List[Int32]

    def __init__(out self):
        self.fd = -1
        self.dirs = List[String]()
        self.dir_fds = List[Int32]()

    def active(self) -> Bool:
        return self.fd >= 0

    def open(mut self) -> Bool:
        if self.fd >= 0:
            return True
        comptime if IS_MACOS:
            self.fd = Int(external_call["kqueue", Int32]())
            if self.fd < 0:
                self.fd = -1
                return False
            _ = external_call["fcntl", Int32](Int32(self.fd), Int32(2), Int32(1)) # F_SETFD, FD_CLOEXEC
            var pending = self.dirs.copy()
            self.dirs.clear()
            for d in pending:
                _ = self.watch_dir(d)
            return True
        else:
            comptime if not HAVE_INOTIFY:
                return False                    # (files are then checked by size and time now and then)
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
        comptime if IS_MACOS:
            var dfd = external_call["openat", Int32](Int32(-2), d.as_c_string_span(), Int32(0x8000), Int32(0)) # AT_FDCWD=-2, O_EVTONLY on Darwin
            if Int(dfd) < 0:
                return False
            _ = external_call["fcntl", Int32](dfd, Int32(2), Int32(1)) # F_SETFD, FD_CLOEXEC
            var ev = List[UInt8](length=32, fill=0)
            # ident = dfd (8 bytes @ 0)
            for i in range(4):
                ev[i] = UInt8((Int(dfd) >> (8 * i)) & 0xFF)
            # filter = EVFILT_VNODE (-4 as int16 = 0xfffc @ 8)
            ev[8] = 0xFC
            ev[9] = 0xFF
            # flags = EV_ADD (0x1) | EV_ENABLE (0x4) | EV_CLEAR (0x20) = 0x25 @ 10
            ev[10] = 0x25
            # fflags = NOTE_WRITE | NOTE_DELETE | NOTE_EXTEND | NOTE_ATTRIB | NOTE_RENAME = 0x2F @ 12
            ev[12] = 0x2F
            var out_ev = List[UInt8](length=32, fill=0)
            var ts = List[UInt8](length=16, fill=0)
            var res = external_call["kevent", Int32](Int32(self.fd), ev.unsafe_ptr(), Int32(1), out_ev.unsafe_ptr(), Int32(0), ts.unsafe_ptr())
            if Int(res) < 0:
                _ = external_call["close", Int32](dfd)
                return False
            self.dir_fds.append(dfd)
            self.dirs.append(dir)
            return True
        else:
            comptime if not HAVE_INOTIFY:
                return False
            var wd = external_call["inotify_add_watch", Int32](Int32(self.fd), d.as_c_string_span(), UInt32(IN_MASK))
            if Int(wd) < 0:
                return False
            self.dirs.append(dir)
            return True

    def drain(self) -> Bool:
        """Discard queued events. True if there were any."""
        if self.fd < 0:
            return False
        comptime if IS_MACOS:
            var chg = List[UInt8](length=32, fill=0)
            var ev = List[UInt8](length=32 * 16, fill=0)
            var ts = List[UInt8](length=16, fill=0) # zero timeout
            var n = external_call["kevent", Int32](Int32(self.fd), chg.unsafe_ptr(), Int32(0), ev.unsafe_ptr(), Int32(16), ts.unsafe_ptr())
            return Int(n) > 0
        else:
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
            comptime if IS_MACOS:
                for dfd in self.dir_fds:
                    _ = external_call["close", Int32](dfd)
                self.dir_fds.clear()
            _ = external_call["close", Int32](Int32(self.fd))
            self.fd = -1
            self.dirs.clear()
