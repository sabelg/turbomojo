#!/usr/bin/env python3
"""MCP stdio server exposing live TurboMojo IDE state, Mojo compiler diagnostics,
and offline Mojo 1.2 documentation search to coding agents (e.g. `agy acp`)."""
import json
import os
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

_IPC_SEQ = 0

REPO_ROOT = Path(__file__).resolve().parent.parent
STATE_FILE = Path(os.environ.get("XDG_STATE_HOME", Path.home() / ".local/state")) / "turbomojo" / "ide-state.json"
DOCS_DIR = Path(os.environ.get("XDG_DATA_HOME", Path.home() / ".local/share")) / "turbomojo" / "docs"
ERRHELP_DIR = (
    REPO_ROOT / "help" / "errors"
    if (REPO_ROOT / "help" / "errors").is_dir()
    else Path(os.environ.get("TURBOMOJO_ERRHELP_DIR", Path.home() / "turbomojo" / "help" / "errors"))
)

TOOLS = [
    {
        "name": "turbomojo_get_diagnostics",
        "description": (
            "Return live Mojo LSP, build, and test diagnostics from TurboMojo's Problems panel, "
            "and optionally run a fast `mojo build` check on a specific .mojo file."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "file_path": {
                    "type": "string",
                    "description": "Optional path to a .mojo file to compile-check with `mojo build`.",
                },
                "include_paths": {
                    "type": "array",
                    "items": {"type": "string"},
                    "description": "Optional extra -I include directories when compile-checking file_path.",
                },
            },
        },
    },
    {
        "name": "turbomojo_get_open_editors",
        "description": "Return TurboMojo's current project directory, open editor files, cursor positions, and modified buffer status.",
        "inputSchema": {"type": "object", "properties": {}},
    },
    {
        "name": "turbomojo_search_mojo_docs",
        "description": (
            "Search offline Mojo 1.2 standard library API docs, language manual pages, "
            "and TurboMojo's compiler error explanations."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "query": {
                    "type": "string",
                    "description": "Symbol name (e.g. 'List.append', 'Span'), topic, or Mojo compiler error snippet.",
                },
                "limit": {
                    "type": "integer",
                    "description": "Maximum number of matches to return (default 8).",
                },
            },
            "required": ["query"],
        },
    },
    {
        "name": "turbomojo_open_location",
        "description": "Open a file and jump to a 1-based line and column in the running TurboMojo IDE session.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "path": {"type": "string", "description": "File path to open in TurboMojo."},
                "line": {"type": "integer", "description": "1-based line number (default 1)."},
                "col": {"type": "integer", "description": "1-based column number (default 1)."},
            },
            "required": ["path"],
        },
    },
    {
        "name": "turbomojo_get_buffer_text",
        "description": (
            "Read the live editor buffer text (including unsaved edits) from a running TurboMojo session, "
            "falling back to disk if no live IDE session has the file open."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "path": {"type": "string", "description": "Path to the file or open editor buffer."},
            },
            "required": ["path"],
        },
    },
    {
        "name": "turbomojo_apply_buffer_edits",
        "description": (
            "Apply 1-based line or character-range edits directly into TurboMojo's live editor buffer "
            "(as a single Ctrl-Z undoable step), falling back to editing on disk when no live IDE is running."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "path": {"type": "string", "description": "Path to the target file."},
                "save": {"type": "boolean", "description": "Save buffer to disk after applying edits (default false)."},
                "edits": {
                    "type": "array",
                    "description": "List of 1-based edits ({start_line, end_line, text} or {start_line, start_col, end_line, end_col, text}).",
                    "items": {
                        "type": "object",
                        "properties": {
                            "start_line": {"type": "integer"},
                            "end_line": {"type": "integer"},
                            "start_col": {"type": "integer"},
                            "end_col": {"type": "integer"},
                            "text": {"type": "string"},
                        },
                        "required": ["start_line", "text"],
                    },
                },
            },
            "required": ["path", "edits"],
        },
    },
    {
        "name": "turbomojo_inspect_codegen",
        "description": (
            "Emit assembly (asm) or LLVM IR (llvm) for a Mojo file and return SIMD vectorization counts, "
            "stack-spill warnings, function symbols, and annotated codegen lines."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "file_path": {"type": "string", "description": "Path to the .mojo file to inspect."},
                "stage": {"type": "string", "enum": ["asm", "llvm"], "description": "Codegen stage: 'asm' (default) or 'llvm'."},
                "filter_symbol": {"type": "string", "description": "Optional substring filter for function/symbol names."},
                "include_paths": {
                    "type": "array",
                    "items": {"type": "string"},
                    "description": "Optional extra -I include directories.",
                },
            },
            "required": ["file_path"],
        },
    },
    {
        "name": "turbomojo_debug_inspect",
        "description": (
            "Inspect the live debugger session inside TurboMojo (active stop location, stack frames, "
            "local variables, watches, CPU/SIMD registers, and disassembly), and optionally evaluate "
            "an LLDB/Mojo expression in the stopped frame."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "expression": {
                    "type": "string",
                    "description": "Optional expression or `:lldb command` to evaluate in the stopped debugger frame.",
                },
            },
        },
    },
    {
        "name": "turbomojo_run_test",
        "description": (
            "Run a Mojo 1.2 TestSuite file (or a single `test_*` function via `--only`) with `mojo run`, "
            "parse structured PASS/FAIL/SKIP results and failure locations, and sync inline ✓/✗ gutter "
            "lenses into the running TurboMojo IDE session."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "path": {"type": "string", "description": "Path to the Mojo test file (`test_*.mojo`)."},
                "test_name": {"type": "string", "description": "Optional single `test_*` function name to run via `--only`."},
                "include_paths": {
                    "type": "array",
                    "items": {"type": "string"},
                    "description": "Optional extra -I include directories.",
                },
                "timeout_sec": {"type": "integer", "description": "Execution timeout in seconds (default 90)."},
            },
            "required": ["path"],
        },
    },
]


def read_ide_state():
    if not STATE_FILE.is_file():
        return None
    try:
        return json.loads(STATE_FILE.read_text(encoding="utf-8", errors="replace"))
    except Exception as exc:
        return {"error": f"Could not parse {STATE_FILE}: {exc}"}


def run_mojo_check(file_path: str, include_paths: list[str]) -> dict:
    p = Path(file_path).expanduser().resolve()
    if not p.is_file():
        return {"error": f"File not found: {p}"}
    out_bin = Path(f"/tmp/turbomojo-mcp-check-{os.getpid()}.o")
    mojo_bin = shutil.which("mojo") or str(Path.home() / ".local/bin/mojo")
    cmd = [mojo_bin, "build", "--emit", "object"]
    inc_set = []
    for inc in include_paths:
        if inc not in inc_set:
            inc_set.append(inc)
    if p.parent.name == "src" and str(p.parent) not in inc_set:
        inc_set.append(str(p.parent))
    elif (p.parent.parent / "src").is_dir() and str(p.parent.parent / "src") not in inc_set:
        inc_set.append(str(p.parent.parent / "src"))
    state = read_ide_state()
    if isinstance(state, dict) and not include_paths:
        proj = state.get("project_dir", "")
        if proj and (Path(proj) / "src").is_dir() and str(p).startswith(proj):
            proj_src = str(Path(proj) / "src")
            if proj_src not in inc_set:
                inc_set.append(proj_src)
    for inc in inc_set:
        cmd.extend(["-I", inc])
    cmd.extend([str(p), "-o", str(out_bin)])
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=45, cwd=str(p.parent))
        return {
            "file": str(p),
            "ok": proc.returncode == 0,
            "exit_code": proc.returncode,
            "output": (proc.stdout + proc.stderr).strip(),
        }
    except Exception as exc:
        return {"file": str(p), "ok": False, "error": str(exc)}
    finally:
        try:
            out_bin.unlink(missing_ok=True)
        except Exception:
            pass


def iter_std_decls(node, prefix=""):
    if not isinstance(node, dict):
        return
    name = node.get("name", "")
    full = f"{prefix}.{name}" if prefix and name and name != "__init__" else (name if name != "__init__" else prefix)
    kind = node.get("kind", "")
    if kind in ("struct", "trait", "alias"):
        yield full, kind, node.get("signature", ""), node.get("summary", ""), node.get("description", "")
    for fn in node.get("functions", []) or []:
        fname = fn.get("name", "")
        qname = f"{full}.{fname}" if full else fname
        for ov in fn.get("overloads", []) or []:
            yield qname, "def", ov.get("signature", ""), ov.get("summary", ""), ov.get("description", "")
    for sub_key in ("packages", "modules", "structs", "traits"):
        for child in node.get(sub_key, []) or []:
            yield from iter_std_decls(child, full)


def search_docs(query: str, limit: int = 8) -> dict:
    q = query.strip().lower()
    if not q:
        return {"query": query, "docs_installed": DOCS_DIR.is_dir(), "results": []}
    results = []
    tokens = [tok for tok in q.replace(".", " ").replace("`", " ").split() if len(tok) > 3]

    if ERRHELP_DIR.is_dir():
        err_scored = []
        for md in sorted(ERRHELP_DIR.glob("*.md")):
            try:
                txt = md.read_text(encoding="utf-8", errors="replace")
            except Exception:
                continue
            low = txt.lower()
            score = 0
            for line in low.splitlines()[:10]:
                if line.startswith("<!-- match:") and line.endswith("-->"):
                    pat = line[len("<!-- match:") : -3].strip()
                    if pat and (pat in q or q in pat):
                        score = max(score, 1000)
            if q in low:
                score = max(score, 500)
            if tokens:
                hits = sum(1 for tok in tokens if tok in low)
                if hits == len(tokens):
                    score = max(score, 250 + 30 * hits)
                elif hits >= 2:
                    score = max(score, 40 * hits)
                elif hits == 1 and len(tokens) == 1:
                    score = max(score, 60)
            if score > 0:
                err_scored.append((score, {
                    "source": f"help/errors/{md.name}",
                    "kind": "error_explanation",
                    "excerpt": txt[:1200],
                }))
        err_scored.sort(key=lambda item: (-item[0], item[1]["source"]))
        for _, entry in err_scored[: max(1, min(4, limit))]:
            results.append(entry)

    std_json = DOCS_DIR / "std.docs.json"
    if std_json.is_file() and len(results) < limit:
        try:
            data = json.loads(std_json.read_text(encoding="utf-8", errors="replace"))
            scored = []
            for qname, kind, sig, summary, desc in iter_std_decls(data.get("decl", {})):
                ql = qname.lower()
                leaf = ql.rsplit(".", 1)[-1]
                score = 0
                if ql == q or leaf == q:
                    score = 100
                elif ql.endswith("." + q):
                    score = 90
                elif q in ql:
                    score = 70
                elif q in summary.lower():
                    score = 40
                if score > 0:
                    scored.append((score, {
                        "symbol": qname,
                        "kind": kind,
                        "signature": sig,
                        "summary": summary,
                        "description": desc[:600],
                    }))
            scored.sort(key=lambda item: (-item[0], len(item[1]["symbol"])))
            for _, entry in scored[: max(1, limit - len(results))]:
                results.append(entry)
        except Exception as exc:
            results.append({"warning": f"Failed reading {std_json}: {exc}"})

    if len(results) < limit and DOCS_DIR.is_dir():
        doc_files = list(DOCS_DIR.rglob("*.md")) + list(DOCS_DIR.rglob("*.mdx"))
        for md in doc_files:
            if len(results) >= limit:
                break
            try:
                txt = md.read_text(encoding="utf-8", errors="replace")
            except Exception:
                continue
            idx = txt.lower().find(q)
            if idx >= 0:
                start = max(0, idx - 150)
                end = min(len(txt), idx + 650)
                results.append({
                    "source": str(md.relative_to(DOCS_DIR)),
                    "kind": "doc_page",
                    "excerpt": txt[start:end],
                })

    return {
        "query": query,
        "docs_installed": DOCS_DIR.is_dir(),
        "results": results[:limit],
    }


def _pid_alive(pid: int) -> bool:
    if pid <= 0:
        return False
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def send_ide_ipc(op: str, payload: dict, timeout_s: float = 1.5):
    global _IPC_SEQ
    state = read_ide_state()
    if not isinstance(state, dict):
        return None
    pid = int(state.get("pid") or 0)
    ipc_dir_raw = state.get("ipc_dir") or ""
    if not ipc_dir_raw or not _pid_alive(pid):
        return None
    ipc_dir = Path(ipc_dir_raw)
    if not ipc_dir.is_dir():
        return None
    _IPC_SEQ += 1
    req_id = f"{os.getpid()}-{_IPC_SEQ}"
    msg = dict(payload)
    msg["id"] = req_id
    msg["op"] = op
    req_tmp = ipc_dir / f".req-{req_id}.tmp"
    req_path = ipc_dir / f"req-{req_id}.json"
    resp_path = ipc_dir / f"resp-{req_id}.json"
    try:
        resp_path.unlink(missing_ok=True)
        req_tmp.write_text(json.dumps(msg) + "\n", encoding="utf-8")
        os.replace(req_tmp, req_path)
    except OSError:
        return None
    deadline = time.monotonic() + timeout_s
    while time.monotonic() < deadline:
        if resp_path.is_file():
            try:
                txt = resp_path.read_text(encoding="utf-8", errors="replace")
                resp_path.unlink(missing_ok=True)
                return json.loads(txt)
            except Exception:
                return None
        time.sleep(0.01)
    try:
        req_path.unlink(missing_ok=True)
    except OSError:
        pass
    return None


def apply_disk_edits(file_path: Path, edits: list[dict]) -> dict:
    raw = file_path.read_text(encoding="utf-8", errors="replace")
    trailing_nl = raw.endswith("\n")
    lines = raw.splitlines()
    if not lines:
        lines = [""]
    ordered = sorted(
        edits,
        key=lambda e: (int(e.get("start_line") or 1), int(e.get("start_col") or 0)),
        reverse=True,
    )
    for ed in ordered:
        sl = max(1, int(ed.get("start_line") or 1))
        el = int(ed.get("end_line") if ed.get("end_line") is not None else sl)
        sc = int(ed.get("start_col") or 0)
        ec = int(ed.get("end_col") or 0)
        txt = str(ed.get("text") or "")
        if sc > 0 or ec > 0:
            r1 = min(sl - 1, len(lines) - 1)
            r2 = min(max(r1, el - 1), len(lines) - 1)
            c1 = min(max(0, sc - 1), len(lines[r1]))
            c2 = min(max(0, (ec if ec > 0 else sc) - 1), len(lines[r2]))
            prefix = lines[r1][:c1]
            suffix = lines[r2][c2:]
            merged = (prefix + txt + suffix).split("\n")
            lines[r1 : r2 + 1] = merged
        else:
            r1 = max(0, sl - 1)
            r2 = el - 1
            clean = txt[:-2] if txt.endswith("\r\n") else (txt[:-1] if txt.endswith("\n") else txt)
            repl_lines = clean.split("\n") if txt != "" else []
            if r2 < r1:
                idx = min(r1, len(lines))
                lines[idx:idx] = repl_lines
            else:
                lines[min(r1, len(lines)) : min(r2 + 1, len(lines))] = repl_lines
    out = "\n".join(lines) + ("\n" if trailing_nl and lines else "")
    file_path.write_text(out, encoding="utf-8")
    return {
        "ok": True,
        "live": False,
        "path": str(file_path),
        "applied": len(ordered),
        "modified": False,
        "lines": len(lines),
    }


def run_codegen_inspect(file_path: str, stage: str, filter_symbol: str, include_paths: list[str]) -> dict:
    p = Path(file_path).expanduser().resolve()
    if not p.is_file():
        return {"ok": False, "error": f"File not found: {p}"}
    emit = "llvm" if stage == "llvm" else "asm"
    ext = ".ll" if emit == "llvm" else ".s"
    out_file = Path(f"/tmp/turbomojo-mcp-codegen-{os.getpid()}{ext}")
    mojo_bin = shutil.which("mojo") or str(Path.home() / ".local/bin/mojo")
    cmd = [mojo_bin, "build", f"--emit={emit}"]
    inc_set = []
    for inc in include_paths:
        if inc not in inc_set:
            inc_set.append(inc)
    if p.parent.name == "src" and str(p.parent) not in inc_set:
        inc_set.append(str(p.parent))
    elif (p.parent.parent / "src").is_dir() and str(p.parent.parent / "src") not in inc_set:
        inc_set.append(str(p.parent.parent / "src"))
    for inc in inc_set:
        cmd.extend(["-I", inc])
    cmd.extend([str(p), "-o", str(out_file)])
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=60, cwd=str(p.parent))
        if proc.returncode != 0 or not out_file.is_file():
            return {
                "ok": False,
                "stage": emit,
                "exit_code": proc.returncode,
                "output": (proc.stdout + proc.stderr).strip(),
            }
        raw = out_file.read_text(encoding="utf-8", errors="replace")
        simd_re = re.compile(r"\b(vmov|vadd|vmul|vfma|vpadd|vpxor|zmm|ymm|xmm|<\d+\s*x\s*)", re.IGNORECASE)
        spill_re = re.compile(r"(%rsp\)|\[sp,|#.*spill|alloca\b)", re.IGNORECASE)
        simd_ops = 0
        spill_ops = 0
        functions = []
        annotated = []
        keep_fn = True
        flt = filter_symbol.lower().strip()
        for line in raw.splitlines():
            stripped = line.strip()
            if emit == "asm" and stripped.endswith(":") and not stripped.startswith("."):
                fn_name = stripped[:-1]
                functions.append(fn_name)
                keep_fn = (not flt) or (flt in fn_name.lower())
            elif emit == "llvm" and stripped.startswith("define "):
                functions.append(stripped[:120])
                keep_fn = (not flt) or (flt in stripped.lower())
            if not keep_fn:
                continue
            tag = ""
            if simd_re.search(line):
                simd_ops += 1
                tag = "[SIMD] "
            if spill_re.search(line):
                spill_ops += 1
                tag = "[SPILL] " + tag
            if len(annotated) < 250 and stripped and not stripped.startswith((".cfi_", "; ModuleID")):
                annotated.append(f"{tag}{line}")
        return {
            "ok": True,
            "file": str(p),
            "stage": emit,
            "simd_ops": simd_ops,
            "spill_ops": spill_ops,
            "functions": functions[:50],
            "lines": annotated,
        }
    except Exception as exc:
        return {"ok": False, "stage": emit, "error": str(exc)}
    finally:
        try:
            out_file.unlink(missing_ok=True)
        except Exception:
            pass


def run_mojo_test_file(file_path: str, test_name: str, include_paths: list[str], timeout_sec: int = 90) -> dict:
    p = Path(file_path).expanduser().resolve()
    if not p.is_file():
        return {"ok": False, "error": f"File not found: {p}"}
    mojo_bin = shutil.which("mojo") or str(Path.home() / ".local/bin/mojo")
    inc_set = []
    for inc in include_paths:
        if inc not in inc_set:
            inc_set.append(inc)
    # Walk ancestors up to 3 levels to locate project root (`pixi.toml` / `src/`)
    proj_root = p.parent
    for anc in [p.parent, p.parent.parent, p.parent.parent.parent]:
        if (anc / "pixi.toml").is_file() or (anc / "mojoproject.toml").is_file():
            proj_root = anc
            break
    if (proj_root / "src").is_dir() and str(proj_root / "src") not in inc_set:
        inc_set.append(str(proj_root / "src"))
    elif p.parent.name == "src" and str(p.parent) not in inc_set:
        inc_set.append(str(p.parent))
    cmd = [mojo_bin, "run"]
    for inc in inc_set:
        cmd.extend(["-I", inc])
    # Link libghostty-vt.a automatically when running tests inside a pixi workspace that provides it
    ghostty_lib = proj_root / ".pixi" / "envs" / "default" / "lib" / "libghostty-vt.a"
    if ghostty_lib.is_file():
        try:
            src_txt = p.read_text(encoding="utf-8", errors="replace")
        except Exception:
            src_txt = ""
        if "from app import" in src_txt or "import app" in src_txt or "from vt import" in src_txt:
            cmd.extend(["-Xlinker", str(ghostty_lib)])
    cmd.append(str(p))
    tname = (test_name or "").strip()
    if tname:
        cmd.extend(["--only", tname])
    t0 = time.monotonic()
    try:
        proc = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=max(5, min(600, int(timeout_sec or 90))),
            cwd=str(proj_root),
        )
    except subprocess.TimeoutExpired as exc:
        return {"ok": False, "file": str(p), "timeout": True, "error": f"Timed out after {timeout_sec}s: {exc}"}
    except Exception as exc:
        return {"ok": False, "file": str(p), "error": str(exc)}
    elapsed = round(time.monotonic() - t0, 3)
    combined = (proc.stdout or "") + (proc.stderr or "")
    tests = []
    passed = 0
    failed = 0
    skipped = 0
    row_re = re.compile(r"^\s*(PASS|FAIL|SKIP)\s*\[\s*([^\]]*)\]\s*(\S+)")
    at_re = re.compile(r"^\s*At\s+(.+?\.(?:mojo|🔥)):(\d+):(\d+):\s*(.*)$")
    for raw_line in combined.splitlines():
        m = row_re.match(raw_line)
        if m:
            kind, dur, name = m.group(1), m.group(2).strip(), m.group(3).strip()
            if kind == "PASS":
                passed += 1
            elif kind == "FAIL":
                failed += 1
            else:
                skipped += 1
            tests.append({"name": name, "status": kind.lower(), "duration_s": dur, "messages": []})
            continue
        if tests and tests[-1]["status"] == "fail" and raw_line.startswith("      "):
            msg_txt = raw_line.strip()
            tests[-1]["messages"].append(msg_txt)
            am = at_re.match(raw_line)
            if am and "location" not in tests[-1]:
                tests[-1]["location"] = {
                    "file": am.group(1),
                    "line": int(am.group(2)),
                    "col": int(am.group(3)),
                    "summary": am.group(4),
                }
    ide_sync = send_ide_ipc(
        "report_test_results",
        {
            "path": str(p),
            "output": combined,
            "exit_code": proc.returncode,
            "keep_skipped": bool(tname),
        },
    )
    return {
        "ok": proc.returncode == 0 and failed == 0,
        "file": str(p),
        "test_filter": tname or None,
        "exit_code": proc.returncode,
        "elapsed_s": elapsed,
        "passed": passed,
        "failed": failed,
        "skipped": skipped,
        "tests": tests,
        "ide_synced": bool(ide_sync and ide_sync.get("ok")),
        "output": combined[-4000:].strip(),
    }


def handle_call(name: str, args: dict) -> dict:
    if name == "turbomojo_get_diagnostics":
        out = {"ide_state": read_ide_state() or {"note": "No live TurboMojo session state file yet."}}
        fp = (args or {}).get("file_path", "")
        if fp:
            out["compile_check"] = run_mojo_check(fp, (args or {}).get("include_paths") or [])
        return out
    if name == "turbomojo_get_open_editors":
        state = read_ide_state()
        if not state:
            return {"note": "No live TurboMojo session state file found yet (~/.local/state/turbomojo/ide-state.json)."}
        return {
            "pid": state.get("pid", 0),
            "ipc_dir": state.get("ipc_dir", ""),
            "project_dir": state.get("project_dir", ""),
            "active_file": state.get("active_file", ""),
            "agent_mode": state.get("agent_mode", ""),
            "agent_model": state.get("agent_model", ""),
            "editors": state.get("editors", []),
        }
    if name == "turbomojo_search_mojo_docs":
        q = (args or {}).get("query", "")
        lim = int((args or {}).get("limit", 8) or 8)
        return search_docs(q, max(1, min(25, lim)))
    if name == "turbomojo_open_location":
        p = str(Path((args or {}).get("path", "")).expanduser().resolve())
        line = max(1, int((args or {}).get("line", 1) or 1))
        col = max(1, int((args or {}).get("col", 1) or 1))
        rep = send_ide_ipc("open_location", {"path": p, "line": line, "col": col})
        if rep is not None:
            return rep
        return {"ok": False, "live": False, "note": "No live TurboMojo TUI session is currently running.", "path": p, "line": line, "col": col}
    if name == "turbomojo_get_buffer_text":
        p = Path((args or {}).get("path", "")).expanduser().resolve()
        rep = send_ide_ipc("get_buffer", {"path": str(p)})
        if rep is not None:
            return rep
        if not p.is_file():
            return {"ok": False, "error": f"File not found: {p}"}
        txt = p.read_text(encoding="utf-8", errors="replace")
        return {"ok": True, "live": False, "modified": False, "path": str(p), "lines": len(txt.splitlines()), "text": txt}
    if name == "turbomojo_apply_buffer_edits":
        p = Path((args or {}).get("path", "")).expanduser().resolve()
        edits = (args or {}).get("edits") or []
        save = bool((args or {}).get("save", False))
        rep = send_ide_ipc("apply_edits", {"path": str(p), "edits": edits, "save": save})
        if rep is not None:
            rep["live"] = True
            return rep
        if not p.is_file():
            return {"ok": False, "error": f"File not found: {p}"}
        return apply_disk_edits(p, edits)
    if name == "turbomojo_inspect_codegen":
        fp = (args or {}).get("file_path", "")
        stage = (args or {}).get("stage", "asm") or "asm"
        flt = (args or {}).get("filter_symbol", "") or ""
        incs = (args or {}).get("include_paths") or []
        return run_codegen_inspect(fp, stage, flt, incs)
    if name == "turbomojo_debug_inspect":
        expr = str((args or {}).get("expression") or "").strip()
        rep = send_ide_ipc("debug_inspect", {"expression": expr}, timeout_s=2.0)
        if rep is not None:
            return rep
        return {
            "ok": False,
            "active": False,
            "state": "offline",
            "note": "No live TurboMojo TUI session is currently running.",
        }
    if name == "turbomojo_run_test":
        fp = (args or {}).get("path", "")
        tname = (args or {}).get("test_name", "") or ""
        incs = (args or {}).get("include_paths") or []
        tsec = int((args or {}).get("timeout_sec", 90) or 90)
        return run_mojo_test_file(fp, tname, incs, tsec)
    raise ValueError(f"Unknown tool: {name}")


def send(msg: dict):
    sys.stdout.write(json.dumps(msg) + "\n")
    sys.stdout.flush()


def main():
    for raw in sys.stdin:
        line = raw.strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
        except Exception:
            continue
        method = msg.get("method")
        req_id = msg.get("id")
        if req_id is None:
            continue
        if method == "initialize":
            client_proto = (msg.get("params") or {}).get("protocolVersion", "2024-11-05")
            send({
                "jsonrpc": "2.0",
                "id": req_id,
                "result": {
                    "protocolVersion": client_proto,
                    "capabilities": {"tools": {}},
                    "serverInfo": {"name": "turbomojo-mcp", "version": "1.0.0"},
                },
            })
        elif method == "ping":
            send({"jsonrpc": "2.0", "id": req_id, "result": {}})
        elif method == "tools/list":
            send({"jsonrpc": "2.0", "id": req_id, "result": {"tools": TOOLS}})
        elif method == "resources/list":
            send({"jsonrpc": "2.0", "id": req_id, "result": {"resources": []}})
        elif method == "prompts/list":
            send({"jsonrpc": "2.0", "id": req_id, "result": {"prompts": []}})
        elif method == "tools/call":
            params = msg.get("params") or {}
            try:
                res = handle_call(params.get("name", ""), params.get("arguments") or {})
                send({
                    "jsonrpc": "2.0",
                    "id": req_id,
                    "result": {"content": [{"type": "text", "text": json.dumps(res, indent=2)}], "isError": False},
                })
            except Exception as exc:
                send({
                    "jsonrpc": "2.0",
                    "id": req_id,
                    "result": {"content": [{"type": "text", "text": str(exc)}], "isError": True},
                })
        else:
            send({"jsonrpc": "2.0", "id": req_id, "error": {"code": -32601, "message": f"Method not found: {method}"}})


if __name__ == "__main__":
    main()
