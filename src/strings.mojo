"""The UI's words outside the code: the menu titles and every command's title and hint
(what the menus, the command palette, the status line and the keyboard reference
show) can come from a strings file, so the IDE can be translated.

A strings file is TOML, keyed by the commands' stable names:

    [menus]
    file = "~D~atei"                  # the menu bar (system, file, edit, ...)
    [titles]
    "file.new" = "~N~eu"              # a '~' marks the hot letter
    [hints]
    "file.new" = "Ein neues Fenster"  # the line in the status bar

It is $XDG_CONFIG_HOME/turbomojo/strings/<language>.toml, the language being
ui.language or the start of LANG ("de_DE.UTF-8": de). English is built in; `tmide
--strings` prints it as a file to start from. Anything a file leaves out stays
English. A file that gives two items of one menu (or two menus) the same hot letter,
names an unknown command, or has a title without a hot letter is reported.
"""
from std.collections import List
from commands import Registry, plain, hot_char, hot_letter_problem, CM_NONE
from toml import TomlDoc, toml_parse, toml_quote, T_STR
from util import lower_str


def menu_key(title: String) -> String:
    """The strings key of a menu: its English name in lower case ("≡" is "system")."""
    var p = lower_str(plain(title))
    if p == "≡":
        return "system"
    return p


def strings_template(reg: Registry) -> String:
    """Every string, in English, as a strings file."""
    var out = String("# TurboMojo UI strings (English). Copy to ~/.config/turbomojo/strings/<language>.toml\n# and translate the values; '~' marks a hot letter. Leave out what you do not translate.\n\n[menus]\n")
    for t in reg.menu_titles:
        out += menu_key(t) + " = " + toml_quote(t) + "\n"
    out += "\n[titles]\n"
    for c in reg.cmds:
        out += toml_quote(c.name) + " = " + toml_quote(c.title) + "\n"
    out += "\n[hints]\n"
    for c in reg.cmds:
        out += toml_quote(c.name) + " = " + toml_quote(c.hint) + "\n"
    return out^


def language_from(setting: String, lang_env: String) -> String:
    """ui.language if set, else the language of LANG ("de_DE.UTF-8" -> "de"; "C",
    "POSIX" or nothing -> "en")."""
    var s = String(setting.strip())
    if s.byte_length() > 0:
        return lower_str(s)
    var l = String(lang_env.strip())
    if l.byte_length() < 2 or l == "C" or l.startswith("C.") or l == "POSIX":
        return "en"
    var cut = l.byte_length()
    for sep in ["_", ".", "@"]:
        var k = l.find(sep)
        if k > 0 and k < cut:
            cut = k
    return lower_str(String(l[byte=0:cut]))


def apply_strings(mut reg: Registry, doc: TomlDoc, where: String) -> List[String]:
    """Put a strings file's words into the registry; what is wrong in it, as warnings."""
    var warn = List[String]()
    for pr in doc.problems:
        warn.append(where + ": " + pr)
    var known = List[String]()
    for i in range(len(reg.menu_titles)):
        var k = menu_key(reg.menu_titles[i])
        known.append(k)
        var v = doc.get_str("menus." + k, "")
        if v.byte_length() > 0:
            var hp = hot_letter_problem(v)
            if hp.byte_length() > 0:
                warn.append(where + ": menus." + k + " " + hp)
            reg.menu_titles[i] = v
    for k in doc.keys_in("menus"):
        if k not in known:
            warn.append(where + ": there is no menu \"" + k + "\"")
    for table in ["titles", "hints"]:
        for name in doc.keys_in(String(table)):
            var ci = -1
            for j in range(len(reg.cmds)):
                if reg.cmds[j].name == name:
                    ci = j
                    break
            if ci < 0:
                warn.append(where + ": " + String(table) + ": there is no command \"" + name + "\"")
                continue
            var v = doc.get_str(String(table) + "." + name, "")
            if v.byte_length() == 0:
                continue
            if String(table) == "titles":
                var hp = hot_letter_problem(v)
                if hp.byte_length() > 0 and not reg.is_hidden(reg.cmds[ci].id):
                    warn.append(where + ": titles." + name + " " + hp)
                reg.cmds[ci].title = v
            else:
                reg.cmds[ci].hint = v
    # hot letters must stay unique: across the menu bar, and within each menu
    var bar = List[Int]()
    for t in reg.menu_titles:
        var h = hot_char(t)
        if h >= 0 and h in bar:
            warn.append(where + ": two menus have the hot letter " + chr(h) + " (" + plain(t) + ")")
        bar.append(h)
    for mi in range(len(reg.menu_titles)):
        var letters = List[Int]()
        for p in reg.layout:
            if p.menu != mi or p.cmd == CM_NONE:
                continue
            var ci = reg.index_of(p.cmd)
            if ci < 0:
                continue
            var h = hot_char(reg.cmds[ci].title)
            if h >= 0 and h in letters:
                warn.append(where + ": in the " + plain(reg.menu_titles[mi]) + " menu two items have the hot letter " + chr(h) + " (" + plain(reg.cmds[ci].title) + ")")
            letters.append(h)
    return warn^
