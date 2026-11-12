<!-- match: body must not be empty || expressions must not appear at file scope -->
# Code outside a block

Mojo says something like: `body must not be empty ...` or `expressions must not appear at file scope ...`

## What it means

After a line ending in `:` (def, if, for, struct...) Mojo expects an indented block; the lines below are not indented, or there are none. A line at the left edge is then outside every function, where only declarations may be - code there is "at file scope".

## How to fix it

- Indent the block (Tab indents the selected lines).
- An empty block needs `pass`.
- At the top of a file, constants are declared with `comptime` (`alias` was removed): `comptime SIZE = 8`.

## Before (does not build)

```mojo
def main():
print(1)
```

## After (builds)

```mojo
def main():
    print(1)
```
