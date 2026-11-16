"""E2E Test Suite for v4.0 Phase 25 (`v3.5` → `v4.0.0`):
Standalone Self-Contained HTML5 Notebook Export (`CM_EXPORT_HTML` + `--export-html` CLI with
collapsible `<details>`, syntax highlighting, Markdown/math, Tensor badges, PNG & animated GIF89a),
Zero-Server `AF_UNIX` Collaborative Live Share (`CM_LIVE_SHARE` host + client real-time cursor &
buffer sync), and `v4.0` Release Artifacts.
"""
from std.testing import assert_equal, assert_true, TestSuite
from std.collections import List
from std.ffi import external_call
from app import App
from screen import CONT
from commands import CM_EXPORT_HTML, CM_LIVE_SHARE
from dialog import D_EXPORT_HTML, D_LIVE_SHARE
from nb_export_share import LiveShareSession, export_ipynb_file_to_html
from signals import own_pid
from util import (
    env_or,
    run_system,
    write_file,
    read_file,
    bytes_to_str,
    str_bytes,
    decode,
    to_str,
    path_exists,
    shell_quote,
)


def _scratch(tag: String) -> String:
    var d = env_or("TMPDIR", "/tmp") + "/tm-v40-p25-" + tag + "-" + String(own_pid())
    _ = run_system("rm -rf " + shell_quote(d) + " && mkdir -p " + shell_quote(d))
    return d


def _clean(d: String):
    _ = run_system("rm -rf " + shell_quote(d))


def _screen_text(app: App) -> String:
    var out = String("")
    for r in range(app.scr.h):
        var cps = List[Int]()
        for c in range(app.scr.w):
            var ch = app.scr.ch[r * app.scr.w + c]
            if ch != CONT:
                cps.append(ch)
        out += to_str(cps) + "\n"
    return out^


def test_p25_e2e_standalone_html5_export_with_folded_code_and_animated_gif() raises:
    var d = _scratch("html")
    var f0 = d + "/anim0.png"
    var f1 = d + "/anim1.png"
    _ = run_system(
        "python3 -c \"import zlib,struct;"
        "sig=b'\\x89PNG\\r\\n\\x1a\\n';"
        "ch=lambda t,b: struct.pack('>I',len(b))+t+b+struct.pack('>I',zlib.crc32(t+b)&0xffffffff);"
        "ihdr=ch(b'IHDR',struct.pack('>IIBBBBB',4,4,8,2,0,0,0));"
        "r0=b''.join(b'\\x00'+b'\\xee\\x44\\x22'*4 for _ in range(4));"
        "r1=b''.join(b'\\x00'+b'\\x22\\xaa\\xee'*4 for _ in range(4));"
        "open(" + shell_quote(f0) + ",'wb').write(sig+ihdr+ch(b'IDAT',zlib.compress(r0))+ch(b'IEND',b''));"
        "open(" + shell_quote(f1) + ",'wb').write(sig+ihdr+ch(b'IDAT',zlib.compress(r1))+ch(b'IEND',b''))\""
    )
    var nb_p = d + "/report.mojo"
    var nb_src = (
        "# %% [markdown]\n"
        "# # Raytracer Report\n"
        "# Energy conservation: $\\alpha + \\beta = 1$\n"
        "# %% Orbit Render\n"
        "def trace_orbit(angle: Float64) -> Float64:\n"
        "    return angle * 2.0\n"
    )
    _ = write_file(nb_p, str_bytes(nb_src))

    var app = App()
    app.cwd = d
    app.scr.resize(120, 36)
    app.open_path(nb_p)
    var ei = app.top_editor()
    # Collapse code cell header row 3 and attach Tensor card + 2-frame animation!
    _ = app.wins[ei].toggle_cell_code_fold(3)
    app.wins[ei].set_cell_output(
        3,
        "rays: [Tensor shape=(64, 64, 3) dtype=float32 min=0.0 max=1.0 mean=0.42]",
        False,
        "ANIM|15|" + f0 + "|" + f1,
        1,
    )

    app.exec(CM_EXPORT_HTML)
    assert_equal(app.dlg.kind, D_EXPORT_HTML)
    app.dismiss_dialog()

    var out_html = d + "/report_out.html"
    assert_true(app.export_active_notebook_html(out_html))
    assert_true(path_exists(out_html))
    var html = bytes_to_str(read_file(out_html))
    assert_true(html.find("<!DOCTYPE html>") >= 0)
    assert_true(html.find("<details class=\"nb-fold\"") >= 0, "Folded cell exported as collapsible <details>")
    assert_true(html.find("nb-badge-tensor") >= 0, "Tensor summary badge styled in HTML")
    assert_true(html.find("data:image/gif;base64,R0lGOD") >= 0, "Multi-frame animation encoded to embedded GIF89a")

    # Also test direct file-to-HTML export on examples/mojo_3d_showcase.ipynb if present
    if path_exists("examples/mojo_3d_showcase.ipynb"):
        var showcase_html = d + "/showcase.html"
        var ex = export_ipynb_file_to_html("examples/mojo_3d_showcase.ipynb", showcase_html)
        assert_true(ex[0], ex[1])
        assert_true(read_file(showcase_html). __len__() > 1000)
    _clean(d)


def test_p25_e2e_live_share_two_apps_collab_sync() raises:
    # Keep Unix socket path short (< 96 chars on macOS & Linux)
    var sock = "/tmp/tm-ls-e2e-" + String(own_pid()) + ".sock"
    var d = _scratch("share")
    var shared_file = d + "/shared_nb.mojo"
    _ = write_file(shared_file, str_bytes("# %% Shared\nvar x = 10\nvar y = 20\n"))

    var host_app = App()
    host_app.scr.resize(120, 36)
    host_app.open_path(shared_file)
    host_app.exec(CM_LIVE_SHARE)
    assert_equal(host_app.dlg.kind, D_LIVE_SHARE)
    host_app.dismiss_dialog()
    host_app.live_share_button(0, sock, "alice")
    assert_true(host_app.live_share.is_active())

    var guest_app = App()
    guest_app.scr.resize(120, 36)
    guest_app.open_path(shared_file)
    guest_app.live_share_button(1, sock, "bob")
    assert_true(guest_app.live_share.is_active())

    # Pump ticks so host accepts guest connection & exchanges initial cursor/buffer state
    for _ in range(4):
        host_app.live_share_tick()
        _ = external_call["usleep", Int32](UInt32(4000))
        guest_app.live_share_tick()
    assert_equal(host_app.live_share.connected_peer_count(), 1)

    # Guest moves cursor to (2, 4) and edits buffer -> Host receives peer cursor + updated text + cell output!
    var gei = guest_app.top_editor()
    guest_app.wins[gei].buf.load(decode("# %% Shared\nvar x = 999\nvar y = 20\n"))
    guest_app.wins[gei].goto(2, 4)
    for _ in range(4):
        guest_app.live_share_tick()
        _ = external_call["usleep", Int32](UInt32(4000))
        host_app.live_share_tick()

    var hei = host_app.top_editor()
    assert_true(to_str(host_app.wins[hei].buf.all_text()).find("var x = 999") >= 0, "Host received guest buffer edit")
    host_app.status_until = 0
    host_app.draw()
    var hscr = _screen_text(host_app)
    assert_true(hscr.find("LIVE:1") >= 0, "Status bar shows LIVE:1 peer pill")
    assert_true(hscr.find("bob") >= 0, "Remote peer cursor badge rendered in editor")

    # Host runs cell output -> Guest receives inline cell output live!
    host_app.cell_apply_output(shared_file, 0, 0, "999", False, List[String]())
    for _ in range(4):
        host_app.live_share_tick()
        _ = external_call["usleep", Int32](UInt32(4000))
        guest_app.live_share_tick()
    assert_equal(len(guest_app.wins[gei].buf.cell_out_texts), 1)
    assert_equal(guest_app.wins[gei].buf.cell_out_texts[0], "999")

    guest_app.live_share.stop()
    host_app.live_share.stop()
    _clean(d)


def main() raises:
    var suite = TestSuite()
    suite.test[test_p25_e2e_standalone_html5_export_with_folded_code_and_animated_gif]()
    suite.test[test_p25_e2e_live_share_two_apps_collab_sync]()
    suite^.run()
