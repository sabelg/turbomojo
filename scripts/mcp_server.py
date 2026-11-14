#!/usr/bin/env python3
"""MCP stdio server exposing live TurboMojo IDE state, Mojo compiler diagnostics,
and offline Mojo 1.2 documentation search to coding agents (e.g. `agy acp`)."""
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

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
