"""The standard library reference: `mojo doc`'s JSON for the `std` package (made by
scripts/fetch-docs.sh) turned into one Markdown page per module, with an index that the
documentation library reads as a book."""
from std.collections import List
from json import Json, json_parse
from util import bytes_to_str, read_file, write_file, str_bytes, path_exists, shell_quote, run_system


def both(summary: String, description: String) -> String:
    var s = String(summary.strip())
    var d = String(description.strip())
    if d.byte_length() > 0:
        s += ("\n\n" if s.byte_length() > 0 else "") + d
    return s


def function_docs(doc: Json, f: Int, level: String) -> String:
    """A function or method with all its overloads, under a heading of `level`."""
    var name = doc.str(doc.get(f, "name"))
    var out = level + " `" + name + "`\n\n"
    for ov in doc.children(doc.get(f, "overloads")):
        out += "```mojo\n" + doc.str(doc.get(ov, "signature")) + "\n```\n\n"
        var dep = doc.str(doc.get(ov, "deprecated"))
        if dep.byte_length() > 0:
            out += "**Deprecated:** " + dep + "\n\n"
        var text = both(doc.str(doc.get(ov, "summary")), doc.str(doc.get(ov, "description")))
        if text.byte_length() > 0:
            out += text + "\n\n"
        var params = String("")
        for p in doc.children(doc.get(ov, "parameters")):
            var pd = String(doc.str(doc.get(p, "description")).strip())
            if pd.byte_length() > 0:
                params += "- `" + doc.str(doc.get(p, "name")) + "`: " + pd + "\n"
        if params.byte_length() > 0:
            out += "**Parameters:**\n\n" + params + "\n"
        var args = String("")
        for a in doc.children(doc.get(ov, "args")):
            var ad = String(doc.str(doc.get(a, "description")).strip())
            if ad.byte_length() > 0:
                var ty = doc.str(doc.get(a, "type"))
                args += "- `" + doc.str(doc.get(a, "name")) + "`" + ((" (`" + ty + "`)") if ty.byte_length() > 0 else String("")) + ": " + ad + "\n"
        if args.byte_length() > 0:
            out += "**Args:**\n\n" + args + "\n"
        var ret = doc.get(ov, "returns")
        if ret >= 0:
            var rd = String(doc.str(doc.get(ret, "doc")).strip())
            if rd.byte_length() > 0:
                out += "**Returns:** " + rd + "\n\n"
        var raises = String(doc.str(doc.get(ov, "raisesDoc")).strip())
        if raises.byte_length() > 0:
            out += "**Raises:** " + raises + "\n\n"
    return out


def aliases_docs(doc: Json, node: Int, level: String) -> String:
    var out = String("")
    for a in doc.children(doc.get(node, "aliases")):
        var name = doc.str(doc.get(a, "name"))
        if name.byte_length() == 0:
            continue
        var value = doc.str(doc.get(a, "value"))
        out += level + " `" + name + "`\n\n```mojo\n" + doc.str(doc.get(a, "signature"), "comptime " + name) + ((" = " + value) if value.byte_length() > 0 else String("")) + "\n```\n\n"
        var text = both(doc.str(doc.get(a, "summary")), doc.str(doc.get(a, "description")))
        if text.byte_length() > 0:
            out += text + "\n\n"
    return out


def type_docs(doc: Json, node: Int, word: String) -> String:
    """A struct or trait: what it is, its parameters, traits, fields and methods."""
    var name = doc.str(doc.get(node, "name"))
    var out = "## " + word + " `" + name + "`\n\n```mojo\n" + doc.str(doc.get(node, "signature"), word + " " + name) + "\n```\n\n"
    var dep = doc.str(doc.get(node, "deprecated"))
    if dep.byte_length() > 0:
        out += "**Deprecated:** " + dep + "\n\n"
    var text = both(doc.str(doc.get(node, "summary")), doc.str(doc.get(node, "description")))
    if text.byte_length() > 0:
        out += text + "\n\n"
    var params = String("")
    for p in doc.children(doc.get(node, "parameters")):
        var pd = String(doc.str(doc.get(p, "description")).strip())
        var ty = doc.str(doc.get(p, "type"))
        params += "- `" + doc.str(doc.get(p, "name")) + ((": " + ty) if ty.byte_length() > 0 else String("")) + "`" + ((" - " + pd) if pd.byte_length() > 0 else String("")) + "\n"
    if params.byte_length() > 0:
        out += "**Parameters:**\n\n" + params + "\n"
    var traits = String("")
    for t in doc.children(doc.get(node, "parentTraits")):
        traits += ("" if traits.byte_length() == 0 else ", ") + "`" + doc.str(doc.get(t, "name")) + "`"
    if traits.byte_length() > 0:
        out += "**Implemented traits:** " + traits + "\n\n"
    var fields = String("")
    for f in doc.children(doc.get(node, "fields")):
        var fty = doc.str(doc.get(f, "type"))
        var ftext = both(doc.str(doc.get(f, "summary")), doc.str(doc.get(f, "description")))
        fields += "- `" + doc.str(doc.get(f, "name")) + ((": " + fty) if fty.byte_length() > 0 else String("")) + "`" + ((" - " + ftext) if ftext.byte_length() > 0 else String("")) + "\n"
    if fields.byte_length() > 0:
        out += "### Fields\n\n" + fields + "\n"
    out += aliases_docs(doc, node, "###")
    var methods = doc.get(node, "functions")
    if methods >= 0 and doc.size(methods) > 0:
        out += "### Methods\n\n"
        for f in doc.children(methods):
            out += function_docs(doc, f, "####")
    return out


def module_markdown(doc: Json, m: Int, dotted: String) -> String:
    """The page of one module."""
    var out = "# " + dotted + "\n\n"
    var text = both(doc.str(doc.get(m, "summary")), doc.str(doc.get(m, "description")))
    if text.byte_length() > 0:
        out += text + "\n\n"
    var overview = String("")
    for s in doc.children(doc.get(m, "structs")):
        overview += "- struct `" + doc.str(doc.get(s, "name")) + "` - " + String(doc.str(doc.get(s, "summary")).strip()) + "\n"
    for t in doc.children(doc.get(m, "traits")):
        overview += "- trait `" + doc.str(doc.get(t, "name")) + "` - " + String(doc.str(doc.get(t, "summary")).strip()) + "\n"
    for f in doc.children(doc.get(m, "functions")):
        var first = doc.at(doc.get(f, "overloads"), 0)
        overview += "- `" + doc.str(doc.get(f, "name")) + "()` - " + (String(doc.str(doc.get(first, "summary")).strip()) if first >= 0 else String("")) + "\n"
    if overview.byte_length() > 0:
        out += "**In this module:**\n\n" + overview + "\n"
    var al = aliases_docs(doc, m, "###")
    if al.byte_length() > 0:
        out += "## Aliases\n\n" + al
    for s in doc.children(doc.get(m, "structs")):
        out += type_docs(doc, s, "struct")
    for t in doc.children(doc.get(m, "traits")):
        out += type_docs(doc, t, "trait")
    var fns = doc.get(m, "functions")
    if fns >= 0 and doc.size(fns) > 0:
        out += "## Functions\n\n"
        for f in doc.children(fns):
            out += function_docs(doc, f, "###")
    return out


def has_content(doc: Json, m: Int) -> Bool:
    for key in ["aliases", "structs", "traits", "functions"]:
        var n = doc.get(m, String(key))
        if n >= 0 and doc.size(n) > 0:
            return True
    return both(doc.str(doc.get(m, "summary")), doc.str(doc.get(m, "description"))).byte_length() > 0


def walk_package(doc: Json, pkg: Int, dotted: String, depth: Int, dir: String, mut index: String) -> Int:
    """Write the pages of a package and what is in it; returns how many pages."""
    var pages = 0
    index += String(depth) + "\t" + dotted + "\t\n"
    var written = String("")
    for m in doc.children(doc.get(pkg, "modules")):
        var name = doc.str(doc.get(m, "name"))
        if name.byte_length() == 0 or not has_content(doc, m):
            continue
        var full = dotted if name == "__init__" else dotted + "." + name
        var file = full + ".md"
        if write_file(dir + "/" + file, str_bytes(module_markdown(doc, m, full))):
            var title = String("(package)") if name == "__init__" else name
            written += String(depth + 1) + "\t" + title + "\t" + file + "\n"
            pages += 1
    index += written
    for p in doc.children(doc.get(pkg, "packages")):
        var name = doc.str(doc.get(p, "name"))
        if name.byte_length() > 0:
            pages += walk_package(doc, p, dotted + "." + name, depth + 1, dir, index)
    return pages


def stdref_build(home: String) -> String:
    """Make `<home>/stdref` from `<home>/std.docs.json`. Returns '' or why not."""
    var source = home + "/std.docs.json"
    if not path_exists(source):
        return "the standard library reference was not downloaded (std.docs.json is missing)"
    var dir = home + "/stdref"
    if run_system("rm -rf " + shell_quote(dir) + " && mkdir -p " + shell_quote(dir)) != 0:
        return "cannot write to " + dir
    var index = String("")
    var pages = 0
    try:
        var doc = json_parse(bytes_to_str(read_file(source)))
        var decl = doc.get(0, "decl")
        if decl < 0:
            return "std.docs.json is not what `mojo doc` writes"
        pages = walk_package(doc, decl, doc.str(doc.get(decl, "name"), "std"), 1, dir, index)
    except e:
        return "std.docs.json cannot be read: " + String(e)
    if pages == 0:
        return "std.docs.json describes no modules"
    if not write_file(dir + "/index.txt", str_bytes(index)):
        return "cannot write to " + dir
    return ""


def stdref_stale(home: String) -> Bool:
    """Is there a downloaded reference that has not been turned into pages yet (or a
    newer one than the pages were made from)?"""
    if not path_exists(home + "/std.docs.json"):
        return False
    if not path_exists(home + "/stdref/index.txt"):
        return True
    return run_system("test " + shell_quote(home + "/std.docs.json") + " -nt " + shell_quote(home + "/stdref/index.txt")) == 0
