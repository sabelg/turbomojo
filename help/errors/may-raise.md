<!-- match: cannot call function that may raise -->
# A call that can raise, in a function that cannot

Mojo says something like: `cannot call function that may raise ...`

## What it means

The function you call is marked `raises` (it can fail with an Error), but the function calling it is not, so the error would have nowhere to go.

## How to fix it

- Mark the caller `raises` too: `def main() raises:`.
- Or handle the error where it happens: `try: ... except e: print(e)`.

## Before (does not build)

```mojo
def parse() raises -> Int:
    return atol("7")

def main():
    print(parse())
```

## After (builds)

```mojo
def parse() raises -> Int:
    return atol("7")

def main():
    try:
        print(parse())
    except e:
        print("could not parse:", e)
```
