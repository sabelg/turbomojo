<!-- match: no matching function in initialization -->
# Constructor arguments do not match any `__init__`

Mojo says something like: `no matching function in initialization`

## What it means

The type has no constructor accepting those arguments. A frequent case in Mojo 1.x is `List[Int](1, 2, 3)` — `List`'s variadic element constructor was removed in favor of list literals `[1, 2, 3]`, `List[Int](capacity=...)`, or `List[Int](length=..., fill=...)`.

## How to fix it

- For a `List` with initial elements, write a list literal: `var nums = [1, 2, 3]` (or `var nums: List[Int] = [1, 2, 3]`).
- For your own structs, add `@fieldwise_init` or check the parameter types of `def __init__(out self, ...):` with **Ctrl-F1** / **F12**.

## Before (does not build)

```mojo
from std.collections import List

def main():
    var nums = List[Int](1, 2, 3)
    print(len(nums))
```

## After (builds)

```mojo
def main():
    var nums = [1, 2, 3]
    print(len(nums))
```
