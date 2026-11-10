"""Tests for src/json.mojo."""
from std.testing import assert_equal, assert_true, assert_false, assert_almost_equal, TestSuite
from std.collections import List
from json import *
from util import str_bytes, decode


def ok(text: String) raises -> Json:
    var d = json_parse(text)
    assert_true(d.ok, "should parse: " + text + " -> " + d.error)
    return d^


def bad(text: String) raises -> Json:
    var d = json_parse(text)
    assert_false(d.ok, "should be rejected: " + text)
    assert_true(d.error.byte_length() > 0)
    assert_true(d.error_pos >= 0)
    return d^


# ------------------------------------------------------------------ scalars
def test_literals() raises:
    assert_equal(ok("null").kind(0), J_NULL)
    assert_true(ok("null").is_null(0))
    var t = ok("true")
    assert_equal(t.kind(0), J_BOOL)
    assert_true(t.bool(0))
    assert_false(ok("false").bool(0, True))
    assert_equal(ok("  \n\t true \r\n").kind(0), J_BOOL)


def test_integers() raises:
    assert_equal(ok("0").int(0), 0)
    assert_equal(ok("-0").int(0), 0)
    assert_equal(ok("42").int(0), 42)
    assert_equal(ok("-17").int(0), -17)
    assert_equal(ok("9007199254740993").int(0), 9007199254740993)   # beyond float precision
    assert_equal(ok("123456789012345678").int(0), 123456789012345678)
    assert_almost_equal(ok("42").float(0), 42.0)


def test_floats() raises:
    assert_almost_equal(ok("1.5").float(0), 1.5)
    assert_almost_equal(ok("-0.25").float(0), -0.25)
    assert_almost_equal(ok("1e3").float(0), 1000.0)
    assert_almost_equal(ok("1E-2").float(0), 0.01)
    assert_almost_equal(ok("2.5e+3").float(0), 2500.0)
    assert_equal(ok("2.9").int(0), 2)           # int() truncates
    assert_equal(ok("-2.9").int(0), -2)
    assert_equal(ok("1e3").int(0), 1000)
    # more than 18 digits falls back to floating point instead of overflowing
    assert_almost_equal(ok("12345678901234567890").float(0), 1.2345678901234567e19, rtol=1e-12)


def test_strings_and_escapes() raises:
    assert_equal(ok("\"hello\"").str(0), "hello")
    assert_equal(ok("\"\"").str(0), "")
    assert_equal(ok("\"a\\\"b\\\\c\\/d\"").str(0), "a\"b\\c/d")
    assert_equal(ok("\"l1\\nl2\\tx\\ry\"").str(0), "l1\nl2\tx\ry")
    var be = decode(ok("\"\\b\\f\"").str(0))
    assert_equal(be[0], 8)
    assert_equal(be[1], 12)
    assert_equal(ok("\"caf\\u00e9\"").str(0), "café")
    assert_equal(ok("\"caf\\u00E9\"").str(0), "café")
    assert_equal(ok("\"日本語 🔥\"").str(0), "日本語 🔥")          # raw UTF-8
    assert_equal(ok("\"\\ud83d\\udd25\"").str(0), "🔥")           # surrogate pair
    assert_equal(decode(ok("\"\\u0041\\u0000z\"").str(0))[0], 65)


def test_broken_surrogates_become_replacement_characters() raises:
    assert_equal(decode(ok("\"\\ud83d\"").str(0))[0], 0xFFFD)        # lone high
    assert_equal(decode(ok("\"\\udd25\"").str(0))[0], 0xFFFD)        # lone low
    var c = decode(ok("\"\\ud83d\\u0041\"").str(0))                  # high + non-low
    assert_equal(len(c), 2)
    assert_equal(c[0], 0xFFFD)
    assert_equal(c[1], 65)


# ---------------------------------------------------------------- structure
def test_arrays() raises:
    var d = ok("[1, \"two\", [3, 4], {}, null, true]")
    assert_equal(d.kind(0), J_ARR)
    assert_equal(d.size(0), 6)
    assert_equal(d.int(d.at(0, 0)), 1)
    assert_equal(d.str(d.at(0, 1)), "two")
    assert_equal(d.size(d.at(0, 2)), 2)
    assert_equal(d.int(d.at(d.at(0, 2), 1)), 4)
    assert_equal(d.kind(d.at(0, 3)), J_OBJ)
    assert_true(d.is_null(d.at(0, 4)))
    assert_true(d.bool(d.at(0, 5)))
    assert_equal(d.at(0, 6), -1)
    assert_equal(d.at(0, -1), -1)
    assert_equal(len(d.children(0)), 6)
    assert_equal(ok("[]").size(0), 0)
    assert_equal(ok("[ ]").size(0), 0)


def test_objects() raises:
    var d = ok("{\"a\": 1, \"b\": {\"c\": [10, 20]}, \"\": \"empty key\", \"a b\": true}")
    assert_equal(d.kind(0), J_OBJ)
    assert_equal(d.size(0), 4)
    assert_equal(d.int(d.get(0, "a")), 1)
    assert_equal(d.int(d.path(0, "b/c/1")), 20)
    assert_equal(d.str(d.get(0, "")), "empty key")
    assert_true(d.bool(d.get(0, "a b")))
    assert_true(d.has(0, "b"))
    assert_false(d.has(0, "zzz"))
    assert_equal(d.key_of(d.at(0, 1)), "b")
    assert_equal(ok("{}").size(0), 0)


def test_missing_things_give_defaults_and_chain_safely() raises:
    var d = ok("{\"a\": {\"n\": 5, \"s\": \"x\"}}")
    assert_equal(d.get(0, "nope"), -1)
    assert_equal(d.int(d.get(d.get(0, "nope"), "deeper"), 99), 99)
    assert_equal(d.str(d.path(0, "a/missing/more"), "dflt"), "dflt")
    assert_equal(d.path(0, "a/n/x"), -1)            # stepping into a number
    assert_equal(d.str(d.path(0, "a/n"), "not a string"), "not a string")
    assert_equal(d.int(d.path(0, "a/s"), -1), -1)
    assert_equal(d.kind(-1), -1)
    assert_equal(d.size(-1), 0)
    assert_equal(d.kind(9999), -1)
    assert_equal(d.get(d.path(0, "a/n"), "k"), -1)  # get on a non-object


def test_path_with_array_indices() raises:
    var d = ok("{\"items\": [{\"name\": \"a\"}, {\"name\": \"b\"}]}")
    assert_equal(d.str(d.path(0, "items/1/name")), "b")
    assert_equal(d.path(0, "items/2/name"), -1)
    assert_equal(d.path(0, "items/x"), -1)
    assert_equal(d.path(0, ""), 0)


def test_deep_nesting_within_the_limit_and_beyond() raises:
    var open = String("")
    var close = String("")
    for _ in range(200):
        open += "["
        close += "]"
    _ = ok(open + close)
    for _ in range(200):
        open += "["
        close += "]"
    var d = bad(open + close)
    assert_true(d.error.find("deep") >= 0)


# ------------------------------------------------------------------- errors
def test_malformed_documents_are_rejected() raises:
    for t in [
        "", "   ", "{", "[", "[1,", "[1 2]", "{\"a\"}", "{\"a\":}", "{a:1}", "{\"a\":1,}",
        "[1,]", "\"open", "tru", "nul", "01", "-", "1.", "1e", ".5", "+1", "\"bad \\q\"",
        "\"\\u12\"", "\"\\u12G4\"", "[1] x", "{} {}", "'single'", "\"tab\there\"",
    ]:
        _ = bad(String(t))


def test_error_position_and_safe_root() raises:
    var d = bad("[1, 2, oops]")
    assert_equal(d.error_pos, 7)
    assert_true(d.error.find("byte 7") >= 0)
    var e = bad("")
    assert_equal(e.kind(0), J_NULL)                 # node 0 exists even after an error
    assert_equal(e.str(e.get(0, "x"), "safe"), "safe")


# ------------------------------------------------------------------- writer
def test_writer_builds_objects_and_arrays() raises:
    var w = JsonWriter()
    w.begin_obj()
    w.kv_str("jsonrpc", "2.0")
    w.kv_int("id", 7)
    w.key("params")
    w.begin_obj()
    w.kv_bool("flag", True)
    w.key("list")
    w.begin_arr()
    w.int(1)
    w.str("two")
    w.null()
    w.begin_arr()
    w.end_arr()
    w.begin_obj()
    w.end_obj()
    w.end_arr()
    w.end_obj()
    w.end_obj()
    assert_equal(w.text(), "{\"jsonrpc\":\"2.0\",\"id\":7,\"params\":{\"flag\":true,\"list\":[1,\"two\",null,[],{}]}}")


def test_writer_scalars_and_raw() raises:
    var w = JsonWriter()
    w.begin_arr()
    w.bool(False)
    w.int(-5)
    w.raw("{\"pre\":\"built\"}")
    w.float(1.5)
    w.end_arr()
    var d = ok(w.text())
    assert_false(d.bool(d.at(0, 0), True))
    assert_equal(d.int(d.at(0, 1)), -5)
    assert_equal(d.str(d.path(0, "2/pre")), "built")
    assert_almost_equal(d.float(d.at(0, 3)), 1.5)


def test_quote_escapes_everything_needed() raises:
    assert_equal(json_quote("plain"), "\"plain\"")
    assert_equal(json_quote("a\"b\\c"), "\"a\\\"b\\\\c\"")
    assert_equal(json_quote("l1\nl2\tx\r"), "\"l1\\nl2\\tx\\r\"")
    assert_equal(json_quote("日本 🔥"), "\"日本 🔥\"")
    var ctl = List[UInt8]()
    ctl.append(1)
    ctl.append(31)
    assert_equal(json_quote(String(unsafe_from_utf8=Span(ctl))), "\"\\u0001\\u001f\"")


def test_string_roundtrip_through_writer_and_parser() raises:
    for s in ["", "plain", "quote \" backslash \\ slash /", "tab\tnewline\nreturn\r", "日本語 🔥 café", "{\"not\": \"json\"}"]:
        var d = ok(json_quote(String(s)))
        assert_equal(d.str(0, "?"), String(s))


def test_dump_roundtrip() raises:
    var text = String("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"capabilities\":{\"hoverProvider\":true,\"triggers\":[\".\",\"(\"],\"n\":-3,\"f\":0.5,\"none\":null}}}")
    var d = ok(text)
    assert_equal(d.dump(), text)
    assert_equal(d.dump(d.path(0, "result/capabilities/triggers")), "[\".\",\"(\"]")
    assert_equal(ok(d.dump()).dump(), text)        # stable


# ------------------------------------------------------- realistic messages
def test_lsp_style_message() raises:
    var d = ok("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/publishDiagnostics\",\"params\":{\"uri\":\"file:///p/a.mojo\",\"diagnostics\":[{\"range\":{\"start\":{\"line\":27,\"character\":19},\"end\":{\"line\":27,\"character\":22}},\"severity\":1,\"message\":\"cannot implicitly convert 'StringLiteral[\\\"x\\\"]' value to 'Int'\"}]}}")
    assert_equal(d.str(d.get(0, "method")), "textDocument/publishDiagnostics")
    assert_false(d.has(0, "id"))
    var diags = d.path(0, "params/diagnostics")
    assert_equal(d.size(diags), 1)
    assert_equal(d.int(d.path(diags, "0/range/start/line")), 27)
    assert_equal(d.int(d.path(diags, "0/range/end/character")), 22)
    assert_equal(d.str(d.path(diags, "0/message")), "cannot implicitly convert 'StringLiteral[\"x\"]' value to 'Int'")


def test_large_array() raises:
    var w = JsonWriter()
    w.begin_arr()
    for i in range(5000):
        w.int(i * 3)
    w.end_arr()
    var d = ok(w.text())
    assert_equal(d.size(0), 5000)
    var kids = d.children(0)
    assert_equal(d.int(kids[4999]), 14997)
    assert_equal(d.int(kids[0]), 0)


def test_parse_bytes_with_invalid_utf8_does_not_fail() raises:
    var b = str_bytes("\"ok")
    b.append(0xFF)
    b.append(34)
    var d = json_parse_bytes(b)
    assert_true(d.ok)                               # bytes are passed through as they are
    assert_equal(d.kind(0), J_STR)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
