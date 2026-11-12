"""The response-time ladder (Nielsen's limits: 0.1 s feels instant, 1 s keeps the flow
of thought, 10 s keeps attention): work that ends within a second shows nothing - a
spinner that flashes on and off is noise; from one second a spinner and the time on
the status line; beyond ten seconds what has been done so far and the key that stops
it, in a box that never takes the keyboard.

The App's side is src/app_progress.mojo; this module is the arithmetic, testable
without one.
"""
from std.collections import List
from util import bytes_to_str

comptime QUIET_MS = 1000         # under a second: nothing
comptime BOX_MS = 10000          # beyond ten: what is done so far, and the cancel key

comptime PS_QUIET = 0
comptime PS_SPINNER = 1
comptime PS_BOX = 2


def progress_stage(elapsed_ms: Int) -> Int:
    if elapsed_ms < QUIET_MS:
        return PS_QUIET
    if elapsed_ms < BOX_MS:
        return PS_SPINNER
    return PS_BOX


def elapsed_text(elapsed_ms: Int) -> String:
    """"3.2 s" under a minute, then "1 min 05 s"."""
    var ms = max(0, elapsed_ms)
    if ms < 60000:
        return String(ms // 1000) + "." + String((ms // 100) % 10) + " s"
    var s = ms // 1000
    var sec = s % 60
    return String(s // 60) + " min " + ("0" if sec < 10 else "") + String(sec) + " s"


def output_lines(data: List[UInt8]) -> Int:
    """Lines of output so far (a last line without its newline counts)."""
    var n = 0
    for b in data:
        if b == 10:
            n += 1
    if len(data) > 0 and data[len(data) - 1] != 10:
        n += 1
    return n


def last_output_line(data: List[UInt8]) -> String:
    """The last line with something on it, without escape codes or carriage-return
    overwrites (a progress bar redrawing itself shows its latest state)."""
    var end = len(data)
    while end > 0:
        var start = end
        while start > 0 and data[start - 1] != 10:
            start -= 1
        # within a line, what follows the last \r is what the terminal shows
        var s = start
        for k in range(start, end):
            if data[k] == 13 and k + 1 < end:
                s = k + 1
        var out = List[UInt8]()
        var k = s
        while k < end:
            var b = data[k]
            if b == 27:
                # skip an escape sequence: ESC [ ... final byte, or ESC and one byte
                k += 1
                if k < end and data[k] == 91:
                    k += 1
                    while k < end and (data[k] < 64 or data[k] > 126):
                        k += 1
                k += 1
                continue
            if b >= 32 or b == 9:
                out.append(b)
            k += 1
        var line = bytes_to_str(out).strip()
        if line.byte_length() > 0:
            return String(line)
        end = start - 1 if start > 0 else 0
    return ""
