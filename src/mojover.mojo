"""Is the Mojo found the one TurboMojo was built with? (P11-03)

Mojo still changes between releases: a TurboMojo built with one version and used with
another can see its language server, builds or the runtime libraries fail in ways that
do not say why. The build records `mojo --version` (version.MOJO_BUILT_WITH); after the
first frame the IDE asks the configured compiler once and, if the release differs, says
so in plain words; `tmide --caps` shows both."""


def mojo_version_of(text: String) -> String:
    """The version in what `mojo --version` prints ("Mojo 1.2.0 (2016d0cd)" -> "1.2.0",
    "Mojo 1.3.0.dev2026111305 (ab12)" -> "1.3.0.dev2026111305"); "" if there is none."""
    for line in text.split("\n"):
        var words = String(line).strip().split(" ")
        for k in range(len(words) - 1):
            var w = String(words[k]).lower()
            if w == "mojo" or w == "mojo:":
                var v = String(String(words[k + 1]).strip())
                if v.byte_length() > 0 and Int(v.as_bytes()[0]) >= 48 and Int(v.as_bytes()[0]) <= 57:
                    return v
    return ""


def mojo_mismatch(built_with: String, found: String) -> String:
    """A message when the Mojo found (`found`: what its --version printed) is not the
    release TurboMojo was built with; "" when they agree, or when either is not known
    (a missing Mojo is told elsewhere)."""
    var b = mojo_version_of(built_with)
    var f = mojo_version_of(found)
    if b.byte_length() == 0 or f.byte_length() == 0 or b == f:
        return ""
    return "TurboMojo was built with Mojo " + b + ", but the mojo found is " + f + ": the language server, builds and running may fail. Rebuild TurboMojo with this Mojo, or use Mojo " + b + "."


def mojo_summary(built_with: String, found: String) -> String:
    """The line `tmide --caps` shows."""
    var b = mojo_version_of(built_with)
    var f = mojo_version_of(found)
    var s = (f if f.byte_length() > 0 else String("not found")) + " (TurboMojo was built with " + (b if b.byte_length() > 0 else String("an unknown version")) + ")"
    if b.byte_length() > 0 and f.byte_length() > 0 and b != f:
        s += " - DIFFERENT"
    return s
