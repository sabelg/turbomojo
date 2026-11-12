"""The calm key echo (P7-07): after a command is run from a menu, the command palette
or a click, the status line says which key does it - "Next time: Ctrl-K B" - in the
keymap in use. Nothing takes the keyboard and nothing needs dismissing. Once its key
has been used KEY_ECHO_ENOUGH times the command is not echoed again; the counts are
kept in the state folder (when the real program runs). ui.key_hints = false turns it
off.

Studies of shortcut learning (Grossman et al. 2007; Scarr et al. 2011) found that a
label in the menu is mostly ignored, while naming the key right after a slower
selection made people switch.
"""
from std.collections import List, Dict
from appstate import *
from util import *

comptime KEY_ECHO_ENOUGH = 3


def parse_key_uses(text: String) -> Dict[String, Int]:
    """"<command name> <count>" lines."""
    var out = Dict[String, Int]()
    for l in text.split("\n"):
        var t = String(String(l).strip())
        var sp = t.rfind(" ")
        if sp <= 0:
            continue
        try:
            out[String(t[byte=0:sp])] = atol(String(t[byte=sp + 1:]))
        except:
            pass
    return out^


__extension App:
    def key_used(mut self, cmd: Int):
        """A command was run by its key."""
        var ci = self.reg.index_of(cmd)
        if ci < 0:
            return
        var name = self.reg.cmds[ci].name
        var n = self.key_uses.get(name, 0) + 1
        self.key_uses[name] = n
        if self.key_uses_path.byte_length() > 0 and n <= KEY_ECHO_ENOUGH:
            self.key_uses_save()

    def key_echo(mut self, cmd: Int):
        """A command was run from a menu, the palette or a click: name its key."""
        if not self.key_hints:
            return
        var ci = self.reg.index_of(cmd)
        if ci < 0:
            return
        if self.key_uses.get(self.reg.cmds[ci].name, 0) >= KEY_ECHO_ENOUGH:
            return                              # the key is known by now
        var k = self.reg.key_label(cmd)
        if k.byte_length() == 0 or k == "F10":
            return
        var hint = "Next time: " + k
        if self.status_until > now_ns() and self.status.byte_length() > 0 and self.status.find("Next time:") < 0:
            self.say(self.status + "   (" + hint + ")")      # the command's own message stays
        else:
            self.say(hint)

    def key_uses_load(mut self, path: String):
        self.key_uses_path = path
        self.key_uses = parse_key_uses(read_text(path))

    def key_uses_save(mut self):
        var out = String("")
        for e in self.key_uses.items():
            out += e.key + " " + String(e.value) + "\n"
        _ = write_file(self.key_uses_path, str_bytes(out))
