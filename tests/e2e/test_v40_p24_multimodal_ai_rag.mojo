"""E2E Test Suite for v4.0 Phase 24 (`v3.4`):
Multimodal Notebook AI Context (Code + Live Tensor/DataFrame Schemas + Plot Vision Payloads + IPC),
Isolated `git worktree` Background Task Runner with Shadow `mojo build` Verification & `offer_edit()`,
and Local Hybrid `mojocst` AST + Okapi BM25 Semantic Codebase Search (`CM_SEMANTIC_SEARCH`).
"""
from std.testing import assert_equal, assert_true, TestSuite
from std.collections import List
from app import App
from commands import CM_SEMANTIC_SEARCH, CM_AGENT_WORKTREE_TASK
from dialog import D_SEMANTIC_SEARCH, D_WORKTREE_TASK
from json import json_parse
from nb_ai_rag import build_multimodal_openai_request_json
from signals import own_pid
from util import (
    env_or,
    run_system,
    write_file,
    read_file,
    bytes_to_str,
    str_bytes,
    to_str,
    shell_quote,
)


def _scratch(tag: String) -> String:
    var d = env_or("TMPDIR", "/tmp") + "/tm-v40-p24-" + tag + "-" + String(own_pid())
    _ = run_system("rm -rf " + shell_quote(d) + " && mkdir -p " + shell_quote(d))
    return d


def _clean(d: String):
    _ = run_system("rm -rf " + shell_quote(d))


def test_p24_e2e_multimodal_notebook_ai_context_and_ipc_query() raises:
    var d = _scratch("mmai")
    var plot_p = d + "/ray_band.png"
    _ = run_system(
        "python3 -c \"import zlib,struct;"
        "sig=b'\\x89PNG\\r\\n\\x1a\\n';"
        "ch=lambda t,b: struct.pack('>I',len(b))+t+b+struct.pack('>I',zlib.crc32(t+b)&0xffffffff);"
        "ihdr=ch(b'IHDR',struct.pack('>IIBBBBB',2,2,8,2,0,0,0));"
        "raw=b'\\x00\\xff\\x00\\x00\\xff\\x00\\x00\\x00\\x00\\x00\\xff\\x00\\x00\\xff';"
        "open(" + shell_quote(plot_p) + ",'wb').write(sig+ihdr+ch(b'IDAT',zlib.compress(raw))+ch(b'IEND',b''))\""
    )
    var nb_path = d + "/experiment.py"
    var nb_src = (
        "# %% Setup\n"
        "import numpy as np\n"
        "def fft_mag(sig):\n"
        "    return np.abs(np.fft.rfft(sig))\n"
        "\n"
        "# %% Scene 2\n"
        "spec = fft_mag(signal)\n"
    )
    _ = write_file(nb_path, str_bytes(nb_src))

    var app = App()
    app.cwd = d
    app.scr.resize(120, 36)
    app.open_path(nb_path)
    var ei = app.top_editor()
    app.wins[ei].set_cell_output(
        0,
        "signal: [Array shape=(4096,) dtype=float32 min=-1.0 max=1.0 mean=0.0]",
        False,
        "",
        1,
    )
    app.wins[ei].set_cell_output(
        5,
        "NameError: name 'signal' is not defined",
        True,
        plot_p,
        2,
    )
    app.wins[ei].goto(6, 0)
    var ctx = app.active_notebook_ai_context(ei, 2)
    assert_equal(ctx.active_cell_index, 1)
    assert_true(ctx.preceding_defs_summary.find("fft_mag") >= 0)
    assert_true(len(ctx.live_schemas) >= 1)
    assert_true(ctx.last_error.find("NameError") >= 0)
    assert_equal(len(ctx.attached_png_b64), 1)

    var req_json = build_multimodal_openai_request_json(
        "qwen2.5-vl",
        "System",
        ctx.prompt_block + "\nFix Scene 2",
        ctx.attached_png_b64,
    )
    assert_true(req_json.find("data:image/png;base64,") >= 0)
    assert_true(json_parse(req_json).ok)

    # Verify IPC `get_notebook_context` returns structured JSON with schemas, traceback & plots!
    var ipc_dir = d + "/ipc"
    app.ipc_enable(ipc_dir)
    _ = write_file(ipc_dir + "/req-nb1.json", str_bytes("{\"id\":\"nb1\",\"op\":\"get_notebook_context\"}\n"))
    assert_true(app.ipc_tick())
    var resp_raw = bytes_to_str(read_file(ipc_dir + "/resp-nb1.json"))
    var resp_doc = json_parse(resp_raw)
    assert_true(resp_doc.ok and resp_doc.bool(resp_doc.get(0, "ok"), False), resp_raw)
    assert_true(resp_raw.find("NameError") >= 0 and resp_raw.find("ray_band.png") >= 0)
    _clean(d)


def test_p24_e2e_isolated_worktree_verified_patch_and_semantic_search() raises:
    var d = _scratch("wt_rag")
    var repo = d + "/repo"
    _ = run_system(
        "mkdir -p " + shell_quote(repo)
        + " && cd " + shell_quote(repo)
        + " && git init -q"
        + " && git config user.email 'test@turbomojo.dev'"
        + " && git config user.name 'TurboMojo Test'"
    )
    var mod_path = repo + "/math_ops.mojo"
    _ = write_file(
        mod_path,
        str_bytes(
            "\"\"\"Fast vector norms and cosine similarity.\"\"\"\n\n"
            "def compute_l2_norm(x: Float64, y: Float64) -> Float64:\n"
            "    return x * x + y * y\n"
        ),
    )
    var png_helper = repo + "/image_loader.mojo"
    _ = write_file(
        png_helper,
        str_bytes(
            "\"\"\"Decode PNG headers and RGBA scanlines.\"\"\"\n\n"
            "def decodePngRgbaHeader(width: Int, height: Int) -> Int:\n"
            "    return width * height * 4\n"
        ),
    )
    _ = run_system("cd " + shell_quote(repo) + " && git add . && git commit -q -m 'init'")

    var app = App()
    app.cwd = repo
    app.project_dir = repo
    app.trust_enforced = False
    app.scr.resize(120, 36)
    app.open_path(mod_path)

    # 1) Test CM_SEMANTIC_SEARCH dialog & natural-language AST+BM25 ranking
    app.exec(CM_SEMANTIC_SEARCH)
    assert_equal(app.dlg.kind, D_SEMANTIC_SEARCH)
    app.dismiss_dialog()
    app.semantic_search_run("decode png rgba scanlines")
    assert_true(len(app.sem_hits) >= 1)
    assert_true(app.sem_hits[0].path.endswith("image_loader.mojo"))
    assert_equal(app.sem_hits[0].symbol_name, "decodePngRgbaHeader")

    # 2) Test CM_AGENT_WORKTREE_TASK: valid Mojo 1.2 edit in isolated worktree passes shadow `mojo build`
    # and applies cleanly into the open buffer via `offer_edit()`!
    app.exec(CM_AGENT_WORKTREE_TASK)
    assert_equal(app.dlg.kind, D_WORKTREE_TASK)
    app.dismiss_dialog()
    app.worktree_task_run(
        "python3 -c \"p='math_ops.mojo'; s=open(p).read().replace('x * x + y * y', '(x * x + y * y) * 1.0'); open(p,'w').write(s)\""
    )
    var updated = to_str(app.wins[app.top_editor()].buf.all_text())
    assert_true(updated.find("(x * x + y * y) * 1.0") >= 0, "Shadow-verified worktree patch applied via offer_edit")

    # 3) Invalid Mojo syntax in isolated worktree is caught by shadow `mojo build` and REJECTED!
    var before_bad = to_str(app.wins[app.top_editor()].buf.all_text())
    app.worktree_task_run(
        "python3 -c \"open('math_ops.mojo','w').write('def broken( -> Int:\\n    return ???\\n')\""
    )
    assert_equal(to_str(app.wins[app.top_editor()].buf.all_text()), before_bad)
    _clean(d)


def main() raises:
    var suite = TestSuite()
    suite.test[test_p24_e2e_multimodal_notebook_ai_context_and_ipc_query]()
    suite.test[test_p24_e2e_isolated_worktree_verified_patch_and_semantic_search]()
    suite^.run()
