<!-- match: value has no attribute -->
# No such field or method

Mojo says something like: `value has no attribute ...`

## What it means

The type has no field or method of that name - a typo, a name from another language (Python's `.length`, Java's `.size()`), or a method of a different type.

## How to fix it

- Check the type's documentation: Ctrl-F1 on the name, or Alt-F1 to search (for example `@List` for List's methods).
- Strings: `s.byte_length()` and `len(s.codepoints())`, not `len(s)`.

## Before (does not build)

```mojo
def main():
    var l = List[Int]()
    print(l.length)
```

## After (builds)

```mojo
def main():
    var l = List[Int]()
    print(len(l))
```
