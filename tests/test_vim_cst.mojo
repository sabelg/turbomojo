"""Unit tests for Phase 22 `vim_cst` module: CST structural text objects, 2-char Flash jump
beacons, pure-Mojo Vim surround operations (`ys`/`ds`/`cs`), `HarpoonList`, and `VimChangeList`."""
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from std.collections import List
from buffer import TextBuffer
from util import decode, to_str
from vim_cst import (
    CstTextObjectSpan,
    resolve_cst_text_object,
    FlashTarget,
    find_flash_targets_in_lines,
    assign_flash_labels,
    surround_pair,
    find_enclosing_surround,
    apply_surround_add,
    apply_surround_delete,
    apply_surround_change,
    HarpoonList,
    parse_serialized,
    VimChangeList,
)


def _buf_from(src: String) -> TextBuffer:
    var b = TextBuffer()
    b.load(decode(src))
    return b^


def _buf_str(b: TextBuffer) -> String:
    return to_str(b.all_text())


def _delete_span(mut b: TextBuffer, sp: CstTextObjectSpan):
    if not sp.ok:
        return
    if sp.linewise:
        if sp.r2 + 1 < b.count():
            _ = b.delete(sp.r1, 0, sp.r2 + 1, 0, sp.r1, 0, 1)
        elif sp.r1 > 0:
            _ = b.delete(sp.r1 - 1, b.llen(sp.r1 - 1), sp.r2, b.llen(sp.r2), sp.r1, 0, 1)
        else:
            _ = b.delete(0, 0, sp.r2, b.llen(sp.r2), 0, 0, 1)
    else:
        _ = b.delete(sp.r1, sp.c1, sp.r2, sp.c2, sp.r1, sp.c1, 1)


def test_cst_func_text_object_mojo_and_python() raises:
    var mojo_src = (
        "@always_inline\n"
        "def compute(\n"
        "    x: Int,\n"
        "    y: Int,\n"
        ") -> Int:\n"
        "    \"\"\"Docstring mentioning def fake(): pass.\"\"\"\n"
        "    var total = x + y\n"
        "    return total\n"
        "\n"
        "def second() -> Int:\n"
        "    return 42\n"
    )
    var b = _buf_from(mojo_src)

    # `if` inside multi-line Mojo `def`: strictly after `)` -> Int: row (row 4), rows 5..7
    var sp_if = resolve_cst_text_object(b, 6, 8, False, 102)
    assert_true(sp_if.ok)
    assert_true(sp_if.linewise)
    assert_equal(sp_if.r1, 5)
    assert_equal(sp_if.r2, 7)

    # `af` includes `@always_inline` at row 0 through trailing blank line at row 8
    var sp_af = resolve_cst_text_object(b, 6, 8, True, 102)
    assert_true(sp_af.ok)
    assert_true(sp_af.linewise)
    assert_equal(sp_af.r1, 0)
    assert_equal(sp_af.r2, 8)

    # `af` on final function (`second`, rows 9..10) does not swallow synthetic EOF newline
    var sp_af2 = resolve_cst_text_object(b, 10, 4, True, 102)
    assert_true(sp_af2.ok)
    assert_equal(sp_af2.r1, 9)
    assert_equal(sp_af2.r2, 10)

    # Python decorated `def` and `async def` fallback (including nested inner `def`)
    var py_src = (
        "@app.get(\"/items\")\n"
        "async def fetch_items(limit: int = 10):\n"
        "    def normalize(v):\n"
        "        return v.strip()\n"
        "    return [normalize(' a ')]\n"
    )
    var pb = _buf_from(py_src)
    var py_outer_af = resolve_cst_text_object(pb, 4, 4, True, 102)
    assert_true(py_outer_af.ok)
    assert_equal(py_outer_af.r1, 0)
    assert_equal(py_outer_af.r2, 4)

    var py_outer_if = resolve_cst_text_object(pb, 4, 4, False, 102)
    assert_true(py_outer_if.ok)
    assert_equal(py_outer_if.r1, 2)
    assert_equal(py_outer_if.r2, 4)

    # Cursor on row 3 selects innermost nested `normalize` function
    var py_inner_if = resolve_cst_text_object(pb, 3, 8, False, 102)
    assert_true(py_inner_if.ok)
    assert_equal(py_inner_if.r1, 3)
    assert_equal(py_inner_if.r2, 3)


def test_cst_struct_trait_class_text_object() raises:
    var src = (
        "@fieldwise_init\n"
        "struct Vec2(Copyable, Movable):\n"
        "    var x: Float64\n"
        "    var y: Float64\n"
        "\n"
        "    def norm_sq(self) -> Float64:\n"
        "        return self.x * self.x + self.y * self.y\n"
        "\n"
        "trait Drawable:\n"
        "    def draw(self, mut out_buf: String):\n"
        "        ...\n"
        "\n"
        "@dataclass\n"
        "class PyConfig:\n"
        "    host: str = 'localhost'\n"
        "    port: int = 8080\n"
    )
    var b = _buf_from(src)

    # `ac` and `ic` on `@fieldwise_init struct Vec2`
    var ac_s = resolve_cst_text_object(b, 3, 4, True, 99)
    assert_true(ac_s.ok)
    assert_true(ac_s.linewise)
    assert_equal(ac_s.r1, 0)
    assert_equal(ac_s.r2, 6)

    var ic_s = resolve_cst_text_object(b, 5, 8, False, 99)
    assert_true(ic_s.ok)
    assert_true(ic_s.linewise)
    assert_equal(ic_s.r1, 2)
    assert_equal(ic_s.r2, 6)

    # `ac` and `ic` on `trait Drawable`
    var ac_t = resolve_cst_text_object(b, 9, 4, True, 99)
    assert_true(ac_t.ok)
    assert_equal(ac_t.r1, 8)
    assert_equal(ac_t.r2, 10)

    var ic_t = resolve_cst_text_object(b, 9, 4, False, 99)
    assert_true(ic_t.ok)
    assert_equal(ic_t.r1, 9)
    assert_equal(ic_t.r2, 10)

    # `ac` and `ic` on Python `@dataclass class PyConfig`
    var ac_c = resolve_cst_text_object(b, 14, 4, True, 99)
    assert_true(ac_c.ok)
    assert_equal(ac_c.r1, 12)
    assert_equal(ac_c.r2, 15)

    var ic_c = resolve_cst_text_object(b, 14, 4, False, 99)
    assert_true(ic_c.ok)
    assert_equal(ic_c.r1, 14)
    assert_equal(ic_c.r2, 15)


def test_cst_argument_and_parameter_text_object() raises:
    # 1. First argument `daa` -> `foo(b, c)`
    var b1 = _buf_from("foo(alpha, beta, gamma)")
    var ia_first = resolve_cst_text_object(b1, 0, 5, False, 97)
    assert_true(ia_first.ok)
    assert_false(ia_first.linewise)
    assert_equal(to_str(b1.get_text(ia_first.r1, ia_first.c1, ia_first.r2, ia_first.c2)), "alpha")
    var aa_first = resolve_cst_text_object(b1, 0, 5, True, 97)
    _delete_span(b1, aa_first)
    assert_equal(_buf_str(b1), "foo(beta, gamma)")

    # 2. Middle argument `daa` -> `foo(alpha, gamma)`
    var b2 = _buf_from("foo(alpha, beta, gamma)")
    var ia_mid = resolve_cst_text_object(b2, 0, 12, False, 97)
    assert_equal(to_str(b2.get_text(ia_mid.r1, ia_mid.c1, ia_mid.r2, ia_mid.c2)), "beta")
    var aa_mid = resolve_cst_text_object(b2, 0, 12, True, 97)
    _delete_span(b2, aa_mid)
    assert_equal(_buf_str(b2), "foo(alpha, gamma)")

    # 3. Last argument `daa` -> `foo(alpha, beta)`
    var b3 = _buf_from("foo(alpha, beta, gamma)")
    var ia_last = resolve_cst_text_object(b3, 0, 19, False, 97)
    assert_equal(to_str(b3.get_text(ia_last.r1, ia_last.c1, ia_last.r2, ia_last.c2)), "gamma")
    var aa_last = resolve_cst_text_object(b3, 0, 19, True, 97)
    _delete_span(b3, aa_last)
    assert_equal(_buf_str(b3), "foo(alpha, beta)")

    # 4. Single argument `daa` -> `foo()`
    var b4 = _buf_from("foo(only_one)")
    var aa_single = resolve_cst_text_object(b4, 0, 6, True, 97)
    assert_true(aa_single.ok)
    _delete_span(b4, aa_single)
    assert_equal(_buf_str(b4), "foo()")

    # 5. `def` parameter list with string containing `,` and nested call default
    var b5 = _buf_from("def render(mut buf: TextBuffer, sep: String = \", \", limit: Int = max(1, 2)):")
    var p_mid_ia = resolve_cst_text_object(b5, 0, 34, False, 97)
    assert_true(p_mid_ia.ok)
    assert_equal(
        to_str(b5.get_text(p_mid_ia.r1, p_mid_ia.c1, p_mid_ia.r2, p_mid_ia.c2)),
        "sep: String = \", \"",
    )
    var p_first_aa = resolve_cst_text_object(b5, 0, 15, True, 97)
    _delete_span(b5, p_first_aa)
    assert_equal(
        _buf_str(b5),
        "def render(sep: String = \", \", limit: Int = max(1, 2)):",
    )
    var p_last_aa = resolve_cst_text_object(b5, 0, 35, True, 97)
    _delete_span(b5, p_last_aa)
    assert_equal(_buf_str(b5), "def render(sep: String = \", \"):")

    # 6. Multi-line call arguments with trailing comma
    var b6 = _buf_from("invoke(\n    first_val,\n    second_val,\n)")
    var ml_ia = resolve_cst_text_object(b6, 1, 6, False, 97)
    assert_equal(to_str(b6.get_text(ml_ia.r1, ml_ia.c1, ml_ia.r2, ml_ia.c2)), "first_val")
    var ml_aa = resolve_cst_text_object(b6, 1, 6, True, 97)
    _delete_span(b6, ml_aa)
    assert_equal(_buf_str(b6), "invoke(\n    second_val,\n)")


def test_cst_notebook_cell_text_object() raises:
    var nb_src = (
        "# %% Setup\n"
        "var x = 10\n"
        "var y = 20\n"
        "\n"
        "# %% Compute\n"
        "print(x + y)\n"
        "# %% Blank\n"
        "\n"
    )
    var b = _buf_from(nb_src)

    # Cell 0 (`# %% Setup`): header=0, start=1, end=3 (row 3 is blank separator)
    var aj0 = resolve_cst_text_object(b, 1, 0, True, 106)
    assert_true(aj0.ok)
    assert_true(aj0.linewise)
    assert_equal(aj0.r1, 0)
    assert_equal(aj0.r2, 3)

    # `ij` trims trailing blank row 3 -> rows 1..2
    var ij0 = resolve_cst_text_object(b, 0, 2, False, 106)
    assert_true(ij0.ok)
    assert_true(ij0.linewise)
    assert_equal(ij0.r1, 1)
    assert_equal(ij0.r2, 2)

    # Cell 1 (`# %% Compute`): header=4, body=5
    var aj1 = resolve_cst_text_object(b, 5, 0, True, 106)
    assert_equal(aj1.r1, 4)
    assert_equal(aj1.r2, 5)

    var ij1 = resolve_cst_text_object(b, 5, 0, False, 106)
    assert_equal(ij1.r1, 5)
    assert_equal(ij1.r2, 5)

    # Cell 2 (`# %% Blank` with empty body line): `ij` falls back to `start_row..end_row`
    var ij2 = resolve_cst_text_object(b, 6, 0, False, 106)
    assert_true(ij2.ok)
    assert_equal(ij2.r1, 7)


def test_flash_targets_smartcase_and_conflict_free_labels() raises:
    var lines = List[String]()
    # 3rd chars after "fo" / "Fo": 's' ("fos"), 'd' ("fod"), 'f' ("FoF"), 'j' ("foj")
    lines.append("fos fod FoF foj")
    lines.append("bar FOk end")

    # Lowercase query ('f', 'o') -> case-insensitive smartcase: matches all 5 occurrences!
    var t_all = find_flash_targets_in_lines(2, lines, 10, 102, 111)
    assert_equal(len(t_all), 5)
    assert_equal(t_all[0].win_idx, 2)
    assert_equal(t_all[0].row, 10)
    assert_equal(t_all[0].col, 0)
    assert_equal(t_all[2].col, 8)
    assert_equal(t_all[4].row, 11)
    assert_equal(t_all[4].col, 4)

    # Continuation chars are 's', 'd', 'F'/'f', 'j', 'k' — home-row 's','d','f','j','k' MUST be skipped!
    # First non-conflicting home-row keys in order `s,d,f,j,k,l,a,g,h,e`: 'l', 'a', 'g', 'h', 'e'
    assert_equal(t_all[0].label, 108)  # 'l'
    assert_equal(t_all[1].label, 97)   # 'a'
    assert_equal(t_all[2].label, 103)  # 'g'
    assert_equal(t_all[3].label, 104)  # 'h'
    assert_equal(t_all[4].label, 101)  # 'e'

    # Uppercase query ('F', 'o') -> smartcase switches to exact case-sensitive: matches only "FoF"
    var t_cs = find_flash_targets_in_lines(0, lines, 0, 70, 111)
    assert_equal(len(t_cs), 1)
    assert_equal(t_cs[0].row, 0)
    assert_equal(t_cs[0].col, 8)
    assert_equal(t_cs[0].label, 115)   # 's' (continuation is 'F', so 's' is free!)

    # Up to 52 targets get unique non-zero ASCII labels
    var many = List[FlashTarget]()
    for i in range(52):
        many.append(FlashTarget(0, i, 0, 0, i, 0))
    assign_flash_labels(many)
    for i in range(52):
        assert_true(many[i].label > 0)
        for j in range(i + 1, 52):
            assert_true(many[i].label != many[j].label)


def test_surround_add_delete_change() raises:
    # Pair formatting: spaced openers vs tight closers & aliases
    var p_open = surround_pair(40)   # '('
    assert_equal(p_open[0], "( ")
    assert_equal(p_open[1], " )")
    var p_close = surround_pair(41)  # ')'
    assert_equal(p_close[0], "(")
    assert_equal(p_close[1], ")")
    assert_equal(surround_pair(98)[0], "(")    # 'b'
    assert_equal(surround_pair(66)[0], "{")    # 'B'
    assert_equal(surround_pair(114)[0], "[")   # 'r'
    assert_equal(surround_pair(97)[0], "<")    # 'a'
    assert_equal(surround_pair(34)[0], "\"")   # '"'

    # `ys`: spaced `(` vs tight `)`
    var b = _buf_from("return value")
    var pos = apply_surround_add(b, 0, 7, 0, 12, 40)  # '(' around "value"
    assert_equal(pos.r, 0)
    assert_equal(pos.c, 7)
    assert_equal(_buf_str(b), "return ( value )")

    # `cs(]` changes spaced `( value )` -> tight `[value]`
    var chg1 = apply_surround_change(b, 0, 10, 40, 93)
    assert_true(chg1[0])
    assert_equal(_buf_str(b), "return [value]")

    # `cs]{` changes tight `[value]` -> spaced `{ value }`
    var chg2 = apply_surround_change(b, 0, 9, 93, 123)
    assert_true(chg2[0])
    assert_equal(_buf_str(b), "return { value }")

    # `ds{` deletes `{ ` and ` }` cleanly back to `return value`
    var del1 = apply_surround_delete(b, 0, 9, 123)
    assert_true(del1[0])
    assert_equal(_buf_str(b), "return value")

    # Tight `)` add (`(value)`) vs `ds)` on spaced `( value )` (keeps inner spaces)
    _ = apply_surround_add(b, 0, 7, 0, 12, 41)
    assert_equal(_buf_str(b), "return (value)")
    _ = apply_surround_change(b, 0, 9, 41, 40)
    assert_equal(_buf_str(b), "return ( value )")
    var del_tight = apply_surround_delete(b, 0, 9, 41)
    assert_true(del_tight[0])
    assert_equal(_buf_str(b), "return  value ")
    b = _buf_from("return value")

    # Quotes: `ys` with `"`, `cs"'`, `ds'`
    _ = apply_surround_add(b, 0, 7, 0, 12, 34)
    assert_equal(_buf_str(b), "return \"value\"")
    var chg_q = apply_surround_change(b, 0, 9, 34, 39)
    assert_true(chg_q[0])
    assert_equal(_buf_str(b), "return 'value'")
    var del_q = apply_surround_delete(b, 0, 9, 39)
    assert_true(del_q[0])
    assert_equal(_buf_str(b), "return value")

    # Multi-line bracket surround lookup & linewise surround add + single-step undo
    var mb = _buf_from("    var a = 1\n    var b = 2")
    var lpos = apply_surround_add(mb, 0, 0, 1, 13, 123, True)
    assert_equal(lpos.r, 0)
    assert_equal(lpos.c, 4)
    assert_equal(_buf_str(mb), "    {\n    var a = 1\n    var b = 2\n    }")
    var enc = find_enclosing_surround(mb, 2, 6, 66)  # 'B' -> '{' .. '}'
    assert_true(enc[0])
    assert_equal(enc[1], 0)
    assert_equal(enc[2], 4)
    assert_equal(enc[3], 3)
    assert_equal(enc[4], 4)
    _ = mb.undo()
    assert_equal(_buf_str(mb), "    var a = 1\n    var b = 2")


def test_harpoon_list_and_change_list() raises:
    var h = HarpoonList()
    assert_equal(h.toggle_pin("src/app.mojo", 14, 2), 1)
    assert_equal(h.toggle_pin("src/vim_cst.mojo", 40, 8, "CST Vim"), 2)
    assert_equal(h.toggle_pin("tests/test_vim_cst.mojo", 0, 0), 3)

    var s1 = h.slot_at(1)
    assert_true(s1[0])
    assert_equal(s1[1].path, "src/app.mojo")
    assert_equal(s1[1].label, "app.mojo")
    assert_equal(s1[1].row, 14)
    assert_equal(s1[1].col, 2)

    var s2 = h.slot_at(2)
    assert_true(s2[0])
    assert_equal(s2[1].label, "CST Vim")

    var menu = h.format_menu_lines()
    assert_equal(len(menu), 3)
    assert_true(menu[0].find("[1]") >= 0 and menu[0].find("app.mojo") >= 0)
    assert_true(menu[1].find("[2]") >= 0 and menu[1].find("CST Vim") >= 0)

    # Toggle existing path unpins it and returns 0
    assert_equal(h.toggle_pin("src/app.mojo", 99, 0), 0)
    assert_equal(h.count(), 2)
    assert_false(h.slot_at(3)[0])

    # Serialize to TOML and roundtrip via `parse_serialized`
    _ = h.toggle_pin("src/with \"quotes\".mojo", 7, 3, "Quote \"Test\"")
    var toml_s = h.serialize_toml()
    var h2 = HarpoonList.parse_serialized(toml_s)
    var h2_fn = parse_serialized(toml_s)
    assert_equal(h2_fn.count(), 3)
    assert_equal(h2.count(), 3)
    assert_equal(h2.slot_at(1)[1].path, "src/vim_cst.mojo")
    assert_equal(h2.slot_at(1)[1].row, 40)
    assert_equal(h2.slot_at(1)[1].col, 8)
    assert_equal(h2.slot_at(3)[1].path, "src/with \"quotes\".mojo")
    assert_equal(h2.slot_at(3)[1].label, "Quote \"Test\"")
    assert_equal(h2.slot_at(3)[1].row, 7)
    assert_equal(h2.slot_at(3)[1].col, 3)

    # Cap at 9 slots
    for k in range(10):
        _ = h2.toggle_pin("extra_" + String(k) + ".mojo", k, 0)
    assert_equal(h2.count(), 9)
    assert_true(h2.slot_at(9)[0])
    assert_false(h2.slot_at(10)[0])

    # `VimChangeList`: `g;` (`jump_older`) and `g,` (`jump_newer`) + 64-entry ring cap
    var cl = VimChangeList()
    assert_false(cl.jump_older(0, 0)[0])
    cl.record(2, 4)
    cl.record(10, 1)
    cl.record(25, 8)
    cl.record(25, 8)  # duplicate consecutive position ignored
    assert_equal(cl.count(), 3)

    # Cursor moved away to (30, 0): first `g;` lands on newest edit (25, 8)
    var j1 = cl.jump_older(30, 0)
    assert_true(j1[0])
    assert_equal(j1[1], 25)
    assert_equal(j1[2], 8)

    var j2 = cl.jump_older(j1[1], j1[2])
    assert_true(j2[0])
    assert_equal(j2[1], 10)
    assert_equal(j2[2], 1)

    var j3 = cl.jump_older(j2[1], j2[2])
    assert_true(j3[0])
    assert_equal(j3[1], 2)
    assert_equal(j3[2], 4)

    # At oldest entry: further `g;` returns False
    assert_false(cl.jump_older(j3[1], j3[2])[0])

    # `g,` steps forward to newer edits
    var n1 = cl.jump_newer()
    assert_true(n1[0])
    assert_equal(n1[1], 10)
    assert_equal(n1[2], 1)

    var n2 = cl.jump_newer()
    assert_true(n2[0])
    assert_equal(n2[1], 25)
    assert_equal(n2[2], 8)
    assert_false(cl.jump_newer()[0])

    # Ring cap at 64
    var cl_cap = VimChangeList()
    for i in range(80):
        cl_cap.record(i, i % 10)
    assert_equal(cl_cap.count(), 64)
    var newest = cl_cap.jump_older(999, 0)
    assert_true(newest[0])
    assert_equal(newest[1], 79)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
