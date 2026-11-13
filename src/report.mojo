"""Help > Report a problem (P11-08): a ready-to-file issue text - what to describe, the
versions, what the terminal can do (as `tmide --caps` shows), the last crash-log entry
and the configuration with anything secret-looking removed. It is written to a file,
copied to the clipboard and opened; nothing is sent anywhere.

Privacy: the home folder is written as ~, values whose names or looks say "secret"
(tokens, keys, passwords, long random strings) are replaced, and the [env] tables of
agents and plugins lose their values."""
from std.collections import List

comptime REPORT_ISSUES_URL = "https://github.com/sabelg/turbomojo/issues/new"
comptime REMOVED = "\"(removed)\""


def lower_ascii(s: String) -> String:
    return s.lower()


def secret_name(key: String) -> Bool:
    """A setting's name that says its value is a secret (keymap, key_hints are not)."""
    var k = lower_ascii(String(key.strip()))
    for w in ["token", "secret", "password", "passwd", "credential", "auth", "cookie", "private"]:
        if k.find(String(w)) >= 0:
            return True
    return k == "key" or k.endswith("_key") or k.endswith("-key") or k.endswith("apikey")


def secret_value(v: String) -> Bool:
    """A value that looks like a secret whatever its name: known token prefixes, or a
    long run of letters and digits without spaces or slashes (not a path, a word or a
    command)."""
    var s = String(v.strip())
    if s.startswith("\"") or s.startswith("'"):
        var t1 = String(s[byte=1:])
        s = t1
    if s.endswith("\"") or s.endswith("'"):
        var t2 = String(s[byte=0 : s.byte_length() - 1])
        s = t2
    for p in ["sk-", "ghp_", "gho_", "github_pat_", "xoxb-", "xoxp-", "AKIA", "glpat-", "hf_"]:
        if s.startswith(String(p)) and s.byte_length() >= 12:
            return True
    if s.byte_length() < 24:
        return False
    var digits = 0
    var letters = 0
    for b in s.as_bytes():
        var c = Int(b)
        if c == 32 or c == 47 or c == 46:       # a space, a slash, a dot: a phrase, a path
            return False
        if c >= 48 and c <= 57:
            digits += 1
        elif (c >= 65 and c <= 90) or (c >= 97 and c <= 122):
            letters += 1
    return digits >= 4 and letters >= 4


def redact_config(text: String) -> String:
    """The config file with secret-looking values replaced; comments and the rest kept."""
    var out = String("")
    var in_env = False
    for raw in text.split("\n"):
        var line = String(raw)
        var t = String(line.strip())
        if t.startswith("["):
            var name = lower_ascii(t)
            in_env = name.endswith(".env]") or name == "[env]" or name.find(".env.") >= 0
            out += line + "\n"
            continue
        var eq = line.find("=")
        if eq > 0 and not t.startswith("#"):
            var key = String(line[byte=0:eq])
            var value = String(line[byte=eq + 1 :])
            if String(key.strip()).lower() == "env":
                out += key + "= { (values removed) }\n"     # an inline table of a program's environment
                continue
            if in_env or secret_name(key) or secret_value(value):
                out += key + "= " + REMOVED + "\n"
                continue
        out += line + "\n"
    # (no extra final newline)
    if out.endswith("\n") and not text.endswith("\n"):
        var t3 = String(out[byte=0 : out.byte_length() - 1])
        out = t3
    return out


def home_as_tilde(text: String, home: String) -> String:
    """The home folder written as ~ (the report names no user)."""
    if home.byte_length() < 2:
        return text
    return text.replace(home, "~")


def last_crash_entry(log: String, max_lines: Int = 60) -> String:
    """The last crash in the crash log - from its "TurboMojo <version>  pid" header on (a
    crash writes one) - or, without one, the log's last lines; "" for an empty log."""
    var lines = log.split("\n")
    var start = -1
    for k in range(len(lines)):
        var l = String(lines[k])
        if l.startswith("TurboMojo ") and l.find("  pid ") > 0:
            start = k
    var first = start if start >= 0 else max(0, len(lines) - 15)
    var out = String("")
    var n = 0
    for k in range(first, len(lines)):
        if n >= max_lines:
            out += "(... " + String(len(lines) - k) + " more lines)\n"
            break
        out += String(lines[k]) + "\n"
        n += 1
    return String(out.strip())


def fenced(text: String) -> String:
    return "```\n" + (text if text.byte_length() > 0 else String("(none)")) + "\n```\n"


def report_text(version: String, built_with: String, mojo_found: String, system: String, terminal: String, caps_lines: List[String], crash: String, config: String) -> String:
    var s = String("<!-- Written by TurboMojo (Help > Report a problem). Nothing has been sent.\n")
    s += "     Read it through, change what you like, then paste it at\n"
    s += "     " + String(REPORT_ISSUES_URL) + " -->\n\n"
    s += "## What happened\n\n(what you did, and what TurboMojo did)\n\n"
    s += "## What you expected\n\n\n"
    s += "## Versions\n\n"
    s += "- TurboMojo " + version + ", built with " + (built_with if built_with.byte_length() > 0 else String("an unknown Mojo")) + "\n"
    s += "- Mojo found: " + (mojo_found if mojo_found.byte_length() > 0 else String("none")) + "\n"
    s += "- System: " + system + "\n"
    s += "- Terminal: " + terminal + "\n\n"
    s += "## What the terminal can do (tmide --caps)\n\n"
    var caps = String("")
    for l in caps_lines:
        caps += l + "\n"
    s += fenced(String(caps.strip()))
    s += "\n## Last crash-log entry\n\n" + fenced(crash)
    s += "\n## Configuration (anything secret-looking removed)\n\n" + fenced(String(config.strip()))
    return s
