"""Documentation from `mojo doc`: reading its JSON and turning an entry into the
Markdown the documentation window shows."""
from std.collections import List
from json import Json


struct DocEntry(Copyable, Movable):
    var name: String
    var kind: String        # function, method, struct, trait, field, alias
    var owner: String       # the struct or trait it belongs to ('' at module level)
    var module: String
    var markdown: String    # what is shown

    def __init__(out self, name: String, kind: String, owner: String, module: String, markdown: String):
        self.name = name
        self.kind = kind
        self.owner = owner
        self.module = module
        self.markdown = markdown


def where_line(kind: String, owner: String, module: String) -> String:
    var s = String("*") + kind + "*"
    if owner.byte_length() > 0:
        s += " of `" + owner + "`"
    if module.byte_length() > 0:
        s += " in module `" + module + "`"
    return s


def prose(summary: String, description: String) -> String:
    var s = String(summary.strip())
    var d = String(description.strip())
    if d.byte_length() > 0:
        s += ("\n\n" if s.byte_length() > 0 else "") + d
    return s


def function_markdown(doc: Json, fn_node: Int, kind: String, owner: String, module: String) -> String:
    """One function with all its overloads."""
    var out = String("")
    var overloads = doc.get(fn_node, "overloads")
    var n = 0
    for ov in doc.children(overloads):
        if n > 0:
            out += "\n\n---\n\n"
        n += 1
        out += "```mojo\n" + doc.str(doc.get(ov, "signature")) + "\n```\n\n" + where_line(kind, owner, module)
        var dep = doc.str(doc.get(ov, "deprecated"))
        if dep.byte_length() > 0:
            out += "\n\n**Deprecated:** " + dep
        var text = prose(doc.str(doc.get(ov, "summary")), doc.str(doc.get(ov, "description")))
        if text.byte_length() > 0:
            out += "\n\n" + text
        # only the arguments that are explained
        var args = String("")
        for a in doc.children(doc.get(ov, "args")):
            var ad = String(doc.str(doc.get(a, "description")).strip())
            if ad.byte_length() == 0:
                continue
            args += "\n- `" + doc.str(doc.get(a, "name")) + "`"
            var ty = doc.str(doc.get(a, "type"))
            if ty.byte_length() > 0:
                args += " (`" + ty + "`)"
            args += ": " + ad
        if args.byte_length() > 0:
            out += "\n\n**Args:**\n" + args
        var ret = doc.get(ov, "returns")
        if ret >= 0:
            var rd = String(doc.str(doc.get(ret, "doc")).strip())
            if rd.byte_length() > 0:
                out += "\n\n**Returns:** " + rd
        var raises = String(doc.str(doc.get(ov, "raisesDoc")).strip())
        if raises.byte_length() > 0:
            out += "\n\n**Raises:** " + raises
    return out


def add_functions(doc: Json, parent: Int, kind: String, owner: String, module: String, mut out: List[DocEntry]):
    for f in doc.children(doc.get(parent, "functions")):
        var name = doc.str(doc.get(f, "name"))
        if name.byte_length() > 0:
            out.append(DocEntry(name, kind, owner, module, function_markdown(doc, f, kind, owner, module)))


def add_aliases(doc: Json, parent: Int, owner: String, module: String, mut out: List[DocEntry]):
    for a in doc.children(doc.get(parent, "aliases")):
        var name = doc.str(doc.get(a, "name"))
        if name.byte_length() == 0:
            continue
        var sig = doc.str(doc.get(a, "signature"), "comptime " + name)
        var value = doc.str(doc.get(a, "value"))
        var md = "```mojo\n" + sig + ((" = " + value) if value.byte_length() > 0 else String("")) + "\n```\n\n" + where_line("constant", owner, module)
        var text = prose(doc.str(doc.get(a, "summary")), doc.str(doc.get(a, "description")))
        if text.byte_length() > 0:
            md += "\n\n" + text
        out.append(DocEntry(name, "alias", owner, module, md))


def add_type(doc: Json, node: Int, word: String, module: String, mut out: List[DocEntry]):
    """A struct or a trait, and everything in it."""
    var name = doc.str(doc.get(node, "name"))
    if name.byte_length() == 0:
        return
    var md = "```mojo\n" + word + " " + name + "\n```\n\n" + where_line(word, "", module)
    var dep = doc.str(doc.get(node, "deprecated"))
    if dep.byte_length() > 0:
        md += "\n\n**Deprecated:** " + dep
    var text = prose(doc.str(doc.get(node, "summary")), doc.str(doc.get(node, "description")))
    if text.byte_length() > 0:
        md += "\n\n" + text
    var fields = String("")
    for f in doc.children(doc.get(node, "fields")):
        var fname = doc.str(doc.get(f, "name"))
        var fty = doc.str(doc.get(f, "type"))
        var ftext = prose(doc.str(doc.get(f, "summary")), doc.str(doc.get(f, "description")))
        fields += "\n- `" + fname + ((": " + fty) if fty.byte_length() > 0 else String("")) + "`" + ((" - " + ftext) if ftext.byte_length() > 0 else String(""))
        var fmd = "```mojo\nvar " + fname + ((": " + fty) if fty.byte_length() > 0 else String("")) + "\n```\n\n" + where_line("field", name, module)
        if ftext.byte_length() > 0:
            fmd += "\n\n" + ftext
        out.append(DocEntry(fname, "field", name, module, fmd))
    if fields.byte_length() > 0:
        md += "\n\n**Fields:**\n" + fields
    var methods = String("")
    for f in doc.children(doc.get(node, "functions")):
        methods += ("" if methods.byte_length() == 0 else ", ") + "`" + doc.str(doc.get(f, "name")) + "`"
    if methods.byte_length() > 0:
        md += "\n\n**Methods:** " + methods
    out.append(DocEntry(name, word, "", module, md))
    add_functions(doc, node, "method", name, module, out)
    add_aliases(doc, node, name, module, out)


def add_module(doc: Json, node: Int, mut out: List[DocEntry]):
    var module = doc.str(doc.get(node, "name"))
    add_aliases(doc, node, "", module, out)
    add_functions(doc, node, "function", "", module, out)
    for s in doc.children(doc.get(node, "structs")):
        add_type(doc, s, "struct", module, out)
    for t in doc.children(doc.get(node, "traits")):
        add_type(doc, t, "trait", module, out)
    # a package: its modules and sub-packages
    for m in doc.children(doc.get(node, "modules")):
        add_module(doc, m, out)
    for p in doc.children(doc.get(node, "packages")):
        add_module(doc, p, out)


def parse_mojo_doc(doc: Json) -> List[DocEntry]:
    """Every documented thing in the output of `mojo doc` for a file or a package."""
    var out = List[DocEntry]()
    var decl = doc.get(0, "decl")
    if decl >= 0:
        add_module(doc, decl, out)
    return out^


def docs_for(entries: List[DocEntry], name: String) -> String:
    """The Markdown for every entry called `name`, separated by rules ('' if none)."""
    var out = String("")
    for e in entries:
        if e.name == name:
            if out.byte_length() > 0:
                out += "\n\n---\n\n"
            out += e.markdown
    return out
