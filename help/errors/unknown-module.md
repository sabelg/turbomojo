<!-- match: unable to locate module -->
# A module that cannot be found

Mojo says something like: `unable to locate module ...`

## What it means

The module in an import is not in the standard library, the project or the include folders.

## How to fix it

- Standard library modules start with `std.`: `from std.collections import List`.
- Your own modules: the folder must be on the include path (`-I src`; TurboMojo's `tools.include_paths`).

## Before (does not build)

```mojo
from collections import List

def main():
    var l = List[Int]()
    print(len(l))
```

## After (builds)

```mojo
from std.collections import List

def main():
    var l = List[Int]()
    print(len(l))
```
