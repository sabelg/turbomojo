"""Tests for the copy-to-the-server bundle (P11-11, scripts/bundle.sh): the tar file has
tmide, the libraries it loads and a README naming the glibc it needs; unpacked in a
clean folder and started with an empty environment, it loads every library from the
bundle - none from the project's .pixi - and runs. Uses the gate's build/tmide."""
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from std.collections import List
from version import TURBOMOJO_VERSION
from signals import own_pid
from util import env_or, run_system, run_capture, bytes_to_str, path_exists, shell_quote, getcwd


def sh(cmd: String) -> String:
    return bytes_to_str(run_capture(cmd + " 2>&1").out)


def test_the_bundle_runs_from_a_clean_folder() raises:
    assert_true(path_exists("build/tmide"), "build tmide first (the gate does)")
    var d = env_or("TMPDIR", "/tmp") + "/turbomojo-bundle-test-" + String(own_pid())
    _ = run_system("rm -rf " + shell_quote(d) + " && mkdir -p " + shell_quote(d + "/clean/home"))
    var made = sh("scripts/bundle.sh --tmide build/tmide --out " + shell_quote(d))
    var arch = String(sh("uname -m").strip())
    var name = "turbomojo-" + String(TURBOMOJO_VERSION) + "-linux-" + arch
    assert_true(made.find("bundle: " + d + "/" + name + ".tar.gz") >= 0, made)
    var listing = sh("tar -tzf " + shell_quote(d + "/" + name + ".tar.gz"))
    for f in ["/bin/tmide", "/lib/libKGENCompilerRTShared.so", "/lib/libstdc++.so.6", "/README.txt"]:
        assert_true(listing.find(name + String(f)) >= 0, listing)
    assert_equal(listing.find("libc.so"), -1)                 # (the system's own stay out)
    _ = run_system("tar -C " + shell_quote(d + "/clean") + " -xzf " + shell_quote(d + "/" + name + ".tar.gz"))
    var b = d + "/clean/" + name
    assert_true(sh("readelf -d " + shell_quote(b + "/bin/tmide")).find("Library runpath: [$ORIGIN/../lib]") > 0)
    var env = "env -i PATH=/usr/bin:/bin HOME=" + shell_quote(d + "/clean/home") + " "
    var libs = sh(env + "ldd " + shell_quote(b + "/bin/tmide"))
    assert_equal(libs.find("not found"), -1, libs)
    assert_equal(libs.find(getcwd()), -1, libs)            # nothing from the project
    assert_true(libs.find(b + "/bin/../lib/libKGENCompilerRTShared.so") > 0, libs)
    assert_true(sh(env + shell_quote(b + "/bin/tmide") + " --version").startswith("TurboMojo " + String(TURBOMOJO_VERSION)))
    assert_true(sh(env + "TERM=xterm " + shell_quote(b + "/bin/tmide") + " --caps </dev/null").find("colour depth") > 0)
    var readme = sh("cat " + shell_quote(b + "/README.txt"))
    assert_true(readme.find("It needs glibc 2.") > 0, readme)
    # the build's own tmide is unchanged
    assert_true(sh("readelf -d build/tmide").find("Library runpath: [$ORIGIN") < 0)
    # no tmide: it says so
    assert_true(sh("scripts/bundle.sh --tmide " + shell_quote(d + "/none") + " --out " + shell_quote(d)).find("bundle: no ") >= 0)
    _ = run_system("rm -rf " + shell_quote(d))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
