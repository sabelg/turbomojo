# TurboMojo tutorial
#
# This is your own copy: change anything, nothing breaks. Work down the file.
# (Help > Tutorial makes a fresh copy at any time.)
#
# LESSON 1 - moving
#   Arrows move the cursor; Ctrl-Left / Ctrl-Right jump by words; Home / End go to
#   the start and end of a line; Ctrl-Home / Ctrl-End to the start and end of the file.
#   Try: go to the word HERE on the next line, select it (hold Shift and press Right
#   four times) and press Delete.
#       delete the word HERE please
#
# LESSON 2 - selecting, copying, undoing
#   Hold Shift while moving to select. Ctrl-C copies, Ctrl-X cuts, Ctrl-V pastes,
#   Ctrl-Z undoes and Ctrl-Y redoes. Ctrl-D duplicates the line you are on.
#   Try: duplicate this line three times, then undo twice.
#
# LESSON 3 - the menus and the palette
#   F10 opens the menu bar; Alt and a highlighted letter opens that menu (Alt-S:
#   Search). Ctrl-P opens the command palette: type "sort" and press Enter to sort
#   the selected lines below.
#       cherry
#       apple
#       banana
#
# LESSON 4 - finding
#   Ctrl-F finds, Ctrl-L finds again, Ctrl-R replaces. Try: replace every "colour"
#   in the program below with "color".
#
# LESSON 5 - running Mojo
#   F7 starts the language server: break the program below (remove a closing
#   bracket) and watch the problem appear. Put it back, then Ctrl-F9 runs it; F9
#   builds it. Errors are listed in the bottom panel: Enter goes to one.
#
# LESSON 6 - debugging
#   Put the cursor on the line with "total +=" and press Ctrl-F8 for a breakpoint.
#   Shift-F5 starts the debugger; F8 steps; Ctrl-F3 shows the variables.
#
# LESSON 7 - more
#   Help > Cheat sheet lists the keys used most; Help > Keyboard reference all of
#   them; Help > TurboMojo guide the rest. Esc closes a menu or a dialog.


def main():
    var colour = "green"
    var total = 0
    for i in range(1, 6):
        total += i
    print("The sum of 1 to 5 is", total, "and the colour is", colour)
