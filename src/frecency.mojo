"""Which files were opened how often and how recently ("frecency"), to rank the files in
the quick-open palette. Kept as a small text file: one line "count last-time path" per
file, most recently opened first."""
from std.collections import List
from util import decode, to_str

comptime FREC_MAX = 500


def frec_weight(age_s: Int) -> Int:
    """How much an opening counts by how long ago the last one was."""
    if age_s < 4 * 3600:
        return 100
    if age_s < 24 * 3600:
        return 70
    if age_s < 7 * 24 * 3600:
        return 50
    if age_s < 30 * 24 * 3600:
        return 30
    return 10


struct Frecency(Copyable, Movable):
    var paths: List[String]
    var counts: List[Int]
    var last: List[Int]         # seconds since 1970

    def __init__(out self):
        self.paths = List[String]()
        self.counts = List[Int]()
        self.last = List[Int]()

    def find(self, path: String) -> Int:
        for k in range(len(self.paths)):
            if self.paths[k] == path:
                return k
        return -1

    def note(mut self, path: String, now_s: Int):
        """A file was opened."""
        var k = self.find(path)
        var count = 1
        if k >= 0:
            count = self.counts[k] + 1
            _ = self.paths.pop(k)
            _ = self.counts.pop(k)
            _ = self.last.pop(k)
        self.paths.insert(0, path)
        self.counts.insert(0, count)
        self.last.insert(0, now_s)
        while len(self.paths) > FREC_MAX:
            _ = self.paths.pop()
            _ = self.counts.pop()
            _ = self.last.pop()

    def forget(mut self, path: String):
        var k = self.find(path)
        if k >= 0:
            _ = self.paths.pop(k)
            _ = self.counts.pop(k)
            _ = self.last.pop(k)

    def score(self, path: String, now_s: Int) -> Int:
        """0 for a file never opened; up to 1000 for one opened often and just now."""
        var k = self.find(path)
        if k < 0:
            return 0
        return min(self.counts[k], 10) * frec_weight(max(0, now_s - self.last[k]))

    def encode(self) -> String:
        var s = String("")
        for k in range(len(self.paths)):
            s += String(self.counts[k]) + " " + String(self.last[k]) + " " + self.paths[k] + "\n"
        return s

    def decode_text(mut self, text: String, paths: Bool = True):
        """Read what encode() wrote; lines that do not fit are skipped (with `paths`,
        those whose key is not an absolute path - False for other keys, such as the
        command names of the palette's recent commands)."""
        self.paths.clear()
        self.counts.clear()
        self.last.clear()
        for raw in text.split("\n"):
            var line = String(raw)
            var a = line.find(" ")
            if a <= 0:
                continue
            var rest = String(line[byte=a + 1:])
            var b = rest.find(" ")
            if b <= 0 or b + 1 >= rest.byte_length():
                continue
            try:
                var count = atol(String(line[byte=0:a]))
                var when = atol(String(rest[byte=0:b]))
                var path = String(rest[byte=b + 1:])
                if count > 0 and when >= 0 and (path.startswith("/") or not paths) and String(path.strip()).byte_length() > 0 and self.find(path) < 0 and len(self.paths) < FREC_MAX:
                    self.paths.append(path)
                    self.counts.append(count)
                    self.last.append(when)
            except:
                continue
