"""Remote compute targets (SSH, Docker, Apptainer, and Slurm) for executing builds,
tests, benchmarks, and GPU workloads while keeping the TUI local and responsive.

Configured in `.turbomojo.toml` or `config.toml` via `[target]` (`active = "..."`) and
`[target.<name>]` sections."""
from std.collections import List
from toml import toml_parse, T_STR, T_LIST
from util import shell_quote, basename


@fieldwise_init
struct ComputeTarget(Copyable, Movable):
    var name: String          # e.g. "local", "h100-box", "max-container", "slurm-a100"
    var kind: String          # "local", "ssh", "docker", "apptainer", "slurm"
    var host: String          # SSH hostname or user@host (also optional login node for slurm)
    var user: String          # optional SSH user
    var port: Int             # SSH port (0 = default 22)
    var remote_dir: String    # remote working directory, e.g. "/tmp/turbomojo-sync/project" or "/workspace"
    var image: String         # container image/name (docker) or .sif path (apptainer)
    var partition: String     # Slurm partition, e.g. "gpu"
    var gpus: Int             # GPU count requested (e.g. 1, 4, 8; 0 = default/all)
    var extra_args: String    # extra ssh / docker / srun flags
    var pixi_env: String      # optional remote pixi environment override


def default_local_target() -> ComputeTarget:
    """Return the built-in local machine target."""
    return ComputeTarget(
        "local",
        "local",
        "",
        "",
        0,
        "",
        "",
        "",
        0,
        "",
        "",
    )


def _rfind_dot(s: String) -> Int:
    var b = s.as_bytes()
    var i = len(b) - 1
    while i >= 0:
        if b[i] == 46:  # '.'
            return i
        i -= 1
    return -1


def _strip_trailing_slash(path: String) -> String:
    var p = String(path.strip())
    while p.byte_length() > 1 and p.endswith("/"):
        var trimmed = String(p[byte=0:p.byte_length() - 1])
        p = trimmed
    return p


def _is_safe_shell_word(s: String) -> Bool:
    if s.byte_length() == 0:
        return False
    for b in s.as_bytes():
        var c = Int(b)
        var ok = (
            (c >= 65 and c <= 90)
            or (c >= 97 and c <= 122)
            or (c >= 48 and c <= 57)
            or c == 47   # /
            or c == 46   # .
            or c == 95   # _
            or c == 45   # -
            or c == 58   # :
            or c == 64   # @
            or c == 61   # =
            or c == 43   # +
        )
        if not ok:
            return False
    return True


def _safe_or_quote(s: String) -> String:
    if _is_safe_shell_word(s):
        return s
    return shell_quote(s)


def _ssh_dest(t: ComputeTarget) -> String:
    var h = String(t.host.strip())
    var u = String(t.user.strip())
    if h.byte_length() == 0:
        return t.name
    if u.byte_length() > 0 and h.find("@") < 0:
        return u + "@" + h
    return h


def _effective_remote_dir(t: ComputeTarget, local_root: String) -> String:
    if t.remote_dir.byte_length() > 0:
        return _strip_trailing_slash(t.remote_dir)
    if local_root.byte_length() > 0:
        var base = basename(_strip_trailing_slash(local_root))
        if base.byte_length() > 0 and base != "/" and base != ".":
            return "/tmp/turbomojo-sync/" + base
        return "/tmp/turbomojo-sync/project"
    return ""


def _is_path_seg_byte(c: Int) -> Bool:
    return (
        (c >= 65 and c <= 90)
        or (c >= 97 and c <= 122)
        or (c >= 48 and c <= 57)
        or c == 95   # _
        or c == 45   # -
        or c == 46   # .
    )


def _replace_path_prefix(text: String, src_prefix: String, dst_prefix: String) -> String:
    var sp = _strip_trailing_slash(src_prefix)
    var dp = _strip_trailing_slash(dst_prefix)
    if sp.byte_length() == 0 or sp == "/" or sp == dp or text.byte_length() == 0:
        return text
    var plen = sp.byte_length()
    var tlen = text.byte_length()
    if tlen < plen or text.find(sp) < 0:
        return text
    var tb = text.as_bytes()
    var out = String("")
    var cursor = 0
    while cursor <= tlen - plen:
        var rel = String(text[byte=cursor:]).find(sp)
        if rel < 0:
            break
        var pos = cursor + rel
        var end = pos + plen
        var prev_ok = pos == 0 or not _is_path_seg_byte(Int(tb[pos - 1]))
        var next_ok = end == tlen or Int(tb[end]) == 47 or not _is_path_seg_byte(Int(tb[end]))
        if prev_ok and next_ok:
            out += String(text[byte=cursor:pos]) + dp
            cursor = end
        else:
            out += String(text[byte=cursor:pos + 1])
            cursor = pos + 1
    if cursor < tlen:
        out += String(text[byte=cursor:])
    return out


def _apply_pixi_env_override(cmd: String, pixi_env: String) -> String:
    var env = String(pixi_env.strip())
    if env.byte_length() == 0 or env == "default":
        return cmd
    var qenv = _safe_or_quote(env)
    for sub in ["pixi run", "pixi exec"]:
        var prefix = String(sub)
        var with_flag = prefix + " -e "
        if cmd.startswith(with_flag):
            var rest = String(cmd[byte=with_flag.byte_length():])
            var sp = rest.find(" ")
            if sp > 0:
                var after_env = String(rest[byte=sp:])
                return with_flag + qenv + after_env
        elif cmd.startswith(prefix + " "):
            var after_sub = String(cmd[byte=prefix.byte_length() + 1:])
            return with_flag + qenv + " " + after_sub
    return cmd


def _prepare_inner_cmd(t: ComputeTarget, local_root: String, rdir: String, inner_cmd: String) -> String:
    var cmd = inner_cmd
    if local_root.byte_length() > 0 and rdir.byte_length() > 0:
        cmd = _replace_path_prefix(cmd, local_root, rdir)
    cmd = _apply_pixi_env_override(cmd, t.pixi_env)
    return cmd


def parse_compute_targets(toml_text: String) -> Tuple[String, List[ComputeTarget]]:
    """Parse `[target]` (`active = "..."`) and `[target.<name>]` tables from config TOML.
    Always places `default_local_target()` at index 0 and falls back `active` to `"local"`."""
    var targets = List[ComputeTarget]()
    targets.append(default_local_target())
    var doc = toml_parse(toml_text)
    var active = String(doc.get_str("target.active", "local").strip())
    if active.byte_length() == 0:
        active = "local"

    var seen = List[String]()
    seen.append("local")
    for key in doc.keys_in("target"):
        var dot = _rfind_dot(key)
        if dot <= 0:
            continue
        var tname = String(String(key[byte=0:dot]).strip())
        if tname.byte_length() == 0 or (tname in seen):
            continue
        seen.append(tname)

        var p = "target." + tname + "."
        var kind = String(doc.get_str(p + "kind", "").strip()).lower()
        var host = String(doc.get_str(p + "host", "").strip())
        var user = String(doc.get_str(p + "user", "").strip())
        var port = max(0, doc.get_int(p + "port", 0))
        var remote_dir = String(doc.get_str(p + "remote_dir", "").strip())
        var image = String(doc.get_str(p + "image", "").strip())
        var partition = String(doc.get_str(p + "partition", "").strip())
        var gpus = doc.get_int(p + "gpus", 0)
        var extra_args = String("")
        var ei = doc.find(p + "extra_args")
        if ei >= 0:
            if doc.vals[ei].kind == T_STR:
                extra_args = String(doc.vals[ei].s.strip())
            elif doc.vals[ei].kind == T_LIST:
                extra_args = " ".join(doc.vals[ei].items)
        var pixi_env = String(doc.get_str(p + "pixi_env", "").strip())

        if kind.byte_length() == 0:
            if partition.byte_length() > 0:
                kind = "slurm"
            elif image.endswith(".sif"):
                kind = "apptainer"
            elif image.byte_length() > 0:
                kind = "docker"
            elif host.byte_length() > 0:
                kind = "ssh"
            else:
                kind = "local"

        targets.append(
            ComputeTarget(
                tname,
                kind,
                host,
                user,
                port,
                remote_dir,
                image,
                partition,
                gpus,
                extra_args,
                pixi_env,
            )
        )

    var found_active = False
    for i in range(len(targets)):
        if targets[i].name == active:
            found_active = True
            break
    if not found_active:
        active = "local"

    return (active, targets^)


def target_status_pill(t: ComputeTarget) -> String:
    """Compact status-bar badge for remote targets (empty string for local)."""
    if t.kind == "local" or t.name == "local":
        return ""
    if t.kind == "ssh":
        return "[target:ssh:" + _ssh_dest(t) + "]"
    if t.kind == "docker":
        return "[target:docker:" + t.name + "]"
    if t.kind == "apptainer":
        return "[target:apptainer:" + t.name + "]"
    if t.kind == "slurm":
        var label = t.partition if t.partition.byte_length() > 0 else t.name
        var g = (":" + String(t.gpus) + "g") if t.gpus > 0 else String("")
        return "[target:slurm:" + label + g + "]"
    return "[target:" + t.kind + ":" + t.name + "]"


def build_remote_sync_cmd(t: ComputeTarget, local_root: String) -> String:
    """Build an `rsync` workspace sync command for `ssh` (and remote `slurm` login nodes).
    Returns `""` for `local` or bind-mounted `docker` / `apptainer` targets."""
    if t.kind == "local" or t.name == "local":
        return ""
    if t.kind != "ssh" and t.kind != "slurm":
        return ""
    if t.host.byte_length() == 0 or local_root.byte_length() == 0:
        return ""

    var src_root = _strip_trailing_slash(local_root)
    var rdir = _effective_remote_dir(t, src_root)
    if rdir.byte_length() == 0:
        return ""

    var dest = _ssh_dest(t)
    var ssh_opts = String("")
    if t.port > 0:
        ssh_opts += " -p " + String(t.port)
    if t.kind == "ssh" and t.extra_args.byte_length() > 0:
        ssh_opts += " " + String(t.extra_args.strip())

    var mkdir_cmd = "ssh" + ssh_opts + " " + _safe_or_quote(dest) + " " + shell_quote("mkdir -p " + _safe_or_quote(rdir))
    var rsync_cmd = String("rsync -az --delete --exclude '.git' --exclude '.pixi' --exclude 'build'")
    if ssh_opts.byte_length() > 0:
        rsync_cmd += " -e " + shell_quote("ssh" + ssh_opts)
    rsync_cmd += " " + shell_quote(src_root + "/") + " " + shell_quote(dest + ":" + rdir + "/")
    return mkdir_cmd + " && " + rsync_cmd


def wrap_target_command(
    t: ComputeTarget,
    local_root: String,
    inner_cmd: String,
    sync_first: Bool = True,
) -> String:
    """Wrap `inner_cmd` for execution on `t` (`local`, `ssh`, `docker`, `apptainer`, `slurm`)."""
    if t.kind == "local" or t.name == "local":
        return inner_cmd

    if t.kind == "ssh":
        var rdir = _effective_remote_dir(t, local_root)
        var rcmd = _prepare_inner_cmd(t, local_root, rdir, inner_cmd)
        var payload = ("cd " + _safe_or_quote(rdir) + " && " + rcmd) if rdir.byte_length() > 0 else rcmd
        var ssh_cmd = String("ssh")
        if t.port > 0:
            ssh_cmd += " -p " + String(t.port)
        if t.extra_args.byte_length() > 0:
            ssh_cmd += " " + String(t.extra_args.strip())
        ssh_cmd += " " + _safe_or_quote(_ssh_dest(t)) + " " + shell_quote(payload)
        if sync_first:
            var sync_cmd = build_remote_sync_cmd(t, local_root)
            if sync_cmd.byte_length() > 0:
                return sync_cmd + " && " + ssh_cmd
        return ssh_cmd

    if t.kind == "docker":
        var rdir = _strip_trailing_slash(t.remote_dir) if t.remote_dir.byte_length() > 0 else String("/workspace")
        var lroot = _strip_trailing_slash(local_root) if local_root.byte_length() > 0 else String(".")
        var img = t.image if t.image.byte_length() > 0 else t.name
        var rcmd = _prepare_inner_cmd(t, local_root, rdir, inner_cmd)
        if t.host == "exec":
            var exec_cmd = "docker exec -w " + _safe_or_quote(rdir)
            if t.extra_args.byte_length() > 0:
                exec_cmd += " " + String(t.extra_args.strip())
            exec_cmd += " " + _safe_or_quote(img) + " bash -lc " + shell_quote(rcmd)
            return exec_cmd
        var run_cmd = String("docker run --rm")
        if t.gpus > 0:
            run_cmd += " --gpus " + String(t.gpus)
        elif t.gpus == 0:
            run_cmd += " --gpus all"
        run_cmd += " -v " + _safe_or_quote(lroot + ":" + rdir) + " -w " + _safe_or_quote(rdir)
        if t.extra_args.byte_length() > 0:
            run_cmd += " " + String(t.extra_args.strip())
        run_cmd += " " + _safe_or_quote(img) + " bash -lc " + shell_quote(rcmd)
        return run_cmd

    if t.kind == "apptainer":
        var rdir = _strip_trailing_slash(t.remote_dir) if t.remote_dir.byte_length() > 0 else String("/workspace")
        var lroot = _strip_trailing_slash(local_root) if local_root.byte_length() > 0 else String(".")
        var img = t.image if t.image.byte_length() > 0 else t.name
        var rcmd = _prepare_inner_cmd(t, local_root, rdir, inner_cmd)
        var app_cmd = "apptainer exec --nv --bind " + _safe_or_quote(lroot + ":" + rdir) + " --pwd " + _safe_or_quote(rdir)
        if t.extra_args.byte_length() > 0:
            app_cmd += " " + String(t.extra_args.strip())
        app_cmd += " " + _safe_or_quote(img) + " bash -lc " + shell_quote(rcmd)
        return app_cmd

    if t.kind == "slurm":
        var srun_cmd = String("srun")
        if t.partition.byte_length() > 0:
            srun_cmd += " --partition=" + _safe_or_quote(t.partition)
        if t.gpus > 0:
            srun_cmd += " --gpus=" + String(t.gpus)
        if t.extra_args.byte_length() > 0:
            srun_cmd += " " + String(t.extra_args.strip())
        if t.host.byte_length() > 0:
            var rdir = _effective_remote_dir(t, local_root)
            var rcmd = _prepare_inner_cmd(t, local_root, rdir, inner_cmd)
            srun_cmd += " bash -lc " + shell_quote(rcmd)
            var payload = ("cd " + _safe_or_quote(rdir) + " && " + srun_cmd) if rdir.byte_length() > 0 else srun_cmd
            var ssh_cmd = String("ssh")
            if t.port > 0:
                ssh_cmd += " -p " + String(t.port)
            ssh_cmd += " " + _safe_or_quote(_ssh_dest(t)) + " " + shell_quote(payload)
            if sync_first:
                var sync_cmd = build_remote_sync_cmd(t, local_root)
                if sync_cmd.byte_length() > 0:
                    return sync_cmd + " && " + ssh_cmd
            return ssh_cmd
        var local_rdir = _strip_trailing_slash(t.remote_dir) if t.remote_dir.byte_length() > 0 else String("")
        var rcmd = _prepare_inner_cmd(t, local_root, local_rdir, inner_cmd)
        var inner_payload = ("cd " + _safe_or_quote(local_rdir) + " && " + rcmd) if local_rdir.byte_length() > 0 else rcmd
        srun_cmd += " bash -lc " + shell_quote(inner_payload)
        return srun_cmd

    return inner_cmd


def remap_remote_output_paths(t: ComputeTarget, local_root: String, output: String) -> String:
    """Rewrite remote workspace prefixes (`t.remote_dir`) in compiler diagnostics and
    tracebacks back to `local_root` so jump-to-error opens local files seamlessly."""
    if t.kind == "local" or t.name == "local":
        return output
    if t.remote_dir.byte_length() == 0 or local_root.byte_length() == 0 or output.byte_length() == 0:
        return output
    return _replace_path_prefix(output, t.remote_dir, local_root)


def format_target_picker_label(t: ComputeTarget, is_active: Bool) -> String:
    """Format a human-readable row for the `D_SELECT_TARGET` compute target picker."""
    var mark = "* " if is_active else "  "
    if t.kind == "local" or t.name == "local":
        return mark + t.name + " (this machine)"
    if t.kind == "ssh":
        var dest = _ssh_dest(t)
        if t.port > 0:
            dest += ":" + String(t.port)
        var rdir = _strip_trailing_slash(t.remote_dir)
        var loc = dest + ((":" + rdir) if rdir.byte_length() > 0 else String(""))
        var g = (" · " + String(t.gpus) + "g") if t.gpus > 0 else String("")
        return mark + t.name + "  [ssh -> " + loc + g + "]"
    if t.kind == "docker":
        var arrow = "docker exec -> " if t.host == "exec" else "docker -> "
        var img = t.image if t.image.byte_length() > 0 else t.name
        var g = (" · " + String(t.gpus) + "g") if t.gpus > 0 else String("")
        return mark + t.name + "  [" + arrow + img + g + "]"
    if t.kind == "apptainer":
        var img = t.image if t.image.byte_length() > 0 else t.name
        return mark + t.name + "  [apptainer -> " + img + "]"
    if t.kind == "slurm":
        var part = t.partition if t.partition.byte_length() > 0 else String("default")
        var via = (_ssh_dest(t) + ":") if t.host.byte_length() > 0 else String("")
        var g = (" · " + String(t.gpus) + "g") if t.gpus > 0 else String("")
        return mark + t.name + "  [slurm -> " + via + part + g + "]"
    return mark + t.name + "  [" + t.kind + "]"
