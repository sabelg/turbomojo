<!-- match: String does not support direct positional indexing -->
# Indexing a UTF-8 `String` needs an explicit unit

Mojo says something like: `String does not support direct positional indexing like s[i] because Mojo strings are UTF-8 encoded ...`

## What it means

In UTF-8 text, a single visible character can take one to four bytes, so `s[i]` is ambiguous between a byte, a Unicode code point, and a grapheme cluster. Mojo asks you to name which unit you want.

## How to fix it

- Use `s[byte=i]` (or `s[byte=a:b]`) for UTF-8 byte offsets (fast O(1) indexing, paired with `s.byte_length()`).
- Iterate over `s.codepoint_slices()` or `s.codepoints()` when stepping through Unicode characters.

## Coming from Python

This is a Python habit. The page *Coming from Python* (Help > Coming from Python, or
**P** in this window) lists the other differences.

## Before (does not build)

```mojo
def main():
    var s = String("mojo")
    print(s[0])
```

## After (builds)

```mojo
def main():
    var s = String("mojo")
    print(s[byte=0])
```
