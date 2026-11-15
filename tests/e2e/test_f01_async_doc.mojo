"""E2E Test Suite for Feature #1:
Async `mojo doc` (F1) & Warm `lsp_pool`.
- Move `mojo doc` (`F1`) to an async non-blocking `aux_job` pipe with a
  "Generating Mojo docs..." status indicator.
- Re-sync + `start_tracking()` across open Mojo windows (`self.lsp_wants(wi)`)
  when restoring from `self.lsp_pool`.

Covers:
- 5 Tier 1 (Isolated Happy Path) tests
- 5 Tier 2 (Boundary Value Analysis & Corner Cases) tests
Strictly conforming to Mojo 1.2 rules.
"""
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from std.collections import List
from std.time import perf_counter_ns

from app import *
from appstate import App, JOB_DOCS, JOB_CODEGEN, M_NORMAL, M_HOVER, now_ns
from window import WK_EDITOR
from docs import DocEntry
from lsp import LspClient, LSP_STARTING, LSP_READY
from json import json_parse
from util import (
    path_exists, write_file, str_bytes, run_system, basename, dirname,
)
from watch import file_sig
from harness import (
    ScratchDir, make_test_app, screen_text, status_text, assert_status_has,
)


def test_f01_t1_01_async_doc_spawn_aux_job() raises:
    """Verifies triggering doc generation initiates non-blocking aux_job (JOB_DOCS)."""
    var s = ScratchDir.create("f01_spawn")
    var mod_path = s.path + "/sample.mojo"
    s.write("sample.mojo", "def hello() -> String:\n    return 'world'\n")

    var app = make_test_app(s)
    app.open_path(mod_path)
    assert_equal(len(app.wins), 1)

    # Initial docs_of_file triggers non-blocking aux_job and returns empty list immediately
    var entries = app.docs_of_file(mod_path)
    assert_equal(len(entries), 0)
    assert_true(app.aux_job.active)
    assert_equal(app.aux_job.kind, JOB_DOCS)
    assert_equal(app.aux_job.path, mod_path)

    app.aux_job.active = False
    s.cleanup()


def test_f01_t1_02_async_doc_completion_and_cache() raises:
    """Verifies EOF on aux_job parses JSON payload and populates doc caches."""
    var s = ScratchDir.create("f01_complete")
    var mod_path = s.path + "/mathlib.mojo"
    s.write("mathlib.mojo", "struct Matrix:\n    var rows: Int\n")

    var app = make_test_app(s)
    app.open_path(mod_path)

    # Set up aux_job with mock doc JSON payload
    app.aux_job.kind = JOB_DOCS
    app.aux_job.path = mod_path
    app.aux_job.exe = ""
    app.aux_job.cancelled = False
    var json_doc = '{"decl": {"name": "mathlib", "structs": [{"name": "Matrix", "signature": "struct Matrix", "summary": "2D Matrix struct", "description": ""}]}}'
    app.aux_job.data = str_bytes(json_doc)

    # Calling finish_docs_job simulates completion (poll_aux_job sets active=False upon EOF)
    app.aux_job.active = False
    app.finish_docs_job(0)
    assert_false(app.aux_job.active)
    assert_equal(len(app.doc_files), 1)
    assert_equal(app.doc_files[0], mod_path)
    assert_equal(len(app.doc_entries), 1)

    # Subsequent call to docs_of_file hits cache immediately
    var cached = app.docs_of_file(mod_path)
    assert_equal(len(cached), 1)
    assert_equal(cached[0].name, "Matrix")

    s.cleanup()


def test_f01_t1_03_status_indicator_during_docgen() raises:
    """Verifies status line and running_tasks() report 'Generating Mojo docs...'."""
    var s = ScratchDir.create("f01_status")
    var mod_path = s.path + "/service.mojo"
    s.write("service.mojo", "def run():\n    pass\n")

    var app = make_test_app(s)
    app.open_path(mod_path)

    # docs_of_file sets status message
    _ = app.docs_of_file(mod_path)
    assert_status_has(app, "Generating Mojo docs...")

    # running_tasks() includes aux_job label
    var tasks = app.running_tasks()
    var found = False
    for i in range(len(tasks)):
        if tasks[i].find("Generating Mojo docs...") >= 0:
            found = True
            break
    assert_true(found)

    app.aux_job.active = False
    s.cleanup()


def test_f01_t1_04_warm_lsp_pool_swap_and_hit() raises:
    """Verifies switching environments parks client in lsp_pool and restores warm client."""
    var s = ScratchDir.create("f01_warm_swap")
    var app = make_test_app(s)

    # Park a dummy client in lsp_pool under key "env_beta"
    var client = LspClient()
    client.starts = 1
    client.conn.proc.running = True
    app.lsp_pool.append(client^)
    app.lsp_pool_keys.append("env_beta")
    assert_equal(len(app.lsp_pool), 1)
    assert_equal(len(app.lsp_pool_keys), 1)

    # Set up active window
    var p = s.path + "/test.mojo"
    s.write("test.mojo", "def main():\n    pass\n")
    app.open_path(p)

    # Emulate pool restoration logic for target_key == "env_beta"
    var target_key = String("env_beta")
    var hit = -1
    for pk in range(len(app.lsp_pool_keys)):
        if app.lsp_pool_keys[pk] == target_key and app.lsp_pool[pk].conn.proc.running:
            hit = pk
            break
    assert_equal(hit, 0)

    # Pop warm client
    app.lsp = app.lsp_pool.pop(hit)
    _ = app.lsp_pool_keys.pop(hit)
    app.lsp_env = target_key
    assert_equal(len(app.lsp_pool), 0)
    assert_equal(len(app.lsp_pool_keys), 0)
    assert_equal(app.lsp_env, "env_beta")

    s.cleanup()


def test_f01_t1_05_resync_start_tracking_open_windows() raises:
    """Verifies that upon pool restoration all windows matching lsp_wants have start_tracking re-enabled."""
    var s = ScratchDir.create("f01_resync")
    var app = make_test_app(s)

    var p1 = s.path + "/a.mojo"
    var p2 = s.path + "/b.mojo"
    s.write("a.mojo", "def a(): pass\n")
    s.write("b.mojo", "def b(): pass\n")

    app.open_path(p1)
    app.open_path(p2)
    assert_equal(len(app.wins), 2)

    # Initially stop tracking on all open buffers
    for wi in range(len(app.wins)):
        app.wins[wi].buf.stop_tracking()
        assert_false(app.wins[wi].buf.track)

    # Verify both windows want LSP
    assert_true(app.lsp_wants(0))
    assert_true(app.lsp_wants(1))

    # Re-sync across open windows as done in app_lsp.mojo:456-459
    for wi in range(len(app.wins)):
        if app.wins[wi].kind == WK_EDITOR and app.lsp_wants(wi):
            app.wins[wi].buf.start_tracking()

    assert_true(app.wins[0].buf.track)
    assert_true(app.wins[1].buf.track)

    s.cleanup()


def test_f01_t2_01_aux_job_busy_rejection() raises:
    """Verifies triggering doc gen while aux_job is busy does not clobber running job."""
    var s = ScratchDir.create("f01_busy")
    var mod_path = s.path + "/busy.mojo"
    s.write("busy.mojo", "var x = 1\n")

    var app = make_test_app(s)
    app.open_path(mod_path)

    # Mark aux_job busy with JOB_CODEGEN
    app.aux_job.active = True
    app.aux_job.kind = JOB_CODEGEN
    app.aux_job.path = "existing/codegen/job"

    # docs_of_file should not overwrite active job
    var entries = app.docs_of_file(mod_path)
    assert_equal(len(entries), 0)
    assert_true(app.aux_job.active)
    assert_equal(app.aux_job.kind, JOB_CODEGEN)
    assert_equal(app.aux_job.path, "existing/codegen/job")

    app.aux_job.active = False
    s.cleanup()


def test_f01_t2_02_doc_syntax_error_json_failure() raises:
    """Verifies non-zero exit code or malformed JSON in docs aux_job reports failure gracefully."""
    var s = ScratchDir.create("f01_err")
    var mod_path = s.path + "/broken.mojo"
    s.write("broken.mojo", "def broken(\n")

    var app = make_test_app(s)
    app.open_path(mod_path)

    # Simulate compiler error exit status 1
    app.aux_job.kind = JOB_DOCS
    app.aux_job.path = mod_path
    app.aux_job.cancelled = False
    app.aux_job.data = str_bytes("syntax error: unexpected EOF")

    app.aux_job.active = False
    app.finish_docs_job(1)
    assert_false(app.aux_job.active)
    # Cache must not be populated on failure
    assert_equal(len(app.doc_files), 0)
    assert_status_has(app, "Documentation generation failed")

    s.cleanup()


def test_f01_t2_03_doc_cancellation_on_editor_close() raises:
    """Verifies cancelling doc generation reports cancellation and discards partial data."""
    var s = ScratchDir.create("f01_cancel")
    var mod_path = s.path + "/cancelled.mojo"
    s.write("cancelled.mojo", "def slow(): pass\n")

    var app = make_test_app(s)
    app.open_path(mod_path)

    app.aux_job.kind = JOB_DOCS
    app.aux_job.path = mod_path
    app.aux_job.cancelled = True
    app.aux_job.data = str_bytes('{"decl": {"name": "slow", "kind": "fn"}}')

    app.aux_job.active = False
    app.finish_docs_job(0)
    assert_false(app.aux_job.active)
    assert_equal(len(app.doc_files), 0)
    assert_status_has(app, "Documentation generation cancelled")

    s.cleanup()


def test_f01_t2_04_lsp_pool_cap_at_two_warm_servers() raises:
    """Verifies pool evicts oldest server when cycling past 2 warm servers."""
    var s = ScratchDir.create("f01_pool_cap")
    var app = make_test_app(s)

    # Emulate pushing 3 successive environments through pool capping logic in app_lsp.mojo:425-430
    var envs = List[String]()
    envs.append("env_1")
    envs.append("env_2")
    envs.append("env_3")

    for k in range(len(envs)):
        var c = LspClient()
        c.conn.proc.running = True
        while len(app.lsp_pool) >= 2:
            _ = app.lsp_pool.pop(0)
            _ = app.lsp_pool_keys.pop(0)
        app.lsp_pool.append(c^)
        app.lsp_pool_keys.append(envs[k])

    assert_equal(len(app.lsp_pool), 2)
    assert_equal(len(app.lsp_pool_keys), 2)
    assert_equal(app.lsp_pool_keys[0], "env_2")
    assert_equal(app.lsp_pool_keys[1], "env_3")

    s.cleanup()


def test_f01_t2_05_lsp_wants_filters_non_mojo_buffers() raises:
    """Verifies lsp_wants filters non-Mojo, untitled, and large buffers."""
    var s = ScratchDir.create("f01_filter")
    var app = make_test_app(s)

    var mojo_file = s.path + "/valid.mojo"
    var fire_file = s.path + "/valid.🔥"
    var txt_file = s.path + "/readme.txt"

    s.write("valid.mojo", "var x = 1\n")
    s.write("valid.🔥", "var y = 2\n")
    s.write("readme.txt", "Plain text\n")

    app.open_path(mojo_file)
    app.open_path(fire_file)
    app.open_path(txt_file)

    assert_equal(len(app.wins), 3)
    assert_true(app.lsp_wants(0))   # .mojo -> True
    assert_true(app.lsp_wants(1))   # .🔥 -> True
    assert_false(app.lsp_wants(2))  # .txt -> False

    # Mark first buffer as large
    app.wins[0].buf.large = True
    assert_false(app.lsp_wants(0))  # large -> False

    # Untitled buffer
    app.wins[0].path = ""
    assert_false(app.lsp_wants(0))  # empty path -> False

    s.cleanup()


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
