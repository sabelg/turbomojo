"""Multimodal Notebook AI Context & Vision Payload Builder, Isolated Git-Worktree
Background Task Runner, and Hybrid `mojocst` CST + Okapi BM25 Semantic Codebase Search.

Provides:
- `NotebookCellDigest`, `NotebookAiContext`, `build_notebook_ai_context`,
  `build_multimodal_openai_request_json`, and `format_notebook_ipc_json`
- `WorktreeFilePatch`, `WorktreeTask`, `create_isolated_worktree`,
  `collect_worktree_patches`, `verify_worktree_mojo_file`, and `cleanup_isolated_worktree`
- `SemanticChunk`, `SemanticHit`, `SemanticCodeIndex`, and `split_code_subtokens`
"""
from std.collections import Dict, List
from std.math import log
from buffer import TextBuffer
from cells import CodeCell, cell_at_row, extract_cell_body_text, parse_cells
from json import JsonWriter
from mojocst import CstDefNode, CstStructNode, CstTraitNode, format_cst_param, parse_mojo_cst
from signals import own_pid
from swap import delete_file
from tensor_inspect import extract_tensor_cards
from util import (
    base64,
    basename,
    bytes_to_str,
    decode,
    dirname,
    env_or,
    is_dir,
    join_path,
    lower,
    lower_str,
    path_exists,
    read_file,
    run_capture,
    shell_quote,
    slice_str,
    str_bytes,
    to_str,
    toolchain_env,
    write_file,
)


comptime BM25_K1: Float64 = 1.5
comptime BM25_B: Float64 = 0.75


# ============================================================================
# 1. Multimodal Notebook AI Context & Vision Payload Builder
# ============================================================================


@fieldwise_init
struct NotebookCellDigest(Copyable, Movable):
    var index: Int
    var title: String
    var is_markdown: Bool
    var code_preview: String
    var output_summary: String
    var tensor_cards: List[String]
    var has_error: Bool
    var error_traceback: String
    var plot_png_paths: List[String]


@fieldwise_init
struct NotebookAiContext(Copyable, Movable):
    var active_cell_index: Int
    var preceding_defs_summary: String
    var live_schemas: List[String]
    var last_error: String
    var attached_png_paths: List[String]
    var attached_png_b64: List[String]
    var prompt_block: String


def _is_markdown_cell(buf: TextBuffer, cell: CodeCell) -> Bool:
    var low_title = lower_str(String(cell.title.strip()))
    if (
        low_title.startswith("[markdown]")
        or low_title.startswith("[md]")
        or low_title == "markdown"
        or low_title == "md"
    ):
        return True
    if cell.header_row >= 0 and cell.header_row < buf.count():
        var hdr = lower_str(String(to_str(buf.line(cell.header_row)).strip()))
        if hdr.find("[markdown]") >= 0 or hdr.find("[md]") >= 0:
            return True
    return False


def _is_digits_only(s: String) -> Bool:
    if s.byte_length() == 0:
        return False
    for b in s.as_bytes():
        if b < 48 or b > 57:
            return False
    return True


def resolve_plot_spec_png(spec: String) -> String:
    """Resolve a plot path or `ANIM|fps|frame0|frame1|...` spec into a single representative PNG path."""
    var trimmed = String(spec.strip())
    if trimmed.byte_length() == 0:
        return ""
    if not trimmed.startswith("ANIM|"):
        return trimmed
    var parts = trimmed.split("|")
    if len(parts) < 2:
        return ""
    var start_idx = 1
    var second = String(parts[1].strip())
    if _is_digits_only(second) or second.startswith("fps="):
        start_idx = 2
    var frames = List[String]()
    for i in range(start_idx, len(parts)):
        var fp = String(parts[i].strip())
        if fp.byte_length() > 0:
            frames.append(fp)
    if len(frames) == 0:
        return ""
    var mid_idx = len(frames) // 2
    if path_exists(frames[mid_idx]):
        return frames[mid_idx]
    if path_exists(frames[0]):
        return frames[0]
    for i in range(len(frames)):
        if path_exists(frames[i]):
            return frames[i]
    return frames[mid_idx]


def _is_schema_card_line(line: String) -> Bool:
    var tr = String(line.strip())
    if tr.byte_length() == 0:
        return False
    return (
        tr.find("[Tensor ") >= 0
        or tr.find("[Tensor]") >= 0
        or tr.find("[DataFrame ") >= 0
        or tr.find("[DataFrame]") >= 0
        or tr.find("[Polars ") >= 0
        or tr.find("[Polars]") >= 0
        or tr.find("[Array ") >= 0
        or tr.find("[Array]") >= 0
        or tr.find("[SIMD ") >= 0
        or tr.find("[SIMD]") >= 0
    )


def _extract_output_schemas(raw_output: String) -> List[String]:
    var cards = List[String]()
    if raw_output.byte_length() == 0:
        return cards^
    var extracted = extract_tensor_cards(raw_output)
    var norm_text = extracted[0]
    for c in extracted[1]:
        if len(cards) == 0 or cards[len(cards) - 1] != c:
            cards.append(c)
    for ln_slice in norm_text.split("\n"):
        var ln = String(ln_slice.strip())
        if _is_schema_card_line(ln):
            var dup = False
            for existing in cards:
                if existing == ln:
                    dup = True
                    break
            if not dup:
                cards.append(ln)
    return cards^


def _detect_output_error(raw_output: String) -> Tuple[Bool, String]:
    var trimmed = String(raw_output.strip())
    if trimmed.byte_length() == 0:
        return (False, "")
    var tb_pos = trimmed.find("Traceback (most recent call last):")
    if tb_pos >= 0:
        return (True, String(trimmed[byte=tb_pos:]))
    var err_lines = List[String]()
    var found_err = False
    for ln_slice in trimmed.split("\n"):
        var ln = String(ln_slice)
        var tr = String(ln.strip())
        if (
            ln.find(": error:") >= 0
            or tr.startswith("Error:")
            or tr.startswith("Unhandled exception")
            or tr.startswith("RuntimeError:")
            or tr.startswith("ValueError:")
            or tr.startswith("TypeError:")
            or tr.startswith("KeyError:")
            or tr.startswith("IndexError:")
            or tr.startswith("AssertionError")
            or tr.startswith("ZeroDivisionError:")
            or tr.startswith("NameError:")
            or tr.startswith("SyntaxError:")
            or tr.startswith("AttributeError:")
            or tr.startswith("ModuleNotFoundError:")
            or tr.startswith("ImportError:")
        ):
            found_err = True
        if found_err:
            err_lines.append(ln)
    if found_err:
        return (True, "\n".join(err_lines))
    return (False, "")


def _truncate_text(s: String, max_chars: Int) -> String:
    var cps = decode(s)
    if len(cps) <= max_chars:
        return s
    return slice_str(cps, 0, max(1, max_chars - 1)) + "…"


def _extract_cell_signatures(body_text: String) -> List[String]:
    var sigs = List[String]()
    for ln_slice in body_text.split("\n"):
        var raw_ln = String(ln_slice)
        var lstripped = String(raw_ln.lstrip())
        if lstripped.byte_length() == 0 or lstripped.startswith("#"):
            continue
        var indent_bytes = raw_ln.byte_length() - lstripped.byte_length()
        if indent_bytes > 0:
            continue
        var clean = String(lstripped.strip())
        if (
            clean.startswith("import ")
            or clean.startswith("from ")
            or clean.startswith("def ")
            or clean.startswith("async def ")
            or clean.startswith("struct ")
            or clean.startswith("trait ")
            or clean.startswith("class ")
            or clean.startswith("comptime ")
        ):
            sigs.append(_truncate_text(clean, 96))
            continue
        if clean.startswith("var "):
            sigs.append(_truncate_text(clean, 88))
            continue
        # Top-level Python/notebook variable assignment `name = ...` or `name: Type = ...`
        var eq_pos = clean.find("=")
        if eq_pos > 0 and not clean.startswith("==") and not clean.startswith("@"):
            var before_eq = String(clean[byte=0:eq_pos])
            if (
                not before_eq.endswith("!")
                and not before_eq.endswith("<")
                and not before_eq.endswith(">")
            ):
                var lhs = String(before_eq.strip())
                var colon = lhs.find(":")
                var ident_cand = String(lhs[byte=0:colon].strip()) if colon > 0 else lhs
                var valid_ident = ident_cand.byte_length() > 0
                for b in ident_cand.as_bytes():
                    var ok_ch = (
                        (b >= 65 and b <= 90)
                        or (b >= 97 and b <= 122)
                        or (b >= 48 and b <= 57)
                        or b == 95
                    )
                    if not ok_ch:
                        valid_ident = False
                        break
                if valid_ident:
                    sigs.append(_truncate_text(clean, 88))
    return sigs^


def summarize_notebook_cells(
    buf: TextBuffer,
    cell_outputs: List[String],
    cell_plots: List[List[String]],
) -> List[NotebookCellDigest]:
    """Build structured `NotebookCellDigest` records for every `# %%` cell in `buf`."""
    var digests = List[NotebookCellDigest]()
    var cells = parse_cells(buf)
    for ci in range(len(cells)):
        var c = cells[ci].copy()
        var is_md = _is_markdown_cell(buf, c)
        var body_info = extract_cell_body_text(buf, c)
        var code_prev = _truncate_text(String(body_info[0].strip()), 160)
        var raw_out = cell_outputs[ci] if ci < len(cell_outputs) else String("")
        var cards = _extract_output_schemas(raw_out)
        var err_info = _detect_output_error(raw_out)
        var out_sum = _truncate_text(String(extract_tensor_cards(raw_out)[0].strip()), 180)
        var pngs = List[String]()
        if ci < len(cell_plots):
            for spec in cell_plots[ci]:
                var resolved = resolve_plot_spec_png(spec)
                if resolved.byte_length() > 0:
                    pngs.append(resolved)
        digests.append(
            NotebookCellDigest(
                c.index,
                c.title,
                is_md,
                code_prev,
                out_sum,
                cards^,
                err_info[0],
                err_info[1],
                pngs^,
            )
        )
    return digests^


def _schema_key(card: String) -> String:
    var colon = card.find(": [")
    if colon > 0:
        return String(card[byte=0:colon].strip())
    return ""


def _upsert_schema(mut schemas: List[String], card: String):
    var key = _schema_key(card)
    if key.byte_length() > 0:
        for i in range(len(schemas)):
            if _schema_key(schemas[i]) == key:
                schemas[i] = card
                return
    for i in range(len(schemas)):
        if schemas[i] == card:
            return
    schemas.append(card)


def build_notebook_ai_context(
    buf: TextBuffer,
    cursor_row: Int,
    cell_outputs: List[String],
    cell_plots: List[List[String]],
    max_images: Int = 2,
) -> NotebookAiContext:
    """Synthesize multimodal notebook context (preceding definitions, live tensor/DataFrame
    schemas, latest traceback, and base64-encoded plot/animation PNGs) around `cursor_row`."""
    var cells = parse_cells(buf)
    if len(cells) == 0:
        return NotebookAiContext(
            0,
            "",
            List[String](),
            "",
            List[String](),
            List[String](),
            "",
        )
    var active_idx = cell_at_row(cells, cursor_row)
    if active_idx < 0:
        active_idx = 0
    if active_idx >= len(cells):
        active_idx = len(cells) - 1

    var digests = summarize_notebook_cells(buf, cell_outputs, cell_plots)

    # 1. Extract imports, defs/structs/traits/comptimes, and top-level vars from preceding cells
    var def_lines = List[String]()
    for ci in range(active_idx):
        if digests[ci].is_markdown:
            continue
        var body_txt = extract_cell_body_text(buf, cells[ci])[0]
        var cell_sigs = _extract_cell_signatures(body_txt)
        if len(cell_sigs) > 0:
            def_lines.append("# [" + cells[ci].title + "]")
            for s in cell_sigs:
                def_lines.append(s)
    var preceding_summary = "\n".join(def_lines)

    # 2. Collect live [Tensor]/[DataFrame]/[Polars]/[Array]/[SIMD] schemas across executed cells
    var schemas = List[String]()
    for ci in range(len(digests)):
        for card in digests[ci].tensor_cards:
            _upsert_schema(schemas, card)
    # Also scan any extra entries in cell_outputs beyond len(digests)
    for ci in range(len(digests), len(cell_outputs)):
        for card in _extract_output_schemas(cell_outputs[ci]):
            _upsert_schema(schemas, card)

    # 3. Capture active cell error or latest traceback error
    var latest_err = String("")
    if active_idx < len(digests) and digests[active_idx].has_error:
        latest_err = digests[active_idx].error_traceback
    else:
        var scan_i = min(active_idx, len(digests) - 1)
        while scan_i >= 0:
            if digests[scan_i].has_error:
                latest_err = digests[scan_i].error_traceback
                break
            scan_i -= 1
        if latest_err.byte_length() == 0:
            var tail_i = len(digests) - 1
            while tail_i > active_idx:
                if digests[tail_i].has_error:
                    latest_err = digests[tail_i].error_traceback
                    break
                tail_i -= 1

    # 4. Attach up to `max_images` PNG plots from active cell (or immediately preceding cell)
    var png_paths = List[String]()
    var png_b64 = List[String]()
    var img_cap = max(0, max_images)
    if img_cap > 0:
        var candidate_cells = List[Int]()
        candidate_cells.append(active_idx)
        if active_idx > 0:
            candidate_cells.append(active_idx - 1)
        for c_idx in candidate_cells:
            if len(png_paths) >= img_cap:
                break
            if c_idx >= 0 and c_idx < len(digests):
                for p in digests[c_idx].plot_png_paths:
                    if len(png_paths) >= img_cap:
                        break
                    var already = False
                    for ep in png_paths:
                        if ep == p:
                            already = True
                            break
                    if already or not path_exists(p):
                        continue
                    var raw_png = read_file(p)
                    if len(raw_png) > 0:
                        png_paths.append(p)
                        png_b64.append(base64(raw_png))

    # 5. Synthesize compact, high-signal prompt block
    var active_body = String(extract_cell_body_text(buf, cells[active_idx])[0].strip())
    var blocks = List[String]()
    blocks.append(
        "=== Notebook Context (Active Cell "
        + String(active_idx + 1)
        + "/"
        + String(len(cells))
        + ": "
        + cells[active_idx].title
        + ") ==="
    )
    if preceding_summary.byte_length() > 0:
        blocks.append("--- Preceding Cell Definitions ---\n" + preceding_summary)
    if len(schemas) > 0:
        blocks.append("--- Live Kernel Schemas ---\n" + "\n".join(schemas))
    if active_body.byte_length() > 0:
        blocks.append("--- Active Cell Code ---\n" + _truncate_text(active_body, 800))
    if latest_err.byte_length() > 0:
        blocks.append("--- Latest Error / Traceback ---\n" + _truncate_text(latest_err, 600))
    if len(png_paths) > 0:
        blocks.append("--- Attached Plot Vision Frames ---\n" + "\n".join(png_paths))
    var prompt_blk = "\n\n".join(blocks)

    return NotebookAiContext(
        active_idx,
        preceding_summary,
        schemas^,
        latest_err,
        png_paths^,
        png_b64^,
        prompt_blk,
    )


def build_multimodal_openai_request_json(
    model: String,
    system_prompt: String,
    user_prompt: String,
    png_b64_list: List[String],
    temperature: Float64 = 0.1,
) -> String:
    """Build an OpenAI-compatible `/v1/chat/completions` JSON request payload.
    Emits string `content` when `png_b64_list` is empty and a multimodal `text` + `image_url`
    content array when one or more PNG base64 payloads are attached."""
    var mdl = model if model.byte_length() > 0 else String("gpt-4o")
    var w = JsonWriter()
    w.begin_obj()
    w.kv_str("model", mdl)
    w.key("temperature")
    w.float(temperature)
    w.key("messages")
    w.begin_arr()

    # System message
    w.begin_obj()
    w.kv_str("role", "system")
    w.kv_str("content", system_prompt)
    w.end_obj()

    # User message (text-only vs multimodal vision array)
    w.begin_obj()
    w.kv_str("role", "user")
    if len(png_b64_list) == 0:
        w.kv_str("content", user_prompt)
    else:
        w.key("content")
        w.begin_arr()
        w.begin_obj()
        w.kv_str("type", "text")
        w.kv_str("text", user_prompt)
        w.end_obj()
        for b64_item in png_b64_list:
            var data_url = (
                b64_item
                if b64_item.startswith("data:image/")
                else ("data:image/png;base64," + b64_item)
            )
            w.begin_obj()
            w.kv_str("type", "image_url")
            w.key("image_url")
            w.begin_obj()
            w.kv_str("url", data_url)
            w.end_obj()
            w.end_obj()
        w.end_arr()
    w.end_obj()

    w.end_arr()
    w.end_obj()
    return w.text()


def format_notebook_ipc_json(ctx: NotebookAiContext) -> String:
    """Serialize live `NotebookAiContext` schemas, errors, and plot paths for MCP/IPC clients."""
    var w = JsonWriter()
    w.begin_obj()
    w.kv_int("active_cell_index", ctx.active_cell_index)
    w.kv_str("preceding_defs_summary", ctx.preceding_defs_summary)
    w.key("live_schemas")
    w.begin_arr()
    for sc in ctx.live_schemas:
        w.str(sc)
    w.end_arr()
    w.kv_bool("has_error", ctx.last_error.byte_length() > 0)
    w.kv_str("last_error", ctx.last_error)
    w.key("attached_png_paths")
    w.begin_arr()
    for pp in ctx.attached_png_paths:
        w.str(pp)
    w.end_arr()
    w.kv_int("attached_image_count", len(ctx.attached_png_b64))
    w.kv_str("prompt_block", ctx.prompt_block)
    w.end_obj()
    return w.text()


# ============================================================================
# 2. Isolated Git-Worktree Background Task Runner
# ============================================================================


@fieldwise_init
struct WorktreeFilePatch(Copyable, Movable):
    var rel_path: String
    var orig_content: String
    var new_content: String
    var unified_diff: String


@fieldwise_init
struct WorktreeTask(Copyable, Movable):
    var id: Int
    var repo_root: String
    var worktree_dir: String
    var task_prompt: String
    var active: Bool
    var verified_ok: Bool
    var diagnostics: String


def create_isolated_worktree(repo_root: String, task_id: Int) -> Tuple[Bool, String, String]:
    """Create a detached git worktree at `/tmp/turbomojo-wt-<pid>-<task_id>` from `HEAD`."""
    if repo_root.byte_length() == 0 or not is_dir(repo_root):
        return (False, "", "Invalid repository root: " + repo_root)
    var wt_dir = "/tmp/turbomojo-wt-" + String(own_pid()) + "-" + String(task_id)
    if path_exists(wt_dir):
        _ = cleanup_isolated_worktree(repo_root, wt_dir)
    var cmd = (
        "git -C "
        + shell_quote(repo_root)
        + " worktree add --detach "
        + shell_quote(wt_dir)
        + " HEAD 2>&1"
    )
    var res = run_capture(cmd)
    if res.status != 0 or not is_dir(wt_dir):
        return (False, wt_dir, String(bytes_to_str(res.out).strip()))
    return (True, wt_dir, "")


def _synthesize_added_diff(rel_path: String, new_content: String) -> String:
    var out = List[String]()
    out.append("--- /dev/null")
    out.append("+++ b/" + rel_path)
    var lines = new_content.split("\n")
    var count = len(lines)
    if count > 0 and String(lines[count - 1]).byte_length() == 0:
        count -= 1
    out.append("@@ -0,0 +1," + String(max(1, count)) + " @@")
    for i in range(count):
        out.append("+" + String(lines[i]))
    return "\n".join(out) + "\n"


def collect_worktree_patches(repo_root: String, wt_dir: String) -> List[WorktreeFilePatch]:
    """Collect modified and newly added files inside `wt_dir` relative to `repo_root`,
    ready to pass directly into `offer_edit()`."""
    var patches = List[WorktreeFilePatch]()
    if wt_dir.byte_length() == 0 or not is_dir(wt_dir):
        return patches^
    var st_res = run_capture(
        "git -C " + shell_quote(wt_dir) + " status --porcelain -uall 2>/dev/null"
    )
    if st_res.status != 0:
        return patches^
    var raw_status = bytes_to_str(st_res.out)
    var seen = Dict[String, Int]()
    for ln_slice in raw_status.split("\n"):
        var ln = String(ln_slice)
        if ln.endswith("\r"):
            var no_cr = String(ln[byte=0 : ln.byte_length() - 1])
            ln = no_cr
        if ln.byte_length() < 4:
            continue
        var raw_rel = String(ln[byte=3:])
        var arrow_pos = raw_rel.find(" -> ")
        if arrow_pos >= 0:
            var after_arrow = String(raw_rel[byte=arrow_pos + 4 :])
            raw_rel = after_arrow
        if raw_rel.byte_length() >= 2 and raw_rel.startswith("\"") and raw_rel.endswith("\""):
            var unq = String(raw_rel[byte=1 : raw_rel.byte_length() - 1])
            raw_rel = unq
        var rel_path = String(raw_rel.strip())
        if rel_path.byte_length() == 0 or seen.get(rel_path, 0) != 0:
            continue
        seen[rel_path] = 1

        var orig_full = join_path(repo_root, rel_path)
        var wt_full = join_path(wt_dir, rel_path)
        var orig_text = bytes_to_str(read_file(orig_full)) if path_exists(orig_full) else String("")
        var new_text = bytes_to_str(read_file(wt_full)) if path_exists(wt_full) else String("")
        if orig_text == new_text:
            continue

        var diff_res = run_capture(
            "git -C "
            + shell_quote(wt_dir)
            + " diff HEAD -- "
            + shell_quote(rel_path)
            + " 2>/dev/null"
        )
        var udiff = bytes_to_str(diff_res.out)
        if String(udiff.strip()).byte_length() == 0:
            udiff = _synthesize_added_diff(rel_path, new_text)
        patches.append(WorktreeFilePatch(rel_path, orig_text, new_text, udiff))
    return patches^


def verify_worktree_mojo_file(
    wt_dir: String,
    rel_mojo_path: String,
    mojo_bin: String = "mojo",
) -> Tuple[Bool, String]:
    """Shadow-compile `<wt_dir>/<rel_mojo_path>` inside `wt_dir` using `mojo build --emit=llvm`
    without touching the user's live working tree."""
    if wt_dir.byte_length() == 0 or not is_dir(wt_dir):
        return (False, "Worktree directory does not exist: " + wt_dir)
    var target_full = join_path(wt_dir, rel_mojo_path)
    if not path_exists(target_full):
        return (False, "Mojo file not found in worktree: " + rel_mojo_path)

    var src_body = bytes_to_str(read_file(target_full))
    var verify_body = src_body
    if ("\n" + verify_body).find("\ndef main(") < 0 and ("\n" + verify_body).find("\ndef main (") < 0:
        verify_body += "\n\ndef main():\n    pass\n"

    var pid_s = String(own_pid())
    var tmp_base = env_or("TMPDIR", "/tmp") + "/turbomojo-wt-verify-" + pid_s
    var tmp_src = tmp_base + ".mojo"
    var tmp_ll = tmp_base + ".ll"
    if not write_file(tmp_src, str_bytes(verify_body)):
        return (False, "Could not write temporary verification buffer")

    var inc_flags = " -I " + shell_quote(wt_dir)
    var wt_src_dir = join_path(wt_dir, "src")
    if is_dir(wt_src_dir):
        inc_flags += " -I " + shell_quote(wt_src_dir)
    var file_parent = dirname(target_full)
    if file_parent != wt_dir and file_parent != wt_src_dir and is_dir(file_parent):
        inc_flags += " -I " + shell_quote(file_parent)

    var env_prefix = toolchain_env(env_or("MODULAR_HOME", ""), mojo_bin)
    var cmd = (
        "cd "
        + shell_quote(wt_dir)
        + " && "
        + env_prefix
        + shell_quote(mojo_bin)
        + " build --emit=llvm"
        + inc_flags
        + " "
        + shell_quote(tmp_src)
        + " -o "
        + shell_quote(tmp_ll)
        + " 2>&1"
    )
    var res = run_capture(cmd)
    delete_file(tmp_src)
    delete_file(tmp_ll)
    var diag = bytes_to_str(res.out).replace(tmp_src, rel_mojo_path)
    return (res.status == 0, String(diag.strip()))


def cleanup_isolated_worktree(repo_root: String, wt_dir: String) -> Bool:
    """Remove isolated worktree `wt_dir` safely via `git worktree remove --force`
    with guarded `/tmp/turbomojo-wt-` cleanup fallback."""
    if wt_dir.byte_length() == 0 or wt_dir == "/" or wt_dir == repo_root:
        return False
    if repo_root.byte_length() > 0 and is_dir(repo_root):
        _ = run_capture(
            "git -C "
            + shell_quote(repo_root)
            + " worktree remove --force "
            + shell_quote(wt_dir)
            + " 2>&1"
        )
        _ = run_capture("git -C " + shell_quote(repo_root) + " worktree prune 2>/dev/null")
    if path_exists(wt_dir) and wt_dir.startswith("/tmp/turbomojo-wt-"):
        _ = run_capture("rm -rf " + shell_quote(wt_dir) + " 2>/dev/null")
        if repo_root.byte_length() > 0 and is_dir(repo_root):
            _ = run_capture("git -C " + shell_quote(repo_root) + " worktree prune 2>/dev/null")
    return not path_exists(wt_dir)


# ============================================================================
# 3. Local Hybrid `mojocst` CST + BM25 Semantic Codebase Search
# ============================================================================


@fieldwise_init
struct SemanticChunk(Copyable, Movable):
    var path: String
    var symbol_name: String
    var kind: String
    var start_row: Int
    var end_row: Int
    var signature: String
    var tokens: List[String]


@fieldwise_init
struct SemanticHit(Copyable, Movable):
    var path: String
    var symbol_name: String
    var kind: String
    var row: Int
    var score_x100: Int
    var preview: String


def _is_ascii_upper(cp: Int) -> Bool:
    return cp >= 65 and cp <= 90


def _is_ascii_lower(cp: Int) -> Bool:
    return cp >= 97 and cp <= 122


def _is_word_letter(cp: Int) -> Bool:
    return _is_ascii_upper(cp) or _is_ascii_lower(cp) or cp >= 0xC0


def _is_stop_word(tok: String) -> Bool:
    if tok.byte_length() < 2:
        return True
    return (
        tok == "the"
        or tok == "and"
        or tok == "for"
        or tok == "def"
        or tok == "var"
        or tok == "self"
        or tok == "int"
        or tok == "bool"
        or tok == "string"
        or tok == "return"
        or tok == "from"
        or tok == "import"
        or tok == "with"
        or tok == "mut"
        or tok == "out"
        or tok == "ref"
        or tok == "true"
        or tok == "false"
        or tok == "none"
        or tok == "pass"
        or tok == "else"
        or tok == "elif"
        or tok == "while"
        or tok == "where"
        or tok == "what"
        or tok == "when"
        or tok == "which"
        or tok == "how"
        or tok == "does"
        or tok == "are"
        or tok == "was"
        or tok == "were"
        or tok == "this"
        or tok == "that"
        or tok == "into"
        or tok == "in"
        or tok == "on"
        or tok == "at"
        or tok == "to"
        or tok == "of"
        or tok == "is"
        or tok == "it"
        or tok == "or"
        or tok == "as"
        or tok == "by"
        or tok == "an"
        or tok == "be"
        or tok == "if"
        or tok == "do"
        or tok == "we"
    )


def _flush_subtoken(mut cur: List[Int], mut out: List[String]):
    if len(cur) == 0:
        return
    var lowered = List[Int]()
    for cp in cur:
        lowered.append(lower(cp))
    cur.clear()
    var word = to_str(lowered)
    if not _is_stop_word(word):
        out.append(word)


def split_code_subtokens(text: String) -> List[String]:
    """Split code identifiers and prose into normalized sub-tokens on `snake_case`,
    `camelCase`/`PascalCase` boundaries, digits, and punctuation, filtering stop-words."""
    var out = List[String]()
    var cps = decode(text)
    var n = len(cps)
    var cur = List[Int]()
    for i in range(n):
        var cp = cps[i]
        if not _is_word_letter(cp):
            _flush_subtoken(cur, out)
            continue
        if len(cur) > 0:
            var prev_cp = cps[i - 1]
            if _is_ascii_lower(prev_cp) and _is_ascii_upper(cp):
                # camelCase transition: `parseIpynb` -> `parse` | `Ipynb`
                _flush_subtoken(cur, out)
            elif (
                _is_ascii_upper(prev_cp)
                and _is_ascii_upper(cp)
                and i + 1 < n
                and _is_ascii_lower(cps[i + 1])
            ):
                # Acronym transition: `PNGImage` -> `PNG` | `Image`
                _flush_subtoken(cur, out)
        cur.append(cp)
    _flush_subtoken(cur, out)
    return out^


def _stem_singular(tok: String) -> String:
    var blen = tok.byte_length()
    if blen >= 5 and tok.endswith("ies"):
        return String(tok[byte=0 : blen - 3]) + "y"
    if blen >= 4 and tok.endswith("s") and not tok.endswith("ss") and not tok.endswith("us"):
        return String(tok[byte=0 : blen - 1])
    return tok


def _subtoken_matches(cand: String, query_tok: String) -> Bool:
    if cand == query_tok:
        return True
    return _stem_singular(cand) == _stem_singular(query_tok)


def _format_def_signature(d: CstDefNode) -> String:
    var p_strs = List[String]()
    for p in d.params:
        p_strs.append(format_cst_param(p))
    var sig = "def " + d.name
    if len(d.comptime_params) > 0:
        var ct_strs = List[String]()
        for cp in d.comptime_params:
            ct_strs.append(cp.raw_text)
        sig += "[" + ", ".join(ct_strs) + "]"
    sig += "(" + ", ".join(p_strs) + ")"
    if d.is_raises:
        sig += " raises"
    if d.return_type.byte_length() > 0:
        sig += " -> " + d.return_type
    return sig


def _extract_leading_and_doc_comments(buf: TextBuffer, header_row: Int, end_row: Int) -> String:
    var doc_parts = List[String]()
    var n = buf.count()
    # Leading `#` comments right above header
    var r_up = header_row - 1
    var up_comments = List[String]()
    while r_up >= 0 and header_row - r_up <= 4:
        var tr = String(to_str(buf.line(r_up)).strip())
        if tr.startswith("#") and not tr.startswith("# %%") and not tr.startswith("#%%"):
            up_comments.append(String(tr[byte=1:].strip()))
            r_up -= 1
        elif tr.startswith("@"):
            r_up -= 1
        else:
            break
    var ui = len(up_comments) - 1
    while ui >= 0:
        if up_comments[ui].byte_length() > 0:
            doc_parts.append(up_comments[ui])
        ui -= 1

    # Triple-quoted docstring or initial `#` comments right inside block
    var r_dn = header_row + 1
    var in_triple = False
    while r_dn <= min(n - 1, min(end_row, header_row + 8)):
        var tr = String(to_str(buf.line(r_dn)).strip())
        if tr.byte_length() == 0:
            if in_triple:
                r_dn += 1
                continue
            break
        if not in_triple and tr.startswith("\"\"\""):
            var after_open = String(tr[byte=3:])
            var close_idx = after_open.find("\"\"\"")
            if close_idx >= 0:
                var single_doc = String(after_open[byte=0:close_idx].strip())
                if single_doc.byte_length() > 0:
                    doc_parts.append(single_doc)
                break
            if String(after_open.strip()).byte_length() > 0:
                doc_parts.append(String(after_open.strip()))
            in_triple = True
            r_dn += 1
            continue
        if in_triple:
            var cidx = tr.find("\"\"\"")
            if cidx >= 0:
                var before_close = String(tr[byte=0:cidx].strip())
                if before_close.byte_length() > 0:
                    doc_parts.append(before_close)
                break
            doc_parts.append(tr)
            r_dn += 1
            continue
        if tr.startswith("#"):
            doc_parts.append(String(tr[byte=1:].strip()))
            r_dn += 1
            continue
        break
    return " ".join(doc_parts)


def _lines_range_text(buf: TextBuffer, r1: Int, r2: Int) -> String:
    var n = buf.count()
    if n <= 0:
        return ""
    var lo = max(0, r1)
    var hi = min(n - 1, r2)
    var lines = List[String]()
    for r in range(lo, hi + 1):
        lines.append(to_str(buf.line(r)))
    return "\n".join(lines)


@fieldwise_init
struct SemanticCodeIndex(Copyable, Movable):
    var chunks: List[SemanticChunk]
    var total_tokens: Int

    def __init__(out self):
        self.chunks = List[SemanticChunk]()
        self.total_tokens = 0

    def _remove_path(mut self, path: String):
        if path.byte_length() == 0 or len(self.chunks) == 0:
            return
        var kept = List[SemanticChunk]()
        var tok_sum = 0
        for i in range(len(self.chunks)):
            if self.chunks[i].path != path:
                tok_sum += len(self.chunks[i].tokens)
                kept.append(self.chunks[i].copy())
        self.chunks = kept^
        self.total_tokens = tok_sum

    def _add_chunk(
        mut self,
        path: String,
        symbol_name: String,
        kind: String,
        start_row: Int,
        end_row: Int,
        signature: String,
        full_text: String,
    ):
        var toks = split_code_subtokens(symbol_name + " " + signature + " " + full_text)
        if len(toks) == 0:
            return
        self.total_tokens += len(toks)
        self.chunks.append(
            SemanticChunk(
                path,
                symbol_name,
                kind,
                start_row,
                end_row,
                signature,
                toks^,
            )
        )

    def index_buffer(mut self, path: String, buf: TextBuffer):
        """Index a `TextBuffer` using `parse_mojo_cst` for Mojo symbols (`struct`, `trait`, `def`)
        plus `# %%` notebook cells and markdown/prose fallback chunks."""
        self._remove_path(path)
        var n = buf.count()
        if n <= 0:
            return

        var low_path = lower_str(path)
        var is_mojo = (
            path.byte_length() == 0
            or low_path.endswith(".mojo")
            or low_path.endswith(".🔥")
        )
        var is_doc = low_path.endswith(".md") or low_path.endswith(".txt") or low_path.endswith(".rst")

        var added_before = len(self.chunks)

        if is_mojo:
            var cst = parse_mojo_cst(buf)

            # Index structs (with traits, fields, decorators, and header/docstring)
            for si in range(len(cst.structs)):
                var st = cst.structs[si].copy()
                var sr = st.header_span.r1
                var er = st.body_span.r2
                var field_parts = List[String]()
                for fi in range(len(st.fields)):
                    field_parts.append(st.fields[fi].name + ": " + st.fields[fi].type_expr)
                var trait_part = (
                    "(" + ", ".join(st.traits) + ")" if len(st.traits) > 0 else String("")
                )
                var doc_txt = _extract_leading_and_doc_comments(buf, sr, er)
                var sig = "struct " + st.name + trait_part
                if len(field_parts) > 0:
                    sig += " { " + ", ".join(field_parts) + " }"
                if doc_txt.byte_length() > 0:
                    sig += " — " + doc_txt
                # For struct body tokens, include lines up to first method (or whole struct if small)
                var struct_end = er
                if len(st.methods) > 0 and st.methods[0].header_span.r1 > sr:
                    struct_end = st.methods[0].header_span.r1 - 1
                var st_from = st.deco_start_row if st.deco_start_row >= 0 else sr
                self._add_chunk(
                    path,
                    st.name,
                    "struct",
                    sr,
                    er,
                    sig,
                    _lines_range_text(buf, st_from, struct_end),
                )

            # Index traits
            for ti in range(len(cst.traits)):
                var tr_node = cst.traits[ti].copy()
                var sr = tr_node.header_span.r1
                var er = tr_node.body_span.r2
                var doc_txt = _extract_leading_and_doc_comments(buf, sr, er)
                var m_names = List[String]()
                for mi in range(len(tr_node.methods)):
                    m_names.append(tr_node.methods[mi].name)
                var sig = "trait " + tr_node.name
                if len(m_names) > 0:
                    sig += " { " + ", ".join(m_names) + " }"
                if doc_txt.byte_length() > 0:
                    sig += " — " + doc_txt
                self._add_chunk(
                    path,
                    tr_node.name,
                    "trait",
                    sr,
                    er,
                    sig,
                    _lines_range_text(buf, sr, er),
                )

            # Index defs (top-level functions and struct/trait methods)
            for di in range(len(cst.defs)):
                var d = cst.defs[di].copy()
                var sr = d.header_span.r1
                var er = d.body_span.r2
                var sym_name = d.name
                if d.indent > 0:
                    for si in range(len(cst.structs)):
                        if sr > cst.structs[si].header_span.r1 and sr <= cst.structs[si].body_span.r2:
                            sym_name = cst.structs[si].name + "." + d.name
                            break
                    for ti in range(len(cst.traits)):
                        if sr > cst.traits[ti].header_span.r1 and sr <= cst.traits[ti].body_span.r2:
                            sym_name = cst.traits[ti].name + "." + d.name
                            break
                var doc_txt = _extract_leading_and_doc_comments(buf, sr, er)
                var deco_prefix = (" ".join(d.decorators) + " ") if len(d.decorators) > 0 else String("")
                var sig = deco_prefix + _format_def_signature(d)
                if doc_txt.byte_length() > 0:
                    sig += " — " + doc_txt
                var d_from = d.deco_start_row if d.deco_start_row >= 0 else sr
                self._add_chunk(
                    path,
                    sym_name,
                    "def",
                    sr,
                    er,
                    sig,
                    _lines_range_text(buf, d_from, er),
                )

        # Index `# %%` cells when cell markers exist
        var cells = parse_cells(buf)
        var has_explicit_cells = len(cells) > 1 or (len(cells) == 1 and cells[0].header_row >= 0)
        if has_explicit_cells:
            for ci in range(len(cells)):
                var c = cells[ci].copy()
                var is_md = _is_markdown_cell(buf, c)
                var body_txt = extract_cell_body_text(buf, c)[0]
                var sig = c.title + ": " + _truncate_text(String(body_txt.strip()), 120)
                var sr = c.header_row if c.header_row >= 0 else c.start_row
                self._add_chunk(
                    path,
                    c.title,
                    "doc" if is_md else "cell",
                    sr,
                    c.end_row,
                    sig,
                    body_txt,
                )

        # Non-Mojo or unstructured fallback chunks (`doc` sections or top-level code blocks)
        if len(self.chunks) == added_before:
            if is_doc:
                var sec_title = basename(path) if path.byte_length() > 0 else String("Document")
                var sec_start = 0
                var sec_lines = List[String]()
                for r in range(n):
                    var ln = to_str(buf.line(r))
                    var tr = String(ln.strip())
                    if tr.startswith("#") and len(sec_lines) > 0:
                        self._add_chunk(
                            path,
                            sec_title,
                            "doc",
                            sec_start,
                            r - 1,
                            sec_title,
                            "\n".join(sec_lines),
                        )
                        sec_lines.clear()
                        sec_start = r
                        var h_trim = tr
                        while h_trim.startswith("#"):
                            var h_sub = String(h_trim[byte=1:].strip())
                            h_trim = h_sub
                        if h_trim.byte_length() > 0:
                            sec_title = h_trim
                    elif tr.startswith("#") and len(sec_lines) == 0:
                        var h_trim = tr
                        while h_trim.startswith("#"):
                            var h_sub = String(h_trim[byte=1:].strip())
                            h_trim = h_sub
                        if h_trim.byte_length() > 0:
                            sec_title = h_trim
                        sec_lines.append(ln)
                    else:
                        sec_lines.append(ln)
                if len(sec_lines) > 0:
                    self._add_chunk(
                        path,
                        sec_title,
                        "doc",
                        sec_start,
                        n - 1,
                        sec_title,
                        "\n".join(sec_lines),
                    )
            else:
                var fallback_name = basename(path) if path.byte_length() > 0 else String("module")
                var full = _lines_range_text(buf, 0, n - 1)
                self._add_chunk(
                    path,
                    fallback_name,
                    "cell",
                    0,
                    n - 1,
                    _truncate_text(String(full.strip()), 120),
                    full,
                )

    def index_file_text(mut self, path: String, content: String):
        """Load `content` into a temporary `TextBuffer` and index it under `path`."""
        var buf = TextBuffer()
        buf.load(decode(content))
        self.index_buffer(path, buf)

    def search(self, query: String, top_k: Int = 15) -> List[SemanticHit]:
        """Rank indexed chunks against `query` using Okapi BM25 (`k1 = 1.5`, `b = 0.75`)
        with `3.0×` exact symbol sub-token boost and `1.8×` signature/docstring boost."""
        var hits = List[SemanticHit]()
        var n_chunks = len(self.chunks)
        if n_chunks == 0 or top_k <= 0:
            return hits^

        var raw_q = split_code_subtokens(query)
        var q_terms = List[String]()
        for qt in raw_q:
            var seen_q = False
            for eq in q_terms:
                if _subtoken_matches(eq, qt):
                    seen_q = True
                    break
            if not seen_q:
                q_terms.append(qt)
        if len(q_terms) == 0:
            return hits^

        var avgdl = Float64(max(1, self.total_tokens)) / Float64(n_chunks)

        # Compute document frequency per unique query term across chunks
        var dfs = List[Int]()
        for qi in range(len(q_terms)):
            var qt = q_terms[qi]
            var df = 0
            for ci in range(n_chunks):
                var found_in_doc = False
                for tok in self.chunks[ci].tokens:
                    if _subtoken_matches(tok, qt):
                        found_in_doc = True
                        break
                if found_in_doc:
                    df += 1
            dfs.append(df)

        for ci in range(n_chunks):
            var dl = Float64(max(1, len(self.chunks[ci].tokens)))
            var sym_toks = split_code_subtokens(self.chunks[ci].symbol_name)
            var sig_toks = split_code_subtokens(self.chunks[ci].signature)

            var score = 0.0
            var matched_q_count = 0

            for qi in range(len(q_terms)):
                if dfs[qi] == 0:
                    continue
                var qt = q_terms[qi]
                var tf = 0.0
                for tok in self.chunks[ci].tokens:
                    if tok == qt:
                        tf += 1.0
                    elif _subtoken_matches(tok, qt):
                        tf += 0.85
                if tf <= 0.0:
                    continue

                matched_q_count += 1
                var df_f = Float64(dfs[qi])
                var n_f = Float64(n_chunks)
                var idf = log(1.0 + (n_f - df_f + 0.5) / (df_f + 0.5))
                var denom = tf + BM25_K1 * (1.0 - BM25_B + BM25_B * (dl / avgdl))
                var term_bm25 = idf * ((tf * (BM25_K1 + 1.0)) / denom)

                var in_sym = False
                for st in sym_toks:
                    if _subtoken_matches(st, qt):
                        in_sym = True
                        break
                var in_sig = False
                if not in_sym:
                    for sgt in sig_toks:
                        if _subtoken_matches(sgt, qt):
                            in_sig = True
                            break

                var boost = 3.0 if in_sym else (1.8 if in_sig else 1.0)
                score += term_bm25 * boost

            if matched_q_count > 0 and score > 0.0:
                if matched_q_count >= 2:
                    score *= 1.0 + 0.12 * Float64(matched_q_count - 1)
                var sc_100 = max(1, Int(score * 100.0 + 0.5))
                var prev = _truncate_text(self.chunks[ci].signature, 110)
                hits.append(
                    SemanticHit(
                        self.chunks[ci].path,
                        self.chunks[ci].symbol_name,
                        self.chunks[ci].kind,
                        self.chunks[ci].start_row,
                        sc_100,
                        prev,
                    )
                )

        # Insertion sort descending by `score_x100` (tie-breaker: earlier row)
        var m = len(hits)
        for i in range(1, m):
            var cur_hit = hits[i].copy()
            var j = i - 1
            while j >= 0 and (
                hits[j].score_x100 < cur_hit.score_x100
                or (hits[j].score_x100 == cur_hit.score_x100 and hits[j].row > cur_hit.row)
            ):
                hits[j + 1] = hits[j].copy()
                j -= 1
            hits[j + 1] = cur_hit^

        if len(hits) > top_k:
            var trimmed = List[SemanticHit]()
            for i in range(top_k):
                trimmed.append(hits[i].copy())
            return trimmed^
        return hits^
