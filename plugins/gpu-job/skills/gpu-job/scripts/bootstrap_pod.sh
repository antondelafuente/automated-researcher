#!/bin/bash
# bootstrap_pod.sh — run ON the pod (first ssh). Minimal, provider-image-agnostic:
# 1) installs rclone if absent and materializes your injected rclone config, so jobs can
#    persist artifacts to YOUR store; 2) pulls an optional identity/env bundle
#    (<remote>/gpu-job/bundle.tar) if you've staged one (e.g. agent auth, .gitconfig); 3)
#    persists every deploy_pod.py PASS_ENV var so LATER ssh sessions can see it too (see
#    _persist_passed_env below — automated-researcher #341).
set -euo pipefail

_proc1_get(){ # _proc1_get <environ-file> <name> — <name>'s value from a NUL-separated KEY=VALUE
              # environ file (e.g. /proc/1/environ — PID 1's env is the one place guaranteed to
              # hold every var RunPod/deploy_pod.py injected into THIS container, regardless of
              # whether the ssh session running bootstrap itself inherited it). Empty if
              # absent/unreadable; never errors (safe under `set -e` at every call site). Uses
              # awk's `printf` (not `print`) so it never appends a newline of its own — a caller
              # that needs to detect a value's OWN trailing newline(s) (see the read/printf '\0'
              # idiom at its call site below) would otherwise be checking an artifact `print`
              # added, not the real content (code-review Finding: command-substitution's universal
              # trailing-newline strip was masking this, silently turning a would-be-rejected
              # trailing-newline value into a truncated one instead).
  awk -v k="$2" 'BEGIN{RS="\0"} index($0, k"=")==1{printf "%s", substr($0, length(k)+2); exit}' "$1" 2>/dev/null || true
}

_shell_quote(){ # _shell_quote <value> — bash-single-quote-safe iff VALUE contains a character that
                # would otherwise change meaning when a later `source /workspace/.env` re-parses
                # this line (space, `"`, `$`, backtick, `\`, ...); left bare for a plain
                # alnum/`_.:/@+,=-`-only value so the common case (API keys, paths) round-trips
                # byte-for-byte through job_lib.sh's env_get, which only strips ONE optional
                # leading/trailing quote char rather than doing full shell-unescaping.
  case "$1" in
    *[!A-Za-z0-9_.:/@+=,-]*) printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")" ;;
    *) printf '%s' "$1" ;;
  esac
}

_drop_kv(){ # _drop_kv <file> <name> — remove any existing `^name=` line from <file>, in-memory
            # capture + truncate-in-place (never a `.tmp.$$` sibling — see _persist_kv's header for
            # why), so <file>'s own permission bits survive since nothing but <file> is ever
            # written. Used both by _persist_kv (to drop a stale value before writing the current
            # one) and directly by every skip path below: the invariant this establishes is that a
            # file never serves a value for a name that is no longer that name's CURRENT PASS_ENV
            # value — a skip is a skip everywhere, not a silent fallback to a stale credential
            # (code-review Finding, round 4: rotating a bare-safe value to a PAM-unsafe one left the
            # OLD value active in /etc/environment forever, since only the workspace file's entry
            # was ever replaced on that path). `|| rest=""` matters: `grep -v` exits 1 when every
            # line matched, which would trip `set -e`; a plain variable is safe here since these are
            # small KV files and a value containing a newline is already rejected upstream.
  local file=$1 name=$2 rest
  if [ -e "$file" ] && grep -q "^${name}=" "$file" 2>/dev/null; then
    rest=$(grep -v "^${name}=" "$file") || rest=""
    if [ -n "$rest" ]; then printf '%s\n' "$rest" > "$file"; else : > "$file"; fi
  fi
}

_persist_kv(){ # _persist_kv <file> <name> <name=value line> — replace any existing `^name=` line in
               # <file> with <line> (via _drop_kv, so a stale value from an earlier
               # bootstrap/experiment can't shadow the CURRENT PASS_ENV value — code-review Finding:
               # the old grep -q-guarded append only ever wrote a name's FIRST value, so a reused
               # <file>, e.g. one that outlives pod teardown on a mounted persistent volume, or a
               # plain repeated bootstrap on the same pod, kept the OLD credential forever instead of
               # picking up a rotated one). _drop_kv's in-memory rewrite means no on-disk
               # intermediate ever exists holding the OTHER surviving secrets at a world-readable
               # mode, and nothing is left orphaned if the script dies mid-rewrite (code-review
               # Finding: a bare `> "${file}.tmp.$$"` redirect created that temp file at the
               # process's default umask — 644 under the common 022 — exposing every other persisted
               # secret during each replacement, and it stayed on disk on a crash).
  local file=$1 name=$2 line=$3
  _drop_kv "$file" "$name"
  # Ensure a separating newline before the append: appending directly onto a file whose last byte
  # isn't a newline concatenates onto the previous line instead of starting a new one (code-review
  # Finding: a file ending `OLD=x` with no trailing newline became `OLD=xNEW_SECRET=value` on
  # append, so neither `source` nor `env_get NEW_SECRET` could see the new var). `$(tail -c1 file)`
  # reads empty iff the last byte already is a newline, since command substitution strips it.
  if [ -s "$file" ] && [ -n "$(tail -c 1 "$file")" ]; then printf '\n' >> "$file"; fi
  printf '%s\n' "$line" >> "$file"
}

_persist_passed_env(){ # _persist_passed_env <environ-file> [workspace-env=/workspace/.env]
  # [etc-environment=/etc/environment] [is-root=auto] — generalizes the R2-only env persistence
  # below to ANY var deploy_pod.py injected via PASS_ENV (#341: TINKER_API_KEY/HF_TOKEN/etc were
  # silently absent from every job-launch ssh session, costing a diagnose-and-relaunch cycle
  # each). deploy_pod.py's pod_env() writes PASSED_ENV_NAMES alongside the real vars — bootstrap
  # has no other record of what was in PASS_ENV. Writes each to <workspace-env> (the
  # `source /workspace/.env`-per-launch-script fallback convention; job_lib.sh's env_get already
  # reads this file), single-quoted via _shell_quote so a value containing shell metacharacters
  # is a literal string when sourced rather than executed (code-review Finding: unescaped values
  # corrupt/inject on `source`) — and, on a root pod, to <etc-environment> too, but ONLY when the
  # value is bare-safe (i.e. _shell_quote left it unquoted): /etc/environment is parsed by PAM, not
  # a shell, and PAM's format has no escape syntax whatsoever, so a quoted value like
  # `QUOTE_VAR='it'\''s a token'` is bash string-concatenation syntax PAM can't parse — it truncates
  # the value or drops the line (code-review Finding). A value that needs quoting is skipped for
  # <etc-environment> with a loud stderr note and still persisted to <workspace-env> only; the
  # bare-safe class (`A-Za-z0-9_.:/@+=,-`) covers every PASS_ENV value seen in practice (API keys,
  # paths) and contains no character PAM treats specially, so this is a deliberate narrowing of what
  # the PAM path carries, not an encoding gap to close later. Since PAM applies /etc/environment to
  # every later non-interactive `ssh pod 'cmd'` with no per-script source to forget (same pattern
  # the RCLONE_MULTI_THREAD_* write below already uses), it stays the PRIMARY mechanism for the
  # values it can carry. Both files are chmod 600 immediately, <etc-environment> included — the
  # issue's own "persisting to a root-only file doesn't broaden exposure" non-goal only holds if
  # that file actually IS root-only, and /etc/environment's normal mode is world-readable
  # (code-review Finding: only <workspace-env> was locked down, leaving the PRIMARY mechanism's
  # file readable by any user on the pod instead of just root).
  local environ_file=$1 workspace_env=${2:-/workspace/.env} etc_env=${3:-/etc/environment} is_root=${4:-}
  [ -n "$is_root" ] || { [ "$(id -u)" = 0 ] && is_root=1 || is_root=0; }
  local names name val qval old_ifs
  names=$(_proc1_get "$environ_file" PASSED_ENV_NAMES)
  [ -n "$names" ] || return 0
  mkdir -p "$(dirname "$workspace_env")"
  [ -e "$workspace_env" ] || : > "$workspace_env"
  # Fail closed (AGENTS.md's scale principle: "trust gates stay fail-closed") rather than silently
  # persisting secrets into a file whose mode we couldn't lock down (code-review Finding: a
  # pre-existing root-owned, caller-writable-but-not-chmod-able file let `chmod 600 ... || true`
  # swallow the failure and a secret land in a world-readable file). On RunPod's stock images both
  # chmods succeed, so this costs nothing in the case #341 was filed for.
  if ! chmod 600 "$workspace_env" 2>/dev/null; then
    echo "[bootstrap] cannot chmod 600 $workspace_env; refusing to persist PASS_ENV values there" >&2
    workspace_env=""
  fi
  if [ "$is_root" = 1 ]; then
    mkdir -p "$(dirname "$etc_env")"
    [ -e "$etc_env" ] || : > "$etc_env"
    if ! chmod 600 "$etc_env" 2>/dev/null; then
      echo "[bootstrap] cannot chmod 600 $etc_env; skipping /etc/environment persistence" >&2
      is_root=0
    fi
  fi
  if [ -z "$workspace_env" ] && [ "$is_root" != 1 ]; then
    echo "[bootstrap] no destination with enforceable root-only permissions; PASS_ENV vars not persisted" >&2
    return 0
  fi
  old_ifs=$IFS; IFS=','
  for name in $names; do
    IFS=$old_ifs
    [ -n "$name" ] || continue
    # read -d '' (not `val=$(...)`) so a genuine trailing newline in the value survives to the
    # newline check below instead of being silently stripped by command substitution (code-review
    # Finding: a value ending in one or more newlines was persisted with those bytes quietly
    # removed rather than rejected, since command substitution strips ALL trailing newlines
    # unconditionally — _proc1_get's own `printf` change above means nothing here is stripping
    # newlines except that universal command-substitution behavior, which this idiom avoids).
    IFS= read -r -d '' val < <(_proc1_get "$environ_file" "$name"; printf '\0')
    [ -n "$val" ] || continue
    case "$val" in
      *$'\n'*)
        echo "[bootstrap] skipping PASS_ENV var $name: value contains a newline, cannot persist as a single KV line" >&2
        # A skip is a skip everywhere: drop any STALE entry from an earlier bootstrap rather than
        # leaving it looking current (code-review Finding, round 4 — same family as the PAM-unsafe
        # skip below).
        if [ -n "$workspace_env" ]; then _drop_kv "$workspace_env" "$name"; fi
        if [ "$is_root" = 1 ]; then _drop_kv "$etc_env" "$name"; fi
        continue ;;
    esac
    qval=$(_shell_quote "$val")
    if [ -n "$workspace_env" ]; then _persist_kv "$workspace_env" "$name" "${name}=${qval}"; fi
    if [ "$is_root" = 1 ]; then
      if [ "$qval" = "$val" ]; then
        _persist_kv "$etc_env" "$name" "${name}=${val}"
      else
        echo "[bootstrap] $name: value contains characters /etc/environment (PAM, no escape syntax) cannot represent; persisted to /workspace/.env only" >&2
        # Drop any STALE bare-safe entry a prior run left here — /etc/environment must never keep
        # serving an old value once the CURRENT value can no longer be represented there.
        _drop_kv "$etc_env" "$name"
      fi
    fi
  done
  IFS=$old_ifs
  echo "[bootstrap] persisted PASS_ENV var(s) for later ssh sessions: $names"
}

# Allow this file to be `source`d (by bootstrap_pod_env_smoke.sh) to reuse the two functions above
# offline, without running the real bootstrap below (rclone install, real /etc/environment writes).
if [ "${BASH_SOURCE[0]}" != "${0}" ]; then
  return 0
fi

# Multi-threaded rclone by default (automated-researcher #284): exported here so THIS bootstrap's own
# rclone pulls use it, and (below) written to /etc/environment so later pod shells / ssh eval-drivers
# inherit it. Overridable — respects a value already set in the environment.
export RCLONE_MULTI_THREAD_STREAMS="${RCLONE_MULTI_THREAD_STREAMS:-16}" RCLONE_MULTI_THREAD_CUTOFF="${RCLONE_MULTI_THREAD_CUTOFF:-100M}"
# Disable huggingface_hub's Xet-accelerated downloader by default (automated-researcher #442): on a
# fresh pod it silently stalls at zero bytes/sec on some host/network paths — no error, no timeout,
# no retry, it just sits (root-caused via a raw curl range-GET on the same host hitting full
# bandwidth, proving the network was fine and the stall was Xet-specific). Same resolved-value
# persistence pattern as RCLONE_MULTI_THREAD_* above — overridable, and inherited by later shells.
export HF_HUB_DISABLE_XET="${HF_HUB_DISABLE_XET:-1}"
if [ -n "${RCLONE_CONF_B64:-}" ]; then
  command -v rclone >/dev/null || (curl -fsSL https://rclone.org/install.sh | bash >/dev/null 2>&1)
  mkdir -p ~/.config/rclone
  echo "$RCLONE_CONF_B64" | base64 -d > ~/.config/rclone/rclone.conf
  echo "[bootstrap] rclone configured"
  if [ -n "${RCLONE_REMOTE:-}" ] && rclone lsf "$RCLONE_REMOTE/gpu-job/" 2>/dev/null | grep -qx bundle.tar; then
    rclone copy "$RCLONE_REMOTE/gpu-job/bundle.tar" /tmp/ && tar xf /tmp/bundle.tar -C ~ && rm /tmp/bundle.tar
    echo "[bootstrap] identity bundle restored"
  fi
fi
# Default multi-threaded rclone so large single-file R2 pulls (venvs, big adapters) parallelize instead
# of throttling to ~1 MB/s single-stream (~148 MB/s measured; automated-researcher #284). Written to
# /etc/environment so EVERY pod shell — incl. `ssh pod 'rclone …'` used by eval-drivers — inherits it;
# overridable per-call. Needs a root pod (RunPod default); skipped gracefully otherwise.
if [ "$(id -u)" = 0 ]; then
  # Persist the RESOLVED values (honors an override passed into bootstrap), per-key idempotent.
  for kv in "RCLONE_MULTI_THREAD_STREAMS=$RCLONE_MULTI_THREAD_STREAMS" "RCLONE_MULTI_THREAD_CUTOFF=$RCLONE_MULTI_THREAD_CUTOFF" "HF_HUB_DISABLE_XET=$HF_HUB_DISABLE_XET"; do
    grep -q "^${kv%%=*}=" /etc/environment 2>/dev/null || echo "$kv" >> /etc/environment
  done
  echo "[bootstrap] rclone multi-thread + HF Xet defaults set"
fi
# Generalized PASS_ENV persistence (#341) — see _persist_passed_env's header above.
_persist_passed_env /proc/1/environ
touch /workspace/.gpu-job-ready 2>/dev/null || touch ~/.gpu-job-ready
echo "[bootstrap] ready"
