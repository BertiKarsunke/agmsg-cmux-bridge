#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC1091
source "$(cd "$(dirname "$0")" && pwd)/lib/compat.sh"

# SessionEnd hook — symmetric counterpart of session-start.sh.
#
# Usage: session-end.sh <type> <project_path>
#
# When Claude Code terminates a session (matchers: clear / resume / logout /
# prompt_input_exit / bypass_permissions_disabled / other), this script:
#   1. Reads session_id from the hook input JSON on stdin.
#   2. Kills the watch.sh process for that session via its pidfile.
#   3. Removes the matching cc-instance.<cc_pid> file if it still points at
#      this session_id, so the next SessionStart starts cleanly.
#
# Cleanup is best-effort: any missing pieces just result in nothing to do.
# The script always exits 0 — SessionEnd cannot block session termination
# anyway, and a non-zero exit would only generate noise in logs.

TYPE="${1:?Usage: session-end.sh <type> <project_path>}"
PROJECT="${2:?Missing project_path}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
RUN_DIR="$SKILL_DIR/run"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/actas-lock.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/resolve-project.sh"
if [ -f "$SCRIPT_DIR/lib/pane.sh" ]; then
  # shellcheck disable=SC1091
  source "$SCRIPT_DIR/lib/pane.sh" || true
fi

# Drop project markers (#92) whose agent process has exited. Liveness-based, so
# a session that persists across /clear keeps its marker until the process dies.
agmsg_marker_gc_stale 2>/dev/null || true

INPUT=$(cat 2>/dev/null || true)
SESSION_ID=""
if [ -n "$INPUT" ]; then
  SESSION_ID=$(printf '%s' "$INPUT" \
    | sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
    | head -1)
fi
# Opt-in: leave the team when the session ends. OFF by default — the identity
# model deliberately keeps registrations across restarts so an agent rejoins as
# the same role (see docs/teams.md). Set AGMSG_LEAVE_ON_EXIT=1 to instead clear
# this project/type's registration on exit. Caveats: it only fires on a graceful
# SessionEnd (a hard kill/crash never runs this hook — liveness GC is the
# backstop), and it no-ops when the project/type has more than one identity,
# since reset.sh can't tell which role this session was (exits non-zero there).
# Best-effort and must never block teardown, hence `|| true`.
case "${AGMSG_LEAVE_ON_EXIT:-}" in
  1|true|yes|on)
    bash "$SCRIPT_DIR/reset.sh" "$PROJECT" "$TYPE" "" "$SESSION_ID" >/dev/null 2>&1 || true
    ;;
esac

[ -z "$SESSION_ID" ] && exit 0

# Re-derive the per-process instance id this session's watcher/locks are keyed
# under (#93). The enclosing agent process is still alive during the hook, so
# agmsg_instance_id normally resolves the same "<sid>.<pid>" that session-start
# computed — cleaning ONLY this process's state, never a sibling --continue/
# --resume process that shares the bare session_id. If the pid can't be
# resolved we fall back to the bare session_id (and clean only the bare-keyed
# artifacts); we deliberately do NOT glob-delete "<sid>.*", which would kill a
# living sibling — those are left to session-start's liveness GC instead.
INSTANCE_ID="$(agmsg_instance_id "$SESSION_ID" "$TYPE")"

agmsg_session_end_clear_panes() {
  declare -F agmsg_pane_registry_clear_if_owner >/dev/null 2>&1 || return 0

  local team name
  while IFS=$'\t' read -r team name; do
    [ -n "$team" ] || continue
    [ -n "$name" ] || continue
    agmsg_pane_registry_clear_if_owner "$team" "$name" "$INSTANCE_ID" 2>/dev/null || true
  done < <("$SCRIPT_DIR/identities.sh" "$PROJECT" "$TYPE" 2>/dev/null || true)
}

agmsg_session_end_clear_panes || true

PIDFILE="$RUN_DIR/watch.$INSTANCE_ID.pid"
if [ -f "$PIDFILE" ]; then
  pid=$(cat "$PIDFILE" 2>/dev/null || true)
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    # Defensive: only kill if the pid's command line still looks like our
    # watch.sh. Pids can be recycled — a stale pidfile could point at an
    # unrelated process that took the same pid.
    cmd=$(compat_get_cmdline "$pid" 2>/dev/null || true)
    case "$cmd" in
      *"$SKILL_DIR/scripts/watch.sh"*) kill "$pid" 2>/dev/null || true ;;
      *) ;;
    esac
  fi
  rm -f "$PIDFILE"
fi

# Drop the per-session stream watermark (see #107) — the session is ending, so
# there is no restart to resume; a future session_id reuse should start fresh.
rm -f "$RUN_DIR/watch.$INSTANCE_ID.watermark" 2>/dev/null || true

# Clean the cc-instance entry that points at this instance id. The enclosing
# CC process may itself be exiting (matcher=logout/etc.), in which case its
# cc-instance.<pid> file would otherwise be left stale. A sibling process that
# shares the bare session_id stores a different instance id, so it is untouched.
for f in "$RUN_DIR"/cc-instance.*; do
  [ -f "$f" ] || continue
  state=$(cat "$f" 2>/dev/null || true)
  [ "$state" = "$INSTANCE_ID" ] && rm -f "$f"
done

# Release any actas exclusivity locks owned by this instance so peers can
# reclaim those identities on their next watcher cycle. Keyed by instance id so
# a sibling resume process's locks are not released out from under it. See #62.
actas_lock_release_all "$INSTANCE_ID" 2>/dev/null || true

exit 0
