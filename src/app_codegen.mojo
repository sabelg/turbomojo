"""Codegen & kernel inspector (`Compile > Inspect generated code`, WK_CODEGEN), benchmark
runner (`std.benchmark` & `max benchmark`), and GPU kernel profiler (`nsys`, `ncu`, `rocprofv3`)."""
from std.collections import List
from appstate import *
from window import Window, WK_CODEGEN, RM_NONE, RM_OK, RM_WARN, RM_DIM
from term import KEY_ESC, KEY_ENTER
from signals import own_pid
from util import *
from codegen import (
    CG_ASM, CG_LLVM, CodegenSummary, format_codegen_header,
    parse_asm_with_line_tables, parse_llvm_with_line_tables,
    extract_kernel_resources, format_kernel_resource_badge,
    find_codegen_rows_for_source,
)
from bench import (
    BenchmarkItem, BenchmarkDiff, is_bench_source, find_bench_functions,
    parse_std_benchmark_output, compute_bench_diff, format_bench_badge,
    serialize_bench_baseline, deserialize_bench_baseline, build_benchmark_cli_command,
    MaxBenchmarkMetrics, parse_max_benchmark_json, diff_max_benchmark,
    format_max_diff_table, inject_max_benchmark_output_flag,
)
from gpuinfo import (
    parse_ncu_csv_output, parse_ncu_source_stall_lines,
    filter_valid_source_stall_lines, check_profiler_permissions,
    build_roofline_cli_command, format_roofline_report,
)
from outline import scan_outline, scope_path, outline_current, SK_FUNCTION, SK_METHOD
from app_jobs import *
from app_outline import *
from app_layout import *
from app_nav import *
from app_files import *
from app_menus import *


__extension App:
    def codegen_index(self) -> Int:
        for i in range(len(self.wins)):
            if self.wins[i].kind == WK_CODEGEN:
                return i
        return -1

    def codegen_render_lines(mut self, lines: List[String], reset_pos: Bool = False):
        var ci = self.codegen_index()
        if ci < 0:
            return
        var text = List[Int]()
        var marks = List[Int]()
        for k in range(len(lines)):
            if k > 0:
                text.append(10)
            for cp in decode(lines[k]):
                text.append(cp)
            if lines[k].startswith("[SPILL]") or lines[k].startswith("  [SPILL]"):
                marks.append(RM_WARN)
            elif lines[k].startswith("[SIMD]") or lines[k].startswith("  [SIMD]"):
                marks.append(RM_OK)
            elif k < 2:
                marks.append(RM_DIM)
            else:
                marks.append(RM_NONE)
        var keep_cr = 0 if reset_pos else self.wins[ci].cr
        var keep_top = 0 if reset_pos else self.wins[ci].top
        self.codegen_base_marks = marks.copy()
        self.codegen_sync_row = -1
        self.codegen_sync_cg_row = -1
        self.wins[ci].buf.load(text)
        self.wins[ci].row_marks = marks^
        self.wins[ci].buf.modified = False
        self.wins[ci].cr = max(0, min(keep_cr, self.wins[ci].buf.count() - 1))
        self.wins[ci].top = max(0, min(keep_top, self.wins[ci].buf.count() - 1))

    def apply_codegen_badges(mut self, path: String, raw: String, mode: Int):
        """Attach per-kernel / per-function register, shared-memory, SIMD & spill badges
        onto `def` headers in the open editor for `path`."""
        var ei = self.find_editor(path)
        if ei < 0:
            return
        var stats = extract_kernel_resources(raw, mode)
        if len(stats) == 0:
            return
        var items = scan_outline(self.wins[ei].buf)
        var changed = False
        for it in items:
            if it.kind != SK_FUNCTION and it.kind != SK_METHOD:
                continue
            var fn_low = it.name.lower()
            if fn_low.byte_length() == 0:
                continue
            var best = -1
            for k in range(len(stats)):
                if stats[k].name == it.name:
                    best = k
                    break
            if best < 0 and fn_low.byte_length() >= 3:
                for k in range(len(stats)):
                    if stats[k].name.lower().find(fn_low) >= 0:
                        best = k
                        break
            if best >= 0:
                var badge = format_kernel_resource_badge(stats[best])
                var updated = False
                for bi in range(len(self.wins[ei].bench_badge_rows)):
                    if self.wins[ei].bench_badge_rows[bi] == it.row:
                        self.wins[ei].bench_badges[bi] = badge
                        updated = True
                        break
                if not updated:
                    self.wins[ei].bench_badge_rows.append(it.row)
                    self.wins[ei].bench_badges.append(badge)
                changed = True
        if changed:
            self.sync_shared_buffers(ei)

    def codegen_sync_cursor(mut self):
        """Live bidirectional cursor synchronization between the Mojo editor (`WK_EDITOR`)
        and its open `WK_CODEGEN` assembly / PTX / LLVM-IR pane."""
        var ci = self.codegen_index()
        if ci < 0 or len(self.codegen_line_map) == 0 or self.codegen_path.byte_length() == 0:
            return
        var ei = self.find_editor(self.codegen_path)
        if ei < 0:
            return
        if self.top() == ci:
            if self.wins[ci].cr != self.codegen_sync_cg_row:
                self.codegen_sync_cg_row = self.wins[ci].cr
                if self.wins[ci].cr >= 0 and self.wins[ci].cr < len(self.codegen_line_map):
                    var mapped = self.codegen_line_map[self.wins[ci].cr]
                    if mapped > 0:
                        var tr = max(0, min(mapped - 1, self.wins[ei].buf.count() - 1))
                        self.wins[ei].cr = tr
                        self.wins[ei].follow = True
                        self.codegen_sync_row = tr
                        var marks = self.codegen_base_marks.copy()
                        for r in find_codegen_rows_for_source(self.codegen_line_map, mapped):
                            if r >= 0 and r < len(marks) and marks[r] != RM_WARN:
                                marks[r] = RM_OK
                        self.wins[ci].row_marks = marks^
            return
        if self.wins[ei].cr != self.codegen_sync_row:
            self.codegen_sync_row = self.wins[ei].cr
            var want_src = self.wins[ei].cr + 1
            var marks = self.codegen_base_marks.copy()
            var matched = find_codegen_rows_for_source(self.codegen_line_map, want_src)
            for mr in matched:
                if mr >= 0 and mr < len(marks) and marks[mr] != RM_WARN:
                    marks[mr] = RM_OK
            self.wins[ci].row_marks = marks^
            if len(matched) > 0:
                self.wins[ci].cr = matched[0]
                self.wins[ci].follow = True
                self.codegen_sync_cg_row = matched[0]

    def codegen_open(mut self) raises:
        """Open (or toggle/refresh) the Codegen Inspector side pane for the active editor."""
        var ci = self.codegen_index()
        var ti = self.top_editor()
        if ci >= 0 and self.top() == ci:
            _ = self.wins.pop(ci)
            self.layout_sync()
            return
        if ti < 0:
            self.info("Inspect Generated Code", "Open a Mojo file first.")
            return
        if not self.ensure_saved(ti):
            return
        var path = String(self.wins[ti].path)
        self.codegen_path = path
        if ci < 0:
            var dh = self.desk_h()
            var mi = self.msg_index()
            if mi >= 0:
                dh = max(8, self.wins[mi].y - 1)
            var w = min(68, max(42, self.scr.w // 2))
            var x = max(0, self.scr.w - w)
            var win = Window(WK_CODEGEN, "Codegen: " + basename(path), "", x, 1, w, dh, self.free_number())
            self.wins.append(win^)
            self.layout_sync()
        else:
            self.wins[ci].title = "Codegen: " + basename(path)
            self.focus(ci)
        self.codegen_refresh()

    def codegen_refresh(mut self) raises:
        if self.codegen_path.byte_length() == 0:
            var ti = self.top_editor()
            if ti < 0 or not self.ensure_saved(ti):
                return
            self.codegen_path = String(self.wins[ti].path)
        if self.aux_job.active:
            self.say("Background format/codegen job is already running")
            return
        var path = self.codegen_path
        var emit_kind = "asm" if self.codegen_mode == CG_ASM else "llvm"
        var ext = ".s" if self.codegen_mode == CG_ASM else ".ll"
        var out_file = env_or("TMPDIR", "/tmp") + "/turbomojo-codegen-" + String(own_pid()) + ext
        self.codegen_out_file = out_file
        var dir = dirname(path)
        var inner = "cd " + shell_quote(dir) + " && exec " + self.mojo_for(path) + " build --debug-level=line-tables --emit=" + emit_kind + self.include_flags_for(path) + " " + shell_quote(path) + " -o " + shell_quote(out_file)
        var cmd = self.with_env(path, inner) + " 2>&1"
        var loading = List[String]()
        loading.append("Codegen Inspector: " + basename(path))
        loading.append("Emitting " + emit_kind + " with mojo build --debug-level=line-tables --emit=" + emit_kind + " ...")
        self.codegen_line_map.clear()
        self.codegen_render_lines(loading, True)
        if self.start_aux_job(JOB_CODEGEN, cmd, path, out_file):
            self.say("Emitting " + emit_kind + " for " + basename(path) + "...")

    def finish_codegen(mut self, status: Int):
        var out_file = self.codegen_out_file
        var path = self.codegen_path
        if self.aux_job.cancelled:
            self.codegen_line_map.clear()
            if out_file.byte_length() > 0:
                delete_file(out_file)
            self.say("Codegen cancelled")
            return
        if status != 0 or not path_exists(out_file):
            self.codegen_line_map.clear()
            var err_txt = bytes_to_str(self.aux_job.data)
            var lines = List[String]()
            lines.append("Codegen failed for " + basename(path) + ":")
            lines.append("")
            for l in err_txt.split("\n"):
                lines.append(String(l))
            self.codegen_render_lines(lines, True)
            if out_file.byte_length() > 0:
                delete_file(out_file)
            self.say("Codegen failed - see Codegen pane")
            return
        var raw = read_text(out_file)
        delete_file(out_file)
        var filt = self.codegen_filter
        var corr = parse_asm_with_line_tables(raw, filt) if self.codegen_mode == CG_ASM else parse_llvm_with_line_tables(raw, filt)
        var summary = CodegenSummary(corr.rendered_lines.copy(), corr.simd_ops, corr.spill_ops, corr.total_insns)
        var rendered = format_codegen_header(basename(path), self.codegen_mode, summary, filt)
        var lmap = List[Int]()
        if len(corr.rendered_lines) > 0:
            var header_rows = len(rendered) - len(corr.rendered_lines)
            for _ in range(header_rows):
                lmap.append(0)
            for src_ln in corr.line_map:
                lmap.append(src_ln)
        else:
            for _ in range(len(rendered)):
                lmap.append(0)
        self.codegen_line_map = lmap^
        self.codegen_render_lines(rendered, True)
        self.apply_codegen_badges(path, raw, self.codegen_mode)
        var ei_now = self.find_editor(path)
        if ei_now >= 0:
            var init_matches = find_codegen_rows_for_source(self.codegen_line_map, self.wins[ei_now].cr + 1)
            if len(init_matches) > 0:
                var ci_now = self.codegen_index()
                if ci_now >= 0:
                    self.wins[ci_now].cr = init_matches[0]
                    self.wins[ci_now].follow = True
                    self.codegen_sync_row = self.wins[ei_now].cr
                    self.codegen_sync_cg_row = init_matches[0]
        self.say("Codegen ready: " + String(summary.simd_ops) + " SIMD ops, " + String(summary.spill_ops) + " spills")

    def codegen_key(mut self, k: Int) raises -> Bool:
        if k == 97 or k == 65:          # a / A -> ASM
            if self.codegen_mode != CG_ASM:
                self.codegen_mode = CG_ASM
                self.codegen_refresh()
            return True
        if k == 108 or k == 76:         # l / L -> LLVM IR
            if self.codegen_mode != CG_LLVM:
                self.codegen_mode = CG_LLVM
                self.codegen_refresh()
            return True
        if k == 114 or k == 82:         # r / R -> refresh
            self.codegen_refresh()
            return True
        if k == 102 or k == 70:         # f / F -> toggle filter to enclosing def
            if self.codegen_filter.byte_length() > 0:
                self.codegen_filter = ""
                self.codegen_refresh()
                return True
            var ei = self.find_editor(self.codegen_path)
            if ei < 0:
                ei = self.top_editor()
            if ei >= 0:
                var items = scan_outline(self.wins[ei].buf)
                var sp = scope_path(items, self.wins[ei].cr)
                var fn_name = String("")
                var si = len(sp) - 1
                while si >= 0:
                    var idx = sp[si]
                    if items[idx].kind == SK_FUNCTION or items[idx].kind == SK_METHOD:
                        fn_name = items[idx].name
                        break
                    si -= 1
                if fn_name.byte_length() == 0:
                    var cur_idx = outline_current(items, self.wins[ei].cr)
                    if cur_idx >= 0 and (items[cur_idx].kind == SK_FUNCTION or items[cur_idx].kind == SK_METHOD):
                        fn_name = items[cur_idx].name
                if fn_name.byte_length() > 0:
                    self.codegen_filter = fn_name
                    self.codegen_refresh()
                else:
                    self.say("No enclosing def found at editor cursor")
            return True
        if k == KEY_ENTER:              # Enter -> jump to mapped source line in WK_EDITOR
            var ci = self.codegen_index()
            if ci >= 0:
                var row = self.wins[ci].cr
                if row >= 0 and row < len(self.codegen_line_map):
                    var src_line = self.codegen_line_map[row]
                    if src_line > 0:
                        var cg_path = String(self.codegen_path)
                        var ei = self.find_editor(cg_path)
                        if ei < 0 and cg_path.byte_length() > 0 and path_exists(cg_path):
                            self.jump_mark()
                            self.open_path(cg_path)
                            ei = self.find_editor(cg_path)
                        if ei < 0:
                            ei = self.top_editor()
                        if ei >= 0:
                            self.jump_mark()
                            self.focus(ei)
                            var t = self.top()
                            var target_row = max(0, min(src_line - 1, self.wins[t].buf.count() - 1))
                            self.wins[t].goto(target_row, 0)
                            var msg = basename(self.wins[t].path) + ":" + String(src_line)
                            self.say(msg)
            return True
        if k == KEY_ESC:
            var ci = self.codegen_index()
            if ci >= 0:
                _ = self.wins.pop(ci)
                self.layout_sync()
            return True
        return False

    # ======================================================= std.benchmark (F08)
    def bench_run(mut self) raises:
        """Run `std.benchmark` with `-O3` on the active Mojo benchmark file via `aux_job`."""
        var i = self.top_editor()
        if i < 0:
            self.info("Run std.benchmark", "Open a Mojo benchmark file first.")
            return
        var src = to_str(self.wins[i].buf.all_text())
        if not is_bench_source(src):
            self.info("Run std.benchmark", "No std.benchmark imports or `def bench_*` functions found in " + self.wins[i].title + ".")
            return
        if not self.ensure_saved(i):
            return
        if self.aux_job.active:
            self.say("Background job is already running")
            return
        var path = String(self.wins[i].path)
        var dir = dirname(path)
        var bench_cli = build_benchmark_cli_command(path)
        var mojo_bin = self.mojo_for(path)
        var inc = self.include_flags_for(path)
        if mojo_bin != "mojo" or inc.byte_length() > 0:
            bench_cli = mojo_bin + " run -O3" + inc + " " + shell_quote(path)
        var inner = "cd " + shell_quote(dir) + " && exec " + bench_cli
        var cmd = self.with_env(path, inner) + " 2>&1"
        if self.start_aux_job(JOB_BENCH, cmd, path, ""):
            self.say("Running std.benchmark (-O3) on " + basename(path) + "...")

    def finish_bench_job(mut self, status: Int):
        """Parse `std.benchmark` output, diff against baseline, badge editor lines, and summarize."""
        var path = String(self.aux_job.path)
        if self.aux_job.cancelled:
            self.say("Benchmark cancelled")
            return
        var out_txt = bytes_to_str(self.aux_job.data)
        if status != 0:
            self.panel_write(PG_MESSAGE)
            _ = self.fill_messages("std.benchmark (-O3) - " + basename(path), self.aux_job.data.copy(), "Benchmark failed (exit " + String(status >> 8) + ")")
            self.say("Benchmark failed - see Message window")
            return
        var items = parse_std_benchmark_output(out_txt)
        var base_json = self.bench_baseline_json
        if base_json.byte_length() == 0:
            var base_path = join_path(state_dir(), "bench_baseline.json")
            if path_exists(base_path):
                base_json = read_text(base_path)
        var base_items = deserialize_bench_baseline(base_json)

        var diffs = List[BenchmarkDiff]()
        var speedups = 0
        var regressions = 0
        for item in items:
            var matched_base = BenchmarkItem(item.name, 0.0, 0)
            for b in base_items:
                if b.name == item.name:
                    matched_base = b.copy()
                    break
            var d = compute_bench_diff(item, matched_base)
            if d.is_speedup:
                speedups += 1
            if d.is_regression:
                regressions += 1
            diffs.append(d^)

        var ei = self.find_editor(path)
        if ei < 0 and path.byte_length() == 0:
            ei = self.top_editor()
        if ei >= 0:
            var fn_locs = find_bench_functions(to_str(self.wins[ei].buf.all_text()))
            var badge_rows = List[Int]()
            var badges = List[String]()
            for loc in fn_locs:
                var fn_name = loc[0]
                var line_1based = loc[1]
                for d in diffs:
                    if d.name == fn_name or d.name.find(fn_name) >= 0 or fn_name.find(d.name) >= 0:
                        badge_rows.append(max(0, line_1based - 1))
                        badges.append(format_bench_badge(d))
                        break
            self.wins[ei].bench_badge_rows = badge_rows^
            self.wins[ei].bench_badges = badges^

        var report = List[String]()
        if len(diffs) > 0:
            report.append("=== Benchmark Summary ===")
            for d in diffs:
                var tag = "  [✓ SPEEDUP]" if d.is_speedup else ("  [⚠ REGRESSION]" if d.is_regression else String(""))
                report.append("  • " + pad_right(d.name, 26) + format_bench_badge(d) + tag)
            report.append("")
        if out_txt.byte_length() > 0:
            report.append(out_txt)
        var footer = "Benchmarked " + String(len(items)) + " function(s)"
        if speedups > 0 or regressions > 0:
            footer += " (" + String(speedups) + " speedup, " + String(regressions) + " regression)"
        self.panel_write(PG_MESSAGE)
        _ = self.fill_messages("std.benchmark (-O3) - " + basename(path), str_bytes("\n".join(report)), footer)
        self.say(footer)

    def bench_save_baseline(mut self):
        """Save latest `std.benchmark` results as the comparison baseline."""
        var items = parse_std_benchmark_output(bytes_to_str(self.aux_job.data))
        if len(items) == 0:
            var mi = self.msg_index()
            if mi >= 0:
                items = parse_std_benchmark_output(to_str(self.wins[mi].buf.all_text()))
        if len(items) > 0:
            self.bench_baseline_json = serialize_bench_baseline(items)
        if self.bench_baseline_json.byte_length() == 0:
            self.say("No benchmark results to save - run std.benchmark first")
            return
        var bpath = join_path(state_dir(), "bench_baseline.json")
        if not path_exists(dirname(bpath)):
            _ = run_system("mkdir -p " + shell_quote(dirname(bpath)))
        _ = write_file(bpath, str_bytes(self.bench_baseline_json))
        var count = len(deserialize_bench_baseline(self.bench_baseline_json))
        self.say("Saved benchmark baseline (" + String(count) + " benchmark(s))")

    # ======================================================= MAX benchmark JSON (F10)
    def max_bench_run(mut self, raw_cmd: String = ""):
        """Run `max benchmark` with `--result-filename` JSON capture via `JOB_MAX_BENCH`."""
        if self.job_busy():
            return
        var out_json = env_or("TMPDIR", "/tmp") + "/turbomojo-max-bench-" + String(own_pid()) + ".json"
        self.max_bench_out_file = out_json
        var model = self.max_model_args if self.max_model_args.byte_length() > 0 else String("modularai/Llama-3.1-8B-Instruct-GGUF")
        var base_cmd = raw_cmd if raw_cmd.byte_length() > 0 else ("max benchmark --model " + shell_quote(model))
        var full_cmd = inject_max_benchmark_output_flag(base_cmd, shell_quote(out_json))
        var root = self.symidx_root()
        var inner = "cd " + shell_quote(root) + " && " + full_cmd
        var cmd = self.with_env(root, inner) + " 2>&1 </dev/null"
        if self.start_job(JOB_MAX_BENCH, cmd, root, out_json):
            self.panel_write(PG_MESSAGE)
            _ = self.fill_messages("MAX Benchmark - " + model, List[UInt8](), "Running max benchmark...")
            self.say("Running max benchmark - Ctrl-F2 cancels")

    def finish_max_bench(mut self, status: Int):
        """Parse captured `max benchmark` JSON output and render comparison table against baseline."""
        var out_json = self.max_bench_out_file
        if out_json.byte_length() == 0:
            out_json = self.job.exe
        if self.job.cancelled:
            if out_json.byte_length() > 0:
                delete_file(out_json)
            self.say("MAX benchmark cancelled")
            return
        var json_text = read_text(out_json) if (out_json.byte_length() > 0 and path_exists(out_json)) else String("")
        if out_json.byte_length() > 0:
            delete_file(out_json)
        if status != 0 and json_text.byte_length() == 0:
            self.panel_write(PG_MESSAGE)
            _ = self.fill_messages("MAX Benchmark", self.job.data.copy(), "MAX benchmark failed (exit " + String(status >> 8) + ")")
            self.say("MAX benchmark failed - see Message window")
            return
        var curr = parse_max_benchmark_json(json_text)
        var base_json = self.max_baseline_json
        if base_json.byte_length() == 0:
            var base_path = join_path(state_dir(), "max_bench_baseline.json")
            if path_exists(base_path):
                base_json = read_text(base_path)
        var base = parse_max_benchmark_json(base_json)
        var model_label = curr.model if curr.model.byte_length() > 0 else self.max_model_args
        var diffs = diff_max_benchmark(curr, base)
        var table = format_max_diff_table(diffs, model_label)
        var raw_out = bytes_to_str(self.job.data)
        if raw_out.byte_length() > 0:
            table.append("")
            table.append(raw_out)
        if self.max_baseline_json.byte_length() == 0 and json_text.byte_length() > 0:
            self.max_baseline_json = json_text
        self.panel_write(PG_MESSAGE)
        _ = self.fill_messages("MAX Benchmark - " + model_label, str_bytes("\n".join(table)), "MAX benchmark finished")
        self.say("MAX benchmark ready for " + model_label)

    def max_bench_save_baseline(mut self):
        """Persist `self.max_baseline_json` as the saved MAX benchmark baseline."""
        if self.max_baseline_json.byte_length() == 0:
            self.say("No MAX benchmark JSON to save")
            return
        var bpath = join_path(state_dir(), "max_bench_baseline.json")
        if not path_exists(dirname(bpath)):
            _ = run_system("mkdir -p " + shell_quote(dirname(bpath)))
        _ = write_file(bpath, str_bytes(self.max_baseline_json))
        self.say("Saved MAX benchmark baseline")

    # ======================================================= GPU profilers & roofline (F09)
    def gpu_profile_command(mut self) raises:
        """Compile > Profile GPU kernels: wrap `nsys profile --stats=true` (NVIDIA) or
        `rocprofv3 --kernel-trace --stats` (AMD) on the active Mojo file into the Message pane."""
        if self.job_busy():
            return
        var i = self.top_editor()
        if i < 0:
            self.info("Profile GPU Kernels", "Open a Mojo file first.")
            return
        if not self.ensure_saved(i):
            return
        var path = String(self.wins[i].path)
        var nsys = which("nsys")
        var rocprof = which("rocprofv3")
        if rocprof.byte_length() == 0:
            rocprof = which("rocprof")
        var sanitizer = which("compute-sanitizer")
        if nsys.byte_length() == 0 and rocprof.byte_length() == 0 and sanitizer.byte_length() == 0:
            self.info("Profile GPU Kernels", "None of `nsys` (Nsight Systems), `rocprofv3` (ROCm), or `compute-sanitizer` was found on PATH.")
            return
        var dir = dirname(path)
        var exe = join_path(dir, "build/" + stem(path))
        var prof_out = env_or("TMPDIR", "/tmp") + "/turbomojo-prof-" + String(own_pid())
        var prof_cmd: String
        var tool_name: String
        if nsys.byte_length() > 0:
            tool_name = "nsys"
            prof_cmd = shell_quote(nsys) + " profile --stats=true --force-overwrite=true -o " + shell_quote(prof_out) + " " + shell_quote(exe) + "; st=$?; rm -f " + shell_quote(prof_out) + "* 2>/dev/null; exit $st"
        elif rocprof.byte_length() > 0:
            tool_name = basename(rocprof)
            if tool_name == "rocprofv3":
                prof_cmd = shell_quote(rocprof) + " --kernel-trace --stats -- " + shell_quote(exe)
            else:
                prof_cmd = shell_quote(rocprof) + " --stats " + shell_quote(exe)
        else:
            tool_name = "compute-sanitizer"
            prof_cmd = shell_quote(sanitizer) + " --tool memcheck " + shell_quote(exe)
        var inner = "cd " + shell_quote(dir) + " && mkdir -p build && " + self.mojo_for(path) + " build" + self.include_flags_for(path) + " " + shell_quote(path) + " -o " + shell_quote(exe) + " && " + prof_cmd
        var cmd = self.with_env(path, inner) + " 2>&1 </dev/null"
        if self.start_job(JOB_TASK, cmd, dir, "profile:" + tool_name):
            self.task_output("Building & profiling GPU kernels with " + tool_name + "...")
            self.say("Profiling " + basename(path) + " with " + tool_name + " - Ctrl-F2 cancels")

    def gpu_roofline_run(mut self) raises:
        """Single-kernel GPU roofline deep dive using `ncu` (NVIDIA) or `rocprofv3` (AMD)."""
        if self.job_busy():
            return
        var i = self.top_editor()
        if i < 0:
            self.info("GPU Kernel Roofline", "Open a Mojo GPU file first.")
            return
        if not self.ensure_saved(i):
            return
        var ncu = which("ncu")
        var rocprof = which("rocprofv3")
        if ncu.byte_length() == 0 and rocprof.byte_length() == 0:
            self.info("GPU Kernel Roofline", "Neither `ncu` (Nsight Compute) nor `rocprofv3` (ROCm) was found on PATH.")
            return
        var path = String(self.wins[i].path)
        var dir = dirname(path)
        var exe = join_path(dir, "build/" + stem(path))
        var out_csv = env_or("TMPDIR", "/tmp") + "/turbomojo-roofline-" + String(own_pid()) + ".csv"
        var tool_name = "ncu" if ncu.byte_length() > 0 else "rocprofv3"
        var mojo_bin = self.mojo_for(path) + self.include_flags_for(path)
        var roof_cmd = build_roofline_cli_command(tool_name, mojo_bin, path, exe, out_csv)
        var src_step = (" && { ncu --csv --page source " + shell_quote(exe) + " > " + shell_quote(out_csv + ".src") + " 2>/dev/null || true; }") if tool_name == "ncu" else String("")
        var inner = "cd " + shell_quote(dir) + " && mkdir -p build && (" + roof_cmd + ")" + src_step
        var cmd = self.with_env(path, inner) + " 2>&1 </dev/null"
        if self.start_job(JOB_ROOFLINE, cmd, path, out_csv):
            self.panel_write(PG_MESSAGE)
            _ = self.fill_messages("GPU Kernel Roofline (" + tool_name + ") - " + basename(path), List[UInt8](), "Profiling kernel roofline...")
            self.say("Profiling GPU roofline for " + basename(path) + " with " + tool_name + " - Ctrl-F2 cancels")

    def finish_gpu_roofline(mut self, status: Int):
        """Parse `ncu` / `rocprofv3` roofline CSV output, check permissions, and display report."""
        var use_aux = self.aux_job.kind == JOB_ROOFLINE and self.job.kind != JOB_ROOFLINE
        var path = String(self.aux_job.path) if use_aux else String(self.job.path)
        var out_csv = String(self.aux_job.exe) if use_aux else String(self.job.exe)
        var cancelled = self.aux_job.cancelled if use_aux else self.job.cancelled
        var raw_stderr = bytes_to_str(self.aux_job.data) if use_aux else bytes_to_str(self.job.data)

        var csv_text = read_text(out_csv) if (out_csv.byte_length() > 0 and path_exists(out_csv)) else String("")
        var src_csv = out_csv + ".src"
        var src_csv_text = read_text(src_csv) if (out_csv.byte_length() > 0 and path_exists(src_csv)) else String("")
        if out_csv.byte_length() > 0:
            delete_file(out_csv)
            delete_file(src_csv)

        if cancelled:
            self.say("GPU roofline profiling cancelled")
            return

        var perm_msg = check_profiler_permissions(raw_stderr + "\n" + csv_text)
        if perm_msg.byte_length() > 0:
            var err_body = perm_msg + ("\n\n" + raw_stderr if raw_stderr.byte_length() > 0 else String(""))
            self.panel_write(PG_MESSAGE)
            _ = self.fill_messages("GPU Kernel Roofline - " + basename(path), str_bytes(err_body), "Permission denied")
            self.say(perm_msg)
            return

        var kernels = parse_ncu_csv_output(csv_text if csv_text.byte_length() > 0 else raw_stderr)
        var stalls = parse_ncu_source_stall_lines(src_csv_text)
        var ei = self.find_editor(path)
        if ei < 0:
            ei = self.top_editor()
        if ei >= 0 and len(stalls) > 0:
            stalls = filter_valid_source_stall_lines(stalls, self.wins[ei].buf.count())

        if len(kernels) == 0 and status != 0:
            self.panel_write(PG_MESSAGE)
            _ = self.fill_messages("GPU Kernel Roofline - " + basename(path), str_bytes(raw_stderr), "Roofline profiling failed (exit " + String(status >> 8) + ")")
            self.say("GPU roofline failed - see Message window")
            return

        var lines = List[String]()
        for k in kernels:
            for rline in format_roofline_report(k):
                lines.append(rline)
            lines.append("")
        if len(stalls) > 0:
            lines.append("Source Line Stall Attribution:")
            for st in stalls:
                lines.append("  " + basename(path) + ":" + String(st[0]) + ":1: stall " + st[1] + " (" + String(Int(st[2])) + ")")
            lines.append("")
        if len(kernels) == 0 and raw_stderr.byte_length() > 0:
            lines.append(raw_stderr)

        var summary_msg = (
            "GPU roofline: " + kernels[0].kernel_name + " [" + kernels[0].bound_classification + "]"
        ) if len(kernels) > 0 else String("GPU roofline finished (no kernel metrics reported)")
        self.panel_write(PG_MESSAGE)
        _ = self.fill_messages("GPU Kernel Roofline - " + basename(path), str_bytes("\n".join(lines)), summary_msg)
        self.say(summary_msg)
