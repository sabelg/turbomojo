"""OSC 133 marks ("semantic prompts", FinalTerm's sequences) around a program run.

A terminal that knows them (Ghostty, kitty, WezTerm, iTerm2, foot, Windows Terminal,
VS Code's terminal, ...) can jump between runs, select one run's output, and show
whether it failed. TurboMojo sends them around a run on the user screen (Run, Test,
leaving the IDE for the program) and in its own Run window, where libghostty-vt reads
them: Ctrl-Shift-Up / Ctrl-Shift-Down jump between the marked prompts there - also
in the shell's terminal window when the shell sends them (fish does; bash and zsh
with their terminal's shell integration).

  ESC ] 133 ; A BEL    a prompt starts (here: the "$ mojo run a.mojo" line)
  ESC ] 133 ; B BEL    the prompt ends, the command starts
  ESC ] 133 ; C BEL    the command runs: its output follows
  ESC ] 133 ; D ; N BEL  it ended with status N

Not sent where they would show as text: the Linux console prints an OSC it does not
know, and TERM=dumb has no escape sequences at all."""

comptime OSC133_PROMPT = "\x1b]133;A\x07"
comptime OSC133_INPUT = "\x1b]133;B\x07"
comptime OSC133_OUTPUT = "\x1b]133;C\x07"


def osc133_end(status: Int) -> String:
    return "\x1b]133;D;" + String(status) + "\x07"


def marks_wanted(term: String) -> Bool:
    """Whether the terminal named by TERM takes OSC 133 quietly."""
    return not (term == "linux" or term == "dumb" or term.byte_length() == 0 or term.startswith("vt1") or term.startswith("vt2"))


def marked_run(label: String, core: String, marks: Bool, eol: String) -> String:
    """The shell text for a run: the "$ label" line (bold), the command `core`, its
    status kept in `st` - with the four marks around them when `marks`. `eol` is what
    ends the label line, as printf writes it ("\\n", or "\\r\\n" for a pty in raw
    mode). `label` is quoted here."""
    var q = "'" + label.replace("'", "'\\''") + "'"
    if not marks:
        return "printf '\\033[1m$ %s\\033[0m" + eol + "' " + q + "; " + core + "; st=$?"
    return (
        "printf '\\033]133;A\\007\\033[1m$ %s\\033[0m\\033]133;B\\007" + eol + "\\033]133;C\\007' " + q
        + "; " + core + "; st=$?; printf '\\033]133;D;%d\\007' $st"
    )
