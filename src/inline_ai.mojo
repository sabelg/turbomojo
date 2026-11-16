"""Inline AI Transform (`Ctrl-Alt-I` / `CM_INLINE_AI`), Closed-Loop Mojo 1.2 Compiler
Auto-Verification ("Verified Patch Mode"), and Local `max serve` FIM Ghost-Text Client.

Supports any OpenAI-compatible HTTP endpoint (`max serve`, `vLLM`, `llama.cpp`, `ollama`,
or cloud endpoints via `[ai]` in `.turbomojo.toml`) with zero Python dependencies.
"""
from std.collections import List
from json import json_parse, json_quote, J_ARR, J_OBJ
from signals import own_pid
from swap import delete_file
from util import (
    decode,
    to_str,
    slice_str,
    is_ident,
    shell_quote,
    run_capture,
    write_file,
    str_bytes,
    bytes_to_str,
    env_or,
    basename,
    dirname,
)


comptime MOJO12_SYSTEM_PROMPT = (
    "You are TurboMojo's inline code transformer for Mojo 1.2.0 and Python. "
    "Output ONLY the replacement code for the target region (no prose, no explanations). "
    "When generating Mojo 1.2 code, strictly obey: "
    "1) Use `def` for all functions/methods (`fn` was removed); put `raises` before `->`. "
    "2) Use `comptime` (`alias` and `@parameter` were removed). "
    "3) Declare variables with `var` (`let` was removed). "
    "4) Use `mut` (`inout` removed), `var` (`owned` removed), and `out self` in `__init__`. "
    "5) Use `@fieldwise_init` with explicit traits `(Copyable, Movable)` (`@value` removed). "
    "6) Prefix stdlib imports with `std.` (`from std.collections import List`)."
)


@fieldwise_init
struct VerifiedPatchResult(Copyable, Movable):
    var ok: Bool
    var compiler_verified: Bool
    var attempts: Int
    var replacement: String
    var diagnostics: String


def extract_code_block_from_ai(raw: String) -> String:
    """Extract clean code from an LLM response, stripping optional markdown ``` fences."""
    var s = String(raw.strip())
    if s.byte_length() == 0:
        return ""
    var fence = s.find("```")
    if fence >= 0:
        var nl = s.find("\n", fence + 3)
        if nl >= 0:
            var close_f = s.find("```", nl + 1)
            if close_f > nl:
                var inner = String(s[byte=nl + 1 : close_f])
                if inner.endswith("\n"):
                    var trimmed = String(inner[byte=0 : inner.byte_length() - 1])
                    inner = trimmed
                return inner
    return s


def build_inline_transform_prompt(
    path: String,
    prefix_context: String,
    selected_code: String,
    suffix_context: String,
    instruction: String,
) -> String:
    """Build a structured user prompt for inline selection/line transformation."""
    return (
        "File: " + basename(path) + "\n"
        "Instruction: " + instruction + "\n\n"
        "--- Context Before ---\n"
        + prefix_context
        + "\n--- Target Region To Replace ---\n"
        + selected_code
        + "\n--- Context After ---\n"
        + suffix_context
        + "\n\nReturn ONLY the replacement code for `Target Region To Replace`."
    )


def build_repair_prompt(
    path: String,
    instruction: String,
    broken_candidate: String,
    compiler_errors: String,
) -> String:
    """Build a self-healing repair prompt feeding `mojo build` diagnostics back to the model."""
    return (
        "Your previous Mojo replacement for `" + basename(path) + "` failed `mojo build` verification.\n"
        "Original instruction: " + instruction + "\n\n"
        "--- Candidate Code That Failed ---\n"
        + broken_candidate
        + "\n\n--- Mojo 1.2.0 Compiler Diagnostics ---\n"
        + compiler_errors
        + "\n\nFix every compiler error above using valid Mojo 1.2.0 syntax (`def`, `comptime`, `var`, "
        "`mut`, `out self`, `@fieldwise_init`, `std.` imports) and return ONLY the corrected replacement code."
    )


def parse_openai_response_text(raw_json: String) -> String:
    """Extract assistant content or completion text from an OpenAI-compatible JSON payload
    (`/v1/chat/completions` or `/v1/completions`)."""
    var doc = json_parse(raw_json)
    if not doc.ok or doc.kind(0) != J_OBJ:
        return ""
    var choices = doc.get(0, "choices")
    if doc.kind(choices) != J_ARR:
        return ""
    var kids = doc.children(choices)
    if len(kids) == 0:
        return ""
    var c0 = kids[0]
    var msg = doc.get(c0, "message")
    if doc.kind(msg) == J_OBJ:
        var content = doc.str(doc.get(msg, "content"), "")
        if content.byte_length() > 0:
            return content
    return doc.str(doc.get(c0, "text"), "")


def query_openai_chat(
    endpoint: String,
    model: String,
    system_prompt: String,
    user_prompt: String,
    api_key: String = "",
    timeout_sec: Int = 20,
) -> Tuple[Bool, String]:
    """Query an OpenAI-compatible `/v1/chat/completions` endpoint (`max serve`, `vLLM`, `ollama`)."""
    var url = String(endpoint.strip())
    if url.byte_length() == 0:
        return (False, "No [ai] endpoint configured")
    var is_cmd_ep = url.startswith("cmd:")
    if not is_cmd_ep and not url.endswith("/chat/completions") and not url.endswith("/completions"):
        if url.endswith("/"):
            var u_trim = String(url[byte=0 : url.byte_length() - 1])
            url = u_trim
        if url.endswith("/v1"):
            url += "/chat/completions"
        else:
            url += "/v1/chat/completions"
    var mdl = model if model.byte_length() > 0 else String("modularai/Llama-3.1-8B-Instruct-GGUF")
    var payload = (
        "{\"model\":"
        + json_quote(mdl)
        + ",\"temperature\":0.1,\"messages\":[{\"role\":\"system\",\"content\":"
        + json_quote(system_prompt)
        + "},{\"role\":\"user\",\"content\":"
        + json_quote(user_prompt)
        + "}]}"
    )
    var key = api_key if api_key.byte_length() > 0 else env_or("OPENAI_API_KEY", env_or("MAX_API_KEY", ""))
    var auth_arg = (" -H " + shell_quote("Authorization: Bearer " + key)) if key.byte_length() > 0 else String("")
    var req_file = env_or("TMPDIR", "/tmp") + "/turbomojo-ai-req-" + String(own_pid()) + ".json"
    if not write_file(req_file, str_bytes(payload)):
        return (False, "Could not write AI request payload")
    var cmd: String
    if is_cmd_ep:
        cmd = String(url[byte=4:].strip()) + " < " + shell_quote(req_file) + " 2>&1"
    else:
        cmd = (
            "curl -sS --max-time "
            + String(max(2, timeout_sec))
            + " -H 'Content-Type: application/json'"
            + auth_arg
            + " -d @"
            + shell_quote(req_file)
            + " "
            + shell_quote(url)
            + " 2>&1"
        )
    var res = run_capture(cmd)
    delete_file(req_file)
    var out_txt = bytes_to_str(res.out)
    if res.status != 0:
        return (False, String(out_txt.strip()))
    var parsed = parse_openai_response_text(out_txt)
    if parsed.byte_length() == 0:
        return (False, "Empty or unrecognized AI response: " + String(out_txt.strip()))
    return (True, extract_code_block_from_ai(parsed))


def splice_lines_preview(
    all_lines: List[String],
    r1: Int,
    r2: Int,
    replacement: String,
) -> String:
    """Splice `replacement` in place of inclusive line range `[r1..r2]` of `all_lines`."""
    var out = List[String]()
    var n = len(all_lines)
    for i in range(min(max(0, r1), n)):
        out.append(all_lines[i])
    for s in replacement.split("\n"):
        out.append(String(s))
    for i in range(max(0, r2 + 1), n):
        out.append(all_lines[i])
    return "\n".join(out) + "\n"


def shadow_compile_check_mojo(
    original_path: String,
    candidate_full_source: String,
    mojo_cmd: String,
    include_flags: String,
) -> Tuple[Bool, String]:
    """Compile-verify `candidate_full_source` with `mojo build --emit=llvm` (fast semantic + IR
    typecheck without slow native linker overhead) and return `(ok, diagnostics)`."""
    var work_dir = dirname(original_path) if original_path.byte_length() > 0 else String("/tmp")
    var pid_s = String(own_pid())
    var shadow_src = env_or("TMPDIR", "/tmp") + "/turbomojo-verify-" + pid_s + ".mojo"
    var shadow_ll = env_or("TMPDIR", "/tmp") + "/turbomojo-verify-" + pid_s + ".ll"
    var verify_body = candidate_full_source
    if ("\n" + verify_body).find("\ndef main(") < 0:
        verify_body += "\n\ndef main():\n    pass\n"
    if not write_file(shadow_src, str_bytes(verify_body)):
        return (False, "Could not write shadow verification buffer")
    var inc = " -I " + shell_quote(work_dir) + include_flags
    var cmd = (
        "cd "
        + shell_quote(work_dir)
        + " && "
        + mojo_cmd
        + " build --emit=llvm"
        + inc
        + " "
        + shell_quote(shadow_src)
        + " -o "
        + shell_quote(shadow_ll)
        + " 2>&1"
    )
    var r = run_capture(cmd)
    delete_file(shadow_src)
    delete_file(shadow_ll)
    var diag = bytes_to_str(r.out).replace(shadow_src, basename(original_path) if original_path.byte_length() > 0 else String("buffer.mojo"))
    return (r.status == 0, String(diag.strip()))


def run_verified_inline_transform(
    endpoint: String,
    model: String,
    path: String,
    all_lines: List[String],
    r1: Int,
    r2: Int,
    instruction: String,
    verify_mojo: Bool,
    mojo_cmd: String,
    include_flags: String,
    max_retries: Int = 2,
) -> VerifiedPatchResult:
    """Execute an inline AI code transform and, when `verify_mojo` is enabled on a `.mojo` file,
    compile-check the spliced result with `mojo build` and self-heal up to `max_retries` times."""
    var n = len(all_lines)
    var pre_lines = List[String]()
    for i in range(max(0, r1 - 20), max(0, min(r1, n))):
        pre_lines.append(all_lines[i])
    var sel_lines = List[String]()
    for i in range(max(0, r1), min(n, r2 + 1)):
        sel_lines.append(all_lines[i])
    var suf_lines = List[String]()
    for i in range(min(n, r2 + 1), min(n, r2 + 21)):
        suf_lines.append(all_lines[i])

    var prompt = build_inline_transform_prompt(
        path,
        "\n".join(pre_lines),
        "\n".join(sel_lines),
        "\n".join(suf_lines),
        instruction,
    )
    var res = query_openai_chat(endpoint, model, MOJO12_SYSTEM_PROMPT, prompt)
    if not res[0]:
        return VerifiedPatchResult(False, False, 1, "", res[1])

    var candidate = res[1]
    if not verify_mojo:
        return VerifiedPatchResult(True, False, 1, candidate, "")

    var attempts = 1
    var chk = shadow_compile_check_mojo(
        path,
        splice_lines_preview(all_lines, r1, r2, candidate),
        mojo_cmd,
        include_flags,
    )
    if chk[0]:
        return VerifiedPatchResult(True, True, attempts, candidate, "")

    var last_diag = chk[1]
    while attempts <= max_retries:
        attempts += 1
        var rep_prompt = build_repair_prompt(path, instruction, candidate, last_diag)
        var rep_res = query_openai_chat(endpoint, model, MOJO12_SYSTEM_PROMPT, rep_prompt)
        if not rep_res[0]:
            break
        candidate = rep_res[1]
        var chk2 = shadow_compile_check_mojo(
            path,
            splice_lines_preview(all_lines, r1, r2, candidate),
            mojo_cmd,
            include_flags,
        )
        if chk2[0]:
            return VerifiedPatchResult(True, True, attempts, candidate, "")
        last_diag = chk2[1]

    return VerifiedPatchResult(True, False, attempts, candidate, last_diag)


def build_fim_curl_command(
    fim_endpoint: String,
    model: String,
    prefix: String,
    suffix: String,
    req_file: String,
) -> String:
    """Write an OpenAI-compatible FIM completion payload to `req_file` and return the non-blocking
    shell command that queries `fim_endpoint` (`max serve` / `vLLM` / `ollama`)."""
    var url = String(fim_endpoint.strip())
    var is_cmd_fim = url.startswith("cmd:")
    if not is_cmd_fim and not url.endswith("/completions") and not url.endswith("/chat/completions"):
        if url.endswith("/"):
            var ut = String(url[byte=0 : url.byte_length() - 1])
            url = ut
        if url.endswith("/v1"):
            url += "/chat/completions"
        else:
            url += "/v1/chat/completions"
    var mdl = model if model.byte_length() > 0 else String("modularai/Llama-3.1-8B-Instruct-GGUF")
    var payload: String
    if url.endswith("/chat/completions"):
        var sys_p = (
            "Complete the single line of code at `<CURSOR>`. "
            "Output ONLY the exact characters to insert at `<CURSOR>` (single line, no markdown, no repeating prefix)."
        )
        var usr_p = prefix + "<CURSOR>" + suffix
        payload = (
            "{\"model\":"
            + json_quote(mdl)
            + ",\"temperature\":0.0,\"max_tokens\":64,\"messages\":[{\"role\":\"system\",\"content\":"
            + json_quote(sys_p)
            + "},{\"role\":\"user\",\"content\":"
            + json_quote(usr_p)
            + "}]}"
        )
    else:
        var fim_prompt = "<|fim_prefix|>" + prefix + "<|fim_suffix|>" + suffix + "<|fim_middle|>"
        payload = (
            "{\"model\":"
            + json_quote(mdl)
            + ",\"temperature\":0.0,\"max_tokens\":64,\"stop\":[\"\\n\"],\"prompt\":"
            + json_quote(fim_prompt)
            + "}"
        )
    _ = write_file(req_file, str_bytes(payload))
    if is_cmd_fim:
        return String(url[byte=4:].strip()) + " < " + shell_quote(req_file) + " 2>/dev/null"
    var key = env_or("OPENAI_API_KEY", env_or("MAX_API_KEY", ""))
    var auth_arg = (" -H " + shell_quote("Authorization: Bearer " + key)) if key.byte_length() > 0 else String("")
    return (
        "curl -sS --max-time 4 -H 'Content-Type: application/json'"
        + auth_arg
        + " -d @"
        + shell_quote(req_file)
        + " "
        + shell_quote(url)
        + " 2>/dev/null"
    )


def sanitize_fim_ghost_text(raw: String, line_suffix: String = "") -> String:
    """Clean single-line FIM completion text for inline ghost rendering at EOL."""
    var s = extract_code_block_from_ai(raw)
    var nl = s.find("\n")
    if nl >= 0:
        var first_l = String(s[byte=0:nl])
        s = first_l
    if s.endswith("\r"):
        var no_cr = String(s[byte=0 : s.byte_length() - 1])
        s = no_cr
    if line_suffix.byte_length() > 0 and s.endswith(line_suffix):
        var cut = String(s[byte=0 : s.byte_length() - line_suffix.byte_length()])
        s = cut
    return s


def ghost_accept_word(ghost: String) -> Tuple[String, String]:
    """Split `ghost` into `(next_word_chunk, remainder)` for `Ctrl-Right` partial acceptance."""
    var cps = decode(ghost)
    var n = len(cps)
    if n == 0:
        return ("", "")
    var i = 0
    # Include leading spaces
    while i < n and (cps[i] == 32 or cps[i] == 9):
        i += 1
    if i < n and is_ident(cps[i]):
        while i < n and is_ident(cps[i]):
            i += 1
    elif i < n:
        i += 1
    return (slice_str(cps, 0, i), slice_str(cps, i, n))
