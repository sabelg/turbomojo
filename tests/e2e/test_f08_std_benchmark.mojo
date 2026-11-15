"""E2E Test Suite for Feature #8: std.benchmark Runner & Baselines.
Covers Tier 1 (5 Happy Path tests), Tier 2 (5 Boundary/Corner tests), and App integration.
"""
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from std.collections import List
from std.math import abs
from bench import (
    BenchmarkItem, is_bench_source, find_bench_functions,
    parse_time_to_ns, parse_std_benchmark_output, compute_bench_diff,
    format_bench_badge, serialize_bench_baseline, deserialize_bench_baseline,
    build_benchmark_cli_command,
)
from snippets import SnippetTemplate, expand_snippet_full
from app import *
from appstate import App, JOB_BENCH
from util import str_bytes, to_str
from harness import ScratchDir, make_test_app


# ---------------------------------------------------------------------------
# Tier 1 Tests: Happy Path
# ---------------------------------------------------------------------------

def test_tier1_f08_detect_bench_source_and_functions() raises:
    """Tier 1: Detect std.benchmark source and find benchmark functions with line numbers."""
    var src = (
        "from std.benchmark import Bencher\n"
        "\n"
        "# Setup helpers\n"
        "def helper():\n"
        "    pass\n"
        "\n"
        "\n"
        "def bench_matmul(mut b: Bencher):\n"
        "    @parameter\n"
        "    def compute():\n"
        "        pass\n"
        "    b.iter[compute]()\n"
        "\n"
        "\n"
        "# Another test\n"
        "def dummy():\n"
        "    pass\n"
        "\n"
        "\n"
        "def bench_norm(mut b: Bencher):\n"
        "    @parameter\n"
        "    def compute():\n"
        "        pass\n"
        "    b.iter[compute]()\n"
    )
    assert_true(is_bench_source(src))
    var funcs = find_bench_functions(src)
    assert_equal(len(funcs), 2)
    assert_equal(funcs[0][0], "bench_matmul")
    assert_equal(funcs[0][1], 8)
    assert_equal(funcs[1][0], "bench_norm")
    assert_equal(funcs[1][1], 20)


def test_tier1_f08_parse_benchmark_output() raises:
    """Tier 1: Parse verbatim std.benchmark console output."""
    var output = (
        "Benchmark report:\n"
        "  bench_matmul: 14.20 ns/op (1000000 iters)\n"
        "  bench_norm:   2.50 us/op (500000 iters)\n"
    )
    var items = parse_std_benchmark_output(output)
    assert_equal(len(items), 2)
    assert_equal(items[0].name, "bench_matmul")
    assert_true(abs(items[0].mean_ns - 14.20) < 0.001)
    assert_equal(items[0].iters, 1000000)

    assert_equal(items[1].name, "bench_norm")
    assert_true(abs(items[1].mean_ns - 2500.0) < 0.1)
    assert_equal(items[1].iters, 500000)


def test_tier1_f08_baseline_json_serialization() raises:
    """Tier 1: Roundtrip serialization and deserialization of benchmark baselines."""
    var items = List[BenchmarkItem]()
    items.append(BenchmarkItem("bench_matmul", 14.2, 1000000))
    items.append(BenchmarkItem("bench_norm", 2500.0, 500000))

    var json_text = serialize_bench_baseline(items)
    assert_true(json_text.find("bench_matmul") >= 0)
    assert_true(json_text.find("bench_norm") >= 0)

    var restored = deserialize_bench_baseline(json_text)
    assert_equal(len(restored), 2)
    assert_equal(restored[0].name, "bench_matmul")
    assert_true(abs(restored[0].mean_ns - 14.2) < 0.1)
    assert_equal(restored[0].iters, 1000000)
    assert_equal(restored[1].name, "bench_norm")
    assert_true(abs(restored[1].mean_ns - 2500.0) < 0.1)
    assert_equal(restored[1].iters, 500000)


def test_tier1_f08_diff_computation_speedup_and_regression() raises:
    """Tier 1: Diff computation correctly identifies speedups, regressions, and neutral changes."""
    var base_a = BenchmarkItem("bench_a", 100.0, 1000)
    var curr_a = BenchmarkItem("bench_a", 88.6, 1000)
    var diff_a = compute_bench_diff(curr_a, base_a)
    assert_true(abs(diff_a.delta_pct - (-11.4)) < 0.01)
    assert_true(diff_a.is_speedup)
    assert_false(diff_a.is_regression)
    assert_equal(format_bench_badge(diff_a), "[⏱ 88.6 ns/op | -11.4% vs base]")

    var base_b = BenchmarkItem("bench_b", 100.0, 1000)
    var curr_b = BenchmarkItem("bench_b", 125.0, 1000)
    var diff_b = compute_bench_diff(curr_b, base_b)
    assert_true(abs(diff_b.delta_pct - 25.0) < 0.01)
    assert_false(diff_b.is_speedup)
    assert_true(diff_b.is_regression)
    assert_equal(format_bench_badge(diff_b), "[⏱ 125.0 ns/op | +25.0% vs base]")

    var base_c = BenchmarkItem("bench_c", 100.0, 1000)
    var curr_c = BenchmarkItem("bench_c", 102.0, 1000)
    var diff_c = compute_bench_diff(curr_c, base_c)
    assert_true(abs(diff_c.delta_pct - 2.0) < 0.01)
    assert_false(diff_c.is_speedup)
    assert_false(diff_c.is_regression)
    assert_equal(format_bench_badge(diff_c), "[⏱ 102.0 ns/op | +2.0% vs base]")


def test_tier1_f08_bench_snippet_expansion() raises:
    """Tier 1: Benchmark snippet template expansion contains Bencher and valid Mojo 1.2 syntax."""
    var tmpl = SnippetTemplate(
        "bench",
        "bench (snippet)",
        "std.benchmark Bencher",
        "from std.benchmark import Bencher\n\ndef bench_${1:case}(mut b: Bencher):\n    @parameter\n    def compute():\n        ${0:pass}\n    b.iter[compute]()",
        "Mojo 1.2 benchmark scaffold using std.benchmark.Bencher.",
    )
    assert_true(tmpl.body.find("from std.benchmark import Bencher") >= 0)
    assert_true(tmpl.body.find("def bench_${1:case}(mut b: Bencher):") >= 0)
    assert_true(tmpl.body.find("b.iter") >= 0)

    var exp = expand_snippet_full(tmpl.body)
    assert_true(exp.text.find("def bench_case(mut b: Bencher):") >= 0)
    assert_true(len(exp.stops) >= 2)


# ---------------------------------------------------------------------------
# Tier 2 Tests: Boundary & Corner Cases
# ---------------------------------------------------------------------------

def test_tier2_f08_time_unit_conversions_picoseconds_to_seconds() raises:
    """Tier 2: Parse and normalize picoseconds, nanoseconds, microseconds, milliseconds, seconds."""
    assert_true(abs(parse_time_to_ns(450.0, "ps") - 0.45) < 0.0001)
    assert_true(abs(parse_time_to_ns(12.5, "ns") - 12.5) < 0.0001)
    assert_true(abs(parse_time_to_ns(3.2, "us") - 3200.0) < 0.001)
    assert_true(abs(parse_time_to_ns(1.5, "ms") - 1500000.0) < 0.1)
    assert_true(abs(parse_time_to_ns(0.25, "s") - 250000000.0) < 1.0)


def test_tier2_f08_missing_baseline_file_or_corrupt_json() raises:
    """Tier 2: Gracefully handles corrupt JSON and missing baseline file."""
    var empty_list = deserialize_bench_baseline("{invalid json [}")
    assert_equal(len(empty_list), 0)

    var item = BenchmarkItem("bench_test", 14.2, 1000)
    var no_base = BenchmarkItem("bench_test", 0.0, 0)
    var diff = compute_bench_diff(item, no_base)
    assert_equal(format_bench_badge(diff), "[⏱ 14.2 ns/op]")


def test_tier2_f08_zero_baseline_division_safety() raises:
    """Tier 2: Avoid division by zero when baseline is 0.0 ns."""
    var base = BenchmarkItem("bench_zero", 0.0, 0)
    var curr = BenchmarkItem("bench_zero", 50.0, 1000)
    var diff = compute_bench_diff(curr, base)
    assert_equal(diff.delta_pct, 0.0)
    assert_false(diff.is_speedup)
    assert_false(diff.is_regression)


def test_tier2_f08_lens_recomputation_on_line_insertion() raises:
    """Tier 2: Gutter lens row numbers adjust correctly when lines are inserted."""
    var base_src = (
        "def bench_test(mut b: Bencher):\n"
        "    pass\n"
    )
    var funcs1 = find_bench_functions(base_src)
    assert_equal(funcs1[0][1], 1)

    var modified_src = (
        "# line 1\n"
        "# line 2\n"
        "# line 3\n"
        "# line 4\n"
        "# line 5\n"
        "def bench_test(mut b: Bencher):\n"
        "    pass\n"
    )
    var funcs2 = find_bench_functions(modified_src)
    assert_equal(funcs2[0][1], 6)
    var lens_row_0based = funcs2[0][1] - 1
    assert_equal(lens_row_0based, 5)


def test_tier2_f08_benchmark_command_generation_flags() raises:
    """Tier 2: CLI invocation command includes -O3 and proper shell quoting."""
    var path = "/tmp/my benchmark tests/bench_kernel.mojo"
    var cmd = build_benchmark_cli_command(path)
    assert_equal(cmd, "mojo run -O3 '/tmp/my benchmark tests/bench_kernel.mojo'")
    assert_true(cmd.find("-O3") >= 0)


def test_app_f08_finish_bench_badges_and_baseline() raises:
    """App integration: finish_bench_job updates win.bench_badges and bench_save_baseline stores JSON."""
    var s = ScratchDir.create("f08_app")
    var bench_path = s.path + "/bench_ops.mojo"
    s.write(
        "bench_ops.mojo",
        "from std.benchmark import Bencher\n\ndef bench_matmul(mut b: Bencher):\n    pass\n",
    )

    var app = make_test_app(s)
    app.open_path(bench_path)
    var base_items = List[BenchmarkItem]()
    base_items.append(BenchmarkItem("bench_matmul", 100.0, 1000))
    app.bench_baseline_json = serialize_bench_baseline(base_items)

    app.aux_job.kind = JOB_BENCH
    app.aux_job.path = bench_path
    app.aux_job.data = str_bytes("Benchmark report:\n  bench_matmul: 80.0 ns/op (1000 iters)\n")
    app.finish_bench_job(0)

    var ei = app.find_editor(bench_path)
    assert_equal(len(app.wins[ei].bench_badge_rows), 1)
    assert_equal(app.wins[ei].bench_badge_rows[0], 2)
    assert_equal(app.wins[ei].bench_badges[0], "[⏱ 80.0 ns/op | -20.0% vs base]")

    var mi = app.msg_index()
    assert_true(mi >= 0)
    assert_true(to_str(app.wins[mi].buf.all_text()).find("SPEEDUP") >= 0)

    s.cleanup()


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
