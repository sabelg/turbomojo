"""Mojo `std.benchmark` runner, baseline regression tracker, and structured `max benchmark` JSON diffing.

Parses `std.benchmark` console output and `max benchmark` JSON reports, computes speedup and
regression deltas against saved baselines, and formats inline editor badges and diff tables."""
from std.collections import List
from json import json_parse, JsonWriter, J_ARR, J_OBJ
from util import shell_quote, pad_right


@fieldwise_init
struct BenchmarkItem(Copyable, Movable):
    var name: String
    var mean_ns: Float64
    var iters: Int


@fieldwise_init
struct BenchmarkDiff(Copyable, Movable):
    var name: String
    var current_ns: Float64
    var baseline_ns: Float64
    var delta_pct: Float64
    var is_speedup: Bool      # delta_pct < -5.0
    var is_regression: Bool   # delta_pct > +5.0


def is_bench_source(text: String) -> Bool:
    """Check if the source file imports std.benchmark or declares benchmark functions."""
    if text.find("std.benchmark") >= 0 or text.find("from benchmark import") >= 0:
        return True
    if text.find("def bench_") >= 0 or text.find("Bencher") >= 0:
        return True
    return False


def find_bench_functions(text: String) -> List[Tuple[String, Int]]:
    """Scan source for `def bench_<name>(...)` functions and return (name, 1-based line)."""
    var out = List[Tuple[String, Int]]()
    var line_num = 1
    for line_slice in text.split("\n"):
        var raw_line = String(line_slice)
        var t = String(raw_line.strip())
        if t.startswith("def bench_"):
            var p_start = t.find("def ") + 4
            var p_paren = t.find("(")
            if p_paren > p_start:
                var fn_name = String(t[byte=p_start:p_paren].strip())
                out.append((fn_name, line_num))
        line_num += 1
    return out^


def parse_float_token(tok: String) -> Float64:
    """Parse a float token into Float64."""
    var s = String(tok.strip())
    var dot = s.find(".")
    var neg = s.startswith("-")
    var start_idx = 1 if neg else 0
    var int_part: Float64 = 0.0
    var end_int = dot if dot >= 0 else s.byte_length()
    var b = s.as_bytes()
    for i in range(start_idx, end_int):
        if b[i] >= 48 and b[i] <= 57:
            int_part = int_part * 10.0 + Float64(Int(b[i]) - 48)
    var frac_part: Float64 = 0.0
    if dot >= 0:
        var div: Float64 = 10.0
        for i in range(dot + 1, s.byte_length()):
            if b[i] >= 48 and b[i] <= 57:
                frac_part += Float64(Int(b[i]) - 48) / div
                div *= 10.0
    var res = int_part + frac_part
    return -res if neg else res


def parse_int_token(tok: String) -> Int:
    """Parse an integer token into Int."""
    var s = String(tok.strip())
    var val = 0
    var b = s.as_bytes()
    for i in range(len(b)):
        if b[i] >= 48 and b[i] <= 57:
            val = val * 10 + Int(b[i]) - 48
    return val


def parse_time_to_ns(val: Float64, unit: String) -> Float64:
    """Convert a time value in any unit (ps, ns, us/µs, ms, s) to nanoseconds."""
    var u = String(unit.strip()).lower()
    if u.startswith("ps"):
        return val * 0.001
    elif u.startswith("ns"):
        return val
    elif u.startswith("us") or u.startswith("µs"):
        return val * 1000.0
    elif u.startswith("ms"):
        return val * 1000000.0
    elif u.startswith("s"):
        return val * 1000000000.0
    return val


def parse_std_benchmark_output(output: String) -> List[BenchmarkItem]:
    """Parse console output from `std.benchmark` runs."""
    var out = List[BenchmarkItem]()
    for line_slice in output.split("\n"):
        var raw_line = String(line_slice)
        var t = String(raw_line.strip())
        if t.byte_length() == 0 or t.startswith("Benchmark report:") or t.startswith("Running"):
            continue
        var colon = t.find(":")
        if colon < 0:
            continue
        var name = String(t[byte=0:colon].strip())
        var rest = String(t[byte=colon + 1:t.byte_length()].strip())

        # Extract number and unit
        var parts = rest.split(" ")
        if len(parts) < 2:
            continue
        var val = parse_float_token(String(parts[0]))
        var unit_tok = String(parts[1])
        var mean_ns = parse_time_to_ns(val, unit_tok)

        # Extract iters from `(1000000 iters)`
        var iters = 1
        var p_paren = rest.find("(")
        if p_paren >= 0:
            var after_paren = String(rest[byte=p_paren + 1:rest.byte_length()])
            var p_close = after_paren.find(")")
            var inside = String(after_paren[byte=0:p_close]) if p_close >= 0 else after_paren
            iters = parse_int_token(inside)

        out.append(BenchmarkItem(name, mean_ns, iters))
    return out^


def compute_bench_diff(curr: BenchmarkItem, base: BenchmarkItem) -> BenchmarkDiff:
    """Compute difference and speedup/regression percentage between current and baseline."""
    if base.mean_ns <= 0.0:
        return BenchmarkDiff(curr.name, curr.mean_ns, base.mean_ns, 0.0, False, False)
    var delta_pct = (curr.mean_ns - base.mean_ns) / base.mean_ns * 100.0
    var is_speedup = delta_pct < -5.0
    var is_regression = delta_pct > 5.0
    return BenchmarkDiff(curr.name, curr.mean_ns, base.mean_ns, delta_pct, is_speedup, is_regression)


def format_1dp(val: Float64) -> String:
    """Format Float64 to 1 decimal place."""
    var neg = val < 0.0
    var v = -val if neg else val
    var i_part = Int(v)
    var frac = Int((v - Float64(i_part)) * 10.0 + 0.5)
    if frac >= 10:
        i_part += 1
        frac = 0
    var s = ("-" if neg else "") + String(i_part) + "." + String(frac)
    return s


def format_bench_badge(diff: BenchmarkDiff) -> String:
    """Format benchmark badge for virtual text rendering."""
    var time_txt = format_1dp(diff.current_ns) + " ns/op"
    if diff.baseline_ns <= 0.0:
        return "[⏱ " + time_txt + "]"
    var sign = "+" if diff.delta_pct > 0.0 else ""
    var pct_txt = sign + format_1dp(diff.delta_pct) + "% vs base"
    return "[⏱ " + time_txt + " | " + pct_txt + "]"


def serialize_bench_baseline(items: List[BenchmarkItem]) -> String:
    """Serialize list of benchmark items to JSON baseline format."""
    var w = JsonWriter()
    w.begin_arr()
    for item in items:
        w.begin_obj()
        w.key("name")
        w.str(item.name)
        w.key("mean_ns")
        w.float(item.mean_ns)
        w.key("iters")
        w.int(item.iters)
        w.end_obj()
    w.end_arr()
    return w.text()


def deserialize_bench_baseline(json_text: String) -> List[BenchmarkItem]:
    """Deserialize JSON baseline text into a list of BenchmarkItem."""
    var out = List[BenchmarkItem]()
    if json_text.byte_length() == 0:
        return out^
    var doc = json_parse(json_text)
    if not doc.ok or doc.kind(0) != J_ARR:
        return out^
    var count = doc.counts[0]
    for idx in range(count):
        var node = doc.at(0, idx)
        if node >= 0 and doc.kind(node) == J_OBJ:
            var name = doc.str(doc.get(node, "name"), "")
            var mean_ns = doc.float(doc.get(node, "mean_ns"), 0.0)
            var iters = doc.int(doc.get(node, "iters"), 0)
            if name.byte_length() > 0:
                out.append(BenchmarkItem(name, mean_ns, iters))
    return out^


def build_benchmark_cli_command(file_path: String) -> String:
    """Build CLI invocation command for running Mojo benchmarks with -O3."""
    return "mojo run -O3 " + shell_quote(file_path)


# ---------------------------------------------------------------------------
# Structured `max benchmark` JSON Capture & Diff (F10)
# ---------------------------------------------------------------------------

@fieldwise_init
struct MaxBenchmarkMetrics(Copyable, Movable):
    var model: String
    var num_prompts: Int
    var ttft_mean_ms: Float64
    var ttft_p99_ms: Float64
    var tpot_mean_ms: Float64
    var tpot_p99_ms: Float64
    var itl_mean_ms: Float64
    var itl_p99_ms: Float64
    var throughput_tok_per_sec: Float64
    var peak_vram_mib: Float64

    def __init__(out self, model: String = ""):
        self.model = model
        self.num_prompts = 0
        self.ttft_mean_ms = 0.0
        self.ttft_p99_ms = 0.0
        self.tpot_mean_ms = 0.0
        self.tpot_p99_ms = 0.0
        self.itl_mean_ms = 0.0
        self.itl_p99_ms = 0.0
        self.throughput_tok_per_sec = 0.0
        self.peak_vram_mib = 0.0


@fieldwise_init
struct MaxMetricDiff(Copyable, Movable):
    var name: String
    var current_val: Float64
    var baseline_val: Float64
    var delta_pct: Float64
    var is_higher_better: Bool
    var status: String


def format_num_1dp(val: Float64) -> String:
    var neg = val < 0.0
    var v = -val if neg else val
    var i_part = Int(v)
    var frac = Int((v - Float64(i_part)) * 10.0 + 0.5)
    if frac >= 10:
        i_part += 1
        frac = 0
    return ("-" if neg else "") + String(i_part) + "." + String(frac)


def parse_max_benchmark_json(json_text: String) -> MaxBenchmarkMetrics:
    """Parse structured JSON generated by `max benchmark --result-filename`."""
    var m = MaxBenchmarkMetrics()
    if json_text.byte_length() == 0:
        return m^
    var doc = json_parse(json_text)
    if not doc.ok or doc.kind(0) != J_OBJ:
        return m^

    m.model = doc.str(doc.get(0, "model"), "")
    m.num_prompts = doc.int(doc.get(0, "num_prompts"), 0)

    # TTFT: check flat keys then nested objects
    var ttft_mean = doc.float(doc.get(0, "mean_ttft_ms"), 0.0)
    if ttft_mean == 0.0:
        ttft_mean = doc.float(doc.path(0, "ttft/mean"), 0.0)
    m.ttft_mean_ms = ttft_mean

    var ttft_p99 = doc.float(doc.get(0, "p99_ttft_ms"), 0.0)
    if ttft_p99 == 0.0:
        ttft_p99 = doc.float(doc.path(0, "ttft/p99"), 0.0)
    m.ttft_p99_ms = ttft_p99

    # TPOT
    var tpot_mean = doc.float(doc.get(0, "mean_tpot_ms"), 0.0)
    if tpot_mean == 0.0:
        tpot_mean = doc.float(doc.path(0, "tpot/mean"), 0.0)
    m.tpot_mean_ms = tpot_mean

    var tpot_p99 = doc.float(doc.get(0, "p99_tpot_ms"), 0.0)
    if tpot_p99 == 0.0:
        tpot_p99 = doc.float(doc.path(0, "tpot/p99"), 0.0)
    m.tpot_p99_ms = tpot_p99

    # ITL
    var itl_mean = doc.float(doc.get(0, "mean_itl_ms"), 0.0)
    if itl_mean == 0.0:
        itl_mean = doc.float(doc.path(0, "itl/mean"), 0.0)
    m.itl_mean_ms = itl_mean

    var itl_p99 = doc.float(doc.get(0, "p99_itl_ms"), 0.0)
    if itl_p99 == 0.0:
        itl_p99 = doc.float(doc.path(0, "itl/p99"), 0.0)
    m.itl_p99_ms = itl_p99

    # Throughput
    var thr = doc.float(doc.get(0, "output_throughput"), 0.0)
    if thr == 0.0:
        thr = doc.float(doc.path(0, "throughput/output_tokens_per_sec"), 0.0)
    if thr == 0.0:
        thr = doc.float(doc.get(0, "mean_output_throughput"), 0.0)
    m.throughput_tok_per_sec = thr

    # Peak VRAM
    var vram = doc.float(doc.path(0, "gpu_stats/peak_memory_mb"), 0.0)
    if vram == 0.0:
        vram = doc.float(doc.get(0, "peak_vram_mib"), 0.0)
    m.peak_vram_mib = vram

    return m^


def make_metric_diff(name: String, curr_val: Float64, base_val: Float64, higher_better: Bool) -> MaxMetricDiff:
    """Create a metric diff with delta calculation and visual status tag."""
    if base_val <= 0.0:
        return MaxMetricDiff(name, curr_val, base_val, 0.0, higher_better, "[≈ FLAT]")
    var delta = (curr_val - base_val) / base_val * 100.0
    var status = String("[≈ FLAT]")
    if higher_better:
        if delta > 2.0:
            status = "[✓ FASTER]"
        elif delta < -2.0:
            status = "[⚠ SLOWER]"
    else:
        if delta < -2.0:
            status = "[✓ LOWER]"
        elif delta > 2.0:
            status = "[⚠ HIGHER]"
    return MaxMetricDiff(name, curr_val, base_val, delta, higher_better, status)


def diff_max_benchmark(curr: MaxBenchmarkMetrics, base: MaxBenchmarkMetrics) -> List[MaxMetricDiff]:
    """Compute comparison diffs across all key metrics."""
    var out = List[MaxMetricDiff]()
    out.append(make_metric_diff("Output Throughput (tok/s)", curr.throughput_tok_per_sec, base.throughput_tok_per_sec, True))
    out.append(make_metric_diff("Mean TTFT (ms)", curr.ttft_mean_ms, base.ttft_mean_ms, False))
    out.append(make_metric_diff("p99 TTFT (ms)", curr.ttft_p99_ms, base.ttft_p99_ms, False))
    out.append(make_metric_diff("Mean TPOT (ms)", curr.tpot_mean_ms, base.tpot_mean_ms, False))
    out.append(make_metric_diff("p99 TPOT (ms)", curr.tpot_p99_ms, base.tpot_p99_ms, False))
    out.append(make_metric_diff("Mean ITL (ms)", curr.itl_mean_ms, base.itl_mean_ms, False))
    out.append(make_metric_diff("p99 ITL (ms)", curr.itl_p99_ms, base.itl_p99_ms, False))
    out.append(make_metric_diff("Peak VRAM (MiB)", curr.peak_vram_mib, base.peak_vram_mib, False))
    return out^


def format_max_diff_table(diffs: List[MaxMetricDiff], model: String) -> List[String]:
    """Format an ASCII/Unicode table comparing current benchmark run against saved baseline."""
    var out = List[String]()
    out.append("MAX Benchmark Comparison: " + model)
    out.append("────────────────────────────────────────────────────────────────────────")
    out.append(pad_right("Metric", 28) + pad_right("Current", 12) + pad_right("Baseline", 12) + pad_right("Delta", 10) + "Status")
    out.append("────────────────────────────────────────────────────────────────────────")

    for d in diffs:
        var curr_txt = format_num_1dp(d.current_val)
        var base_txt = format_num_1dp(d.baseline_val) if d.baseline_val > 0.0 else "—"
        var delta_txt = (("+" if d.delta_pct > 0.0 else "") + format_num_1dp(d.delta_pct) + "%") if d.baseline_val > 0.0 else "—"
        var stat_txt = d.status if d.baseline_val > 0.0 else "—"
        out.append(pad_right(d.name, 28) + pad_right(curr_txt, 12) + pad_right(base_txt, 12) + pad_right(delta_txt, 10) + stat_txt)

    out.append("────────────────────────────────────────────────────────────────────────")
    return out^


def inject_max_benchmark_output_flag(cmd: String, output_path: String) -> String:
    """Inject or replace --result-filename in max benchmark command line."""
    var b = cmd.as_bytes()
    for flag in ["--result-filename", "--output-file"]:
        var p = cmd.find(flag)
        if p >= 0:
            var flag_len = flag.byte_length()
            var after_flag = p + flag_len
            while after_flag < len(b) and b[after_flag] == 32:
                after_flag += 1
            # find end of argument
            var end_arg = after_flag
            while end_arg < len(b) and b[end_arg] != 32:
                end_arg += 1
            var prefix = String(cmd[byte=0:p])
            var suffix = String(cmd[byte=end_arg:cmd.byte_length()])
            return prefix + flag + " " + output_path + suffix

    return cmd + " --result-filename " + output_path
