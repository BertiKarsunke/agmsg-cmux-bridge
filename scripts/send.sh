#!/usr/bin/env bash
set -euo pipefail

# Usage: send.sh <team> <from> <to> <message> [--force]

TEAM="${1:?Usage: send.sh <team> <from> <to> <message> [--force]}"
FROM="${2:?Missing from agent}"
TO="${3:?Missing to agent}"
BODY="${4:?Missing message body}"
FORCE=0
if [ "${5:-}" = "--force" ]; then
  FORCE=1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/storage.sh"
if [ -f "$SCRIPT_DIR/lib/pane.sh" ]; then
  source "$SCRIPT_DIR/lib/pane.sh" || true
fi
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/validate.sh"

# #414: TEAM becomes a path segment (teams/$TEAM/config.json) below whether or
# not --force is given, so validate it unconditionally, before any config-path
# resolution or DB init. --force bypasses roster *membership* only — it must
# never bypass team-name path safety.
agmsg_validate_team_name "$TEAM" || exit 1

agmsg_storage_load
DB="$(agmsg_db_path "$TEAM")"

# Keep the full-schema bootstrap (registry + storage tables) for a first-ever
# command; the message write itself goes through the storage facade below.
[ -f "$DB" ] || bash "$SCRIPT_DIR/internal/init-db.sh" >/dev/null

# #355: reject a from/to that isn't registered in <team> — an unnoticed typo
# (e.g. a stray send to "dummy") used to insert successfully with exit 0,
# landing an undeliverable message and polluting history. Validation lives
# here (the front door), not in storage.sh, so other entry points (api.sh)
# can keep their own policy. --force bypasses this for intentional
# pre-registration sends (e.g. notifying a role before its own join.sh runs).
if [ "$FORCE" -ne 1 ]; then
  TEAM_CONFIG="$SCRIPT_DIR/../teams/$TEAM/config.json"

  _agmsg_roster_check() {
    local role="$1" name="$2"
    if [ ! -f "$TEAM_CONFIG" ]; then
      echo "Error: team '$TEAM' has no registered agents — cannot send as $role '$name' (use --force to bypass)." >&2
      return 1
    fi
    local cfg_sql name_sql found roster q="'"
    cfg_sql=$(agmsg_sql_readfile_path "$TEAM_CONFIG")
    name_sql=${name//$q/$q$q}
    found=$(agmsg_sqlite_mem "
      WITH raw(json) AS (SELECT CAST(readfile('$cfg_sql') AS TEXT)),
      cfg(json) AS (SELECT CASE WHEN json_valid(json) THEN json END FROM raw)
      SELECT value
      FROM cfg, json_each(json_extract(cfg.json, '\$.agents'))
      WHERE key = '$name_sql';
    ")
    if [ -z "$found" ]; then
      roster=$(agmsg_sqlite_mem "
        WITH raw(json) AS (SELECT CAST(readfile('$cfg_sql') AS TEXT)),
        cfg(json) AS (SELECT CASE WHEN json_valid(json) THEN json END FROM raw)
        SELECT group_concat(key, ', ')
        FROM cfg, json_each(json_extract(cfg.json, '\$.agents'));
      ")
      echo "Error: $role agent '$name' is not registered in team '$TEAM' (registered: ${roster:-none}). Use --force to bypass." >&2
      return 1
    fi
    return 0
  }

  _agmsg_roster_check "from" "$FROM" || exit 1
  _agmsg_roster_check "to" "$TO" || exit 1
fi

# Write through the storage axis (§2.1 storage_send) — the active driver now owns
# the message log (an append-only message_sent event), not a direct INSERT.
# storage_send re-inits its schema idempotently before writing, which subsumes the
# #114 concurrent first-write race the old path retried around (a process seeing
# the DB file before the table exists just creates it). The new id is not surfaced.
storage_send "$TEAM" "$FROM" "$TO" "$BODY" >/dev/null

echo "Sent to $TO in team $TEAM"

agmsg_send_pane_push() {
  [ "${AGMSG_PANE_PUSH:-1}" != "0" ] || return 0
  [ "$FROM" != "$TO" ] || return 0
  declare -F agmsg_pane_registry_read >/dev/null 2>&1 || return 0
  declare -F agmsg_pane_registry_field >/dev/null 2>&1 || return 0
  declare -F agmsg_pane_skill_dir >/dev/null 2>&1 || return 0
  declare -F agmsg_pane_alive >/dev/null 2>&1 || return 0
  declare -F agmsg_pane_inject >/dev/null 2>&1 || return 0

  local info backend addr socket wake skill_dir registry_file
  skill_dir="$(agmsg_pane_skill_dir 2>/dev/null)" || return 0
  registry_file="$skill_dir/run/pane.$TEAM.$TO.json"
  if [ ! -f "$registry_file" ]; then
    echo "pane-push: no pane registered for $TO (delivered via inbox only)"
    return 0
  fi

  if ! info="$(agmsg_pane_registry_read "$TEAM" "$TO" 2>/dev/null)"; then
    echo "pane-push: no pane registered for $TO (delivered via inbox only)"
    return 0
  fi

  backend="$(agmsg_pane_registry_field "$info" 1)"
  addr="$(agmsg_pane_registry_field "$info" 2)"
  socket="$(agmsg_pane_registry_field "$info" 5)"
  if [ -z "$backend" ] || [ -z "$addr" ]; then
    echo "pane-push: no pane registered for $TO (delivered via inbox only)"
    return 0
  fi

  # Warn when another agent in this team is registered at the same pane: the
  # nudge below wakes whoever owns that pane, not necessarily $TO. Detection
  # only in `pane.sh doctor` let this go unnoticed for days (agmsg-role-sharing).
  local f other other_info shared=""
  for f in "$skill_dir/run/pane.$TEAM."*.json; do
    [ -e "$f" ] || continue
    other="$(basename "$f")"
    other="${other#pane.$TEAM.}"
    other="${other%.json}"
    [ "$other" = "$TO" ] && continue
    other_info="$(agmsg_pane_registry_read "$TEAM" "$other" 2>/dev/null)" || continue
    [ "$(agmsg_pane_registry_field "$other_info" 1)" = "$backend" ] || continue
    [ "$(agmsg_pane_registry_field "$other_info" 2)" = "$addr" ] || continue
    shared="${shared:+$shared, }$other"
  done
  if [ -n "$shared" ]; then
    echo "pane-push: WARNING $TO shares $backend pane $addr with $shared (collision — run pane.sh doctor)"
  fi

  if agmsg_pane_alive "$backend" "$addr" "$socket" 2>/dev/null; then
    wake="[agmsg-cmux] New agmsg message: '$FROM' -> '$TO' (team=$TEAM). You are '$TO' — run your agmsg skill to read your inbox and handle it now."
    if agmsg_pane_inject "$backend" "$addr" "$wake" "$socket" 2>/dev/null; then
      echo "pane-push: nudged $TO ($backend $addr)"
    fi
  else
    echo "pane-push: $TO pane not alive, skipped"
  fi
}

agmsg_send_pane_push || true
