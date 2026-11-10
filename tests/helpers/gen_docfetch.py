"""Write src/docfetch.mojo from scripts/fetch-docs.sh (run from the project folder)."""
src = open("scripts/fetch-docs.sh").read()
assert '"""' not in src
body = src.replace("\\", "\\\\")
head = '"""The documentation download script, carried inside the program so that an installed\nTurboMojo can run it without its source tree. It is the text of scripts/fetch-docs.sh\n(a test keeps the two equal); regenerate with tests/helpers/gen_docfetch.py."""\n\ncomptime FETCH_SCRIPT = """'
open("src/docfetch.mojo", "w").write(head + body + '"""\n')
