"""E2E Test Suite for Feature #10: Structured max benchmark JSON Capture & Diff.
Covers Tier 1 (5 Happy Path tests), Tier 2 (5 Boundary/Corner tests), and App integration.
"""
from std.testing import assert_equal, assert_true, TestSuite
from std.math import abs
from bench import (
    MaxBenchmarkMetrics, parse_max_benchmark_json, diff_max_benchmark,
    format_max_diff_table, inject_max_benchmark_output_flag,
)
from app import *
from appstate import App, JOB_MAX_BENCH
from util import to_str
from harness import ScratchDir, make_test_app


# ---------------------------------------------------------------------------
# Tier 1 Tests: Happy Path
# ---------------------------------------------------------------------------

def test_tier1_f10_parse_max_benchmark_json_complete() raises:
    """Tier 1: Parse complete flat max benchmark JSON output."""
    var json_text = (
        "{\n"
        "  \"model\": \"Qwen2.5-7B\",\n"
        "  \"num_prompts\": 32,\n"
        "  \"mean_ttft_ms\": 18.42,\n"
        "  \"p99_ttft_ms\": 25.80,\n"
        "  \"mean_tpot_ms\": 12.35,\n"
        "  \"p99_tpot_ms\": 15.20,\n"
        "  \"mean_itl_ms\": 11.95,\n"
        "  \"p99_itl_ms\": 14.90,\n"
        "  \"output_throughput\": 420.5,\n"
        "  \"gpu_stats\": {\n"
        "    \"peak_memory_mb\": 14500.0\n"
        "  }\n"
        "}\n"
    )
    var m = parse_max_benchmark_json(json_text)
    assert_equal(m.model, "Qwen2.5-7B")
    assert_equal(m.num_prompts, 32)
    assert_true(abs(m.ttft_mean_ms - 18.42) < 0.001)
    assert_true(abs(m.ttft_p99_ms - 25.80) < 0.001)
    assert_true(abs(m.tpot_mean_ms - 12.35) < 0.001)
    assert_true(abs(m.tpot_p99_ms - 15.20) < 0.001)
    assert_true(abs(m.itl_mean_ms - 11.95) < 0.001)
    assert_true(abs(m.itl_p99_ms - 14.90) < 0.001)
    assert_true(abs(m.throughput_tok_per_sec - 420.5) < 0.001)
    assert_true(abs(m.peak_vram_mib - 14500.0) < 0.1)


def test_tier1_f10_parse_nested_percentile_json() raises:
    """Tier 1: Parse nested percentile and throughput objects in JSON."""
    var json_text = (
        "{\n"
        "  \"model\": \"Llama-3-8B\",\n"
        "  \"ttft\": {\"mean\": 18.42, \"p99\": 25.80},\n"
        "  \"tpot\": {\"mean\": 12.35, \"p99\": 15.20},\n"
        "  \"itl\": {\"mean\": 11.95, \"p99\": 14.90},\n"
        "  \"throughput\": {\"output_tokens_per_sec\": 420.5}\n"
        "}\n"
    )
    var m = parse_max_benchmark_json(json_text)
    assert_equal(m.model, "Llama-3-8B")
    assert_true(abs(m.ttft_mean_ms - 18.42) < 0.001)
    assert_true(abs(m.ttft_p99_ms - 25.80) < 0.001)
    assert_true(abs(m.throughput_tok_per_sec - 420.5) < 0.001)


def test_tier1_f10_diff_calculation_throughput_and_latencies() raises:
    """Tier 1: Throughput and latency diff calculations with correct status tags."""
    var base = MaxBenchmarkMetrics("Qwen2.5-7B")
    base.throughput_tok_per_sec = 400.0
    base.ttft_mean_ms = 25.0
    base.peak_vram_mib = 14000.0

    var curr = MaxBenchmarkMetrics("Qwen2.5-7B")
    curr.throughput_tok_per_sec = 460.0
    curr.ttft_mean_ms = 20.0
    curr.peak_vram_mib = 14100.0

    var diffs = diff_max_benchmark(curr, base)
    assert_equal(len(diffs), 8)

    assert_true(abs(diffs[0].delta_pct - 15.0) < 0.01)
    assert_equal(diffs[0].status, "[✓ FASTER]")

    assert_true(abs(diffs[1].delta_pct - (-20.0)) < 0.01)
    assert_equal(diffs[1].status, "[✓ LOWER]")

    assert_true(abs(diffs[7].delta_pct - 0.71) < 0.1)
    assert_equal(diffs[7].status, "[≈ FLAT]")


def test_tier1_f10_format_diff_table_layout() raises:
    """Tier 1: Format aligned diff table layout with header and dividers."""
    var base = MaxBenchmarkMetrics("Qwen2.5-7B")
    base.throughput_tok_per_sec = 400.0
    base.ttft_mean_ms = 25.0

    var curr = MaxBenchmarkMetrics("Qwen2.5-7B")
    curr.throughput_tok_per_sec = 460.0
    curr.ttft_mean_ms = 20.0

    var diffs = diff_max_benchmark(curr, base)
    var table = format_max_diff_table(diffs, "Qwen2.5-7B")

    assert_true(len(table) >= 8)
    assert_true(table[0].find("Qwen2.5-7B") >= 0)
    assert_true(table[1].find("───") >= 0)
    assert_true(table[2].find("Current") >= 0)
    assert_true(table[2].find("Delta") >= 0)


def test_tier1_f10_cli_output_file_flag_injection() raises:
    """Tier 1: Append --result-filename when no existing output flag is present."""
    var cmd = "max benchmark --backend modular --num-prompts 32"
    var out_path = "/tmp/run.json"
    var res = inject_max_benchmark_output_flag(cmd, out_path)
    assert_equal(res, "max benchmark --backend modular --num-prompts 32 --result-filename /tmp/run.json")


# ---------------------------------------------------------------------------
# Tier 2 Tests: Boundary & Corner Cases
# ---------------------------------------------------------------------------

def test_tier2_f10_single_concurrency_null_aggregate_throughput() raises:
    """Tier 2: Single-concurrency run falling back to mean_output_throughput."""
    var json_text = (
        "{\n"
        "  \"model\": \"Mistral-7B\",\n"
        "  \"output_throughput\": null,\n"
        "  \"mean_output_throughput\": 45.2\n"
        "}\n"
    )
    var m = parse_max_benchmark_json(json_text)
    assert_true(abs(m.throughput_tok_per_sec - 45.2) < 0.001)


def test_tier2_f10_missing_gpu_stats_cpu_inference() raises:
    """Tier 2: CPU inference run lacking gpu_stats block defaults safely to 0.0."""
    var json_text = (
        "{\n"
        "  \"model\": \"BERT-Base\",\n"
        "  \"mean_ttft_ms\": 5.2\n"
        "}\n"
    )
    var m = parse_max_benchmark_json(json_text)
    assert_equal(m.peak_vram_mib, 0.0)


def test_tier2_f10_first_run_no_baseline_table() raises:
    """Tier 2: Table formatting when running for the first time without baseline."""
    var curr = MaxBenchmarkMetrics("Qwen2.5-7B")
    curr.throughput_tok_per_sec = 450.0
    var no_base = MaxBenchmarkMetrics("Qwen2.5-7B")

    var diffs = diff_max_benchmark(curr, no_base)
    var table = format_max_diff_table(diffs, "Qwen2.5-7B")

    assert_true(len(table) >= 8)
    assert_true(table[4].find("—") >= 0)


def test_tier2_f10_corrupt_or_truncated_json_payload() raises:
    """Tier 2: Truncated JSON returns default metrics without raising."""
    var corrupt_json = "{\"model\": \"Llama\", \"mean_ttft_ms\": 12."
    var m = parse_max_benchmark_json(corrupt_json)
    assert_equal(m.model, "")
    assert_equal(m.throughput_tok_per_sec, 0.0)


def test_tier2_f10_cli_replacement_of_existing_output_flag() raises:
    """Tier 2: Replace existing --result-filename or --output-file in command."""
    var cmd1 = "max benchmark --result-filename old.json --num-prompts 16"
    var res1 = inject_max_benchmark_output_flag(cmd1, "/tmp/new.json")
    assert_equal(res1, "max benchmark --result-filename /tmp/new.json --num-prompts 16")

    var cmd2 = "max benchmark --output-file /var/log/out.json --backend modular"
    var res2 = inject_max_benchmark_output_flag(cmd2, "/tmp/new.json")
    assert_equal(res2, "max benchmark --output-file /tmp/new.json --backend modular")


def test_app_f10_finish_max_bench_diff() raises:
    """App integration: finish_max_bench parses captured JSON and renders comparison table."""
    var s = ScratchDir.create("f10_app")
    var out_json = s.path + "/max_out.json"
    s.write(
        "max_out.json",
        "{\"model\": \"Qwen2.5-7B\", \"output_throughput\": 500.0, \"mean_ttft_ms\": 15.0}",
    )

    var app = make_test_app(s)
    app.max_baseline_json = "{\"model\": \"Qwen2.5-7B\", \"output_throughput\": 400.0, \"mean_ttft_ms\": 20.0}"
    app.max_bench_out_file = out_json
    app.job.kind = JOB_MAX_BENCH
    app.finish_max_bench(0)

    var mi = app.msg_index()
    assert_true(mi >= 0)
    var msg_txt = to_str(app.wins[mi].buf.all_text())
    assert_true(msg_txt.find("[✓ FASTER]") >= 0)
    assert_true(msg_txt.find("[✓ LOWER]") >= 0)

    s.cleanup()


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
