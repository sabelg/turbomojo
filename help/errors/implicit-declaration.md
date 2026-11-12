<!-- match: implicit declaration of -->
# A new name needs `var`

Mojo says something like: `implicit declaration of ...`

## What it means

Unlike Python, Mojo does not create a variable the first time you assign to it: a new name is declared with `var`.

## How to fix it

- Write `var x = 1` the first time; later assignments are `x = 2`.
- Inside a struct, fields are declared with `var` in the struct body.

## Before (does not build)

```mojo
def main():
    count = 1
    print(count)
```

## After (builds)

```mojo
def main():
    var count = 1
    count = count + 1
    print(count)
```
