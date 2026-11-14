# Exercise 2 of 13: functions are def
#
# This was written for an older Mojo. Make it build with Mojo 1.x.
# When it is right, it prints:
#     Hello, Mojo!
#
# Check it with Help > Exercise done? ({key}). F1 on a line with an error explains
# the message. Lost? Ctrl-Z undoes; Help > Exercises > Reset gives the original back.
# expect: Hello, Mojo!


fn greet(name: String) -> String:
    return "Hello, " + name + "!"


def main():
    print(greet("Mojo"))
