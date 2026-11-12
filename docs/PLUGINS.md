# TurboMojo plugins

A plugin is a program of its own - in any language - that TurboMojo starts and talks to
with JSON-RPC 2.0, one message per line on its standard input and output. If it
crashes, hangs or writes nonsense it is stopped and you are told; TurboMojo goes on.

## Installing one

Plugins live in `~/.config/turbomojo/plugins/`, one folder each, never in a project
(opening a folder must not run its code). Try the example:

    cp -r examples/plugins/wordcount ~/.config/turbomojo/plugins/

and start TurboMojo again: the ≡ menu gets "Count words" (Ctrl-Alt-W) and "Insert
today's date" and "Most used words" (a table panel), and the status line shows the
words of the file in front.
`plugins = false` under `[tools]` starts none. What a plugin writes to its standard
error goes to `~/.local/state/turbomojo/plugin-<name>.log`.

## plugin.toml

    name = "wordcount"
    command = "python3 plugin.py"      # started in the plugin's folder

## The messages (API version 1)

TurboMojo to the plugin:

| Message | Kind | What |
|---|---|---|
| `initialize` {api, version, root} | request | The plugin answers `{"commands": [{"id", "title", "hint"?, "key"?}], "events": [...]}`. A `~` in a title marks its hot letter. A key is given only if no command has it. |
| `command` {id} | request | One of its commands was chosen (menu, key or palette). |
| `event` {name, path, ok} | notification | `open`, `save` or `build` (`ok`: it built), for the events it asked for. |
| `panel/select` {id, row, data} | notification | Enter on a row of its panel (row from 0). |
| `panel/closed` {id} | notification | The user closed its panel. |
| `shutdown` | notification | TurboMojo is ending. |

The plugin to TurboMojo:

| Message | Answer | What |
|---|---|---|
| `editor/get` | {path, text, line, column, selection} | The editor in front (line and column from 1). |
| `editor/insert` {text} | null | Insert at the cursor (undoable). |
| `ui/message` {text} | null | A message on the status line. |
| `ui/notify` {level, title, text} | null | A notification; level `info`, `done`, `warn` or `error`. |
| `status/set` {text} | null | The plugin's item on the status line (at most 40 characters; '' removes it). |
| `panel/open` {id, title, kind, columns?} | null | A panel at the right edge (the editors make room); `kind` `list` or `table`, a table with its column titles. Opening one that is open brings it to the front. |
| `panel/set` {id, rows} | null | Its rows: each `{"text"}` (list) or `{"cells": [...]}` (table), with `"style"` (`error`, `warn`, `ok`, `dim`) and `"data"` (any text, given back on Enter). |
| `panel/close` {id} | null | Close it. |

A plugin that has not answered `initialize` within 10 seconds is stopped. Unknown
methods get the error -32601. When a plugin stops, its panels close.

A plugin that waits for an answer to its own request must keep what else arrives
meanwhile (the example's `ask` does): TurboMojo may send a command or an event then.
