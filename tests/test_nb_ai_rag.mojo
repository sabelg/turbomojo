"""Unit tests for `src/nb_ai_rag.mojo`.

Covers:
1. Multimodal Notebook AI Context & Vision Payload Builder (`NotebookAiContext`, `NotebookCellDigest`)
2. Isolated Git-Worktree Background Task Runner (`WorktreeTask`, `WorktreeFilePatch`)
3. Hybrid `mojocst` CST + Okapi BM25 Semantic Codebase Search (`SemanticCodeIndex`)
"""
from std.collections import List
from std.testing import assert_equal, assert_false, assert_true, TestSuite
from buffer import TextBuffer
from json import J_ARR, J_OBJ, J_STR, json_parse
from nb_ai_rag import (
    NotebookAiContext,
    NotebookCellDigest,
    SemanticChunk,
    SemanticCodeIndex,
    SemanticHit,
    WorktreeFilePatch,
    WorktreeTask,
    build_multimodal_openai_request_json,
    build_notebook_ai_context,
    cleanup_isolated_worktree,
    collect_worktree_patches,
    create_isolated_worktree,
    format_notebook_ipc_json,
    resolve_plot_spec_png,
    split_code_subtokens,
    summarize_notebook_cells,
    verify_worktree_mojo_file,
)
from signals import own_pid
from util import (
    base64,
    bytes_to_str,
    decode,
    env_or,
    is_dir,
    join_path,
    path_exists,
    read_file,
    run_capture,
    shell_quote,
    str_bytes,
    write_file,
)


def _tiny_png_bytes(seed: Int) -> List[UInt8]:
    """Minimal valid 8-byte PNG signature + deterministic payload chunk for base64 tests."""
    var out = List[UInt8]()
    for b in [137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82]:
        out.append(UInt8(b))
    out.append(UInt8(seed & 255))
    return out^


def test_notebook_ai_context_and_vision_payload() raises:
    var tmp_dir = env_or("TMPDIR", "/tmp") + "/turbomojo-test-nb-ai-" + String(own_pid())
    _ = run_capture("rm -rf " + shell_quote(tmp_dir) + " && mkdir -p " + shell_quote(tmp_dir))

    var png_plot = join_path(tmp_dir, "loss_curve.png")
    var f0 = join_path(tmp_dir, "anim_0.png")
    var f1 = join_path(tmp_dir, "anim_1.png")
    var f2 = join_path(tmp_dir, "anim_2.png")
    var plot_bytes = _tiny_png_bytes(42)
    var f1_bytes = _tiny_png_bytes(99)
    assert_true(write_file(png_plot, plot_bytes))
    assert_true(write_file(f0, _tiny_png_bytes(10)))
    assert_true(write_file(f1, f1_bytes))
    assert_true(write_file(f2, _tiny_png_bytes(20)))

    var anim_spec = "ANIM|16|" + f0 + "|" + f1 + "|" + f2
    assert_equal(resolve_plot_spec_png(anim_spec), f1)
    assert_equal(resolve_plot_spec_png(png_plot), png_plot)

    var nb_src = (
        "# %% [markdown]\n"
        "# # Model Training Notebook\n"
        "# %% Setup & Model\n"
        "from std.collections import List\n"
        "comptime HIDDEN_DIM = 128\n"
        "struct LayerConfig(Copyable, Movable):\n"
        "    var dim: Int\n"
        "def scale_weights(x: Float64) -> Float64:\n"
        "    return x * 0.5\n"
        "var lr = 0.001\n"
        "# %% Plot & Tensor Inspection\n"
        "var logits = compute_logits()\n"
        "# %% Active Failing Cell\n"
        "var bad = logits / 0.0\n"
    )
    var buf = TextBuffer()
    buf.load(decode(nb_src))

    var outputs = List[String]()
    outputs.append("")
    outputs.append("df: [DataFrame 256×4 · cols: step(int64), loss(float32) · 0 null]")
    outputs.append("__TM_CARD__ logits: [Tensor float32[32, 128] · cuda:0 · min=-1.2 max=2.4 mean=0.01 · 0 NaN]")
    outputs.append(
        "Traceback (most recent call last):\n"
        "  File \"<cell>\", line 14, in <module>\n"
        "ZeroDivisionError: float division by zero"
    )

    var plots = List[List[String]]()
    plots.append(List[String]())
    plots.append(List[String]())
    var c2_plots = List[String]()
    c2_plots.append(png_plot)
    c2_plots.append(anim_spec)
    plots.append(c2_plots^)
    plots.append(List[String]())

    var digests = summarize_notebook_cells(buf, outputs, plots)
    assert_equal(len(digests), 4)
    assert_true(digests[0].is_markdown)
    assert_false(digests[1].is_markdown)
    assert_equal(len(digests[2].plot_png_paths), 2)
    assert_equal(digests[2].plot_png_paths[0], png_plot)
    assert_equal(digests[2].plot_png_paths[1], f1)
    assert_true(digests[3].has_error)

    # Cursor at row 13 (inside Cell 3: `# %% Active Failing Cell`)
    # Active cell has 0 plots, so immediately preceding cell's plot + ANIM middle frame are attached!
    var ctx = build_notebook_ai_context(buf, 13, outputs, plots, max_images=2)
    assert_equal(ctx.active_cell_index, 3)
    assert_true(ctx.preceding_defs_summary.find("from std.collections import List") >= 0)
    assert_true(ctx.preceding_defs_summary.find("comptime HIDDEN_DIM = 128") >= 0)
    assert_true(ctx.preceding_defs_summary.find("struct LayerConfig") >= 0)
    assert_true(ctx.preceding_defs_summary.find("def scale_weights") >= 0)
    assert_true(ctx.preceding_defs_summary.find("var lr = 0.001") >= 0)

    assert_equal(len(ctx.live_schemas), 2)
    assert_true(ctx.live_schemas[0].find("[DataFrame 256×4") >= 0)
    assert_true(ctx.live_schemas[1].find("[Tensor float32[32, 128]") >= 0)
    assert_true(ctx.last_error.find("ZeroDivisionError: float division by zero") >= 0)

    assert_equal(len(ctx.attached_png_paths), 2)
    assert_equal(ctx.attached_png_paths[0], png_plot)
    assert_equal(ctx.attached_png_paths[1], f1)
    assert_equal(len(ctx.attached_png_b64), 2)
    assert_equal(ctx.attached_png_b64[0], base64(plot_bytes))
    assert_equal(ctx.attached_png_b64[1], base64(f1_bytes))
    assert_true(ctx.prompt_block.find("Live Kernel Schemas") >= 0)
    assert_true(ctx.prompt_block.find("ZeroDivisionError") >= 0)

    # Verify OpenAI text-only request JSON
    var empty_imgs = List[String]()
    var txt_req = build_multimodal_openai_request_json(
        "qwen2.5-coder",
        "System rules",
        ctx.prompt_block,
        empty_imgs,
        0.1,
    )
    var txt_doc = json_parse(txt_req)
    assert_true(txt_doc.ok, txt_doc.error)
    assert_equal(txt_doc.str(txt_doc.get(0, "model")), "qwen2.5-coder")
    assert_equal(txt_doc.kind(txt_doc.path(0, "messages/1/content")), J_STR)
    assert_equal(txt_doc.str(txt_doc.path(0, "messages/1/content")), ctx.prompt_block)

    # Verify OpenAI multimodal vision request JSON
    var mm_req = build_multimodal_openai_request_json(
        "gpt-4o",
        "Vision system prompt",
        "Inspect these plots",
        ctx.attached_png_b64,
        0.2,
    )
    var mm_doc = json_parse(mm_req)
    assert_true(mm_doc.ok, mm_doc.error)
    var content_arr = mm_doc.path(0, "messages/1/content")
    assert_equal(mm_doc.kind(content_arr), J_ARR)
    assert_equal(mm_doc.size(content_arr), 3)
    assert_equal(mm_doc.str(mm_doc.path(content_arr, "0/type")), "text")
    assert_equal(mm_doc.str(mm_doc.path(content_arr, "0/text")), "Inspect these plots")
    assert_equal(mm_doc.str(mm_doc.path(content_arr, "1/type")), "image_url")
    assert_equal(
        mm_doc.str(mm_doc.path(content_arr, "1/image_url/url")),
        "data:image/png;base64," + base64(plot_bytes),
    )
    assert_equal(
        mm_doc.str(mm_doc.path(content_arr, "2/image_url/url")),
        "data:image/png;base64," + base64(f1_bytes),
    )

    # Verify IPC JSON serialization
    var ipc_json = format_notebook_ipc_json(ctx)
    var ipc_doc = json_parse(ipc_json)
    assert_true(ipc_doc.ok, ipc_doc.error)
    assert_equal(ipc_doc.kind(0), J_OBJ)
    assert_equal(ipc_doc.int(ipc_doc.get(0, "active_cell_index")), 3)
    assert_true(ipc_doc.bool(ipc_doc.get(0, "has_error")))
    assert_equal(ipc_doc.int(ipc_doc.get(0, "attached_image_count")), 2)
    assert_equal(ipc_doc.size(ipc_doc.get(0, "live_schemas")), 2)

    _ = run_capture("rm -rf " + shell_quote(tmp_dir))


def test_isolated_git_worktree_lifecycle() raises:
    var repo_dir = env_or("TMPDIR", "/tmp") + "/turbomojo-test-wt-repo-" + String(own_pid())
    _ = run_capture("rm -rf " + shell_quote(repo_dir) + " && mkdir -p " + shell_quote(repo_dir + "/src"))

    var orig_mojo = (
        "\"\"\"Sample module.\"\"\"\n\n"
        "def add_vals(a: Int, b: Int) -> Int:\n"
        "    return a + b\n"
    )
    assert_true(write_file(repo_dir + "/src/math_ops.mojo", str_bytes(orig_mojo)))

    var init_res = run_capture(
        "git -C "
        + shell_quote(repo_dir)
        + " init -q && git -C "
        + shell_quote(repo_dir)
        + " config user.email 'test@turbomojo.local' && git -C "
        + shell_quote(repo_dir)
        + " config user.name 'TurboMojo Test' && git -C "
        + shell_quote(repo_dir)
        + " add . && git -C "
        + shell_quote(repo_dir)
        + " commit -q -m 'initial'"
    )
    assert_equal(init_res.status, 0)

    var created = create_isolated_worktree(repo_dir, 7)
    assert_true(created[0], created[2])
    var wt_dir = created[1]
    assert_true(wt_dir.startswith("/tmp/turbomojo-wt-"))
    assert_true(is_dir(wt_dir))

    var task = WorktreeTask(
        7,
        repo_dir,
        wt_dir,
        "Add multiply helper",
        True,
        False,
        "",
    )
    assert_equal(task.id, 7)
    assert_true(task.active)

    # Edit tracked file AND create new untracked file inside isolated worktree
    var updated_mojo = (
        "\"\"\"Sample module.\"\"\"\n\n"
        "def add_vals(a: Int, b: Int) -> Int:\n"
        "    return a + b\n\n"
        "def mul_vals(a: Int, b: Int) -> Int:\n"
        "    return a * b\n"
    )
    var new_mojo = (
        "\"\"\"Extra module.\"\"\"\n"
        "from math_ops import mul_vals\n\n"
        "def square_val(x: Int) -> Int:\n"
        "    return mul_vals(x, x)\n"
    )
    assert_true(write_file(wt_dir + "/src/math_ops.mojo", str_bytes(updated_mojo)))
    assert_true(write_file(wt_dir + "/src/extra_ops.mojo", str_bytes(new_mojo)))

    # Main working tree MUST remain completely untouched
    var live_main_content = bytes_to_str(read_file(repo_dir + "/src/math_ops.mojo"))
    assert_equal(live_main_content, orig_mojo)
    assert_false(path_exists(repo_dir + "/src/extra_ops.mojo"))

    # Shadow-compile inside the isolated worktree using the local Mojo 1.2 binary
    var mojo_bin = "/home/user/turbomojo/.pixi/envs/default/bin/mojo"
    if path_exists(mojo_bin):
        var v_ok = verify_worktree_mojo_file(wt_dir, "src/extra_ops.mojo", mojo_bin)
        assert_true(v_ok[0], v_ok[1])

        # Also verify compiler catches invalid syntax inside worktree without touching repo_dir
        assert_true(
            write_file(
                wt_dir + "/src/broken.mojo",
                str_bytes("def bad_syntax(x: Int) -> Int:\n    return unknown_symbol_xyz\n"),
            )
        )
        var v_bad = verify_worktree_mojo_file(wt_dir, "src/broken.mojo", mojo_bin)
        assert_false(v_bad[0])
        assert_true(v_bad[1].find("unknown_symbol_xyz") >= 0, v_bad[1])
        _ = run_capture("rm -f " + shell_quote(wt_dir + "/src/broken.mojo"))

    var patches = collect_worktree_patches(repo_dir, wt_dir)
    assert_equal(len(patches), 2)

    var found_modified = False
    var found_added = False
    for i in range(len(patches)):
        var p = patches[i].copy()
        if p.rel_path == "src/math_ops.mojo":
            found_modified = True
            assert_equal(p.orig_content, orig_mojo)
            assert_equal(p.new_content, updated_mojo)
            assert_true(p.unified_diff.find("+def mul_vals") >= 0, p.unified_diff)
        elif p.rel_path == "src/extra_ops.mojo":
            found_added = True
            assert_equal(p.orig_content, "")
            assert_equal(p.new_content, new_mojo)
            assert_true(p.unified_diff.find("+def square_val") >= 0, p.unified_diff)
    assert_true(found_modified)
    assert_true(found_added)

    # Guard rails & cleanup
    assert_false(cleanup_isolated_worktree(repo_dir, repo_dir))
    assert_false(cleanup_isolated_worktree(repo_dir, "/"))
    assert_true(cleanup_isolated_worktree(repo_dir, wt_dir))
    assert_false(path_exists(wt_dir))

    _ = run_capture("rm -rf " + shell_quote(repo_dir))


def test_subtoken_splitting_and_semantic_bm25_index() raises:
    var t1 = split_code_subtokens("parseIpynbCell")
    assert_equal(len(t1), 3)
    assert_equal(t1[0], "parse")
    assert_equal(t1[1], "ipynb")
    assert_equal(t1[2], "cell")

    var t2 = split_code_subtokens("def decode_PNGImages24(self, var the_input: String) -> Bool")
    # Stop-words `def`, `self`, `var`, `the`, `string`, `bool` and digits `24` are stripped!
    var joined2 = "|".join(t2)
    assert_equal(joined2, "decode|png|images|input")

    var idx = SemanticCodeIndex()
    idx.index_file_text(
        "src/image_codec.mojo",
        (
            "\"\"\"Image codecs.\"\"\"\n\n"
            "@fieldwise_init\n"
            "struct PngHeader(Copyable, Movable):\n"
            "    var width_px: Int\n"
            "    var height_px: Int\n"
            "    var color_channels: Int\n\n"
            "def decode_png_image(raw_bytes: List[UInt8]) -> PngHeader:\n"
            "    \"\"\"Inflate IDAT chunks and decode PNG scanline filters into RGBA pixels.\"\"\"\n"
            "    return PngHeader(64, 64, 4)\n\n"
            "def encode_bmp_thumbnail(raw_bytes: List[UInt8]) -> Bool:\n"
            "    return False\n"
        ),
    )
    idx.index_file_text(
        "src/gpu_shmem.mojo",
        (
            "\"\"\"GPU kernel layout analyzer.\"\"\"\n\n"
            "trait TileLayoutCheck:\n"
            "    def has_conflict(self) -> Bool: ...\n\n"
            "def analyze_shared_memory_tiling(stride: Int) -> Int:\n"
            "    \"\"\"Detect warp bank conflict stalls across shared memory swizzle lanes.\"\"\"\n"
            "    var bank_conflict_count = stride % 32\n"
            "    return bank_conflict_count\n"
        ),
    )
    idx.index_file_text(
        "src/router.mojo",
        (
            "\"\"\"HTTP JSON helpers.\"\"\"\n\n"
            "def dispatch_json_rpc(method_name: String) -> Int:\n"
            "    return 200\n"
        ),
    )

    assert_true(len(idx.chunks) >= 5)
    assert_true(idx.total_tokens > 20)

    # Natural-language query #1: plural `images` matches `decode_png_image` via symbol 3.0x boost
    var q_png = idx.search("where do we decode png images", top_k=5)
    assert_true(len(q_png) >= 1)
    assert_equal(q_png[0].path, "src/image_codec.mojo")
    assert_equal(q_png[0].symbol_name, "decode_png_image")
    assert_equal(q_png[0].kind, "def")
    assert_true(q_png[0].score_x100 > 0)

    # Natural-language query #2: docstring + body terms (`bank conflict shared memory`)
    var q_gpu = idx.search("bank conflict shared memory", top_k=5)
    assert_true(len(q_gpu) >= 1)
    assert_equal(q_gpu[0].path, "src/gpu_shmem.mojo")
    assert_equal(q_gpu[0].symbol_name, "analyze_shared_memory_tiling")

    # Struct field query: `width_px color_channels` matches `PngHeader` struct
    var q_struct = idx.search("PngHeader color channels width", top_k=5)
    assert_true(len(q_struct) >= 1)
    assert_equal(q_struct[0].symbol_name, "PngHeader")
    assert_equal(q_struct[0].kind, "struct")

    # Re-indexing same file replaces chunks cleanly without leaking duplicate entries
    var count_before = len(idx.chunks)
    idx.index_file_text(
        "src/router.mojo",
        "\"\"\"HTTP JSON helpers.\"\"\"\n\ndef dispatch_json_rpc(method_name: String) -> Int:\n    return 201\n",
    )
    assert_equal(len(idx.chunks), count_before)

    # Verify direct struct construction for SemanticChunk / SemanticHit completeness
    var manual_chunk = SemanticChunk("a.mojo", "foo", "def", 0, 2, "def foo()", split_code_subtokens("foo bar"))
    var manual_hit = SemanticHit(manual_chunk.path, manual_chunk.symbol_name, manual_chunk.kind, 0, 150, "def foo()")
    assert_equal(manual_hit.score_x100, 150)


def test_edge_cases_schema_upsert_and_doc_indexing() raises:
    # 1. Reassigned variable schema card updates in place and `max_images=1` caps attached plots
    var tmp_dir = env_or("TMPDIR", "/tmp") + "/turbomojo-test-nb-edge-" + String(own_pid())
    _ = run_capture("rm -rf " + shell_quote(tmp_dir) + " && mkdir -p " + shell_quote(tmp_dir))
    var p0 = join_path(tmp_dir, "first.png")
    var p1 = join_path(tmp_dir, "second.png")
    assert_true(write_file(p0, _tiny_png_bytes(1)))
    assert_true(write_file(p1, _tiny_png_bytes(2)))

    # ANIM where only frame 0 exists on disk falls back to frame 0 cleanly
    var sparse_anim = "ANIM|24|" + p0 + "|" + join_path(tmp_dir, "missing_mid.png") + "|" + join_path(tmp_dir, "missing_end.png")
    assert_equal(resolve_plot_spec_png(sparse_anim), p0)

    var buf = TextBuffer()
    buf.load(decode("# %% Cell A\nx = make_small()\n# %% Cell B\nx = make_large()\n"))
    var outs = List[String]()
    outs.append("x: [Array float32[4] · min=0.0 max=1.0 mean=0.5 · 0 NaN]")
    outs.append("x: [Polars 1024×6 · cols: ts(i64), price(f64) · 0 null]")
    var plts = List[List[String]]()
    plts.append(List[String]())
    var active_plts = List[String]()
    active_plts.append(sparse_anim)
    active_plts.append(p1)
    plts.append(active_plts^)

    var ctx = build_notebook_ai_context(buf, 3, outs, plts, max_images=1)
    assert_equal(ctx.active_cell_index, 1)
    assert_equal(len(ctx.live_schemas), 1)
    assert_true(ctx.live_schemas[0].find("[Polars 1024×6") >= 0)
    assert_equal(len(ctx.attached_png_paths), 1)
    assert_equal(ctx.attached_png_paths[0], p0)

    # 2. Structural boost check: exact symbol match (3.0x) outranks body-only mention (1.0x)
    var idx = SemanticCodeIndex()
    idx.index_file_text(
        "src/body_only.mojo",
        (
            "\"\"\"Helper.\"\"\"\n\n"
            "def run_pipeline_step(flag: Bool) -> Int:\n"
            "    var quicksort_partition = 1\n"
            "    return quicksort_partition\n"
        ),
    )
    idx.index_file_text(
        "src/sym_match.mojo",
        (
            "\"\"\"Sorting.\"\"\"\n\n"
            "def quicksort_partition(pivot: Int) -> Int:\n"
            "    return pivot\n"
        ),
    )
    idx.index_file_text(
        "docs/architecture.md",
        "# Kernel Telemetry\n\nStreaming Roofline metrics and NVML utilization counters.\n",
    )
    var hits_sort = idx.search("quicksort partition", top_k=5)
    assert_true(len(hits_sort) >= 2)
    assert_equal(hits_sort[0].symbol_name, "quicksort_partition")
    assert_true(hits_sort[0].score_x100 > hits_sort[1].score_x100)

    var hits_doc = idx.search("roofline nvml utilization counters", top_k=5)
    assert_true(len(hits_doc) >= 1)
    assert_equal(hits_doc[0].kind, "doc")
    assert_equal(hits_doc[0].path, "docs/architecture.md")

    _ = run_capture("rm -rf " + shell_quote(tmp_dir))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
