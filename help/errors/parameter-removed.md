<!-- match: statement does not support decorators -->
# `@parameter` was replaced by `comptime`

Mojo says something like: `'if' statement does not support decorators; remove the decorator` (or `'for' statement does not support decorators`)

## What it means

Older Mojo code used `@parameter` above `if` or `for` to evaluate branches and unroll loops at compile time. In Mojo 1.x, `@parameter` on statements was removed in favor of `comptime if` and `comptime for`.

## How to fix it

- Replace `@parameter` + `if cond:` with `comptime if cond:`.
- Replace `@parameter` + `for i in range(N):` with `comptime for i in range(N):`.

## Before (does not build)

```mojo
def main():
    @parameter
    if True:
        print("unrolled at compile time")
```

## After (builds)

```mojo
def main():
    comptime if True:
        print("unrolled at compile time")
```
