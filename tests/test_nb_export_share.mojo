"""Unit and end-to-end socket tests for `src/nb_export_share.mojo` (Phase 25)."""
from std.collections import List
from std.ffi import external_call
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from nb_export_share import (
    HtmlCellView,
    html_escape,
    highlight_code_to_html,
    render_markdown_to_html,
    render_notebook_cells_html,
    export_notebook_html,
    export_ipynb_bytes_to_html,
    export_ipynb_file_to_html,
    LS_OFF,
    LS_HOST,
    LS_CLIENT,
    LiveShareEvent,
    PeerCursor,
    encode_live_share_event,
    decode_live_share_event,
    LiveShareSession,
)
from signals import own_pid
from util import (
    str_bytes,
    bytes_to_str,
    read_file,
    write_file,
    path_exists,
    run_system,
    shell_quote,
)


def _sleep_ms(ms: Int):
    _ = external_call["usleep", Int32](UInt32(ms * 1000))


def test_html_escape_and_syntax_highlight() raises:
    assert_equal(
        html_escape("a < b & c > \"d\" 'e' 🔥"),
        "a &lt; b &amp; c &gt; &quot;d&quot; &#39;e&#39; 🔥",
    )

    var mojo_src = (
        "@fieldwise_init\n"
        "struct Pair(Copyable, Movable):\n"
        "    var x: Int\n"
        "\n"
        "def add(a: Int, b: Int) -> Int:\n"
        "    # compute sum <fast>\n"
        "    var msg = \"ok\"\n"
        "    print(len(msg), 42)\n"
        "    return a + b\n"
    )
    var mj_html = highlight_code_to_html(mojo_src, True)
    assert_true(mj_html.startswith("<pre><code>"))
    assert_true(mj_html.endswith("</code></pre>"))
    assert_true(mj_html.find("<span class=\"tk-preproc\">@fieldwise_init</span>") >= 0)
    assert_true(mj_html.find("<span class=\"tk-kw\">struct</span>") >= 0)
    assert_true(mj_html.find("<span class=\"tk-fn\">Pair</span>") >= 0)
    assert_true(mj_html.find("<span class=\"tk-type\">Int</span>") >= 0)
    assert_true(mj_html.find("<span class=\"tk-kw\">def</span>") >= 0)
    assert_true(mj_html.find("<span class=\"tk-fn\">add</span>") >= 0)
    assert_true(mj_html.find("<span class=\"tk-cmt\"># compute sum &lt;fast&gt;</span>") >= 0)
    assert_true(mj_html.find("<span class=\"tk-str\">&quot;ok&quot;</span>") >= 0)
    assert_true(mj_html.find("<span class=\"tk-builtin\">print</span>") >= 0)
    assert_true(mj_html.find("<span class=\"tk-num\">42</span>") >= 0)
    assert_false(mj_html.find("<script") >= 0)

    var py_src = "def greet(xs: list):\n    return len(xs)\n"
    var py_html = highlight_code_to_html(py_src, False)
    assert_true(py_html.find("<span class=\"tk-kw\">def</span>") >= 0)
    assert_true(py_html.find("<span class=\"tk-fn\">greet</span>") >= 0)
    assert_true(py_html.find("<span class=\"tk-builtin\">len</span>") >= 0)


def test_render_markdown_to_html() raises:
    var md = (
        "# Heading One\n"
        "## Heading Two\n"
        "### Heading Three\n"
        "#### Heading Four\n"
        "\n"
        "Energy $E = mc^2$ with **bold**, *italic*, and `inline_code<T>`.\n"
        "\n"
        "- First bullet\n"
        "* Second [TurboMojo](https://modular.com) & [Bad](javascript:alert(1))\n"
        "\n"
        "> Quoted wisdom\n"
        "\n"
        "```mojo\n"
        "comptime N = 16\n"
        "```\n"
    )
    var html = render_markdown_to_html(md)
    assert_true(html.find("<h1>Heading One</h1>") >= 0)
    assert_true(html.find("<h2>Heading Two</h2>") >= 0)
    assert_true(html.find("<h3>Heading Three</h3>") >= 0)
    assert_true(html.find("<h4>Heading Four</h4>") >= 0)
    assert_true(html.find("<span class=\"nb-math\">E = mc^2</span>") >= 0)
    assert_true(html.find("<strong>bold</strong>") >= 0)
    assert_true(html.find("<em>italic</em>") >= 0)
    assert_true(html.find("<code>inline_code&lt;T&gt;</code>") >= 0)
    assert_true(html.find("<ul><li>First bullet</li><li>Second ") >= 0)
    assert_true(html.find("<a href=\"https://modular.com\">TurboMojo</a>") >= 0)
    assert_true(html.find("javascript:") < 0)
    assert_true(html.find("<blockquote><p>Quoted wisdom</p></blockquote>") >= 0)
    assert_true(html.find("<span class=\"tk-kw\">comptime</span>") >= 0)


def test_export_ipynb_bytes_and_file_to_html() raises:
    # 1x1 transparent PNG base64 and 1x1 GIF base64
    var png_b64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg=="
    var gif_b64 = "R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7"

    var ipynb_json = (
        "{\n"
        "  \"cells\": [\n"
        "    {\n"
        "      \"cell_type\": \"markdown\",\n"
        "      \"metadata\": {},\n"
        "      \"source\": [\"# Kernel Benchmark\\n\", \"Loss curve $\\\\mathcal{L}(\\\\theta)$ and **SIMD** speedup.\"]\n"
        "    },\n"
        "    {\n"
        "      \"cell_type\": \"code\",\n"
        "      \"execution_count\": 1,\n"
        "      \"metadata\": {\"title\": \"Tensor Stats\"},\n"
        "      \"outputs\": [\n"
        "        {\"name\": \"stdout\", \"output_type\": \"stream\", \"text\": [\"w: [Tensor float32[4, 8] · min=0.0 max=1.0]\\n\", \"df: [DataFrame 10×2 · cols: x, y]\\n\"]}\n"
        "      ],\n"
        "      \"source\": [\"var x = 42\\n\", \"print(x)\"]\n"
        "    },\n"
        "    {\n"
        "      \"cell_type\": \"code\",\n"
        "      \"execution_count\": 2,\n"
        "      \"metadata\": {\"title\": \"Plot Generator\", \"jupyter\": {\"source_hidden\": true}},\n"
        "      \"outputs\": [\n"
        "        {\n"
        "          \"data\": {\n"
        "            \"image/png\": \"" + png_b64 + "\",\n"
        "            \"image/gif\": \"" + gif_b64 + "\",\n"
        "            \"text/plain\": [\"<Figure>\"]\n"
        "          },\n"
        "          \"metadata\": {},\n"
        "          \"output_type\": \"display_data\"\n"
        "        }\n"
        "      ],\n"
        "      \"source\": [\"# hidden plot builder\\n\", \"var hidden_secret = 99\"]\n"
        "    },\n"
        "    {\n"
        "      \"cell_type\": \"code\",\n"
        "      \"execution_count\": 3,\n"
        "      \"metadata\": {},\n"
        "      \"outputs\": [\n"
        "        {\"ename\": \"ValueError\", \"evalue\": \"bad shape\", \"output_type\": \"error\", \"traceback\": [\"Traceback (most recent call last):\", \"ValueError: bad shape\"]}\n"
        "      ],\n"
        "      \"source\": [\"raise Error(\\\"bad shape\\\")\"]\n"
        "    }\n"
        "  ],\n"
        "  \"metadata\": {\n"
        "    \"kernelspec\": {\"display_name\": \"Mojo\", \"language\": \"mojo\", \"name\": \"mojo\"}\n"
        "  },\n"
        "  \"nbformat\": 4,\n"
        "  \"nbformat_minor\": 5\n"
        "}\n"
    )

    var res = export_ipynb_bytes_to_html("Bench Report", str_bytes(ipynb_json))
    assert_true(res[0], res[2])
    assert_equal(res[2], "")
    var html = res[1]

    assert_true(html.startswith("<!DOCTYPE html>"))
    assert_true(html.find("@media (prefers-color-scheme: light)") >= 0)
    assert_true(html.find("<title>Bench Report</title>") >= 0)
    assert_true(html.find("<h1>Kernel Benchmark</h1>") >= 0)
    assert_true(html.find("<span class=\"nb-math\">\\mathcal{L}(\\theta)</span>") >= 0)
    assert_true(html.find("In [1]") >= 0)
    assert_true(html.find("Out [1]") >= 0)
    assert_true(html.find("nb-badge-tensor") >= 0)
    assert_true(html.find("nb-badge-df") >= 0)

    # Hidden-code cell 2 must wrap source in collapsed <details class="nb-fold"> (no open attr)
    # while keeping Out [2] and embedded PNG/GIF images outside </details>!
    var det_start = html.find("<details class=\"nb-fold\">")
    var det_end = html.find("</details>", det_start)
    var out2_pos = html.find("Out [2]")
    var png_pos = html.find("src=\"data:image/png;base64," + png_b64 + "\"")
    var gif_pos = html.find("src=\"data:image/gif;base64," + gif_b64 + "\"")
    assert_true(det_start > 0)
    assert_true(det_end > det_start)
    assert_true(out2_pos > det_end)
    assert_true(png_pos > det_end)
    assert_true(gif_pos > det_end)

    # Error cell 3 styling
    assert_true(html.find("nb-output-error") >= 0)
    assert_true(html.find("nb-traceback") >= 0)
    assert_true(html.find("ValueError: bad shape") >= 0)

    # Invalid JSON handling
    var bad = export_ipynb_bytes_to_html("Broken", str_bytes("{not valid json"))
    assert_false(bad[0])
    assert_equal(bad[1], "")
    assert_true(bad[2].byte_length() > 0)

    # Direct HtmlCellView + export_notebook_html check
    var manual_cells = List[HtmlCellView]()
    var uris = List[String]()
    uris.append("data:image/gif;base64," + gif_b64)
    manual_cells.append(
        HtmlCellView(0, "Demo", False, False, 1, "x = 1", "1", False, uris^)
    )
    var direct_html = export_notebook_html("Direct", manual_cells, False)
    assert_equal(direct_html, render_notebook_cells_html("Direct", manual_cells, False))
    assert_true(direct_html.find("Python 3") >= 0)

    # File-based export for both .ipynb and # %% .mojo source
    var tmp_dir = "/tmp/tm-test-nb-html-" + String(own_pid())
    _ = run_system("rm -rf " + shell_quote(tmp_dir) + " && mkdir -p " + shell_quote(tmp_dir))

    var in_ipynb = tmp_dir + "/demo.ipynb"
    var out_html1 = tmp_dir + "/demo.html"
    assert_true(write_file(in_ipynb, str_bytes(ipynb_json)))
    var f_res1 = export_ipynb_file_to_html(in_ipynb, out_html1)
    assert_true(f_res1[0], f_res1[1])
    assert_true(path_exists(out_html1))
    assert_true(bytes_to_str(read_file(out_html1)).find("Kernel Benchmark") >= 0)

    var in_mojo = tmp_dir + "/cells.mojo"
    var out_html2 = tmp_dir + "/cells.html"
    var pct_src = (
        "# %% [markdown] Intro\n"
        "# ## Native Mojo Cells\n"
        "# Speedup $2\\times$.\n"
        "# %% Compute\n"
        "def run() -> Int:\n"
        "    return 7\n"
    )
    assert_true(write_file(in_mojo, str_bytes(pct_src)))
    var f_res2 = export_ipynb_file_to_html(in_mojo, out_html2)
    assert_true(f_res2[0], f_res2[1])
    var mojo_exported = bytes_to_str(read_file(out_html2))
    assert_true(mojo_exported.find("<h2>Native Mojo Cells</h2>") >= 0)
    assert_true(mojo_exported.find("<span class=\"tk-fn\">run</span>") >= 0)

    _ = run_system("rm -rf " + shell_quote(tmp_dir))


def test_live_share_wire_codec() raises:
    var ev = LiveShareEvent(
        "sync_full",
        "alice",
        "/work/kernel.mojo",
        12,
        4,
        28,
        "def main():\n    print(\"🔥 hello\")\n",
    )
    var wire = encode_live_share_event(ev)
    assert_true(wire.endswith("\n"))
    # Must be single-line JSON (only the trailing '\n')
    assert_equal(wire.find("\n"), wire.byte_length() - 1)

    var dec = decode_live_share_event(wire)
    assert_true(dec[0])
    assert_equal(dec[1].kind, "sync_full")
    assert_equal(dec[1].peer_name, "alice")
    assert_equal(dec[1].path, "/work/kernel.mojo")
    assert_equal(dec[1].row, 12)
    assert_equal(dec[1].col, 4)
    assert_equal(dec[1].end_row, 28)
    assert_equal(dec[1].text, "def main():\n    print(\"🔥 hello\")\n")

    assert_false(decode_live_share_event("")[0])
    assert_false(decode_live_share_event("{bad")[0])
    assert_false(decode_live_share_event("{\"row\": 1}")[0])


def test_live_share_loopback_host_and_two_guests() raises:
    var sock_path = "/tmp/tm-test-share-" + String(own_pid()) + ".sock"
    var host = LiveShareSession()
    var guest1 = LiveShareSession()
    var guest2 = LiveShareSession()

    assert_equal(host.mode, LS_OFF)
    assert_true(host.start_host(sock_path, "host"))
    assert_equal(host.mode, LS_HOST)
    assert_true(path_exists(sock_path))

    assert_true(guest1.connect_client(sock_path, "guest1"))
    assert_equal(guest1.mode, LS_CLIENT)
    assert_true(guest2.connect_client(sock_path, "guest2"))
    assert_equal(guest2.mode, LS_CLIENT)

    _sleep_ms(15)
    var host_init = host.poll_events()
    assert_equal(host.connected_peer_count(), 2)
    var saw_g1_hello = False
    var saw_g2_hello = False
    for i in range(len(host_init)):
        if host_init[i].kind == "hello" and host_init[i].peer_name == "guest1":
            saw_g1_hello = True
        if host_init[i].kind == "hello" and host_init[i].peer_name == "guest2":
            saw_g2_hello = True
    assert_true(saw_g1_hello)
    assert_true(saw_g2_hello)

    # Drain any relayed hello frames on guests
    _sleep_ms(10)
    _ = guest1.poll_events()
    _ = guest2.poll_events()

    # 1. Host broadcasts cursor + sync_full + cell_out to both guests
    host.broadcast(LiveShareEvent("cursor", "host", "nb.mojo", 5, 10, 5, ""))
    host.broadcast(
        LiveShareEvent("sync_full", "host", "nb.mojo", 0, 0, 2, "# %% Cell 1\nvar a = 10\n")
    )
    host.broadcast(
        LiveShareEvent("cell_out", "host", "nb.mojo", 0, 1, 0, "10\n")
    )

    _sleep_ms(15)
    var g1_evs = guest1.poll_events()
    var g2_evs = guest2.poll_events()
    assert_equal(len(g1_evs), 3)
    assert_equal(len(g2_evs), 3)
    assert_equal(g1_evs[0].kind, "cursor")
    assert_equal(g1_evs[1].kind, "sync_full")
    assert_equal(g1_evs[1].text, "# %% Cell 1\nvar a = 10\n")
    assert_equal(g1_evs[2].kind, "cell_out")
    assert_equal(g2_evs[2].text, "10\n")

    assert_equal(len(guest1.peer_cursors), 1)
    assert_equal(guest1.peer_cursors[0].peer_name, "host")
    assert_equal(guest1.peer_cursors[0].row, 5)
    assert_equal(guest1.peer_cursors[0].col, 10)

    # 2. guest1 broadcasts cursor + edit_line -> host receives AND relays to guest2 (not back to guest1)
    guest1.broadcast(LiveShareEvent("cursor", "guest1", "nb.mojo", 1, 8, 1, ""))
    guest1.broadcast(LiveShareEvent("edit_line", "guest1", "nb.mojo", 1, 0, 1, "var a = 42"))

    _sleep_ms(15)
    var h_evs = host.poll_events()
    assert_equal(len(h_evs), 2)
    assert_equal(h_evs[0].kind, "cursor")
    assert_equal(h_evs[0].peer_name, "guest1")
    assert_equal(h_evs[1].kind, "edit_line")
    assert_equal(h_evs[1].text, "var a = 42")
    assert_equal(len(host.peer_cursors), 1)
    assert_equal(host.peer_cursors[0].peer_name, "guest1")
    assert_equal(host.peer_cursors[0].row, 1)
    assert_equal(host.peer_cursors[0].col, 8)

    _sleep_ms(15)
    var g1_echo = guest1.poll_events()
    var g2_relayed = guest2.poll_events()
    assert_equal(len(g1_echo), 0)
    assert_equal(len(g2_relayed), 2)
    assert_equal(g2_relayed[0].kind, "cursor")
    assert_equal(g2_relayed[0].peer_name, "guest1")
    assert_equal(g2_relayed[1].kind, "edit_line")
    assert_equal(g2_relayed[1].text, "var a = 42")

    # guest2 now tracks both host and guest1 cursors; updating guest1 cursor updates in place
    assert_equal(len(guest2.peer_cursors), 2)
    guest1.broadcast(LiveShareEvent("cursor", "guest1", "nb.mojo", 9, 3, 9, ""))
    _sleep_ms(15)
    _ = host.poll_events()
    _sleep_ms(15)
    _ = guest2.poll_events()
    assert_equal(len(host.peer_cursors), 1)
    assert_equal(host.peer_cursors[0].row, 9)
    assert_equal(host.peer_cursors[0].col, 3)
    assert_equal(len(guest2.peer_cursors), 2)

    var pc_check = PeerCursor("manual", "a.mojo", 1, 2)
    assert_equal(pc_check.peer_name, "manual")

    # 3. Clean disconnect and stop() socket cleanup
    guest2.stop()
    assert_equal(guest2.mode, LS_OFF)
    _sleep_ms(15)
    _ = host.poll_events()
    assert_equal(host.connected_peer_count(), 1)

    host.stop()
    assert_equal(host.mode, LS_OFF)
    assert_false(path_exists(sock_path))

    _sleep_ms(15)
    _ = guest1.poll_events()
    assert_equal(guest1.mode, LS_OFF)
    guest1.stop()


def test_live_share_partial_frames_large_payload_and_errors() raises:
    var sock_path = "/tmp/tm-test-share-frag-" + String(own_pid()) + ".sock"
    var host = LiveShareSession()
    assert_false(host.connect_client("/tmp/tm-nonexistent-sock-" + String(own_pid()) + ".sock"))

    var overlong = "/tmp/"
    for _ in range(120):
        overlong += "x"
    assert_false(host.start_host(overlong))

    assert_true(host.start_host(sock_path, "host"))
    # Re-starting host on existing socket path unlinks stale socket cleanly
    assert_true(host.start_host(sock_path, "host"))

    var guest = LiveShareSession()
    assert_true(guest.connect_client(sock_path, "guest"))
    _sleep_ms(10)
    _ = host.poll_events()

    # Raw split write right in the middle of a 4-byte UTF-8 emoji ('🔥' = F0 9F 94 A5)
    var full_frame = str_bytes(
        encode_live_share_event(
            LiveShareEvent("edit_line", "guest", "utf8.mojo", 3, 0, 3, "var s = \"🔥mojo\"")
        )
    )
    var split_at = -1
    for i in range(len(full_frame)):
        if full_frame[i] == 0xF0:
            split_at = i + 2
            break
    assert_true(split_at > 0)

    var gfd = guest.client_fds[0]
    _ = external_call["write", Int](Int32(gfd), full_frame.unsafe_ptr(), split_at)
    _sleep_ms(10)
    var partial_evs = host.poll_events()
    assert_equal(len(partial_evs), 0)

    _ = external_call["write", Int](
        Int32(gfd), full_frame.unsafe_ptr().unsafe_offset(split_at), len(full_frame) - split_at
    )
    _sleep_ms(10)
    var done_evs = host.poll_events()
    assert_equal(len(done_evs), 1)
    assert_equal(done_evs[0].text, "var s = \"🔥mojo\"")

    # Large >64KB sync_full broadcast
    var big_lines = List[String]()
    for r in range(2000):
        big_lines.append("var line_" + String(r) + " = " + String(r * 3))
    var big_src = "\n".join(big_lines)
    host.broadcast(LiveShareEvent("sync_full", "host", "big.mojo", 0, 0, 2000, big_src))
    _sleep_ms(20)
    var big_evs = guest.poll_events()
    assert_equal(len(big_evs), 1)
    assert_equal(big_evs[0].kind, "sync_full")
    assert_equal(big_evs[0].text.byte_length(), big_src.byte_length())

    guest.stop()
    host.stop()
    assert_false(path_exists(sock_path))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
