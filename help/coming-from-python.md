# Coming from Python

Mojo looks like Python, and much of what you know carries over: indentation, `for` and
`while`, `if`/`elif`/`else`, `print`, lists and dictionaries, `try`/`except`. These are
the places where Python habits trip you up in Mojo 1.x. Every Mojo example on this page
builds as it is.

The keys of TurboMojo next to VS Code's are on the page **Coming from other editors**.

## A program starts at `main`

Python runs a file from the top. Mojo runs `def main()`; only declarations may stand at
the top level of a file.

```mojo
def main():
    print("hello")
```

## Functions are `def`; `raises` says it can fail

There is no `fn` any more. A `def` that can raise an error says so with `raises`, and a
function that calls it must handle the error or say `raises` too.

```mojo
def parse(text: String) raises -> Int:
    return Int(text)


def main() raises:
    print(parse("42") + 1)
```

## New names need `var`

Assigning to a new name does not create it: `var` does. The type can be written or
left to Mojo.

```mojo
def main():
    var count = 0
    var name: String = "Mojo"
    count += 1
    print(name, count)
```

## Arguments are read-only by default

A function cannot change its arguments unless they are `mut` (the caller's variable
changes) or `var` (the function gets its own copy).

```mojo
def bump(mut n: Int):
    n += 1


def main():
    var x = 1
    bump(x)
    print(x)
```

## Copying is asked for

`b = a` copies a Python list's reference; in Mojo a `List` is a value and is not copied
behind your back. Write `a.copy()` to copy, or `a^` to move it (then `a` cannot be used).

```mojo
def main():
    var a: List[Int] = [1, 2, 3]
    var b = a.copy()
    b.append(4)
    print(len(a), len(b))
```

## `struct` instead of `class`

There are no classes ("classes are not supported yet"). A `struct` declares its fields
with `var`; its constructor takes `out self`; a method that changes it takes `mut self`.
Instead of inheritance, a struct implements traits.

```mojo
struct Counter:
    var count: Int

    def __init__(out self):
        self.count = 0

    def bump(mut self):
        self.count += 1


def main():
    var c = Counter()
    c.bump()
    print(c.count)
```

## Strings: no `len()`, no f-strings

`len(s)` is not allowed, because "length" could mean bytes or characters: write
`s.byte_length()` or `len(s.codepoints())`. There are no f-strings; build text with `+`
and `String(x)`, or give `print` several values.

```mojo
def main():
    var s = String("héllo")
    var n = 3
    print(s.byte_length(), len(s.codepoints()))
    print("n = " + String(n), "and", n)
```

## Imports start with `std.`

The standard library is imported as `std.collections`, `std.os` and so on. Python
modules are still at hand through `std.python`.

```mojo
from std.collections import Dict
from std.python import Python


def main() raises:
    var d = Dict[String, Int]()
    d["a"] = 1
    var math = Python.import_module("math")
    print(d["a"], math.sqrt(16.0))
```

## `None` is `Optional`

A function that may return nothing returns an `Optional`; test it, then take
`.value()`.

```mojo
def find(xs: List[Int], v: Int) -> Optional[Int]:
    for i in range(len(xs)):
        if xs[i] == v:
            return i
    return None


def main():
    var xs: List[Int] = [5, 6]
    var r = find(xs, 6)
    if r:
        print(r.value())
```

## Constants are `comptime`

A value known when the program is built is a `comptime` constant (there is no
`alias` any more).

```mojo
comptime SIZE = 8


def main():
    print(SIZE * 2)
```

## Jupyter notebooks & `# %%` cells

TurboMojo opens Jupyter **`.ipynb`** files directly (`tmide notebook.ipynb` or **F3**) for
both **Mojo** and **Python** kernels, and also runs `# %%` cells in `.mojo` and `.py` files:

- **Ctrl-Enter** executes the current cell (**Ctrl-Shift-Enter** executes and jumps to the
  next cell); inline virtual outputs show `numpy`, `torch`, `pandas`, `polars`, and Mojo
  `SIMD` / `Tensor` shape & NaN/Inf cards plus `matplotlib` plots (`Text > Open cell plot preview`).
- **F2** saves `.ipynb` notebooks back to standard nbformat v4 JSON (including cell outputs);
  see **Help > Jupyter & notebooks** for details.

## When something goes wrong

**F1** on a problem explains the message, with a program before and after the fix;
Help > Error messages lists them all; Help > Exercises has small programs to practise
these differences on.
