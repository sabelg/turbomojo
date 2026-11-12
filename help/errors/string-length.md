<!-- match: is not supported because Mojo strings are UTF-8 -->
# The length of a string

Mojo says something like: `is not supported because Mojo strings are UTF-8 ...`

## What it means

`len()` of a string is not allowed: Mojo strings are UTF-8, so "length" could mean bytes, code points or characters as you see them.

## How to fix it

- `s.byte_length()`: bytes (what slicing with `[byte=...]` uses).
- `len(s.codepoints())`: Unicode code points.

## Coming from Python

This is a Python habit. The page *Coming from Python* (Help > Coming from Python, or
**P** in this window) lists the other differences.

## Before (does not build)

```mojo
def main():
    var s = String("héllo")
    print(len(s))
```

## After (builds)

```mojo
def main():
    var s = String("héllo")
    print(s.byte_length(), len(s.codepoints()))
```
