"""E2E Test Suite for v3.0 Phase 20 (v3.0):
Apple Silicon Metal Unified-Memory GPU Detection, Omarchy Live Theme Sync (`theme = "omarchy"`),
Desktop Packaging Artifacts (`turbomojo.desktop`, `turbomojo.svg`, `PKGBUILD`), and Plugin & Snippet Hub.
"""
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from std.collections import List
from app import App
from commands import CM_PLUGIN_INSTALL
from dialog import D_PLUGIN_INSTALL
from gpuinfo import parse_gpus, parse_gpu_samples, gpu_short
from omarchy_sync import parse_omarchy_colors_toml
from plugins import install_plugin, update_plugin, remove_plugin, load_plugin_snippets
from signals import own_pid
from util import env_or, run_system, write_file, read_file, str_bytes, bytes_to_str, path_exists, getcwd


def _scratch(tag: String) -> String:
    var d = env_or("TMPDIR", "/tmp") + "/tm-v30-p20-" + tag + "-" + String(own_pid())
    _ = run_system("rm -rf '" + d + "' && mkdir -p '" + d + "'")
    return d


def test_p20_01_apple_silicon_metal_gpu_detection() raises:
    """macOS `system_profiler SPDisplaysDataType` + `sysctl hw.memsize` parses Apple Silicon unified memory."""
    var mac_out = (
        "metal\n"
        "Graphics/Displays:\n"
        "    Apple M3 Max:\n"
        "      Chipset Model: Apple M3 Max\n"
        "      Type: GPU\n"
        "      Total Number of Cores: 40\n"
        "      Metal Support: Metal 3\n"
        "68719476736\n"
    )
    var gpus = parse_gpus(mac_out)
    assert_equal(len(gpus), 1)
    assert_true(gpus[0].name.find("M3 Max") >= 0, gpus[0].name)
    assert_true(gpus[0].memory.find("64 GiB unified") >= 0, gpus[0].memory)
    assert_equal(gpu_short(gpus), "GPU M3 Max")

    var samples = parse_gpu_samples(mac_out)
    assert_equal(len(samples[0]), 1)
    assert_equal(samples[0][0].mem_total_mib, 65536)


def test_p20_02_omarchy_live_theme_sync_and_packaging_files() raises:
    """`theme = "omarchy"` parses `colors.toml` into `Palette` and live-reloads when theme colors change."""
    var d = _scratch("omarchy")
    try:
        var colors_p = d + "/colors.toml"
        var catppuccin = (
            'mode = "dark"\n'
            'accent = "#89b4fa"\n'
            'selection = "#45475a"\n'
            'muted = "#585b70"\n'
            'background = "#1e1e2e"\n'
            'dark_background = "#161622"\n'
            'darker_background = "#101019"\n'
            'lighter_background = "#313244"\n'
            'foreground = "#cdd6f4"\n'
            'dark_foreground = "#6c7086"\n'
            'red = "#f38ba8"\n'
            'yellow = "#f9e2af"\n'
            'green = "#a6e3a1"\n'
            'cyan = "#94e2d5"\n'
            'blue = "#89b4fa"\n'
            'magenta = "#f5c2e7"\n'
        )
        assert_true(write_file(colors_p, str_bytes(catppuccin)))
        var parsed = parse_omarchy_colors_toml(catppuccin)
        assert_true(parsed[0])
        assert_equal(parsed[1].ed_bg, 0x1E1E2E)
        assert_equal(parsed[1].ed_fg, 0xCDD6F4)
        assert_equal(parsed[1].frame_act, 0x89B4FA)

        var app = App()
        app.scr.resize(100, 28)
        app.omarchy_colors_file = colors_p
        app.theme_id = "omarchy"
        app.theme_apply()
        assert_equal(app.pal.ed_bg, 0x1E1E2E)

        # Simulate user running `omarchy theme set tokyo-night` -> `colors.toml` updates on disk
        var tokyo = catppuccin.replace("#1e1e2e", "#1a1b26").replace("#89b4fa", "#7aa2f7")
        _ = run_system("sleep 0.02")
        assert_true(write_file(colors_p, str_bytes(tokyo)))
        assert_true(app.omarchy_theme_recheck())
        assert_equal(app.pal.ed_bg, 0x1A1B26)
        assert_equal(app.pal.frame_act, 0x7AA2F7)

        # Verify packaging artifacts exist and are well-formed
        var root = getcwd()
        assert_true(path_exists(root + "/packaging/turbomojo.desktop"))
        assert_true(path_exists(root + "/packaging/turbomojo.svg"))
        var pkgbuild = bytes_to_str(read_file(root + "/packaging/PKGBUILD"))
        assert_true(pkgbuild.find("turbomojo.desktop") >= 0)
        assert_true(pkgbuild.find("turbomojo.svg") >= 0)
        assert_true(pkgbuild.find("tmvim") >= 0)
    finally:
        _ = run_system("rm -rf '" + d + "'")


def test_p20_03_plugin_and_snippet_hub_git_pin_update_and_remove() raises:
    """Install plugins & snippet packs from local folders and Git repos (@tag pinned), load snippets, update, and remove."""
    var d = _scratch("plughub")
    try:
        var pdir = d + "/installed_plugins"
        var repo = d + "/sample_git_plugin"
        _ = run_system("mkdir -p '" + repo + "'")
        var manifest = 'name = "gpu-snips"\nversion = "1.0.0"\nkind = "snippets"\n'
        var snips = '[snippets.kern]\ndescription = "GPU kernel template"\nbody = "def ${1:kernel}(tid: Int):\\n    $0"\n'
        assert_true(write_file(repo + "/plugin.toml", str_bytes(manifest)))
        assert_true(write_file(repo + "/snippets.toml", str_bytes(snips)))
        _ = run_system(
            "git -C '" + repo + "' init -q && "
            "git -C '" + repo + "' config user.email 't@example.com' && "
            "git -C '" + repo + "' config user.name 'T' && "
            "git -C '" + repo + "' add . && "
            "git -C '" + repo + "' commit -q -m 'v1.0.0' && "
            "git -C '" + repo + "' tag v1.0.0"
        )
        # Advance repo to v1.1.0 so we can test `@v1.0.0` version pinning!
        assert_true(write_file(repo + "/plugin.toml", str_bytes('name = "gpu-snips"\nversion = "1.1.0"\nkind = "snippets"\n')))
        _ = run_system("git -C '" + repo + "' commit -am 'v1.1.0' -q")

        # 1. Install pinned `@v1.0.0`
        var pin_res = install_plugin(repo + "@v1.0.0", pdir)
        assert_true(pin_res.ok, pin_res.message)
        assert_equal(pin_res.version, "1.0.0")
        assert_true(pin_res.has_snippets)
        # Updating a pinned plugin refuses until unpinned
        var up_pinned = update_plugin("gpu-snips", pdir)
        assert_false(up_pinned[0])

        # 2. Load snippet pack into App completion snippets and test D_PLUGIN_INSTALL dialog
        var loaded_snips = load_plugin_snippets(pdir)
        assert_equal(len(loaded_snips), 1)
        assert_equal(loaded_snips[0].prefix, "kern")

        var app = App()
        app.cwd = d
        app.plugins_dir = pdir
        app.plugins_on = False
        app.scr.resize(100, 28)
        app.ensure_user_snippets()
        var found_kern = False
        for us in app.user_snippets:
            if us.trigger == "kern":
                found_kern = True
        assert_true(found_kern)

        app.exec(CM_PLUGIN_INSTALL)
        assert_equal(app.dlg.kind, D_PLUGIN_INSTALL)

        # 3. Reinstall unpinned -> gets v1.1.0, then remove cleanly
        var unpin_res = install_plugin(repo, pdir)
        assert_true(unpin_res.ok)
        assert_equal(unpin_res.version, "1.1.0")
        var rm_res = remove_plugin("gpu-snips", pdir)
        assert_true(rm_res[0])
        assert_false(path_exists(pdir + "/gpu-snips"))
    finally:
        _ = run_system("rm -rf '" + d + "'")


def main() raises:
    var suite = TestSuite()
    suite.test[test_p20_01_apple_silicon_metal_gpu_detection]()
    suite.test[test_p20_02_omarchy_live_theme_sync_and_packaging_files]()
    suite.test[test_p20_03_plugin_and_snippet_hub_git_pin_update_and_remove]()
    suite^.run()
