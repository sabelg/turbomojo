# TurboMojo keymap reference

The keys of every command in the three keymaps (Options > Keys: Modern, the default;
Turbo, WordStar's as in Turbo C++; Emacs). Two keys with a space between are pressed one
after the other (Ctrl-K B). A dash: no key in that keymap - the menus and the command
palette (Ctrl-P, then >) have every command. Your own keys (`[keys]` in the config file)
come on top; Help > Keyboard reference (F1) shows the keys as you have them.

This file is made by `tmide --keys` (TurboMojo 2.0.0).

## System (≡)

| Command | Modern | Turbo | Emacs |
|---|---|---|---|
| Command palette | Ctrl-P | Ctrl-P | Alt-X |

## File

| Command | Modern | Turbo | Emacs |
|---|---|---|---|
| New | Ctrl-N | Ctrl-N | - |
| Open | F3, Ctrl-O | F3, Ctrl-O, Ctrl-K R | F3, Ctrl-O, Ctrl-X Ctrl-F |
| Save | F2, Ctrl-S | F2, Ctrl-K S, Ctrl-K D | F2, Ctrl-X Ctrl-S |
| Save as | - | Ctrl-K W | Ctrl-X Ctrl-W |
| Save all | - | - | Ctrl-X S |
| Go to file | Alt-G | Alt-G | Alt-G |
| Close | Alt-F3, Ctrl-W | Alt-F3, Ctrl-K Q | Alt-F3, Ctrl-X K |
| Terminal | Alt-F11 | Alt-F11 | Alt-F11 |
| Next change | Alt-N | Alt-N | Alt-N |
| Previous change | Alt-B | Alt-B | Alt-B |
| Agent panel | Ctrl-F11 | Ctrl-F11 | Ctrl-F11 |
| Quit | Alt-X, Ctrl-Q | Alt-X, Ctrl-K X | Ctrl-Q, Ctrl-X Ctrl-C |

## Edit

| Command | Modern | Turbo | Emacs |
|---|---|---|---|
| Undo | Ctrl-Z, Alt-Bksp | Alt-Bksp | Ctrl-Z, Alt-Bksp, Ctrl-/, Ctrl-X U |
| Redo | Ctrl-Y | Alt-Shift-Bksp | - |
| Cut | Ctrl-X, Shift-Del | Shift-Del | Shift-Del, Ctrl-W |
| Copy | Ctrl-C, Ctrl-Ins | Ctrl-Ins, Ctrl-K C | Ctrl-C, Ctrl-Ins |
| Paste | Ctrl-V, Shift-Ins | Shift-Ins, Ctrl-K V | Shift-Ins, Ctrl-Y |
| Clear | Ctrl-Del | Ctrl-Del, Ctrl-K Y | Ctrl-Del |
| Select all | Ctrl-A | Ctrl-Q B | Ctrl-X H |
| Toggle comment | Ctrl-/ | Ctrl-/ | - |
| Duplicate line | Ctrl-D | - | - |
| Delete line | Ctrl-K | Ctrl-Y | - |
| Complete word | Ctrl-Space | Ctrl-Space | Ctrl-Space |
| Add next occurrence | Alt-D | Alt-D, Ctrl-K T | - |
| Add cursor above | Ctrl-Alt-Up, Alt-Shift-Up | Ctrl-Alt-Up, Alt-Shift-Up | Ctrl-Alt-Up, Alt-Shift-Up |
| Add cursor below | Ctrl-Alt-Down, Alt-Shift-Down | Ctrl-Alt-Down, Alt-Shift-Down | Ctrl-Alt-Down, Alt-Shift-Down |
| Fold or unfold | Alt-- | Alt-- | Alt-- |
| Expand all | Alt-= | Alt-= | Alt-= |

## Text

| Command | Modern | Turbo | Emacs |
|---|---|---|---|
| Move line up | Alt-Up | Alt-Up | Alt-Up |
| Move line down | Alt-Down | Alt-Down | Alt-Down |
| Join lines | Alt-J | Alt-J | Alt-J |
| Indent lines | - | Ctrl-K I | - |
| Unindent lines | - | Ctrl-K U | - |
| Upper case | Alt-U | Alt-U | Alt-U |
| Lower case | Alt-L | Alt-L | Alt-L |
| Record macro / stop | Ctrl-F5 | Ctrl-F5 | Ctrl-F5 |
| Play macro | Ctrl-F6 | Ctrl-F6 | Ctrl-F6 |

## Search

| Command | Modern | Turbo | Emacs |
|---|---|---|---|
| Find | Ctrl-F | Ctrl-Q F | Ctrl-S |
| Replace | Ctrl-R | Ctrl-Q A | Ctrl-R |
| Search again | Ctrl-L | Ctrl-L | Ctrl-L |
| Find in files | Shift-F3 | Shift-F3 | Shift-F3 |
| Go to line number | Ctrl-G | Ctrl-Q G | Ctrl-G |
| Go to symbol | Ctrl-T | - | Ctrl-T |
| Go to symbol in project | Alt-F12 | Alt-F12 | Alt-F12 |
| Match bracket | Ctrl-] | Ctrl-], Ctrl-Q [, Ctrl-Q ] | Ctrl-] |
| Describe symbol | Alt-I | Alt-I | Alt-I |
| Parameter info | Alt-P | Alt-P | Alt-P |
| Go to definition | F12 | F12 | F12 |
| Find references | Shift-F12 | Shift-F12 | Shift-F12 |
| Rename symbol | Shift-F2 | Shift-F2 | Shift-F2 |
| Quick fix | Alt-Enter | Alt-Enter | Alt-Enter |
| Back | Alt-, | Alt-, | Alt-, |
| Forward | Alt-. | Alt-. | Alt-. |
| Previous message | Alt-F7 | Alt-F7 | Alt-F7 |
| Next message | Alt-F8 | Alt-F8 | Alt-F8 |

## Run

| Command | Modern | Turbo | Emacs |
|---|---|---|---|
| Run | Ctrl-F9, F8 | Ctrl-F9, F8 | Ctrl-F9, F8 |
| Debug | Shift-F5 | Shift-F5 | Shift-F5 |
| Step out | Shift-F8 | Shift-F8 | Shift-F8 |
| Go to cursor | F4 | F4 | F4 |
| Add watch | Ctrl-F7 | Ctrl-F7 | Ctrl-F7 |
| Evaluate | Ctrl-F4 | Ctrl-F4 | Ctrl-F4 |
| User screen | Alt-F5 | Alt-F5 | Alt-F5 |
| Toggle breakpoint | Ctrl-F8 | Ctrl-F8 | Ctrl-F8 |
| Pixi tasks | Shift-F9 | Shift-F9 | Shift-F9 |

## Compile

| Command | Modern | Turbo | Emacs |
|---|---|---|---|
| Build | F9, Ctrl-B | F9, Ctrl-B | F9 |
| Format source | Alt-F9 | Alt-F9 | Alt-F9 |
| Cancel build | Ctrl-F2 | Ctrl-F2 | Ctrl-F2 |
| Check with language server | F7 | F7 | F7 |

## Options

| Command | Modern | Turbo | Emacs |
|---|---|---|---|
| Soft wrap | Alt-Z | Alt-Z | Alt-Z |

## Window

| Command | Modern | Turbo | Emacs |
|---|---|---|---|
| Zoom | F5 | F5 | F5 |
| Next | F6 | F6 | F6, Ctrl-X O |
| Previous | Shift-F6 | Shift-F6 | Shift-F6 |
| Split right | Alt-\ | Alt-\ | Alt-\ |
| Split down | Alt-\| | Alt-\| | Alt-\| |
| Next pane | Alt-F6 | Alt-F6 | Alt-F6 |
| Next tab | Alt-PgDn | Alt-PgDn | Alt-PgDn |
| Previous tab | Alt-PgUp | Alt-PgUp | Alt-PgUp |
| Grow pane | Alt-} | Alt-} | Alt-} |
| Shrink pane | Alt-{ | Alt-{ | Alt-{ |
| File explorer | Ctrl-E | - | - |
| Outline | Ctrl-F12 | Ctrl-F12 | Ctrl-F12 |
| Call stack and variables | Ctrl-F3 | Ctrl-F3 | Ctrl-F3 |
| CPU - machine code, registers, memory | Alt-F2 | Alt-F2 | Alt-F2 |
| List | Alt-0 | Alt-0 | Alt-0, Ctrl-X B |

## Help

| Command | Modern | Turbo | Emacs |
|---|---|---|---|
| Keyboard reference | F1 | F1 | F1 |
| Notifications | Shift-F10 | Shift-F10 | Shift-F10 |
| Topic search | Ctrl-F1 | Ctrl-F1 | Ctrl-F1 |
| Mojo documentation | Shift-F1 | Shift-F1 | Shift-F1 |
| Find in documentation | Alt-F1 | Alt-F1 | Alt-F1 |

## Not in a menu

| Command | Modern | Turbo | Emacs |
|---|---|---|---|
| Cursor left | - | Ctrl-S | Ctrl-B |
| Cursor right | - | Ctrl-D | Ctrl-F |
| Cursor up | - | Ctrl-E | Ctrl-P |
| Cursor down | - | Ctrl-X | Ctrl-N |
| Cursor word left | - | Ctrl-A | - |
| Cursor word right | - | Ctrl-F | - |
| Cursor to line start | - | Ctrl-Q S | Ctrl-A |
| Cursor to line end | - | Ctrl-Q D | Ctrl-E |
| Cursor page up | - | Ctrl-R | Alt-V |
| Cursor page down | - | Ctrl-C | Ctrl-V |
| Cursor to top | - | Ctrl-Q R | Alt-< |
| Cursor to bottom | - | Ctrl-Q C | Alt-> |
| Delete character | - | Ctrl-G | Ctrl-D |
| Delete word right | - | Ctrl-T | Alt-D |
| Cut to end of line | - | Ctrl-Q Y | Ctrl-K |
| Scroll up | - | Ctrl-W | - |
| Scroll down | - | Ctrl-Z | - |
| Insert / overwrite | - | Ctrl-V | - |
| Send to REPL | Ctrl-F10 | Ctrl-F10 | Ctrl-F10 |
| Mention in agent prompt | Shift-F11 | Shift-F11 | Shift-F11 |

## Always

| Key | What it does |
|---|---|
| F10 | The menu bar |
| Alt and a menu's letter | That menu |
| Alt-1 to Alt-9 | The window with that number |
| Esc | Close a menu, a dialog or a box; cancel a key sequence |
| F1 on a problem | Its explanation |
