# TurboMojo plugin API

A plugin is a program of its own, in any language, that TurboMojo starts and talks to
with [JSON-RPC 2.0](https://www.jsonrpc.org/specification): one message per line on
the plugin's standard input (from TurboMojo) and standard output (to TurboMojo). A
plugin can add commands with keys, an item on the status line and panels, listen to
what happens in the editor, read the file in front and insert text into it.

A plugin cannot take TurboMojo down: one that crashes, ends, or does not answer at
start-up is stopped, you are told, and its commands and panels go away; lines it
writes that are not JSON-RPC are ignored. Everything else goes on.

This is version 1 of the API (`"api": 1` in `initialize`).

## Contents

- [Installing a plugin](#installing-a-plugin)
- [plugin.toml](#plugintoml)
- [The life of a plugin](#the-life-of-a-plugin)
- [Messages from TurboMojo](#messages-from-turbomojo)
- [Messages to TurboMojo](#messages-to-turbomojo)
- [Errors](#errors)
- [Writing a plugin: a minimal one](#writing-a-plugin-a-minimal-one)
- [Advice](#advice)

## Installing a plugin

Plugins live in `~/.config/turbomojo/plugins/` (or `$XDG_CONFIG_HOME/turbomojo/plugins/`),
one folder each. They are never taken from a project: opening someone else's folder
must not run their code. TurboMojo starts the plugins it finds when it starts.

To try the example that comes with TurboMojo:

    mkdir -p ~/.config/turbomojo/plugins
    cp -r examples/plugins/wordcount ~/.config/turbomojo/plugins/

Start TurboMojo again: the ≡ menu gets Count words (Ctrl-Alt-W), Insert today's date
and Most used words, and the status line shows the words of the file in front.

`plugins = false` under `[tools]` in the config file starts none. What a plugin writes
to its standard error goes to `~/.local/state/turbomojo/plugin-<name>.log`: print your
debugging there, never to standard output.

## plugin.toml

```toml
name = "wordcount"              # how TurboMojo calls it (default: the folder's name)
command = "python3 plugin.py"   # started in the plugin's folder, through sh
```

A folder without a `command` is reported (in the configuration warnings) and skipped.

## The life of a plugin

1. TurboMojo starts `command` in the plugin's folder.
2. It sends the request `initialize`. The plugin answers within **10 seconds** with
   what it adds - its commands and the events it wants. A plugin that does not answer
   in time is stopped.
3. From then on either side may send messages at any time: TurboMojo sends commands
   chosen by the user, events and panel choices; the plugin asks for the editor's text,
   inserts, shows messages, sets its status item and fills its panels.
4. When TurboMojo ends it sends `shutdown` and then ends the plugin's process. A
   plugin should also end by itself when it reads the end of its input.

If the plugin's output ends, or the process ends, the plugin is stopped: its commands
leave the menus, the palette and their keys, and its status item and panels go. (A
command run by other means while it is stopped says "The plugin ... is not running"
and why.)

## Messages from TurboMojo

### initialize (request)

```json
{"jsonrpc": "2.0", "id": 1, "method": "initialize",
 "params": {"api": 1, "version": "1.8", "root": "/home/me/project"}}
```

`api` is this document's version, `version` TurboMojo's, `root` the project folder.
The answer says what the plugin adds:

```json
{"jsonrpc": "2.0", "id": 1, "result": {
  "commands": [
    {"id": "count", "title": "Count ~w~ords", "hint": "Count the words of the file", "key": "Ctrl-Alt-W"},
    {"id": "date", "title": "Insert today's date"}
  ],
  "events": ["open", "save", "build"]}}
```

- `commands`: each has an `id` (the plugin's own name for it) and a `title` (`~` marks
  the hot letter in the menu); `hint` is shown on the status line while the item is
  chosen in a menu. Commands are put in the ≡ menu, below a line, and the command
  palette (Ctrl-P, then `>`) finds them.
- `key` (optional) is written as in the keyboard reference: `Ctrl-Alt-W`, `F11`,
  `Shift-F4`, `Alt-X`. A key that another command already has is **not** taken away
  from it: the command then has no key, and the user is told.
- `events`: which of `open`, `save` and `build` it wants to hear about.

### command (request)

The user chose one of the plugin's commands (from the menu, its key or the palette).

```json
{"jsonrpc": "2.0", "id": 7, "method": "command", "params": {"id": "count"}}
```

Answer it (with `null`) when you have done what it does.

### event (notification)

```json
{"jsonrpc": "2.0", "method": "event", "params": {"name": "save", "path": "/home/me/project/main.mojo", "ok": true}}
```

| `name` | When | `ok` |
|---|---|---|
| `open` | a file was opened in an editor | true |
| `save` | a file was saved | true |
| `build` | a build ended | whether it built |

### panel/select (notification)

Enter on a row of one of the plugin's panels. `row` counts the rows given to
`panel/set` from 0; `data` is that row's `data`.

```json
{"jsonrpc": "2.0", "method": "panel/select", "params": {"id": "words", "row": 1, "data": "banana"}}
```

### panel/closed (notification)

The user closed one of the plugin's panels (Alt-F3).

```json
{"jsonrpc": "2.0", "method": "panel/closed", "params": {"id": "words"}}
```

### shutdown (notification)

TurboMojo is ending; the plugin should end too.

```json
{"jsonrpc": "2.0", "method": "shutdown"}
```

## Messages to TurboMojo

Each of these may be sent as a request (with an `id`: TurboMojo answers) or as a
notification (without one: no answer). Ask with a request when you need the answer or
want to know it was done.

### editor/get

The editor in front (none: an empty object).

```json
{"jsonrpc": "2.0", "id": 101, "method": "editor/get", "params": {}}
```

```json
{"jsonrpc": "2.0", "id": 101, "result": {"path": "/home/me/project/main.mojo", "text": "def main():\n    pass\n",
 "line": 2, "column": 5, "selection": ""}}
```

`line` and `column` count from 1; `selection` is the selected text ('' when there is
none); `path` is '' for a window that was never saved.

### editor/insert

Insert text at the cursor of the editor in front, as if typed (Undo takes it back).
No editor: the error -32000.

```json
{"jsonrpc": "2.0", "id": 102, "method": "editor/insert", "params": {"text": "2026-11-12"}}
```

### editor/edit

Apply one or more 1-based range edits to an open editor (`path` optional; defaults to the
editor in front) as a single Undo step. No editor: the error -32000.

```json
{"jsonrpc": "2.0", "id": 104, "method": "editor/edit", "params": {"path": "/home/me/project/main.mojo", "edits": [
  {"start_line": 2, "start_col": 5, "end_line": 2, "end_col": 9, "text": "return"}]}}
```

### diagnostics/set

Replace the plugin's diagnostic marks on an open editor (`path` optional; defaults to the
editor in front). `severity` is `error`, `warning`, `info` or `hint` (or `1`..`4`).

```json
{"jsonrpc": "2.0", "id": 105, "method": "diagnostics/set", "params": {"path": "/home/me/project/main.mojo", "diagnostics": [
  {"line": 2, "col": 5, "end_line": 2, "end_col": 9, "severity": "warning", "message": "empty body"}]}}
```

### ui/message

A message on the status line, for a few seconds.

```json
{"jsonrpc": "2.0", "method": "ui/message", "params": {"text": "Done: 12 files"}}
```

### ui/notify

A notification: a toast at the top right, and in Help > Notifications. While the user
is typing it waits for a pause.

```json
{"jsonrpc": "2.0", "method": "ui/notify", "params": {"level": "done", "title": "Word count", "text": "120 words"}}
```

`level` is `info`, `done`, `warn` or `error` (default `info`); `title` defaults to the
plugin's name.

### status/set

The plugin's item on the status line, at most 40 characters ('' removes it). Items
are shown left of the insert / overwrite mark, when no message is on the line.

```json
{"jsonrpc": "2.0", "method": "status/set", "params": {"text": "120 words"}}
```

### panel/open

A panel at the right edge of the desktop; the editors next to it make room. `kind` is
`list` (default) or `table`; a table has `columns`, its column titles. Opening one
that is open already changes its title and columns. A panel comes to the front only as
the answer to one of the plugin's commands the user ran in the last 3 seconds (and
not while they type); one a plugin opens on its own, after a save say, stays beside
the window the user works in.

```json
{"jsonrpc": "2.0", "method": "panel/open", "params": {"id": "words", "title": "Most used words", "kind": "table", "columns": ["Word", "Times"]}}
```

### panel/set

The rows of a panel, all of them, replacing what it showed. A row is `{"text"}` in a
list or `{"cells": [...]}` in a table, with optionally `"style"` (`error`, `warn`, `ok`
or `dim`: the row's colour) and `"data"` (any text, given back by `panel/select`).
A panel that is not open: the error -32000.

```json
{"jsonrpc": "2.0", "id": 103, "method": "panel/set", "params": {"id": "words", "rows": [
  {"cells": ["apple", "3"], "style": "ok", "data": "apple"},
  {"cells": ["banana", "2"], "data": "banana"}]}}
```

Table columns are as wide as their widest cell (at most 40 characters; longer cells are
cut with "…").

### panel/close

```json
{"jsonrpc": "2.0", "method": "panel/close", "params": {"id": "words"}}
```

## Errors

TurboMojo answers a request it cannot do with a JSON-RPC error:

| Code | When |
|---|---|
| -32601 | there is no such method |
| -32000 | it cannot be done now (no editor for `editor/insert`, no such panel for `panel/set`) |

An error answer to `initialize` stops the plugin. An error answer to `command` is shown
on the status line.

## Writing a plugin: a minimal one

The whole of a plugin that adds one command, which says how many lines the file in
front has (save it as `plugin.py`, with a `plugin.toml` whose command is
`python3 plugin.py`):

```python
import json, sys

waiting = []                    # what came while we waited for an answer


def send(msg):
    sys.stdout.write(json.dumps(msg) + "\n")
    sys.stdout.flush()


def read_line():
    line = sys.stdin.readline()
    if not line:
        sys.exit(0)             # TurboMojo has gone
    return json.loads(line)


def ask(method, params, ids=[1000]):
    ids[0] += 1
    send({"jsonrpc": "2.0", "id": ids[0], "method": method, "params": params})
    while True:
        m = read_line()
        if m.get("id") == ids[0] and "method" not in m:
            return m.get("result")
        waiting.append(m)       # keep it for the loop below


while True:
    m = waiting.pop(0) if waiting else read_line()
    if m.get("method") == "initialize":
        send({"jsonrpc": "2.0", "id": m["id"], "result": {
            "commands": [{"id": "lines", "title": "Count lines"}]}})
    elif m.get("method") == "command":
        text = (ask("editor/get", {}) or {}).get("text", "")
        send({"jsonrpc": "2.0", "method": "ui/message",
              "params": {"text": "%d lines" % len(text.splitlines())}})
        send({"jsonrpc": "2.0", "id": m["id"], "result": None})
    elif m.get("method") == "shutdown":
        break
```

`examples/plugins/wordcount/plugin.py` is a longer one: a status item, events, a key,
inserting text and a table panel.

## Advice

- **Keep what arrives while you wait.** TurboMojo may send a command or an event while
  your plugin waits for an answer to its own request; a plugin that reads only for
  its answer and drops the rest loses them. Keep them and handle them afterwards (the
  `waiting` list above), or use a thread.
- **Flush** after every line you write; one message per line, no line feeds inside it
  (JSON escapes them).
- **Debug on standard error** - it goes to the plugin's log. Anything on standard
  output that is not a JSON-RPC message is ignored.
- **Be quick to answer `initialize`**: do slow set-up afterwards.
- **Do not take keys** the user relies on: choose combinations with Ctrl-Alt or let the
  user run the command from the menu or the palette.
