"""A plugin that registers a command and dies when it is run (tests/test_plugins.mojo);
its key is one TurboMojo already has, so it must not get it."""
import json, sys
for line in sys.stdin:
    m = json.loads(line)
    if m.get("method") == "initialize":
        print(json.dumps({"jsonrpc": "2.0", "id": m["id"], "result": {"commands": [{"id": "boom", "title": "Crash now", "key": "F2"}]}}), flush=True)
    elif m.get("method") == "command":
        sys.exit(3)
