#!/usr/bin/env python3
"""TurboMojo's performance budgets (run by scripts/perf.sh, and so by scripts/check.sh):

- start-up: from launching build/tmide on a file until the file's first line is on
  screen (in a tmux pane), median of 5;
- key to frame: from a key sent to the pane until it is on screen, median of 30, next
  to what tmux itself takes for the same round trip through `cat`;
- 1M-line open: the editor's loader on a 1,000,000-line file (bench/open_bench.mojo);
- idle: CPU the IDE uses in 10 s of doing nothing.

Each has a budget; going over fails the run. The IDE runs with configuration and state
folders of its own (nothing of the user's is read or written). The results are added to
build/perf-history.csv, one line per run, to see a trend.

Usage: perf.py <tmide> <open_bench> <1M-line file>
"""
import csv, os, shutil, subprocess, sys, time

TMIDE, OPEN_BENCH, BIG = sys.argv[1], sys.argv[2], sys.argv[3]
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
HOME = os.path.join(ROOT, "build", "perf-home")
CLK = os.sysconf("SC_CLK_TCK")

# budgets: generous next to what this machine measures (see docs/JOURNAL.md, P9-02), so
# that a loaded machine does not fail the gate, tight enough to catch a real regression
BUDGET_START_MS = 400
BUDGET_KEY_MS = 30          # above tmux's own round trip
BUDGET_OPEN_MS = 1000
BUDGET_IDLE_MS = 100        # CPU in 10 s


def tmux(*a):
    return subprocess.run(["tmux", "-L", "tmperf", *a], capture_output=True, text=True).stdout


def median(xs):
    xs = sorted(xs)
    return xs[len(xs) // 2]


def fresh_home():
    shutil.rmtree(HOME, ignore_errors=True)
    for d in ("config", "state", "cache"):
        os.makedirs(os.path.join(HOME, d))
    return "env XDG_CONFIG_HOME=%s/config XDG_STATE_HOME=%s/state XDG_CACHE_HOME=%s/cache " % (HOME, HOME, HOME)


def wait_for(name, text, limit):
    t0 = time.perf_counter()
    while text not in tmux("capture-pane", "-p", "-t", name):
        if time.perf_counter() - t0 > limit:
            raise SystemExit("perf: '%s' did not appear; the pane shows:\n%s" % (text, tmux("capture-pane", "-p", "-t", name)))
        time.sleep(0.0005)
    return time.perf_counter() - t0


def ended(pid):
    for _ in range(200):
        if not os.path.exists("/proc/%d" % pid):
            return
        time.sleep(0.05)


def start_once(sample, first):
    env = fresh_home()
    t0 = time.perf_counter()
    subprocess.run(["tmux", "-L", "tmperf", "new-session", "-d", "-s", "p", "-x", "120", "-y", "40", env + TMIDE + " " + sample])
    wait_for("p", first, 20)
    took = time.perf_counter() - t0
    pid = int(tmux("display", "-p", "-t", "p", "#{pane_pid}").strip())
    return took, pid


def stop(pid):
    tmux("kill-server")
    ended(pid)


def key_round_trips(name, n):
    out = []
    for k in range(n):
        mark = "Q%dZ" % k
        t0 = time.perf_counter()
        subprocess.run(["tmux", "-L", "tmperf", "send-keys", "-t", name, "-l", mark])
        wait_for(name, mark, 5)
        out.append((time.perf_counter() - t0) * 1000)
    return out


def cpu_ms(pid, secs):
    def ticks():
        f = open("/proc/%d/stat" % pid).read().rsplit(")", 1)[1].split()
        return int(f[11]) + int(f[12])
    a = ticks()
    time.sleep(secs)
    return (ticks() - a) * 1000 / CLK


def main():
    sample = os.path.join(ROOT, "build", "perf-sample.mojo")
    with open(sample, "w") as f:
        f.write("# perf sample: the first line\n")
        for i in range(200):
            f.write("def f%d(x: Int) -> Int:\n    return x * %d\n\n" % (i, i))
    first = "# perf sample: the first line"
    tmux("kill-server")
    # start-up
    starts = []
    for _ in range(5):
        took, pid = start_once(sample, first)
        starts.append(took * 1000)
        stop(pid)
    # key to frame, and idle CPU, in one more run
    took, pid = start_once(sample, first)
    time.sleep(0.5)
    tmux("send-keys", "-t", "p", "C-End")
    time.sleep(0.2)
    keys = key_round_trips("p", 30)
    idle = cpu_ms(pid, 10)
    stop(pid)
    # tmux's own round trip, through cat
    subprocess.run(["tmux", "-L", "tmperf", "new-session", "-d", "-s", "c", "-x", "120", "-y", "40", "cat"])
    time.sleep(0.3)
    floor = key_round_trips("c", 30)
    tmux("kill-server")
    # the 1M-line open
    out = subprocess.run([OPEN_BENCH, BIG], capture_output=True, text=True).stdout
    open_ms = None
    for line in out.splitlines():
        if "open total" in line:
            open_ms = float(line.split("open total")[1].split()[0])
    if open_ms is None:
        raise SystemExit("perf: open_bench said nothing:\n" + out)
    start_ms, key_ms, floor_ms = median(starts), median(keys), median(floor)
    rows = [
        ("start-up (file on screen)", start_ms, BUDGET_START_MS, ""),
        ("key to frame", key_ms - floor_ms, BUDGET_KEY_MS, " (%.1f ms, tmux itself %.1f ms)" % (key_ms, floor_ms)),
        ("open 1,000,000 lines", open_ms, BUDGET_OPEN_MS, ""),
        ("idle CPU in 10 s", idle, BUDGET_IDLE_MS, ""),
    ]
    over = False
    for name, value, budget, note in rows:
        ok = value <= budget
        over = over or not ok
        print("%-28s %8.1f ms   budget %5d ms   %s%s" % (name, value, budget, "ok" if ok else "OVER BUDGET", note))
    hist = os.path.join(ROOT, "build", "perf-history.csv")
    new = not os.path.exists(hist)
    with open(hist, "a", newline="") as f:
        w = csv.writer(f)
        if new:
            w.writerow(["time", "start_ms", "key_ms", "tmux_ms", "open_1m_ms", "idle_cpu_ms"])
        w.writerow([time.strftime("%Y-%m-%dT%H:%M:%S"), "%.1f" % start_ms, "%.1f" % key_ms, "%.1f" % floor_ms, "%.1f" % open_ms, "%.1f" % idle])
    shutil.rmtree(HOME, ignore_errors=True)
    if over:
        raise SystemExit("PERF FAILED")
    print("PERF OK")


main()
