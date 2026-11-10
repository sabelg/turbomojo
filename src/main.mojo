"""TurboMojo - a Turbo C++ style TUI IDE for Mojo, written in Mojo."""
from std.sys import argv
from std.ffi import external_call
from app import *
from term import is_terminal
from commands import CM_NEW


def main() raises:
    var app = App()
    app.load_config()
    var args = argv()
    if len(args) == 2 and String(args[1]) == "--caps":
        # diagnostics: show what this terminal reports, then exit
        app.term.raw()
        var caps = app.term.probe(300)
        app.term.cooked()
        print("TurboMojo terminal capabilities")
        for line in caps.describe():
            print("  " + line)
        return
    if not is_terminal():
        print("TurboMojo needs an interactive terminal (input or output is redirected).")
        external_call["exit", NoneType](Int32(2))
    app.enable_history()
    for i in range(1, len(args)):
        try:
            app.open_path(String(args[i]))
        except e:
            print("cannot open", String(args[i]), ":", String(e))
    if app.top_editor() < 0:
        app.exec(CM_NEW)
    app.show_config_warnings()
    app.offer_recovery()
    try:
        app.run()
    except e:
        # an error escaped the event loop: keep the user's work, then report
        var n = app.emergency_save()
        app.sig.close()
        app.term.leave()
        app.log_error("fatal: " + String(e))
        print("TurboMojo stopped because of an internal error:", String(e))
        if n > 0:
            print("Unsaved buffers were kept and will be offered when you start TurboMojo again.")
        print("Details:", app.log_path)
        external_call["exit", NoneType](Int32(1))
