#!/usr/bin/env python3
"""Soak test: TurboMojo edits for a long time in a tmux pane, and its memory is watched.

One cycle: open soak.mojo through the palette (Alt-G), type and move, undo and redo,
find, open the palette and a menu and close them, now and then resize the terminal,
save and close the window. Closing frees the text and its undo history, so after the
first cycles the memory should stay level. Every cycle the IDE's resident memory
(VmRSS) is sampled; at the end the average of the last third is compared with the
first third after the warm-up. The run fails if the IDE ends, its screen stops
showing the editor, the crash log gets an entry, or the memory grows more than the
allowance.

The IDE runs on a tmux server of its own with configuration and state folders of its
own (nothing of the user's is read or written).

Usage: soak.py <tmide> [minutes] (default 10)
"""
import os, random, shutil, subprocess, sys, tempfile, time

TMIDE = sys.argv[1]
MINUTES = float(sys.argv[2]) if len(sys.argv) > 2 else 10.0
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
# outside the repository: inside it, the IDE would take the repository as its project
HOME = tempfile.mkdtemp(prefix="turbomojo-soak-")
WORK = os.path.join(HOME, "work")
GROWTH_ALLOWED = 0.15          # the last third may be this much above the first ...
GROWTH_SLACK_KB = 8 * 1024     # ... plus this much (allocator noise)


def tmux(*a):
    return subprocess.run(["tmux", "-L", "tmsoak", *a], capture_output=True, text=True).stdout


recent = []                     # the last actions, for a failure report


def keys(*k):
    recent.append(" ".join(k))
    del recent[:-25]
    subprocess.run(["tmux", "-L", "tmsoak", "send-keys", "-t", "s", *k])
    if "Escape" in k:
        # a terminal sends Alt-X as Esc and x: a key typed within 25 ms of Esc would be
        # read as Alt and that key (as a person never types it), so wait a little
        time.sleep(0.1)


def text(s):
    recent.append("type " + s)
    del recent[:-25]
    subprocess.run(["tmux", "-L", "tmsoak", "send-keys", "-t", "s", "-l", s])


def screen():
    return tmux("capture-pane", "-p", "-t", "s")


def wait_for(what, limit=10):
    t0 = time.time()
    while what not in screen():
        if time.time() - t0 > limit:
            return False
        time.sleep(0.05)
    return True


def rss_kb(pid):
    for line in open("/proc/%d/status" % pid):
        if line.startswith("VmRSS:"):
            return int(line.split()[1])
    return 0


def main():
    for d in ("config", "state", "cache", "work"):
        os.makedirs(os.path.join(HOME, d))
    original = '"""Soak test file."""\n\n\ndef main():\n    var total = 0\n    for i in range(10):\n        total += i\n    print(total)\n'
    env = "env XDG_CONFIG_HOME=%s/config XDG_STATE_HOME=%s/state XDG_CACHE_HOME=%s/cache " % (HOME, HOME, HOME)
    tmux("kill-server")
    time.sleep(0.3)
    subprocess.run(["tmux", "-L", "tmsoak", "new-session", "-d", "-s", "s", "-x", "120", "-y", "40", "-c", WORK, env + TMIDE])
    if not wait_for("File", 20):
        tmux("kill-server")
        sys.exit("soak: the IDE did not start:\n" + screen())
    pid = int(tmux("display", "-p", "-t", "s", "#{pane_pid}").strip())
    rng = random.Random(20261112)
    samples = []
    t_end = time.time() + MINUTES * 60
    cycle = 0
    while time.time() < t_end:
        cycle += 1
        # the same file every cycle (a growing file would grow the memory with it; and as
        # another program changed it, its saved undo history is not taken up again)
        with open(os.path.join(WORK, "soak.mojo"), "w") as f:
            f.write(original)
        # open it through the palette
        keys("M-g")
        time.sleep(0.15)
        text("soak.mojo")
        time.sleep(0.15)
        keys("Enter")
        if not wait_for("═ soak.mojo ═", 10):
            sys.exit("soak: cycle %d: the file did not open:\n%s" % (cycle, screen()))
        keys("C-End")
        for _ in range(rng.randint(20, 60)):
            r = rng.random()
            if r < 0.45:
                text(rng.choice(["x = 1", "total += i", "# note", "print(total)", "var s = String(\"é€🔥\")"]))
                keys("Enter")
            elif r < 0.60:
                keys(rng.choice(["Up", "Down", "Left", "Right", "Home", "End", "PageUp", "PageDown", "C-Home", "C-End"]))
            elif r < 0.70:
                keys("C-z")
            elif r < 0.75:
                keys("C-y")
            elif r < 0.80:
                keys("C-d")                     # duplicate line
            elif r < 0.85:
                keys("BSpace")
            elif r < 0.90:
                keys("C-f")
                time.sleep(0.05)
                text("total")
                keys("Enter")
                time.sleep(0.05)
                keys("Escape")
            elif r < 0.95:
                keys("C-p")
                time.sleep(0.05)
                keys("Escape")
            else:
                keys("F10")
                time.sleep(0.05)
                keys("Right", "Right", "Escape")
            time.sleep(0.01)
            if not os.path.exists("/proc/%d" % pid):
                sys.exit("soak: the IDE ended in cycle %d, right after: %s" % (cycle, " | ".join(recent[-4:])))
        if cycle % 10 == 0:
            tmux("resize-window", "-t", "s", "-x", str(rng.randint(80, 160)), "-y", str(rng.randint(24, 50)))
        keys("C-s")
        time.sleep(0.2)
        keys("M-F3")                            # close the window
        time.sleep(0.3)
        if not os.path.exists("/proc/%d" % pid):
            sys.exit("soak: the IDE ended in cycle %d; the last actions: %s" % (cycle, " | ".join(recent)))
        if "File" not in screen():
            sys.exit("soak: cycle %d: the screen does not show the IDE:\n%s" % (cycle, screen()))
        samples.append(rss_kb(pid))
    crash = os.path.join(HOME, "state", "turbomojo", "crash.log")
    crashed = os.path.exists(crash) and "=== crash ===" in open(crash, errors="replace").read()
    tmux("kill-server")
    warm = samples[len(samples) // 10:] if len(samples) >= 10 else samples
    third = max(1, len(warm) // 3)
    first = sum(warm[:third]) / third
    last = sum(warm[-third:]) / third
    allowed = first * (1 + GROWTH_ALLOWED) + GROWTH_SLACK_KB
    print("soak: %d cycles in %.1f min" % (cycle, MINUTES))
    print("memory (VmRSS): start %.1f MB, after warm-up %.1f MB, end %.1f MB, peak %.1f MB" % (samples[0] / 1024, first / 1024, last / 1024, max(samples) / 1024))
    print("growth from the first to the last third: %+.1f MB (allowed up to %+.1f MB)" % ((last - first) / 1024, (allowed - first) / 1024))
    with open(os.path.join(ROOT, "build", "soak-rss.csv"), "w") as f:
        f.write("cycle,rss_kb\n")
        for i, s in enumerate(samples):
            f.write("%d,%d\n" % (i + 1, s))
    if crashed:
        sys.exit("SOAK FAILED: the crash log has an entry: " + crash)
    if last > allowed:
        sys.exit("SOAK FAILED: memory grew (a leak?) - see build/soak-rss.csv")
    shutil.rmtree(HOME, ignore_errors=True)
    print("SOAK OK")


main()
