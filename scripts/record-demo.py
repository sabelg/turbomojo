#!/usr/bin/env python3
"""Record a short demo of TurboMojo as an asciinema cast (docs/demo.cast).

The IDE runs on a tmux server of its own, with a home, configuration and state of its
own and a copy of examples/hello.mojo in a folder of its own (so no one's settings or
paths are in the recording). The script types what a person would - a menu, running the
program, the command palette, the tiled layout, the theme preview - and after each step
takes the screen with its colours (`tmux capture-pane -e`) as one frame of the cast.
Play it with `asciinema play docs/demo.cast`, or upload it wherever you like.

Usage: scripts/record-demo.py [OUT.cast]   (after `pixi run build`; needs tmux)
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TMIDE = os.path.join(ROOT, "build", "tmide")
SOCK = "tmdemo"
W, H = 100, 30


def tmux(*a):
    return subprocess.run(["tmux", "-L", SOCK, *a], capture_output=True, text=True).stdout


def keys(*k):
    subprocess.run(["tmux", "-L", SOCK, "send-keys", "-t", "s", *k])


def text(s):
    subprocess.run(["tmux", "-L", SOCK, "send-keys", "-t", "s", "-l", s])


def screen(colour=False):
    return tmux("capture-pane", "-p", "-t", "s", *(["-e"] if colour else []))


def wait_for(what, limit=10.0):
    end = time.time() + limit
    while time.time() < end:
        if what in screen():
            return True
        time.sleep(0.1)
    return False


class Cast:
    def __init__(self):
        self.t0 = time.time()
        self.events = []
        self.last = None

    def frame(self, hold=0.0):
        """Take the screen as it is now; then let it stand `hold` seconds."""
        time.sleep(0.15)                 # (the IDE's next frame)
        s = screen(colour=True)
        if s != self.last:
            data = "\x1b[H\x1b[2J" + s.rstrip("\n").replace("\n", "\r\n") + "\x1b[0m"
            self.events.append([round(time.time() - self.t0, 3), "o", data])
            self.last = s
        time.sleep(hold)

    def write(self, path):
        with open(path, "w") as f:
            f.write(json.dumps({"version": 2, "width": W, "height": H, "title": "TurboMojo",
                                "env": {"TERM": "xterm-256color", "SHELL": "/bin/sh"}}) + "\n")
            for e in self.events:
                f.write(json.dumps(e, ensure_ascii=False) + "\n")


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, "docs", "demo.cast")
    if not shutil.which("tmux"):
        sys.exit("record-demo: needs tmux")
    if not os.path.exists(TMIDE):
        sys.exit("record-demo: build TurboMojo first (pixi run build)")
    home = tempfile.mkdtemp(prefix="turbomojo-demo-")
    work = os.path.join(home, "demo")
    os.makedirs(work)
    shutil.copy(os.path.join(ROOT, "examples", "hello.mojo"), work)
    for d in ("config", "state/turbomojo", "cache"):
        os.makedirs(os.path.join(home, d), exist_ok=True)
    open(os.path.join(home, "state", "turbomojo", "theme-asked"), "w").close()
    with open(os.path.join(home, "state", "turbomojo", "trusted"), "w") as f:
        f.write(work + "\n")          # (the demo's own folder: running it asks nothing)
    env = "env HOME=%s XDG_CONFIG_HOME=%s/config XDG_STATE_HOME=%s/state XDG_CACHE_HOME=%s/cache COLORTERM=truecolor " % (home, home, home, home)
    tmux("kill-server")
    time.sleep(0.2)
    try:
        subprocess.run(["tmux", "-L", SOCK, "-f", "/dev/null", "new-session", "-d", "-s", "s",
                        "-x", str(W), "-y", str(H), "-c", work, env + TMIDE + " hello.mojo"])
        tmux("set", "-g", "default-terminal", "tmux-256color")
        if not wait_for("hello.mojo", 20):
            sys.exit("record-demo: the IDE did not start:\n" + screen())
        cast = Cast()
        cast.frame(1.5)
        # walk into the code
        for _ in range(4):
            keys("Down")
            cast.frame(0.1)
        keys("End")
        cast.frame(0.8)
        # the menus, Turbo C++ style
        keys("F10")
        cast.frame(0.6)
        for _ in range(4):
            keys("Right")
            cast.frame(0.4)
        keys("Escape")
        cast.frame(0.3)
        # run it: Ctrl-F9
        keys("C-F9")
        cast.frame(0.2)
        if not wait_for("6765", 120):        # (fib(20): the output, not the source)
            sys.exit("record-demo: the program's output did not show:\n" + screen())
        cast.frame(2.0)
        keys("F6")
        cast.frame(0.5)
        # the command palette: a tiled layout
        keys("C-p")
        cast.frame(0.5)
        for ch in "tiled":
            text(ch)
            cast.frame(0.05)
        cast.frame(0.6)
        keys("Enter")
        cast.frame(0.8)
        # ... with the file explorer beside the code
        keys("C-e")                          # (File explorer)
        cast.frame(1.5)
        keys("F6")
        cast.frame(0.5)
        # the themes, previewed as you move
        keys("C-p")
        cast.frame(0.3)
        for ch in "colour theme":
            text(ch)
            cast.frame(0.03)
        keys("Enter")
        cast.frame(1.0)
        for _ in range(5):
            keys("Down")
            cast.frame(0.9)
        keys("Escape")
        cast.frame(1.0)
        cast.write(out)
        print("record-demo: %d frames, %.1f s -> %s" % (len(cast.events), cast.events[-1][0], out))
    finally:
        tmux("kill-server")
        shutil.rmtree(home, ignore_errors=True)


if __name__ == "__main__":
    main()
