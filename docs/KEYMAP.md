# TurboMojo keymap reference

The keys of every command in the three keymaps (Options > Keys: Modern, the default;
Turbo, WordStar's as in Turbo C++; Emacs). Two keys with a space between are pressed one
after the other (Ctrl-K B). A dash: no key in that keymap - the menus and the command
palette (Ctrl-P, then >) have every command. Your own keys (`[keys]` in the config file)
come on top; Help > Keyboard reference (F1) shows the keys as you have them.

This file is made by `tmide --keys` (TurboMojo 2.2.0).

## System (≡)

| Command | Modern | Turbo | Emacs |
|---|---|---|---|
| Command palette | Ctrl-P | Ctrl-P | Alt-X |

## File

| Command | Modern | Turbo | Emacs |
|---|---|---|---|
| New | Ctrl-N | Ctrl-N | - |
| Open | F3, Ctrl-O | F3, Ctrl-K R | F3, Ctrl-O, Ctrl-X Ctrl-F |
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
| Auto indent | - | Ctrl-O I | - |
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

## Vim (Options > Keys: Vim)

In Normal and Visual mode vim has the plain keys; Ctrl and Alt keys, the F-keys and
the menus are TurboMojo's (the Modern keys) in every mode. In Insert mode only Esc is
vim's. A number before a command repeats it (3j, 2dd, 3.).

| Key | Mode | What it does |
|---|---|---|
| Esc | Insert, Visual | Back to Normal mode (also cancels a half-typed command) |
| i a | Normal | Insert before / after the cursor |
| I A | Normal | Insert at the line's first character / its end |
| o O | Normal | Open a line below / above and insert |
| h j k l | Normal, Visual | Left, down, up, right (also the arrows, Backspace, Space, Enter) |
| w b e | Normal, Visual | Next word, back a word, end of the word |
| W B E | Normal, Visual | The same for words between blanks |
| 0 ^ $ | Normal, Visual | The line's start, its first character, its end |
| + - Enter | Normal, Visual | The first character of the next / the line before |
| gg G | Normal, Visual | The first / the last line (with a count: that line) |
| f t F T | Normal, Visual | To / just before the next character typed (F T: to the left) |
| ; , | Normal, Visual | The last f t F T again / the other way |
| % | Normal, Visual | The matching bracket |
| { } | Normal, Visual | The empty line before / after the paragraph |
| / ? | Normal, Visual | Search forwards / backwards: type the pattern on the status row, then Enter |
| n N | Normal, Visual | The last search again / the other way |
| * # | Normal, Visual | Search for the word under the cursor, forwards / backwards |
| : | Normal, Visual | A command line (in Visual mode for the selection's lines): see below |
| d c y | Normal | Delete / change / copy (yank) what the motion or text object covers: dw, c$, y3j, dd, cc, yy |
| > < | Normal | Indent / unindent the lines the motion covers: >>, <ip |
| iw aw iW aW | after d c y | The word (aw: with the blanks after it) |
| i" a" i' a' | after d c y | Inside the quotes (a: with them) |
| i( a( i{ a{ i[ a[ i< a< | after d c y | Inside the brackets (a: with them); ib iB too |
| ip ap | after d c y | The paragraph (ap: with the empty lines after it) |
| x X | Normal | Delete the character under / before the cursor |
| D C Y | Normal | d$, c$, yy |
| s S | Normal | Change the character / the line |
| r | Normal | Replace the character under the cursor with the next one typed |
| J | Normal, Visual | Join the line and the next (the lines selected) |
| p P | Normal | Put what was deleted or copied after / before the cursor (whole lines: below / above) |
| . | Normal | Repeat the last change |
| u Ctrl-R | Normal | Undo / redo |
| v V | Normal, Visual | Visual mode: characters / whole lines (again: back to Normal) |
| o | Visual | To the other end of the selection |
| d x y c > < J | Visual | Delete, delete, copy, change, indent, unindent, join the selection |

Patterns are vim's: `\(` `\)` `\|` `\+` `\{n,m}` `\<` `\>` are operators and a bare `(` `|` `+` is the
character; `\c` ignores case. Matches are marked until `:noh`.

| Command line | What it does |
|---|---|
| :w | Save (:w FILE writes a copy; :w! FILE over an existing file) |
| :q :q! | Close the window (:q! without saving) |
| :wq :x | Save and close (:x saves only when changed) |
| :wa :qa :wqa | Save all / quit (asking about unsaved files) / both |
| :e FILE | Open a file |
| :N | Go to line N (also :$, :.+3) |
| :s/a/b/g | Replace in this line; :%s for every line, :N,M for some, :'<,'> the selection; flags g i I; & and \1 in the replacement |
| :d :y | Delete / copy lines (with a range: :2,5d) |
| :noh | Unmark the search's matches |
| :NAME | One of TurboMojo's commands: :build, :run, :gotoLine, :compile.build, or its menu title |
