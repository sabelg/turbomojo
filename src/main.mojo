"""TurboMojo - a Turbo C++ style TUI IDE for Mojo, written in Mojo."""
from std.sys import argv
from app import App
from menu import CM_NEW


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
        app.term.leave()
        print("TurboMojo crashed:", String(e))
