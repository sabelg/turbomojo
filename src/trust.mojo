"""Which project folders the user has said they trust. Things that run commands or code
from a folder (builds, runs, tasks, the language server, tool commands set by the
project's own settings file) wait for that."""
from std.collections import List


struct TrustStore(Copyable, Movable):
    var roots: List[String]

    def __init__(out self):
        self.roots = List[String]()

    def is_trusted(self, folder: String) -> Bool:
        """A folder is trusted if it, or a folder above it, was trusted."""
        if folder.byte_length() == 0:
            return False
        for r in self.roots:
            if folder == r or folder.startswith(r + "/") or r == "/":
                return True
        return False

    def add(mut self, folder: String):
        if folder.startswith("/") and not (folder in self.roots):
            self.roots.append(folder)

    def remove(mut self, folder: String) -> Bool:
        """Take back the trust given to exactly this folder. False if it was not given
        to this folder itself (it may still be trusted through a folder above it)."""
        for k in range(len(self.roots)):
            if self.roots[k] == folder:
                _ = self.roots.pop(k)
                return True
        return False

    def encode(self) -> String:
        var s = String("")
        for r in self.roots:
            s += r + "\n"
        return s

    def decode_text(mut self, text: String):
        """One folder per line; anything that is not an absolute path is passed over."""
        self.roots.clear()
        for raw in text.split("\n"):
            var line = String(raw)
            if not line.startswith("/"):
                continue
            var n = line.byte_length()
            while n > 1 and String(line[byte=n - 1:n]) == "/":
                n -= 1
            var folder = String(line[byte=0:n])
            if not (folder in self.roots):
                self.roots.append(folder)
