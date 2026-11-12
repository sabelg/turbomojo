#!/usr/bin/env python3
"""Make src/errhelp_pages.mojo from the explanations in help/errors/ (in the order of
help/errors/ORDER). Run it after changing a page; tests/test_errhelp.mojo checks that
the built-in pages are the same as the files."""
import json
import os
import re
import sys

root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
src = os.path.join(root, "help", "errors")
keys = open(os.path.join(src, "ORDER")).read().split()
out = ['"""The explanations of Mojo error messages, made from help/errors/ by',
       'scripts/gen_errhelp.py - do not edit here."""', "",
       "comptime ERR_PAGE_COUNT = %d" % len(keys), ""]
for k in keys:
    text = open(os.path.join(src, k + ".md")).read()
    if not re.match(r"<!-- match: .+? -->\n", text):
        sys.exit(k + ".md does not start with <!-- match: ... -->")
    out.append("comptime ERR_%s = %s" % (k.upper().replace("-", "_"), json.dumps(text, ensure_ascii=False)))
out += ["", "", "def err_page_key(i: Int) -> String:", '    """The file name (without .md) of explanation i."""']
for i, k in enumerate(keys):
    out.append('    %s i == %d:\n        return "%s"' % ("if" if i == 0 else "elif", i, k))
out += ['    return ""', "", "", "def err_page_text(i: Int) -> String:", '    """The text of explanation i."""']
for i, k in enumerate(keys):
    out.append("    %s i == %d:\n        return ERR_%s" % ("if" if i == 0 else "elif", i, k.upper().replace("-", "_")))
out += ['    return ""', ""]
open(os.path.join(root, "src", "errhelp_pages.mojo"), "w").write("\n".join(out))
print("src/errhelp_pages.mojo:", len(keys), "pages")
