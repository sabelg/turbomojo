<!-- match: 'fn' has been removed -->
# `fn` no longer exists

Mojo says something like: `'fn' has been removed ...`

## What it means

Mojo 1.x has one kind of function: `def`. A `def` does not raise unless it is marked `raises`, which is what `fn` used to mean.

## How to fix it

- Replace `fn` with `def`.
- If the function can raise an error, add `raises`: `def load(path: String) raises -> String:`.

## Before (does not build)

```mojo
fn main():
    print(1)
```

## After (builds)

```mojo
def main():
    print(1)
```
