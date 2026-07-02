#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC1091
source "$(cd "$(dirname "$0")" && pwd)/lib/compat.sh"

# Check inbox across all teams with cooldown. Skips if last check was < 60 seconds ago.
# Usage: check-inbox.sh <type> <project_path>

TYPE="${1:?Usage: check-inbox.sh <type> <project_path>}"
PROJECT="${2:?Missing project_path}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/storage.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/actas-lock.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/resolve-project.sh"  # agmsg_agent_pid, for instance-id derivation
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/type-registry.sh"
# Optional: pane helpers for turn-mode pane-push. Sourced best-effort so a
# checkout without the pane lib (or a stripped install) still delivers via the
# inbox. Lets this Stop hook keep the session's pane registration fresh (below).
if [ -f "$SCRIPT_DIR/lib/pane.sh" ]; then
  # shellcheck disable=SC1091
  source "$SCRIPT_DIR/lib/pane.sh" || true
fi

# Some Stop-hook runtimes (codex, copilot) want an explicit JSON status object
# even when there is nothing to deliver; others (claude-code) stay silent. This
# is the type's manifest `stop_output=` (data), not a hardcoded type list.
STOP_OUTPUT="$(agmsg_type_get "$TYPE" stop_output 2>/dev/null || true)"
emit_status_json() {
  [ "$STOP_OUTPUT" = "json" ] || return 0
  printf '{\n  "continue": true,\n  "systemMessage": "%s"\n}\n' "$1"
}

# Hook runtimes that pass JSON do so on stdin. Interactive invocations such as
# Gemini's PostToolUse command may inherit a terminal stdin instead; reading
# unconditionally there blocks waiting for input.
INPUT=""
if [ ! -t 0 ]; then
  INPUT=$(cat 2>/dev/null || true)
fi

# Prevent infinite loop: if stop hook is already active, exit silently
if echo "$INPUT" | grep -q '"stop_hook_active"[[:space:]]*:[[:space:]]*true' 2>/dev/null; then
  exit 0
fi

# Defer to the monitor watcher when one is alive for this session.
# Avoids double-delivery when delivery.mode = both. The session id field name
# differs by vendor: Claude Code emits snake_case "session_id"; Grok Build (and
# Cursor) emit camelCase "sessionId". Try snake first (claude-code unaffected),
# then camel, then the GROK_SESSION_ID env Grok injects into every hook.
SESSION_ID=$(printf '%s' "$INPUT" \
  | sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
  | head -1)
[ -z "$SESSION_ID" ] && SESSION_ID=$(printf '%s' "$INPUT" \
  | sed -n 's/.*"sessionId"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
  | head -1)
[ -z "$SESSION_ID" ] && SESSION_ID="${GROK_SESSION_ID:-}"
if [ -n "$SESSION_ID" ]; then
  # The monitor watcher keys its pidfile (and its actas owner, below) on the
  # per-process instance id (#93), not the bare session_id. Normalize to the
  # same token so this Stop-hook defers to a live watcher in `both` mode instead
  # of double-delivering.
  SESSION_ID="$(agmsg_normalize_instance_id "$SESSION_ID" "$TYPE")"
  PIDFILE="$SKILL_DIR/run/watch.$SESSION_ID.pid"
  if [ -f "$PIDFILE" ]; then
    WATCH_PID=$(cat "$PIDFILE" 2>/dev/null || true)
    if [ -n "$WATCH_PID" ] && kill -0 "$WATCH_PID" 2>/dev/null; then
      exit 0
    fi
  fi
fi

PROJECT="$(agmsg_resolve_project "$PROJECT" "$TYPE")"
PAIRS="$("$SCRIPT_DIR/identities.sh" "$PROJECT" "$TYPE")"
if [ -z "$PAIRS" ]; then
  exit 0
fi
PAIR_AGENT_COUNT=$(printf '%s\n' "$PAIRS" | awk -F'\t' 'NF >= 2 && !seen[$2]++ { c++ } END { print c + 0 }')

# Cooldown check. The marker is hook runtime state, not message storage, so it
# lives in the skill's run dir — independent of AGMSG_STORAGE_PATH. Keeping it
# out of the store means an overridden/sandboxed store still gets delivery even
# when the default db dir doesn't exist.
MARKER_HASH=$(printf '%s\t%s' "$PROJECT" "$TYPE" | cksum | awk '{print $1}')
MARKER="$SKILL_DIR/run/.lastcheck-${TYPE}-${MARKER_HASH}"

if [ -f "$MARKER" ]; then
  last=$(compat_file_mtime "$MARKER")
  now=$(date +%s)
  # Prefer the new delivery.turn.check_interval; fall back to legacy
  # hook.check_interval for users who haven't migrated.
  INTERVAL=$("$SCRIPT_DIR/config.sh" get delivery.turn.check_interval "")
  [ -z "$INTERVAL" ] && INTERVAL=$("$SCRIPT_DIR/config.sh" get hook.check_interval 60)
  case "$INTERVAL" in ''|*[!0-9]*) INTERVAL=60 ;; esac
  if [ $(( now - last )) -lt "$INTERVAL" ]; then
    emit_status_json "agmsg: check skipped (cooldown)"
    exit 0
  fi
fi

mkdir -p "$SKILL_DIR/run"
touch "$MARKER"

# Best-effort: keep this session's pane registration fresh so peers can
# pane-push to the live surface. Turn-mode agents (codex, gemini, ...) only
# register a pane at join/actas; without this a session that moved to a new
# pane (restart, re-split) becomes unreachable by pane-push until it rejoins.
# Runs once per delivery interval (after the cooldown gate), independent of
# whether the message store exists or has new rows. No-op when pane-push is
# disabled or no tmux/cmux/wezterm backend is present. Only refresh pairs this
# session owns — skip roles an actas elsewhere has claimed.
if [ "${AGMSG_PANE_PUSH:-1}" != "0" ] \
   && declare -F agmsg_pane_registry_write >/dev/null 2>&1; then
  while IFS=$'\t' read -r pane_team pane_agent; do
    [ -n "$pane_team" ] || continue
    [ -n "$pane_agent" ] || continue
    case "$(actas_lock_state "$pane_team" "$pane_agent" "${SESSION_ID:-}")" in
      other:*) continue ;;
    esac
    agmsg_pane_registry_write "$pane_team" "$pane_agent" "$TYPE" "$PROJECT" "${SESSION_ID:-}" >/dev/null 2>&1 || true
  done <<< "$PAIRS"
fi

# Check for unread messages and mark as read
DB="$(agmsg_db_path)"
if [ ! -f "$DB" ]; then exit 0; fi

OUTPUT=""
agmsg_check_sql_quote() {
  printf '%s' "$1" | sed "s/'/''/g"
}

while IFS=$'\t' read -r team agent; do
  [ -n "$team" ] || continue
  [ -n "$agent" ] || continue
  state=$(actas_lock_state "$team" "$agent" "${SESSION_ID:-}")
  # Honor actas exclusivity locks. If (team, AGENT) is currently held by
  # another live session, that session is the owner of that role's inbox —
  # don't deliver here. Mirrors the per-pair filtering watch.sh does for
  # CC sessions (#62), giving Stop-hook delivery (codex / claude-code
  # turn-mode) the same "respect peer locks" guarantee.
  #
  # Note: AGENT comes from whoami.sh, which returns the first registered
  # agent for (project, type). It is NOT the session's in-memory actas
  # role. That asymmetry is the Codex caveat documented in README — if a
  # Codex session actas'd into <name>, check-inbox is still polling
  # whatever whoami chose first, not <name>.
  case "$state" in
    other:*) continue ;;
  esac

  team_sql=$(agmsg_check_sql_quote "$team")
  agent_sql=$(agmsg_check_sql_quote "$agent")
  RESULT=$(agmsg_sqlite "$DB" "
    SELECT from_agent || char(31) || replace(replace(body, char(10), '\n'), char(9), '\t') || char(31) || created_at
    FROM messages WHERE team='$team_sql' AND to_agent='$agent_sql' AND read_at IS NULL
    ORDER BY created_at ASC;
  ")
  if [ -n "$RESULT" ]; then
    COUNT=$(echo "$RESULT" | wc -l | tr -d ' ')
    if [ "$PAIR_AGENT_COUNT" -gt 1 ]; then
      OUTPUT+="$COUNT new message(s) in $team (as $agent):"$'\n'
    else
      OUTPUT+="$COUNT new message(s) in $team:"$'\n'
    fi
    while IFS=$'\x1f' read -r from body ts; do
      OUTPUT+="  [$ts] $from: $body"$'\n'
    done <<< "$RESULT"
    OUTPUT+=$'\n'
    # Mark as read
    agmsg_sqlite "$DB" "UPDATE messages SET read_at=strftime('%Y-%m-%dT%H:%M:%SZ','now') WHERE team='$team_sql' AND to_agent='$agent_sql' AND read_at IS NULL;" 2>/dev/null || true
  fi
done <<< "$PAIRS"

# No new messages
if [ -z "$OUTPUT" ]; then
  emit_status_json "agmsg: no new messages"
  exit 0
fi

# New messages found
if [ -n "$OUTPUT" ]; then
  # Escape for JSON: backslash, double-quote, newlines, tabs (macOS/Linux compatible)
  ESCAPED=$(printf '%s' "$OUTPUT" | sed 's/\\/\\\\/g; s/"/\\"/g; s/	/\\t/g' | awk '{if(NR>1) printf "\\n"; printf "%s",$0}')
  cat <<ENDJSON
{
  "decision": "block",
  "reason": "$ESCAPED"
}
ENDJSON
  exit 0
fi
