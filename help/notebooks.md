# Notebooks & Jupyter

TurboMojo runs interactive **Mojo 1.2** and **Python** notebooks directly in the terminal — both standard Jupyter **`.ipynb`** files (nbformat v3 and v4) and plain-text **`# %%`** scripts — with stateful kernels, `In [k]` / `Out [k]` execution prompts, rendered Markdown cells, Jupyter Command Mode, and IPython `!` / `%` magics.

## Opening & creating `.ipynb` notebooks

- **Open any `.ipynb` file**: choose **File > Open notebook (.ipynb)...** (`Alt-F` then `K`), **File > Open... (F3 / Ctrl-O)**, press **Alt-G** (Go to file), press **Enter** on a `.ipynb` file in the **File explorer (Ctrl-E)**, or run `tmide notebook.ipynb` from the shell.
- **Create a new notebook**: choose **File > New Jupyter notebook (.ipynb)...** (`Alt-F` then `J`, or `Ctrl-P` -> `New Jupyter notebook`, or `:nb demo.ipynb` in Vim mode), or run `tmide new_notebook.ipynb`.
- **Automatic kernel selection**: TurboMojo reads `metadata.kernelspec` and `metadata.language_info` in `.ipynb` files to choose **Mojo** (`mojo repl`) or **Python** (`python3`). New or empty notebooks default to Mojo inside Mojo workspaces and Python inside Python projects.
- **Lossless save & export**: pressing **F2** (`Ctrl-S` / `:w`) on an `.ipynb` buffer writes valid nbformat v4 JSON while preserving top-level notebook metadata, `execution_count`, cell outputs (`stream`, `execute_result`, `error`), and base64 `image/png` plots. Any `.mojo` or `.py` script with `# %%` cells can also be exported via **Text > Export notebook as .ipynb...**.

## Running cells & Jupyter shortcuts

| Key / Action | What it does |
|---|---|
| **Shift-Enter** | Run current cell and advance (appends a new `# %%` cell when at the bottom) |
| **Ctrl-Enter** (`Compile > Run code cell`) | Run the current `# %%` cell in place |
| **Alt-Enter** | Run the current `# %%` cell and insert a new cell directly below |
| **Click `[▶ Run]`** or cell `[ ]` gutter | Execute that cell with the mouse |
| `Compile > Run queue: all cells (# %%)` | Execute every code cell from top to bottom in order |
| `Text > Run cells above` | Execute all code cells above the cursor in order |
| `Compile > Restart cell kernel` | Reset persistent `mojo repl` / `python3` kernel state |
| `Compile > Toggle inline cell yield` | Show or hide virtual multi-line output blocks under cells |
| `Text > Clear cell outputs` | Clear inline output blocks and execution badges |
| `Text > Open cell plot preview` | Render `matplotlib` / PNG plots via Kitty, Sixel, or half-blocks |

## Jupyter Command Mode (`Esc` inside `.ipynb`)

Pressing **Esc** inside an `.ipynb` buffer switches from **Edit Mode** (`NB:EDIT`, green cell rail) to **Jupyter Command Mode** (`NB:CMD`, blue cell rail), matching classic JupyterLab / Jupyter Notebook single-key shortcuts:

| Command Mode Key | Action |
|---|---|
| **Enter** | Enter Edit Mode inside the selected cell |
| **j** / **Down**, **k** / **Up** | Select next / previous cell |
| **a** / **b** | Insert a new `# %%` cell **above** / **below** |
| **d d** / **x** | Delete / cut the selected cell (1-step Undo with **z** / **Ctrl-Z**) |
| **c** / **v** | Copy cell / paste cell below |
| **m** / **y** | Convert cell to **Markdown** (`# %% [markdown]`) / **Code** (`# %%`) |
| **f** / **Tab** | Hide / show the selected cell's code (keeping `Out [k]` & images visible) |
| **F** / **Shift-Tab** | Compact presentation view: collapse / expand **all** code cells |
| **o** / **l** | Toggle inline cell outputs / toggle line numbers |
| **0 0** / **i i** | Restart notebook kernel / interrupt running cell |
| **h** / **?** | Open this Notebooks & Jupyter guide |

In **Vim mode** (`tmide vim` or `Options > Keys: Vim`), use `<Space>c` / `<Space>C` to run cells, `]n` / `[n` to jump between cells, and `:cell add|above|del|md|code|restart|clear`.

## Cell syntax, Markdown & `%magic` commands

Cells are delimited by `# %%` headers:

```mojo
# %% [markdown]
# ## Matrix benchmark
# Compare SIMD vector addition in Mojo 1.2.

# %% Setup
from std.collections import List

var xs: List[Int] = [10, 20, 30, 40]
print("count =", len(xs))

# %% Compute sum
var total = 0
for x in xs:
    total += x
print("total =", total)
```

- **Rendered Markdown cells**: `# %% [markdown]` cells automatically render headings, bullets, and quotes cleanly when the cursor is outside the cell (or in Command Mode), and reveal raw lines automatically when you edit them.
- **IPython `!shell` & `%magic` support (Python kernel)**: `!cmd` shell escapes (with `{var}` interpolation), `%matplotlib inline`, `%pip`, `%pwd`, `%cd`, `%env`, `%who` / `%whos`, `%reset`, `%time`, `%timeit`, `%%time`, `%%bash` / `%%sh`, `%%capture`, and `%%writefile` work out of the box.
- **Card-based Jupyter view & collapsible code cells**: `.ipynb` cells render as connected cards (`╭─ In [k] ─╮` ... `├─ Out [k] ─┤` ... `╰───╯`) with clickable **`[▾ Hide code]`** / **`[▸ +N lines]`** and **`[▶ Run]`** pills (persisted via standard `jupyter.source_hidden` metadata). Collapsing code cells hides only the code while keeping `Out [k]` and rendered images visible directly underneath.
- **Inline editor image, animation, scrubber & GIF89a export**: PNG plots (`matplotlib`, `PIL.Image`, `display()`, `_repr_png_()`) and animations (`matplotlib.animation.FuncAnimation`, animated GIFs, Python `clear_output(wait=True); display(fig)`, and Mojo `__TM_FRAME__ <path>` / `__TM_ANIM__ <fps> <f0.png> ...`) render **directly beneath each cell** across Kitty/Ghostty (`U+10EEEE`), Sixel / WezTerm / Konsole, and 24-bit 2×2 Quadrant canvases. Click `[⏸ Pause]` / `[▶ Play]` to toggle inline playback, or click any image/animation to open the dedicated **Image Zoom Window (`WK_IMGVIEW`)** (`Space` pause/play, clickable timeline scrubber, `g` / `[g GIF]` pure-Mojo GIF89a export, `+/-` pan & zoom, `[/]` frame step, `o` OS viewer, `Esc` close).
- **Interactive `# @param` widgets, `WK_DATAGRID`, LaTeX/Mermaid & HTML5 export**: annotate variables with `# @param {type:"slider", min:0, max:100, step:5}`, `# @param {type:"boolean"}`, or `# @param ["a", "b"]` to render live interactive controls (`Alt-Left` / `Alt-Right` or mouse click); click any `[Tensor]` / `[DataFrame]` card (or run `Notebook: DataGrid & Tensor heatmap` in **Ctrl-P**) to inspect sortable Viridis heatmaps in `WK_DATAGRID`; write `$...$` LaTeX math and fenced ```` ```mermaid ```` diagrams in `# %% [markdown]` cells; connect external kernels with `tmide --kernel conn.json`; and export self-contained reports with **File > Export standalone HTML5 notebook...** (`tmide --export-html`).
- **Virtual inline output, rapid `Shift-Enter` queueing & Tensor cards**: stdout, bare trailing expressions (`Out [k]`), errors, and shape/dtype/NaN summary cards (`SIMD`, `Tensor`, `numpy`, `torch`, `pandas`, `polars`) appear directly beneath each cell without shifting file line numbers; pressing **Shift-Enter** rapidly queues `[⋯ queued]` cells in FIFO order.
- **Live Mojo LSP in notebooks**: pressing **F7** runs `mojo-lsp-server` over `NotebookVirtualDoc` so completions, hover (**Alt-I**), go-to-definition (**F12**), and error underlines map back to exact cell lines.
