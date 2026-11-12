<!-- match: cannot implicitly convert -->
# A value of the wrong type

Mojo says something like: `cannot implicitly convert ...`

## What it means

A value of one type was used where another type is needed, and Mojo will not convert between them by itself (for example text where a number is expected).

## How to fix it

- Convert it yourself: `Int("12")` or `atol("12")` parses text (and raises if it is not a number); `String(42)` makes text of a number.
- Or change the declared type, if the value is right and the type was wrong.

## Before (does not build)

```mojo
def main():
    var n: Int = "12"
    print(n)
```

## After (builds)

```mojo
def main() raises:
    var n: Int = Int("12")
    print(n)
```
