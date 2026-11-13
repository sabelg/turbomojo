"""File > New project (P11-04): a folder with what a Mojo project needs, so that a newcomer
does not have to know pixi first - a pixi.toml (the Modular channel, `mojo` as its
dependency, `hello` and `test` tasks), a hello.mojo, a test for it and a .gitignore.
The IDE writes the files itself (what `pixi init` and `pixi add mojo` would leave),
opens them and then runs `pixi install`, whose output goes to the Message page."""
from std.collections import List
from mojover import mojo_version_of


comptime NP_CHANNELS = "[\"https://conda.modular.com/max\", \"conda-forge\"]"


def np_name_problem(name: String) -> String:
    """Why `name` cannot be a project's name ("" if it can): pixi takes letters, digits,
    `-`, `_` and `.`, starting with a letter or digit."""
    if name.byte_length() == 0:
        return "Give the project a name"
    if name.byte_length() > 64:
        return "The name is too long (64 characters at most)"
    var b = name.as_bytes()
    for k in range(len(b)):
        var c = Int(b[k])
        var letter = (c >= 97 and c <= 122) or (c >= 65 and c <= 90) or (c >= 48 and c <= 57)
        if k == 0 and not letter:
            return "The name must start with a letter or a digit"
        if not letter and c != 45 and c != 95 and c != 46:
            return "The name may have letters, digits, - _ and . only (not \"" + chr(c) + "\")"
    return ""


def np_platform(machine: String) -> String:
    """The pixi platform for what `uname -sm` says ("Linux x86_64" -> "linux-64")."""
    var m = machine.strip().lower()
    var mac = m.startswith("darwin")
    if m.endswith("x86_64") or m.endswith("amd64"):
        return "osx-64" if mac else "linux-64"
    if m.endswith("aarch64") or m.endswith("arm64"):
        return "osx-arm64" if mac else "linux-aarch64"
    return "linux-64"


def np_mojo_spec(built_with: String) -> String:
    """The `mojo` version to ask for: the release series TurboMojo was built with
    ("Mojo 1.2.0 (2016d0cd)" -> ">=1.2,<1.3"), so the IDE and the project's Mojo agree;
    any release ("*") when that is not known."""
    var v = mojo_version_of(built_with)
    var parts = v.split(".")
    if len(parts) < 2:
        return "*"
    try:
        var major = Int(String(parts[0]))
        var minor = Int(String(parts[1]))
        return ">=" + String(major) + "." + String(minor) + ",<" + String(major) + "." + String(minor + 1)
    except:
        return "*"


def np_pixi_toml(name: String, platform: String, mojo_spec: String) -> String:
    var s = String("[workspace]\n")
    s += "name = \"" + name + "\"\n"
    s += "version = \"0.1.0\"\n"
    s += "channels = " + NP_CHANNELS + "\n"
    s += "platforms = [\"" + platform + "\"]\n\n"
    s += "[dependencies]\n"
    s += "mojo = \"" + mojo_spec + "\"\n\n"
    s += "[tasks]\n"
    s += "hello = \"mojo run hello.mojo\"\n"
    s += "test = \"mojo run -I . test_hello.mojo\"\n"
    return s


def np_hello() -> String:
    return """\"\"\"Your first Mojo program: Ctrl-F9 runs it (or `pixi run hello` in a terminal).\"\"\"


def greeting(name: String) -> String:
    return "Hello, " + name + "!"


def main():
    print(greeting("Mojo"))
"""


def np_test() -> String:
    return """\"\"\"Tests for hello.mojo: Run > Pixi tasks > test runs them (or `pixi run test`).\"\"\"
from std.testing import assert_equal, TestSuite
from hello import greeting


def test_greeting() raises:
    assert_equal(greeting("Mojo"), "Hello, Mojo!")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
"""


def np_gitignore() -> String:
    return "# pixi's environments\n.pixi/\n*.egg-info\n"


def np_files(name: String, platform: String, mojo_spec: String) -> List[String]:
    """The project's files as name, content, name, content, ..."""
    var out = List[String]()
    out.append("pixi.toml")
    out.append(np_pixi_toml(name, platform, mojo_spec))
    out.append("hello.mojo")
    out.append(np_hello())
    out.append("test_hello.mojo")
    out.append(np_test())
    out.append(".gitignore")
    out.append(np_gitignore())
    return out^
