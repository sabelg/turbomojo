"""File > New project (P11-04): a folder with what a Mojo project needs, so that a newcomer
does not have to know pixi first - a pixi.toml (the Modular channel, `mojo` as its
dependency, `hello` and `test` tasks), a hello.mojo, a test for it and a .gitignore.
The IDE writes the files itself (what `pixi init` and `pixi add mojo` would leave),
opens them and then runs `pixi install`, whose output goes to the Message page."""
from std.collections import List
from mojover import mojo_version_of


comptime NP_CHANNELS = "[\"https://conda.modular.com/max\", \"conda-forge\"]"
comptime NP_TMPL_EXEC = 0       # Executable + TestSuite (default)
comptime NP_TMPL_PKG = 1        # Library package (src/<pkg>/__init__.mojo + tests/)
comptime NP_TMPL_GPU = 2        # GPU kernel (DeviceContext + TileTensor)
comptime NP_TMPL_PYEXT = 3      # Python <-> Mojo extension module (PythonModuleBuilder)


def np_template_names() -> List[String]:
    var out = List[String]()
    out.append("Executable + TestSuite       (hello.mojo, test_hello.mojo)")
    out.append("Mojo Package + TestSuite     (src/<pkg>/__init__.mojo, tests/)")
    out.append("GPU Kernel (TileTensor)      (kernel.mojo, DeviceContext, MAX)")
    out.append("Python Extension Module      (<mod>.mojo, PythonModuleBuilder)")
    return out^


def np_pkg_ident(name: String) -> String:
    """Valid Mojo/Python module identifier derived from the folder name (`hello-mojo` -> `hello_mojo`)."""
    var out = String("")
    for b in name.as_bytes():
        var c = Int(b)
        if (c >= 97 and c <= 122) or (c >= 65 and c <= 90) or (c >= 48 and c <= 57):
            out += chr(c)
        else:
            out += "_"
    if out.byte_length() == 0:
        return "app"
    var first = Int(out.as_bytes()[0])
    if first >= 48 and first <= 57:
        out = "m_" + out
    return out


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
    return "# pixi's environments\n.pixi/\n*.egg-info\n__mojocache__/\nbuild/\n*.so\n"


def np_pkg_toml(name: String, pkg: String, platform: String, mojo_spec: String) -> String:
    var s = String("[workspace]\n")
    s += "name = \"" + name + "\"\n"
    s += "version = \"0.1.0\"\n"
    s += "channels = " + NP_CHANNELS + "\n"
    s += "platforms = [\"" + platform + "\"]\n\n"
    s += "[dependencies]\n"
    s += "mojo = \"" + mojo_spec + "\"\n\n"
    s += "[tasks]\n"
    s += "package = \"mojo package src/" + pkg + " -o build/" + pkg + ".mojopkg\"\n"
    s += "test = \"mojo run -I src tests/test_" + pkg + ".mojo\"\n"
    return s


def np_pkg_init(pkg: String) -> String:
    return "\"\"\"Package `" + pkg + "`: reusable Mojo types and functions.\"\"\"\n\n\ndef add(a: Int, b: Int) -> Int:\n    return a + b\n"


def np_pkg_test(pkg: String) -> String:
    return "\"\"\"Unit tests for `" + pkg + "` (`pixi run test`).\"\"\"\nfrom std.testing import assert_equal, TestSuite\nfrom " + pkg + " import add\n\n\ndef test_add() raises:\n    assert_equal(add(20, 22), 42)\n\n\ndef main() raises:\n    TestSuite.discover_tests[__functions_in_module()]().run()\n"


def np_gpu_toml(name: String, platform: String, mojo_spec: String) -> String:
    var s = String("[workspace]\n")
    s += "name = \"" + name + "\"\n"
    s += "version = \"0.1.0\"\n"
    s += "channels = " + NP_CHANNELS + "\n"
    s += "platforms = [\"" + platform + "\"]\n\n"
    s += "[dependencies]\n"
    s += "max = \"*\"\n"
    s += "mojo = \"" + mojo_spec + "\"\n\n"
    s += "[tasks]\n"
    s += "kernel = \"mojo run kernel.mojo\"\n"
    s += "test = \"mojo run -I . test_kernel.mojo\"\n"
    return s


def np_gpu_kernel() -> String:
    return """\"\"\"GPU vector addition kernel using DeviceContext and TileTensor.\"\"\"
from std.math import ceildiv
from std.sys import has_accelerator
from max.gpu import global_idx
from max.gpu.host import DeviceContext
from layout import TileTensor, row_major

comptime dtype = DType.float32
comptime N = 1024
comptime BLOCK = 256
comptime vec_layout = row_major[N]()


def add_kernel(
    a: TileTensor[dtype, type_of(vec_layout), MutAnyOrigin],
    b: TileTensor[dtype, type_of(vec_layout), MutAnyOrigin],
    c: TileTensor[dtype, type_of(vec_layout), MutAnyOrigin],
    size: Int,
):
    comptime assert a.flat_rank == 1 and b.flat_rank == 1 and c.flat_rank == 1
    var tid = global_idx.x
    if tid < size:
        c[tid] = a[tid] + b[tid]


def add_scalar(a: Float32, b: Float32) -> Float32:
    return a + b


def main() raises:
    comptime if not has_accelerator():
        print("No GPU accelerator detected; scalar check:", add_scalar(1.0, 2.0))
    else:
        var ctx = DeviceContext()
        var a_buf = ctx.enqueue_create_buffer[dtype](N)
        var b_buf = ctx.enqueue_create_buffer[dtype](N)
        var c_buf = ctx.enqueue_create_buffer[dtype](N)
        a_buf.enqueue_fill(1.0)
        b_buf.enqueue_fill(2.0)
        ctx.enqueue_function[add_kernel](
            TileTensor(a_buf, vec_layout),
            TileTensor(b_buf, vec_layout),
            TileTensor(c_buf, vec_layout),
            N,
            grid_dim=ceildiv(N, BLOCK),
            block_dim=BLOCK,
        )
        with c_buf.map_to_host() as host:
            var out = TileTensor(host, vec_layout)
            comptime assert out.flat_rank == 1
            print("c[0] =", out[0])
"""


def np_gpu_test() -> String:
    return """\"\"\"Tests for kernel.mojo (`pixi run test`).\"\"\"
from std.testing import assert_equal, TestSuite
from kernel import add_scalar


def test_scalar_ref() raises:
    assert_equal(add_scalar(1.5, 2.5), Float32(4.0))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
"""


def np_pyext_toml(name: String, mod: String, platform: String, mojo_spec: String) -> String:
    var s = String("[workspace]\n")
    s += "name = \"" + name + "\"\n"
    s += "version = \"0.1.0\"\n"
    s += "channels = " + NP_CHANNELS + "\n"
    s += "platforms = [\"" + platform + "\"]\n\n"
    s += "[dependencies]\n"
    s += "mojo = \"" + mojo_spec + "\"\n"
    s += "python = \">=3.11\"\n\n"
    s += "[tasks]\n"
    s += "build = \"mojo build --emit shared-lib " + mod + ".mojo -o " + mod + ".so\"\n"
    s += "test = \"python test_ext.py\"\n"
    return s


def np_pyext_mojo(mod: String) -> String:
    var s = String("\"\"\"Mojo Python extension module (`import mojo.importer; import ") + mod + "`).\"\"\"\n"
    s += "from std.os import abort\n"
    s += "from std.python import PythonObject\n"
    s += "from std.python.bindings import PythonModuleBuilder\n\n\n"
    s += "@export\n"
    s += "def PyInit_" + mod + "() abi(\"C\") -> PythonObject:\n"
    s += "    try:\n"
    s += "        var m = PythonModuleBuilder(\"" + mod + "\")\n"
    s += "        m.def_function[add](\"add\")\n"
    s += "        m.def_function[greet](\"greet\")\n"
    s += "        return m.finalize()\n"
    s += "    except e:\n"
    s += "        abort(String(\"failed to create module: \", e))\n\n\n"
    s += "def add(a: PythonObject, b: PythonObject) raises -> PythonObject:\n"
    s += "    return a + b\n\n\n"
    s += "def greet(name: PythonObject) raises -> PythonObject:\n"
    s += "    var s = String(py=name)\n"
    s += "    return PythonObject(\"Hello from Mojo, \" + s + \"!\")\n"
    return s


def np_pyext_test(mod: String) -> String:
    var s = String("\"\"\"Verify the Mojo Python extension via mojo.importer (`pixi run test`).\"\"\"\n")
    s += "import mojo.importer  # noqa: F401\n"
    s += "import " + mod + "\n\n\n"
    s += "def main() -> None:\n"
    s += "    assert " + mod + ".add(2, 3) == 5\n"
    s += "    assert " + mod + ".greet(\"Python\") == \"Hello from Mojo, Python!\"\n"
    s += "    print(\"OK:\", " + mod + ".greet(\"Python\"))\n\n\n"
    s += "if __name__ == \"__main__\":\n"
    s += "    main()\n"
    return s


def np_files(name: String, platform: String, mojo_spec: String, template: Int = NP_TMPL_EXEC) -> List[String]:
    """The project's files as name, content, name, content, ..."""
    var out = List[String]()
    var ident = np_pkg_ident(name)
    if template == NP_TMPL_PKG:
        out.append("pixi.toml")
        out.append(np_pkg_toml(name, ident, platform, mojo_spec))
        out.append("src/" + ident + "/__init__.mojo")
        out.append(np_pkg_init(ident))
        out.append("tests/test_" + ident + ".mojo")
        out.append(np_pkg_test(ident))
        out.append(".gitignore")
        out.append(np_gitignore())
        return out^
    if template == NP_TMPL_GPU:
        out.append("pixi.toml")
        out.append(np_gpu_toml(name, platform, mojo_spec))
        out.append("kernel.mojo")
        out.append(np_gpu_kernel())
        out.append("test_kernel.mojo")
        out.append(np_gpu_test())
        out.append(".gitignore")
        out.append(np_gitignore())
        return out^
    if template == NP_TMPL_PYEXT:
        out.append("pixi.toml")
        out.append(np_pyext_toml(name, ident, platform, mojo_spec))
        out.append(ident + ".mojo")
        out.append(np_pyext_mojo(ident))
        out.append("test_ext.py")
        out.append(np_pyext_test(ident))
        out.append(".gitignore")
        out.append(np_gitignore())
        return out^
    out.append("pixi.toml")
    out.append(np_pixi_toml(name, platform, mojo_spec))
    out.append("hello.mojo")
    out.append(np_hello())
    out.append("test_hello.mojo")
    out.append(np_test())
    out.append(".gitignore")
    out.append("# pixi's environments\n.pixi/\n*.egg-info\n")
    return out^
