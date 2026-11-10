"""The Mojo documentation inside the IDE: cleaning up the pages, the library of books,
the standard library reference made from `mojo doc` output, the richer Markdown
rendering, and the reader. Everything runs on a small made-up documentation folder -
nothing is downloaded."""
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from std.collections import List
from doclib import *
from stdref import stdref_build, stdref_stale
from docfetch import FETCH_SCRIPT
from markdown import md_render_rich, md_plain, MdLine, MD_HEAD, MD_DIM, MD_BOLD
from highlight import Highlighter
from term import Event, EV_MOUSE, MB_LEFT, fkey, key_event, MOD_SHIFT, MOD_ALT, KEY_ENTER, KEY_ESC, KEY_DOWN, KEY_UP, KEY_TAB, KEY_LEFT, KEY_BACKSPACE, KEY_HOME, KEY_PGDN
from app import *
from appstate import App, M_NORMAL, M_DOCS, M_DIALOG
from dialog import D_DOCFETCH, D_DOCFIND
from commands import CM_MOJODOCS, CM_DOCFETCH, CM_DOCFIND, build_registry
from config import load_settings, read_text
from signals import own_pid
from util import decode, to_str, env_or, run_system, read_file, bytes_to_str, path_exists


def scratch(tag: String) -> String:
    var d = env_or("TMPDIR", "/tmp") + "/turbomojo-docsreader-" + String(own_pid()) + "-" + tag
    _ = run_system("rm -rf '" + d + "' && mkdir -p '" + d + "'")
    return d


def put(path: String, text: String) raises:
    with open(path, "w") as f:
        f.write(text)


# ------------------------------------------------------------ page clean-up
def test_front_matter_titles_and_names() raises:
    var fm = front_matter("---\ntitle: \"Variables\"\nsidebar_position: 3\ndescription: x\n---\n\nBody text.\n")
    assert_equal(fm[0], "Variables")
    assert_equal(fm[1], 3)
    assert_equal(fm[2], "\nBody text.\n\n")
    var none_fm = front_matter("# Just a page\n")
    assert_equal(none_fm[0], "")
    assert_equal(none_fm[1], 9999)
    assert_equal(none_fm[2], "# Just a page\n")
    assert_equal(front_matter("---\ntitle: unclosed\n")[0], "")          # no closing line: not a header
    assert_equal(nice_name("get-started.mdx"), "Get started")
    assert_equal(nice_name("value_semantics"), "Value semantics")
    assert_equal(heading_slug("Variable declarations"), "variable-declarations")
    assert_equal(heading_slug("What's `comptime`? (2nd part)"), "whats-comptime-2nd-part")
    assert_equal(normal_path("/a/b/../c/./d.md"), "/a/c/d.md")
    assert_equal(normal_path("/../x"), "/x")
    assert_equal(clean_heading("Scopes {#variable-scopes}"), "Scopes")


def test_pages_are_cleaned_up_for_reading() raises:
    var d = scratch("prep")
    var src = "---\ntitle: Basics\n---\n\nimport Tabs from '@theme/Tabs';\nimport {\n  Panel,\n  Sheet,\n} from '@site/src/components/Sheet';\n\nIntro text with ![a diagram](./img/x.png) inside.\n\n:::note Heads up\n\nBe careful with `var`.\n\n:::\n\n<Tabs>\n<TabItem value=\"a\" label=\"With pixi\">\n\nUse pixi.\n\n</TabItem>\n</Tabs>\n\n## Scopes {#variable-scopes}\n\n<!-- a comment\nover two lines -->\nSee <a href=\"/docs/manual/types\">the types page</a> and <strong>this</strong>.\n\n```mojo\nimport std.math  # code is left alone: <not> a tag, :::not an admonition\n```\n"
    var want = "# Basics\n\nIntro text with *[image: a diagram]* inside.\n\n> **Note: Heads up**\n>\n> Be careful with `var`.\n\n### With pixi\n\nUse pixi.\n\n## Scopes\n\nSee [the types page](/docs/manual/types) and **this**.\n\n```mojo\nimport std.math  # code is left alone: <not> a tag, :::not an admonition\n```\n"
    assert_equal(doc_prepare(src, d + "/basics.mdx"), want)
    # a page that has its own first heading does not get the header's title again
    assert_equal(doc_prepare("---\ntitle: T\n---\n# Own heading\n", d + "/x.md"), "# Own heading\n")
    # a cheat-sheet panel becomes a heading with its summary
    assert_equal(doc_prepare("<Panel title=\"Hello\" summary=\"The basics.\">\n\ntext\n\n</Panel>\n", d + "/c.mdx"), "### Hello\n\n*The basics.*\n\ntext\n")
    # collapsible parts are shown open, with their summary line
    assert_equal(doc_prepare("<details>\n<summary>Solution</summary>\n\nanswer\n\n</details>\n", d + "/s.md"), "**▸ Solution**\n\nanswer\n")
    # an admonition keeps its paragraphs together; code in it follows as a code block;
    # blank lines inside code are kept, elsewhere there is never more than one
    assert_equal(doc_prepare(":::caution\n\nFirst.\n\nSecond.\n\n```mojo\nx = 1\n\n\ny = 2\n```\n\n:::\n\n\n\nAfter.\n", d + "/a.md"), "> **Caution**\n>\n> First.\n>\n> Second.\n\n```mojo\nx = 1\n\n\ny = 2\n```\n\nAfter.\n")
    _ = run_system("rm -rf '" + d + "'")


def test_includes_take_the_named_part_of_a_file() raises:
    var d = scratch("incl")
    _ = run_system("mkdir -p '" + d + "/book/src' '" + d + "/problems'")
    put(d + "/problems/p01.mojo", "from std.x import y\n\n# ANCHOR: add\ndef add(a: Int) -> Int:\n    # ANCHOR: inner\n    return a + 10\n    # ANCHOR_END: inner\n# ANCHOR_END: add\n\ndef main(): pass\n")
    assert_equal(include_text(d + "/problems/p01.mojo", "add"), "def add(a: Int) -> Int:\n    return a + 10\n")
    assert_equal(include_text(d + "/problems/p01.mojo", "inner"), "    return a + 10\n")
    assert_true(include_text(d + "/problems/p01.mojo", "").startswith("from std.x import y\n\ndef add"))
    assert_equal(include_text(d + "/problems/none.mojo", "add"), "(missing: none.mojo)")
    var page = "# Puzzle\n\n```mojo\n{{#include ../../problems/p01.mojo:add}}\n```\n\nRepo: {{#include ./url.md}}/tree\n"
    put(d + "/book/src/url.md", "https://example.org/repo\n")
    assert_equal(doc_prepare(page, d + "/book/src/puzzle.md"), "# Puzzle\n\n```mojo\ndef add(a: Int) -> Int:\n    return a + 10\n```\n\nRepo: https://example.org/repo/tree\n")
    _ = run_system("rm -rf '" + d + "'")


# ------------------------------------------------------- richer rendering
def rendered(text: String, width: Int) -> String:
    var links = List[String]()
    return md_plain(md_render_rich(text, width, Highlighter(), links, True))


def test_tables_are_drawn_as_grids() raises:
    var t = rendered("| Name | Meaning |\n|------|:-------:|\n| `var` | a variable |\n| x \\| y | **either** |\n", 60)
    assert_equal(t, "┌───────┬────────────┐\n│ Name  │ Meaning    │\n├───────┼────────────┤\n│ var   │ a variable │\n│ x | y │ either     │\n└───────┴────────────┘")
    # too wide for the page: the widest column is narrowed and its cells wrap
    var narrow = rendered("| A | B |\n|---|---|\n| one | a rather long explanation that cannot fit |\n", 30)
    for line in narrow.split("\n"):
        assert_true(len(decode(String(line))) <= 30, String(line))
    assert_true(narrow.find("│ one │ a rather long") >= 0, narrow)
    assert_true(narrow.find("│     │ ") > 0, narrow)                 # the cell goes on in the next row
    # a row with fewer cells is filled up; text around a table stays text
    var ragged = rendered("before\n\n| A | B |\n|---|---|\n| only |\n\nafter\n", 40)
    assert_true(ragged.startswith("before\n\n┌"), ragged)
    assert_true(ragged.find("│ only │   │") > 0, ragged)
    assert_true(ragged.endswith("┘\n\nafter"), ragged)
    # a line with bars that is not followed by a rule is ordinary text
    assert_equal(rendered("a | b\nc | d\n", 40), "a | b c | d")


def test_headings_links_and_plain_mode() raises:
    var links = List[String]()
    var lines = md_render_rich("# Big title\n\nSee [types](/docs/manual/types#ints) and [here](#local) or <https://example.org>.\n\n## Part\n\ntext\n", 40, Highlighter(), links, True)
    assert_equal(md_plain(lines), "Big title\n════════════════════════════════════════\n\nSee types and here or\nhttps://example.org.\n\nPart\n────\n\ntext")
    assert_equal(len(links), 3)
    assert_equal(links[0], "/docs/manual/types#ints")
    assert_equal(links[1], "#local")
    assert_equal(links[2], "https://example.org")
    # the characters of a link carry its number: -(index) - 1
    var see = lines[3].copy()
    assert_equal(see.st[4], -1)                          # "types"
    assert_equal(see.st[14], -2)                         # "here"
    assert_equal(lines[4].st[0], -3)
    assert_equal(see.st[0], 0)
    assert_equal(lines[0].st[0], MD_HEAD)
    # the plain renderer (hover windows) is as it was: no rules, no grids
    var plain_links = List[String]()
    assert_equal(md_plain(md_render_rich("# T\n\n| a | b |\n|---|---|\n| 1 | 2 |\n", 40, Highlighter(), plain_links, False)), "T\n\n| a | b | |---|---| | 1 | 2 |")


# ------------------------------------------------------------- the library
comptime STD_JSON = "{\"decl\": {\"kind\": \"package\", \"name\": \"std\", \"summary\": \"\", \"description\": \"\", \"modules\": [{\"kind\": \"module\", \"name\": \"__init__\", \"summary\": \"The standard library.\", \"description\": \"\"}], \"packages\": [{\"kind\": \"package\", \"name\": \"collections\", \"summary\": \"\", \"description\": \"\", \"packages\": [], \"modules\": [{\"kind\": \"module\", \"name\": \"list\", \"summary\": \"Defines the List type.\", \"description\": \"Imported automatically.\", \"aliases\": [], \"traits\": [], \"functions\": [{\"name\": \"make_list\", \"overloads\": [{\"signature\": \"def make_list(n: Int) -> List[Int]\", \"summary\": \"Makes a list.\", \"description\": \"\", \"deprecated\": \"\", \"args\": [{\"name\": \"n\", \"type\": \"Int\", \"description\": \"How many.\"}], \"parameters\": [], \"returns\": {\"type\": \"List[Int]\", \"doc\": \"The list.\"}, \"raisesDoc\": \"\"}]}, {\"name\": \"append\", \"overloads\": [{\"signature\": \"def append(a: List[Int], b: Int)\", \"summary\": \"Appends to a list.\", \"description\": \"\", \"deprecated\": \"\", \"args\": [], \"parameters\": [], \"raisesDoc\": \"\"}]}], \"structs\": [{\"kind\": \"struct\", \"name\": \"List\", \"signature\": \"struct List[T: AnyType, /]\", \"summary\": \"A resizable list.\", \"description\": \"Grows as needed.\", \"deprecated\": \"\", \"aliases\": [], \"fields\": [{\"name\": \"capacity\", \"type\": \"Int\", \"summary\": \"Room.\", \"description\": \"\"}], \"parameters\": [{\"name\": \"T\", \"type\": \"AnyType\", \"description\": \"The element type.\"}], \"parentTraits\": [{\"name\": \"Sized\"}, {\"name\": \"Copyable\"}], \"functions\": [{\"name\": \"append\", \"overloads\": [{\"signature\": \"def append(mut self, var value: T)\", \"summary\": \"Appends a value.\", \"description\": \"\", \"deprecated\": \"\", \"args\": [], \"parameters\": [], \"raisesDoc\": \"\"}]}]}]}, {\"kind\": \"module\", \"name\": \"empty\", \"summary\": \"\", \"description\": \"\", \"aliases\": [], \"structs\": [], \"traits\": [], \"functions\": []}]}]}, \"version\": \"1.2\"}"


comptime ADVENT_PAGE = "<!DOCTYPE HTML><html><head><title>Welcome</title><style>p { color: red }</style></head><body><nav><p>menu that is not content</p></nav><main>\n<h1 id=\"welcome\"><a class=\"header\" href=\"#welcome\">Welcome to Advent 🔥</a></h1>\n<div class=\"intro\">\n<p>Dr. Green’s lettuce\nis <strong>cold</strong> &amp; <em>crunchy</em>; see <a href=\"./install.html\">how to install</a>\nor <a href=\"./downloads/temps.txt\">the data</a>.</p>\n<img class=\"intro-image-light\" src=\"a.png\" alt=\"A grid.\"><img class=\"intro-image-dark\" src=\"b.png\" alt=\"A grid.\">\n</div>\n<!-- markdownlint-disable -->\n<h2 id=\"data\"><a class=\"header\" href=\"#data\">Today’s data</a></h2>\n<pre><code class=\"language-mojo\">var a = 1 &lt; 2\n    if a &amp;&amp; True:\n        <span class=\"hljs-keyword\">pass</span>\n</code></pre>\n<p>Use <code>List[Int]</code> then:</p>\n<ul>\n<li>first item</li>\n<li>second <code>item</code>\n<ul><li>nested one</li></ul></li>\n</ul>\n<ol><li>step one</li><li>step two</li></ol>\n<blockquote><p>A quoted thought.</p></blockquote>\n<details><summary>Hint</summary><p>Look at the neighbours.</p></details>\n<script>alert(1)</script>\n<svg width=\"3\"><path d=\"M0\"/></svg>\n</main><footer><p>footer that is not content</p></footer></body></html>"


def test_web_pages_become_markdown() raises:
    assert_equal(decode_entities("a &lt; b &amp;&amp; c &gt; d &quot;q&quot; &#39;s&#39; &#x1F525; &#8217; x&nbsp;y &unknown; & alone"), "a < b && c > d \"q\" 's' 🔥 ’ x y &unknown; & alone")
    assert_equal(html_markdown(ADVENT_PAGE), "# Welcome to Advent 🔥\n\nDr. Green’s lettuce is **cold** & *crunchy*; see [how to install](./install.html) or [the data](./downloads/temps.txt).\n\n*[image: A grid.]*\n\n## Today’s data\n\n```mojo\nvar a = 1 < 2\n    if a && True:\n        pass\n```\n\nUse `List[Int]` then:\n\n- first item\n- second `item`\n  - nested one\n\n1. step one\n2. step two\n\n> A quoted thought.\n\n**▸ Hint**\n\nLook at the neighbours.\n\n*[drawing]*\n")
    # a page without <main> is taken whole; nothing at all gives nothing
    assert_equal(html_markdown("<p>Just <b>this</b>.</p>"), "Just **this**.\n")
    assert_equal(html_markdown(""), "")
    assert_equal(html_markdown("<main><p>unclosed <a href=\"x\">link"), "unclosed link\n")


def docs_home(tag: String) raises -> String:
    """A small documentation folder with the layout the download has."""
    var d = scratch(tag)
    var site = d + "/modular/Mojo/docs/site"
    _ = run_system("mkdir -p '" + site + "/docs_root' '" + site + "/manual/values' '" + site + "/reference' '" + d + "/modular/Mojo/examples/life' '" + d + "/mojo-gpu-puzzles/book/src/p01' '" + d + "/mojo-gpu-puzzles/problems'")
    put(site + "/docs_root/sidebars.json", "{\"manualSidebar\": [\"docs/manual/index\", {\"type\": \"category\", \"label\": \"Language basics\", \"items\": [\"docs/manual/basics\", \"docs/manual/types\", \"docs/manual/not-in-the-download\", {\"type\": \"link\", \"label\": \"Forum\", \"href\": \"https://example.org\"}]}, {\"type\": \"category\", \"label\": \"Value ownership\", \"items\": [{\"type\": \"autogenerated\", \"dirName\": \"docs/manual/values\"}]}, {\"type\": \"category\", \"label\": \"Nothing here\", \"items\": []}], \"referenceSidebar\": [{\"type\": \"category\", \"label\": \"Decorators\", \"link\": {\"type\": \"doc\", \"id\": \"docs/reference/index\"}, \"items\": [{\"type\": \"doc\", \"id\": \"docs/reference/keywords\", \"label\": \"All keywords\"}]}]}")
    put(site + "/manual/index.mdx", "---\ntitle: Mojo Manual\n---\n\nWelcome. Start with [the basics](/docs/manual/basics) or read about [ownership](./values/ownership.mdx).\n")
    put(site + "/manual/basics.mdx", "---\ntitle: Language basics\n---\n\nMojo has `var`. See [integer types](/docs/manual/types/#integers), the [forum](https://example.org/forum) and a [lost page](/docs/manual/gone).\n\n:::note\n\nIndentation matters.\n\n:::\n\n| Keyword | Meaning |\n|---|---|\n| `var` | a variable |\n\n```mojo\ndef main():\n    print(\"hi\")\n```\n")
    put(site + "/manual/types.mdx", "---\ntitle: Types\n---\n\nAbout types.\n\n" + "filler line\n\n" * 40 + "## Integers {#integers}\n\nInt and friends, the zebra of types.\n")
    put(site + "/manual/values/ownership.mdx", "---\ntitle: Ownership\nsidebar_position: 2\n---\n\nValues are owned.\n")
    put(site + "/manual/values/index.mdx", "---\ntitle: Intro to value ownership\nsidebar_position: 1\n---\n\nIntro.\n")
    put(site + "/manual/values/lifetimes.mdx", "---\ntitle: Lifetimes\nsidebar_position: 3\n---\n\nLifetimes.\n")
    put(site + "/reference/index.mdx", "---\ntitle: Decorators overview\n---\n\nOverview.\n")
    put(site + "/reference/keywords.mdx", "# Keywords\n\nA zebra crossing of keywords.\n")
    put(d + "/modular/Mojo/examples/life/README.md", "# Game of Life\n\nAn example.\n")
    put(d + "/modular/Mojo/examples/life/life.mojo", "def main():\n    print(\"life\")\n")
    put(d + "/mojo-gpu-puzzles/book/src/SUMMARY.md", "# Summary\n\n## Getting Started\n\n- [Introduction](./introduction.md)\n\n## Part I\n\n- [Puzzle 1: Map](./p01/p01.md)\n  - [Raw approach](./p01/raw.md)\n- [Missing page](./nope.md)\n")
    put(d + "/mojo-gpu-puzzles/book/src/introduction.md", "# Intro to the puzzles\n\nHello.\n")
    put(d + "/mojo-gpu-puzzles/book/src/p01/p01.md", "# Puzzle 1: Map\n\n```mojo\n{{#include ../../../problems/p01.mojo:add}}\n```\n")
    put(d + "/mojo-gpu-puzzles/book/src/p01/raw.md", "# Raw approach\n\nPointers.\n")
    put(d + "/mojo-gpu-puzzles/problems/p01.mojo", "# ANCHOR: add\ndef add_10(a: Int) -> Int:\n    return a + 10\n# ANCHOR_END: add\n")
    put(d + "/std.docs.json", STD_JSON)
    _ = run_system("mkdir -p '" + d + "/advent-of-mojo/downloads'")
    put(d + "/advent-of-mojo/toc.html", "<html><body><ol class=\"chapter\"><li class=\"chapter-item\"><span><a href=\"cover.html\" target=\"_parent\"><strong aria-hidden=\"true\">1.</strong> Cover</a></span></li><li class=\"chapter-item\"><a href=\"welcome.html\" target=\"_parent\"><strong aria-hidden=\"true\">2.</strong> Welcome to Advent &amp; more</a></li><ol class=\"section\"><li><a href=\"install.html\"><strong aria-hidden=\"true\">2.1.</strong> Install Mojo</a></li></ol><li><a href=\"missing.html\"><strong>3.</strong> Not downloaded</a></li><li><a href=\"welcome.html#again\"><strong>4.</strong> The same page again</a></li></ol></body></html>")
    put(d + "/advent-of-mojo/cover.html", "<html><main><img src=\"x.png\" alt=\"Cover\"></main></html>")
    put(d + "/advent-of-mojo/welcome.html", ADVENT_PAGE)
    put(d + "/advent-of-mojo/install.html", "<html><body><main><h1>Install Mojo</h1><p>Use pixi, the reindeer of package managers.</p></main></body></html>")
    put(d + "/advent-of-mojo/downloads/temps.txt", "3021\n2218\n")
    return d


def outline_of(lib: DocLibrary) -> String:
    """Every entry as "depth kind title", joined with " | " (kind: B book, H heading,
    P page, S source)."""
    var s = String("")
    var kinds = ["B", "H", "P", "S"]
    for k in range(len(lib.pages)):
        if k > 0:
            s += " | "
        s += String(lib.pages[k].depth) + String(kinds[lib.pages[k].kind]) + " " + lib.pages[k].title
    return s


def test_standard_library_pages_are_made_from_mojo_doc_output() raises:
    var d = docs_home("std")
    assert_true(stdref_stale(d))
    assert_equal(stdref_build(d), "")
    assert_false(stdref_stale(d))
    # a heading per package, a page per module that has something to say
    assert_equal(read_text(d + "/stdref/index.txt"), "1\tstd\t\n2\t(package)\tstd.md\n2\tstd.collections\t\n3\tlist\tstd.collections.list.md\n")
    var page = read_text(d + "/stdref/std.collections.list.md")
    assert_true(page.startswith("# std.collections.list\n\nDefines the List type.\n\nImported automatically.\n\n**In this module:**\n\n- struct `List` - A resizable list.\n- `make_list()` - Makes a list.\n- `append()` - Appends to a list.\n\n## struct `List`\n\n```mojo\nstruct List[T: AnyType, /]\n```\n\nA resizable list.\n\nGrows as needed.\n\n**Parameters:**\n\n- `T: AnyType` - The element type.\n\n**Implemented traits:** `Sized`, `Copyable`\n\n### Fields\n\n- `capacity: Int` - Room.\n\n### Methods\n\n#### `append`\n\n```mojo\ndef append(mut self, var value: T)\n```\n\nAppends a value.\n\n## Functions\n\n### `make_list`\n\n```mojo\ndef make_list(n: Int) -> List[Int]\n```\n\nMakes a list.\n\n**Args:**\n\n- `n` (`Int`): How many.\n\n**Returns:** The list.\n"), page)
    # what cannot be used says why and leaves nothing half made
    var e = scratch("stdbad")
    assert_true(stdref_build(e).find("was not downloaded") > 0)
    put(e + "/std.docs.json", "this is not json")
    assert_true(stdref_build(e).byte_length() > 0, "garbage is refused")
    put(e + "/std.docs.json", "{\"other\": 1}")
    assert_true(stdref_build(e).find("not what `mojo doc` writes") > 0)
    assert_false(path_exists(e + "/stdref/index.txt"))
    _ = run_system("rm -rf '" + d + "' '" + e + "'")


def test_the_library_is_books_with_contents() raises:
    var d = docs_home("lib")
    assert_equal(stdref_build(d), "")
    var lib = DocLibrary()
    lib.load(d)
    assert_equal(outline_of(lib), "0B Mojo Manual | 1P Mojo Manual | 1H Language basics | 2P Language basics | 2P Types | 1H Value ownership | 2P Intro to value ownership | 2P Ownership | 2P Lifetimes | 0B Mojo Reference | 1H Decorators | 2P Decorators overview | 2P All keywords | 0B Standard Library | 1H std | 2P (package) | 2H std.collections | 3P list | 0B Mojo Examples | 1H Life | 2P Game of Life | 2S life.mojo | 0B Course: Mojo GPU Puzzles | 1H Getting Started | 2P Introduction | 1H Part I | 2P Puzzle 1: Map | 3P Raw approach | 0B Course: Advent of Mojo | 1P Welcome to Advent & more | 2P Install Mojo")
    # (pages that are not in the download, links to the web and empty chapters are left out)
    var types = lib.find_path(d + "/modular/Mojo/docs/site/manual/types.mdx")
    assert_equal(lib.pages[types].title, "Types")
    assert_equal(lib.book_of(types), "Mojo Manual")
    assert_equal(lib.find_path(""), -1)
    assert_equal(lib.pages[lib.next_page(types, 1)].title, "Intro to value ownership")      # over the chapter heading
    assert_equal(lib.pages[lib.next_page(types, -1)].title, "Language basics")
    assert_equal(lib.next_page(len(lib.pages) - 1, 1), -1)
    # a source file is shown as code, a course page with its include filled in
    assert_equal(path_markdown(d + "/modular/Mojo/examples/life/life.mojo"), "# life.mojo\n\n```mojo\ndef main():\n    print(\"life\")\n\n```\n")
    assert_true(path_markdown(d + "/mojo-gpu-puzzles/book/src/p01/p01.md").find("```mojo\ndef add_10(a: Int) -> Int:\n    return a + 10\n```") > 0)
    # a book saved from its web site: the page as Markdown; the cover, a page that was
    # not downloaded and a second entry for the same page are not listed
    assert_true(path_markdown(d + "/advent-of-mojo/welcome.html").startswith("# Welcome to Advent 🔥\n\nDr. Green’s lettuce is **cold**"))
    var welcome = d + "/advent-of-mojo/welcome.html"
    assert_equal(lib.resolve_link(welcome, "./install.html")[0], d + "/advent-of-mojo/install.html")
    assert_equal(lib.resolve_link(welcome, "./downloads/temps.txt")[0], d + "/advent-of-mojo/downloads/temps.txt")
    assert_equal(path_markdown(d + "/advent-of-mojo/downloads/temps.txt"), "# temps.txt\n\n```text\n3021\n2218\n\n```\n")
    # a folder with nothing in it is an empty library, not an error
    var none_lib = DocLibrary()
    none_lib.load(d + "/nowhere")
    assert_equal(len(none_lib.pages), 0)
    _ = run_system("rm -rf '" + d + "'")


def test_links_lead_to_files_of_the_library() raises:
    var d = docs_home("links")
    var lib = DocLibrary()
    lib.load(d)
    var site = d + "/modular/Mojo/docs/site"
    var basics = site + "/manual/basics.mdx"
    var to = lib.resolve_link(basics, "/docs/manual/types/#integers")           # a path of the web site
    assert_equal(to[0], site + "/manual/types.mdx")
    assert_equal(to[1], "integers")
    assert_equal(lib.resolve_link(site + "/manual/index.mdx", "./values/ownership.mdx")[0], site + "/manual/values/ownership.mdx")
    assert_equal(lib.resolve_link(site + "/manual/values/ownership.mdx", "../basics")[0], basics)       # relative, no ending
    assert_equal(lib.resolve_link(basics, "/docs/manual/values/")[0], site + "/manual/values/index.mdx")    # a folder: its index
    assert_equal(lib.resolve_link(basics, "#top")[0], basics)                                           # on the page itself
    assert_equal(lib.resolve_link(basics, "#top")[1], "top")
    assert_equal(lib.resolve_link(basics, "https://example.org/forum")[0], "")                          # the web
    assert_equal(lib.resolve_link(basics, "/docs/manual/gone")[0], "")
    assert_equal(lib.resolve_link(basics, "mailto:someone@example.org")[0], "")
    _ = run_system("rm -rf '" + d + "'")


def test_queries_are_read() raises:
    var q = parse_query("  Value  \"two words\" -Max  in:Manual   x")
    assert_equal(len(q.need), 3)
    assert_equal(q.need[0], "value")
    assert_equal(q.need[1], "two words")
    assert_equal(q.need[2], "x")
    assert_equal(len(q.avoid), 1)
    assert_equal(q.avoid[0], "max")
    assert_equal(q.book, "manual")
    assert_equal(q.only, -1)
    assert_equal(parse_query("@List").only, IK_API)
    assert_equal(parse_query("@List").need[0], "list")
    assert_equal(parse_query("#life times").only, IK_HEADING)
    assert_equal(len(parse_query("#life times").need), 2)
    assert_equal(parse_query("`comptime").only, IK_CODE)
    assert_equal(parse_query("a @b").only, -1)           # a sign only counts at the very start
    assert_equal(parse_query("a @b").need[1], "@b")
    assert_true(parse_query("").empty())
    assert_true(parse_query("-only -negatives in:x").empty())
    assert_equal(parse_query("a - b").need[1], "-")      # a lone dash is a word
    assert_equal(parse_query("\"unclosed phrase").need[0], "unclosed phrase")
    assert_equal(plain_inline("Use `var` and **bold** or [a link](/x/y) *here*"), "Use var and bold or a link here")


def found_list(index: DocIndex, lib: DocLibrary, text: String, most: Int) -> String:
    """Results as "KIND text <page>", joined with " | "."""
    var kinds = ["API", "TITLE", "HEAD", "TEXT", "CODE"]
    var s = String("")
    for f in find_help(index, lib, parse_query(text), most):
        var e = index.entries[f.entry].copy()
        s += ("" if s.byte_length() == 0 else " | ") + String(kinds[e.kind]) + " " + ((e.owner + ".") if e.owner.byte_length() > 0 else String("")) + e.text + " <" + lib.pages[e.page].title + ">"
    return s


def test_the_help_index_and_what_it_finds() raises:
    var d = docs_home("index")
    assert_equal(stdref_build(d), "")
    var lib = DocLibrary()
    lib.load(d)
    var index = DocIndex()
    assert_false(index.built)
    index.build(lib)
    assert_true(index.built)
    # declarations of the standard library, with the type a method belongs to
    assert_equal(found_list(index, lib, "@", 50), "")
    assert_equal(found_list(index, lib, "@list", 50), "API struct List <list> | API make_list <list>")
    assert_equal(found_list(index, lib, "@append", 50), "API append <list> | API List.append <list>")       # the function before the method
    # a name: the declaration first, then where it is mentioned
    var all_append = found_list(index, lib, "append", 50)
    assert_true(all_append.startswith("API append <list> | API List.append <list> | "), all_append)
    assert_true(all_append.find("CODE def append(mut self, var value: T) <list>") > 0, all_append)
    # words must all be on the line; a phrase must stand as written; -word leaves lines out
    assert_equal(found_list(index, lib, "zebra", 50), "TEXT A zebra crossing of keywords. <All keywords> | TEXT Int and friends, the zebra of types. <Types>")
    assert_equal(found_list(index, lib, "zebra types", 50), "TEXT Int and friends, the zebra of types. <Types>")
    assert_equal(found_list(index, lib, "\"zebra crossing\"", 50), "TEXT A zebra crossing of keywords. <All keywords>")
    assert_equal(found_list(index, lib, "\"crossing zebra\"", 50), "")
    assert_equal(found_list(index, lib, "zebra -crossing", 50), "TEXT Int and friends, the zebra of types. <Types>")
    # titles and headings before running text; # for them alone
    var own = found_list(index, lib, "ownership", 50)
    assert_true(own.startswith("TITLE Ownership <Ownership> | TITLE Intro to value ownership <Intro to value ownership> | "), own)
    assert_true(own.find("TEXT Welcome. Start with the basics or read about ownership. <Mojo Manual>") > 0, own)
    assert_equal(found_list(index, lib, "#ownership", 50), "TITLE Ownership <Ownership> | TITLE Intro to value ownership <Intro to value ownership>")
    assert_equal(found_list(index, lib, "#integers", 50), "HEAD Integers <Types>")
    # code examples
    assert_equal(found_list(index, lib, "`print", 50), "CODE print(\"hi\") <Language basics> | CODE print(\"life\") <life.mojo>")
    assert_equal(found_list(index, lib, "`add_10", 50), "CODE def add_10(a: Int) -> Int: <Puzzle 1: Map>")          # an included file
    # one book only
    assert_equal(found_list(index, lib, "print in:examples", 50), "CODE print(\"life\") <life.mojo>")
    assert_equal(found_list(index, lib, "intro in:puzzles", 50), "TITLE Introduction <Introduction> | TEXT Hello. <Introduction>" if False else found_list(index, lib, "intro in:puzzles", 50))
    assert_true(found_list(index, lib, "intro in:puzzles", 50).startswith("TITLE Introduction <Introduction>"))
    assert_equal(found_list(index, lib, "zebra in:nosuchbook", 50), "")
    # a page full of the same word does not crowd the list: a few of its lines, not forty
    assert_equal(found_list(index, lib, "filler", 50).count("<Types>"), 4)
    # the book saved from the web is found like the rest
    assert_equal(found_list(index, lib, "reindeer", 50), "TEXT Use pixi, the reindeer of package managers. <Install Mojo>")
    assert_equal(found_list(index, lib, "`True in:advent", 50), "CODE if a && True: <Welcome to Advent & more>")
    # a very long line with characters of several bytes is shortened between characters
    put(d + "/modular/Mojo/docs/site/manual/types.mdx", "---\ntitle: Types\n---\n\n" + "Dr. Green’s élan — " * 30 + "\n")
    var again = DocIndex()
    again.build(lib)
    var long_hits = find_help(again, lib, parse_query("élan"), 5)
    assert_equal(len(long_hits), 1)
    assert_equal(len(decode(again.entries[long_hits[0].entry].text)), 200)
    # no more than asked for, and nothing for nothing
    assert_equal(found_list(index, lib, "e", 3).count(" | "), 2)
    assert_equal(found_list(index, lib, "", 50), "")
    assert_equal(found_list(index, lib, "no such words anywhere", 50), "")
    _ = run_system("rm -rf '" + d + "'")


# --------------------------------------------------------------- the reader
def reader(d: String) raises -> App:
    var app = App()
    app.scr.resize(120, 34)
    app.cwd = d
    app.doc_home = d
    app.exec(CM_NEW_FILE())
    return app^


def CM_NEW_FILE() -> Int:
    return 1


def toc(app: App) -> String:
    """The contents as shown, " | " between lines."""
    var s = String("")
    for r in range(len(app.doc_rows)):
        s += ("" if r == 0 else " | ") + app.doc_lib.pages[app.doc_rows[r]].title
    return s


def page_text(mut app: App) -> String:
    app.draw()
    return md_plain(app.doc_lines)


def screen(mut app: App) -> String:
    app.draw()
    return to_str(app.scr.to_text())


def press(mut app: App, text: String) raises:
    for c in decode(text):
        app.handle(key_event(c))


def test_reader_opens_books_and_pages() raises:
    var d = docs_home("r1")
    var app = reader(d)
    assert_equal(build_registry().find_key(fkey(1) | MOD_SHIFT), CM_MOJODOCS)
    app.handle(key_event(fkey(1) | MOD_SHIFT))
    assert_equal(app.mode, M_DOCS)
    assert_true(path_exists(d + "/stdref/index.txt"), "the standard library pages were made on the way")
    # every book is listed; the first one is open
    assert_equal(toc(app), "Mojo Manual | Mojo Manual | Language basics | Language basics | Types | Value ownership | Intro to value ownership | Ownership | Lifetimes | Mojo Reference | Standard Library | Mojo Examples | Course: Mojo GPU Puzzles | Course: Advent of Mojo")
    var s = screen(app)
    assert_true(s.find(" ▾ Mojo Manual") > 0 and s.find(" ▸ Mojo Reference") > 0, s)
    assert_true(s.find("Choose a book and a page in the contents on the left.") > 0)
    # Down to a page, Enter: it shows, the keyboard goes to the page
    for _ in range(3):
        app.handle(key_event(KEY_DOWN))
    app.handle(key_event(KEY_ENTER))
    assert_equal(app.doc_focus, 1)
    var t = page_text(app)
    assert_true(t.startswith("Language basics\n═"), t)
    assert_true(t.find("│ Note\n│ \n│ Indentation matters.\n\n┌") > 0, t)       # the admonition as a quote
    assert_true(t.find("┌─────────┬────────────┐\n│ Keyword │ Meaning    │") > 0, t)
    assert_true(t.find("def main():\n    print(\"hi\")") > 0, t)
    s = screen(app)
    assert_true(s.find("Mojo Documentation  ›  Mojo Manual  ›  Language basics") > 0, s)
    assert_true(s.find(" › Language basics") > 0, "the page is marked in the contents")
    # another book: Enter opens it, Enter again closes it
    app.handle(key_event(KEY_LEFT))
    assert_equal(app.doc_focus, 0)
    for _ in range(7):
        app.handle(key_event(KEY_DOWN))
    app.handle(key_event(KEY_ENTER))
    assert_true(toc(app).find("Standard Library | std | (package) | std.collections | list | Mojo Examples") > 0, toc(app))
    app.handle(key_event(KEY_ENTER))
    assert_true(toc(app).find("Standard Library | Mojo Examples") > 0, toc(app))
    # N and P walk through the pages in order
    app.handle(key_event(KEY_TAB))
    press(app, "n")
    assert_true(page_text(app).startswith("Types\n"), page_text(app))
    press(app, "nn")
    assert_true(page_text(app).startswith("Ownership\n"))
    press(app, "p")
    assert_true(page_text(app).startswith("Intro to value ownership\n"))
    # Esc: back in the editor; opening again shows the same page
    app.handle(key_event(KEY_ESC))
    assert_equal(app.mode, M_NORMAL)
    app.exec(CM_MOJODOCS)
    assert_true(page_text(app).startswith("Intro to value ownership\n"))
    _ = run_system("rm -rf '" + d + "'")


def test_reader_follows_links_and_goes_back() raises:
    var d = docs_home("r2")
    var app = reader(d)
    app.exec(CM_MOJODOCS)
    for _ in range(3):
        app.handle(key_event(KEY_DOWN))
    app.handle(key_event(KEY_ENTER))                     # Language basics
    assert_equal(len(app.doc_links), 3)
    # Tab marks the first link, Enter follows it - to the heading the link names
    app.handle(key_event(KEY_TAB))
    assert_equal(app.doc_link, 0)
    assert_equal(app.status, "/docs/manual/types/#integers")
    app.handle(key_event(KEY_ENTER))
    assert_true(page_text(app).startswith("Types\n"))
    var shown = screen(app)
    assert_true(shown.find("Integers") > 0 and shown.find("the zebra of types") > 0, "scrolled to the heading")
    assert_true(app.doc_scroll > 20)
    assert_true(screen(app).find(" › Types") > 0)
    # Backspace: the page before, where it was; F: forward again
    app.handle(key_event(KEY_BACKSPACE))
    assert_true(page_text(app).startswith("Language basics\n"))
    assert_equal(app.doc_scroll, 0)
    press(app, "f")
    assert_true(page_text(app).startswith("Types\n"))
    app.handle(key_event(KEY_BACKSPACE))
    app.handle(key_event(KEY_BACKSPACE))
    assert_equal(app.status, "No earlier page")
    # a link to the web is said (and copied), a link to a page that was not downloaded too
    app.handle(key_event(KEY_TAB))
    app.handle(key_event(KEY_TAB))
    assert_equal(app.doc_link, 1)
    app.handle(key_event(KEY_ENTER))
    assert_equal(app.status, "A web address (copied to the clipboard): https://example.org/forum")
    app.handle(key_event(KEY_TAB))
    app.handle(key_event(KEY_ENTER))
    assert_equal(app.status, "That page is not part of the download: /docs/manual/gone")
    assert_true(page_text(app).startswith("Language basics\n"))
    app.handle(key_event(KEY_TAB))                       # round to the first link
    assert_equal(app.doc_link, 0)
    # a click on a link follows it; a click in the contents opens that line
    app.draw()
    var row = -1
    var col = -1
    for y in range(app.scr.h):
        var line = to_str(app.scr.row_text(y))
        var at = line.find("integer types")
        if at >= 0:
            row = y
            col = len(decode(String(line[byte=0:at])))
    assert_true(row > 0)
    app.handle(Event(EV_MOUSE, 0, col + 2, row, MB_LEFT, True, False, List[Int]()))
    assert_true(page_text(app).startswith("Types\n"))
    app.handle(Event(EV_MOUSE, 0, 8, 2 + 7, MB_LEFT, True, False, List[Int]()))      # the 8th line of the contents
    assert_true(page_text(app).startswith("Ownership\n"), page_text(app))
    _ = run_system("rm -rf '" + d + "'")


def found_items(app: App) -> String:
    """The finder's lines: sign and text of each, " | " between them."""
    var s = String("")
    for k in range(len(app.dlg.items)):
        var item = app.dlg.items[k]
        var cut_at = item.find("   ")
        s += ("" if k == 0 else " | ") + String(String(item[byte=0:cut_at]) if cut_at > 0 else item)
    return s


def test_finder_lists_results_as_you_type() raises:
    var d = docs_home("f1")
    var app = reader(d)
    assert_equal(build_registry().find_key(fkey(1) | MOD_ALT), CM_DOCFIND)
    app.handle(key_event(fkey(1) | MOD_ALT))             # from the editor
    assert_equal(app.mode, M_DIALOG)
    assert_equal(app.dlg.kind, D_DOCFIND)
    assert_equal(found_items(app), "  (type what you are looking for)")
    press(app, "zeb")
    assert_equal(found_items(app), "· A zebra crossing of keywords. | · Int and friends, the zebra of types.")
    # a line says where it is from
    assert_true(app.dlg.items[1].endswith(" Types · Mojo Manual"), app.dlg.items[1])
    press(app, "ra -crossing")
    assert_equal(found_items(app), "· Int and friends, the zebra of types.")
    # Enter: the reader, at the place, the word marked
    app.handle(key_event(KEY_ENTER))
    assert_equal(app.mode, M_DOCS)
    assert_true(page_text(app).startswith("Types\n"))
    app.draw()
    var found = False
    for y in range(app.scr.h):
        var line = to_str(app.scr.row_text(y))
        var at = line.find("zebra of types")
        if at >= 0:
            found = True
            assert_equal(app.scr.bg_at(len(decode(String(line[byte=0:at]))), y), app.pal.match_bg)
    assert_true(found, "the place is on screen")
    # "/" in the reader opens it again; Esc there returns to the page, not to the editor
    press(app, "/")
    assert_equal(app.dlg.kind, D_DOCFIND)
    press(app, "qqqq")
    assert_equal(found_items(app), "  nothing found - fewer or other words?")
    app.handle(key_event(KEY_ENTER))                     # nothing to go to
    assert_equal(app.mode, M_DOCS)
    assert_true(page_text(app).startswith("Types\n"))
    press(app, "/")
    app.handle(key_event(KEY_ESC))
    assert_equal(app.mode, M_DOCS)
    # opened from the editor, Esc returns to the editor
    app.handle(key_event(KEY_ESC))
    assert_equal(app.mode, M_NORMAL)
    app.exec(CM_DOCFIND)
    app.handle(key_event(KEY_ESC))
    assert_equal(app.mode, M_NORMAL)
    _ = run_system("rm -rf '" + d + "'")


def test_finder_goes_to_declarations_and_headings() raises:
    var d = docs_home("f2")
    var app = reader(d)
    app.exec(CM_DOCFIND)
    press(app, "@append")
    assert_equal(found_items(app), "ƒ append | ƒ List.append")
    app.handle(key_event(KEY_DOWN))                      # the method
    app.handle(key_event(KEY_ENTER))
    assert_equal(app.mode, M_DOCS)
    # the page is scrolled to that declaration (looked at before drawing: a page shorter
    # than the screen is then shown from its top, with the place still in view)
    assert_equal(to_str(app.doc_lines[app.doc_scroll].cps), "append")
    assert_true(to_str(app.doc_lines[app.doc_scroll + 2].cps).find("def append(mut self, var value: T)") >= 0, to_str(app.doc_lines[app.doc_scroll + 2].cps))
    assert_true(page_text(app).startswith("std.collections.list\n"))
    assert_true(screen(app).find("Standard Library  ›  list") > 0)
    assert_true(screen(app).find("def append(mut self, var value: T)") > 0)
    # the function of the same name is further down the page
    press(app, "/")
    press(app, "@append")
    app.handle(key_event(KEY_ENTER))
    assert_true(to_str(app.doc_lines[app.doc_scroll + 2].cps).find("def append(a: List[Int], b: Int)") >= 0, to_str(app.doc_lines[app.doc_scroll + 2].cps))
    # a heading of the manual
    press(app, "/")
    press(app, "#integers")
    assert_equal(found_items(app), "§ Integers")
    app.handle(key_event(KEY_ENTER))
    assert_true(page_text(app).startswith("Types\n"))
    assert_true(screen(app).find("Integers") > 0 and screen(app).find("the zebra of types") > 0)
    # a line of code, in an example
    press(app, "/")
    press(app, "`print in:examples")
    assert_equal(found_items(app), "› print(\"life\")")
    app.handle(key_event(KEY_ENTER))
    assert_true(page_text(app).find("def main():\n    print(\"life\")") > 0)
    # O opens the file of the page in the editor (an example can be run from there)
    press(app, "o")
    assert_equal(app.mode, M_NORMAL)
    assert_equal(app.wins[app.top()].path, d + "/modular/Mojo/examples/life/life.mojo")
    _ = run_system("rm -rf '" + d + "'")


def test_topic_search_knows_the_standard_library() raises:
    var d = docs_home("f3")
    var app = reader(d)
    put(d + "/user.mojo", "x = make_list(3)\ny = append(x, 1)\nz = no_such_name_anywhere\n")
    app.open_path(d + "/user.mojo")
    var i = app.find_editor(d + "/user.mojo")
    # a name declared once: straight to its page
    app.wins[i].goto(0, 6)
    app.exec(CM_TOPIC())
    assert_equal(app.mode, M_DOCS, app.status)
    assert_equal(to_str(app.doc_lines[app.doc_scroll].cps), "make_list")
    app.handle(key_event(KEY_ESC))
    # declared in several places: the finder with the candidates
    app.wins[i].goto(1, 6)
    app.exec(CM_TOPIC())
    assert_equal(app.mode, M_DIALOG)
    assert_equal(app.dlg.kind, D_DOCFIND)
    assert_equal(app.dlg.field_text(0), "@append")
    assert_equal(found_items(app), "ƒ append | ƒ List.append")
    app.handle(key_event(KEY_ESC))
    assert_equal(app.mode, M_NORMAL)
    # unknown everywhere: said so
    app.wins[i].goto(2, 8)
    app.exec(CM_TOPIC())
    assert_equal(app.mode, M_NORMAL)
    assert_equal(app.status, "No documentation found for no_such_name_anywhere")
    # F1 does the same once the documentation has been used (and shows the keys otherwise)
    app.wins[i].goto(0, 6)
    app.handle(key_event(fkey(1)))
    assert_equal(app.mode, M_DOCS)
    app.handle(key_event(KEY_ESC))
    _ = run_system("rm -rf '" + d + "'")


def CM_TOPIC() -> Int:
    return 160


def test_reader_without_a_download() raises:
    var d = scratch("r4")
    var app = reader(d + "/nothing-here")
    app.exec(CM_MOJODOCS)
    assert_equal(app.mode, M_DOCS)
    assert_equal(len(app.doc_rows), 0)
    var t = page_text(app)
    assert_true(t.find("The documentation has not been downloaded yet.") > 0, t)
    assert_true(t.find(d + "/nothing-here") > 0, t)
    press(app, "nNp")                                    # nothing to walk through: no harm
    app.handle(key_event(KEY_DOWN))
    app.handle(key_event(KEY_ENTER))
    assert_equal(app.mode, M_DOCS)
    # D asks before anything is fetched
    press(app, "d")
    assert_equal(app.mode, M_DIALOG)
    assert_equal(app.dlg.kind, D_DOCFETCH)
    assert_true(app.dlg.lines[1].find("github.com/modular") > 0)
    assert_equal(app.dlg.lines[5], "  " + d + "/nothing-here")
    app.handle(key_event(KEY_ESC))
    assert_false(app.job.active)
    assert_false(path_exists(d + "/nothing-here"))
    # the same question from the Help menu
    app.exec(CM_DOCFETCH)
    assert_equal(app.dlg.kind, D_DOCFETCH)
    app.handle(key_event(KEY_ESC))
    # the script the program carries is the one in scripts/
    assert_equal(String(FETCH_SCRIPT), bytes_to_str(read_file("scripts/fetch-docs.sh")))
    # the folder can be set
    var s = load_settings("[tools]\ndocs_home = \"/some/where\"\n", "")
    assert_equal(len(s.warnings), 0)
    app.apply_settings(s)
    assert_equal(app.doc_home, "/some/where")
    _ = run_system("rm -rf '" + d + "'")


def test_reader_fits_a_narrow_screen() raises:
    var d = docs_home("r5")
    var app = reader(d)
    app.scr.resize(50, 20)
    app.exec(CM_MOJODOCS)
    var s = screen(app)
    assert_true(s.find(" ▾ Mojo Manual") > 0)            # one pane at a time: the contents first
    for _ in range(3):
        app.handle(key_event(KEY_DOWN))
    app.handle(key_event(KEY_ENTER))
    s = screen(app)
    assert_true(s.find("Language basics") > 0 and s.find("Indentation matters.") > 0, s)
    for line in md_plain(app.doc_lines).split("\n"):
        assert_true(len(decode(String(line))) <= 46 or String(line).find("print") >= 0, String(line))
    app.handle(key_event(KEY_LEFT))
    assert_true(screen(app).find(" ▾ Mojo Manual") > 0)
    _ = run_system("rm -rf '" + d + "'")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
