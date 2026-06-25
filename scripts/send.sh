#!/usr/bin/env bash
set -euo pipefail

# Usage: send.sh <team> <from> <to> <message>

TEAM="${1:?Usage: send.sh <team> <from> <to> <message>}"
FROM="${2:?Missing from agent}"
TO="${3:?Missing to agent}"
BODY="${4:?Missing message body}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/storage.sh"
if [ -f "$SCRIPT_DIR/lib/pane.sh" ]; then
  source "$SCRIPT_DIR/lib/pane.sh" || true
fi
DB="$(agmsg_db_path)"

[ -f "$DB" ] || bash "$SCRIPT_DIR/internal/init-db.sh" >/dev/null

INSERT="INSERT INTO messages (team, from_agent, to_agent, body) VALUES ('$TEAM', '$FROM', '$TO', '$(echo "$BODY" | sed "s/'/''/g")');"

# Retry once after ensuring the schema. Under a concurrent first-write fan-out
# (leader → N members against a fresh/override store), one process can see the
# DB file exist before the winning initializer has finished creating the table,
# so its INSERT would hit "no such table". init-db.sh is idempotent + uses the
# busy_timeout, so re-running it waits for the schema, then the INSERT lands.
# See #114.
if ! agmsg_sqlite "$DB" "$INSERT" 2>/dev/null; then
  bash "$SCRIPT_DIR/internal/init-db.sh" >/dev/null
  agmsg_sqlite "$DB" "$INSERT"
fi

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

  if agmsg_pane_alive "$backend" "$addr" "$socket" 2>/dev/null; then
    wake="[agmsg-cmux] '$FROM' sent you a new agmsg message (team=$TEAM). Run your agmsg skill to read the inbox and handle it now."
    if agmsg_pane_inject "$backend" "$addr" "$wake" "$socket" 2>/dev/null; then
      echo "pane-push: nudged $TO ($backend $addr)"
    fi
  else
    echo "pane-push: $TO pane not alive, skipped"
  fi
}

agmsg_send_pane_push || true
