<!-- match: StringSpan[ || StringSlice[ -->
# A string slice or span where an owned `String` is needed

Mojo says something like: `... cannot be converted from 'StringSpan[...]' to 'String'`

## What it means

Byte slicing (`name[byte=0:2]`) and zero-copy views return a borrowed `StringSpan` or `StringSlice` pointing into existing UTF-8 bytes rather than allocating a new `String`. When a function or struct field requires an owned `String`, you convert the view explicitly.

## How to fix it

- Wrap the slice in `String(...)` to allocate an owned `String`: `String(name[byte=0:2])`.
- Or, if the function only reads the text, let it accept `StringSlice` so callers need not copy.

## Coming from Python

This is a Python habit. The page *Coming from Python* (Help > Coming from Python, or
**P** in this window) lists the other differences.

## Before (does not build)

```mojo
def greet(s: String):
    print("hi", s)

def main():
    var name = String("Ada")
    greet(name[byte=0:2])
```

## After (builds)

```mojo
def greet(s: String):
    print("hi", s)

def main():
    var name = String("Ada")
    greet(String(name[byte=0:2]))
```
