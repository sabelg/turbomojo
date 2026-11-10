"""TurboMojo - a Turbo C++ style TUI IDE for Mojo, written in Mojo."""
from std.sys import argv
from std.ffi import external_call
from app import *
from commands import CM_NEW


def main() raises:
    var app = App()
    var args = argv()
    for i in range(1, len(args)):
        try:
            app.open_path(String(args[i]))
        except e:
            print("cannot open", String(args[i]), ":", String(e))
    if app.top_editor() < 0:
        app.exec(CM_NEW)
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
            print("Unsaved buffers were written to", app.recovery_dir)
        print("Details:", app.log_path)
        external_call["exit", NoneType](Int32(1))
