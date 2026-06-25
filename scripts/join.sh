#!/usr/bin/env bash
set -euo pipefail

# Usage: join.sh <team> <agent_id> <type> <project_path>
#
# Adds an agent to a team. Creates the team if it doesn't exist.

TEAM="${1:?Usage: join.sh <team> <agent_id> <type> <project_path>}"
AGENT_ID="${2:?Missing agent_id}"
AGENT_TYPE="${3:?Missing type (a registered type under scripts/drivers/types/<name>/)}"
PROJECT_PATH="${4:?Missing project_path}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/type-registry.sh"
if [ -f "$SCRIPT_DIR/lib/pane.sh" ]; then
  source "$SCRIPT_DIR/lib/pane.sh" || true
fi

# Reject unknown agent types — the rest of agmsg (delivery.sh,
# session-start.sh, identities.sh lookups) only supports registered types
# (scripts/drivers/types/<name>/type.conf). Allowing arbitrary strings silently mis-registers an
# agent and makes monitor mode fail with a confusing "no joined teams" message.
if ! agmsg_is_known_type "$AGENT_TYPE"; then
  echo "Unknown agent type: '$AGENT_TYPE' (supported: $(agmsg_known_types | sort -u | paste -sd, - | sed 's/,/, /g'))" >&2
  exit 1
fi

SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TEAMS_DIR="$SCRIPT_DIR/../teams"

# Reject team names that would escape teams/ as a path segment (#140).
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/validate.sh"
agmsg_validate_team_name "$TEAM" || exit 1

# Resolve the session's real project root from the passed pwd (see #92), so an
# agent-driven join from a subdir/worktree registers under the project the
# session lives in instead of minting a phantom record for the subdir.
# Callers passing an explicit, deliberate path (e.g. spawn.sh's --project, which
# may not be registered yet) set AGMSG_RESOLVE_PROJECT=0 to keep their path.
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/resolve-project.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/storage.sh"
PROJECT_PATH="$(agmsg_resolve_project "$PROJECT_PATH" "$AGENT_TYPE")"

TEAM_CONFIG="$TEAMS_DIR/$TEAM/config.json"

# --- Ensure team config exists ---
mkdir -p "$TEAMS_DIR/$TEAM"
if [ ! -f "$TEAM_CONFIG" ]; then
  cat > "$TEAM_CONFIG" <<EOF
{
  "name": "$TEAM",
  "agents": {},
  "created_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
  echo "Created team: $TEAM"
fi

# --- Add or extend agent registrations ---
CONFIG_SQL=$(agmsg_sql_readfile_path "$TEAM_CONFIG")
AGENT_ID_SQL=$(printf '%s' "$AGENT_ID" | sed "s/'/''/g")
AGENT_TYPE_SQL=$(printf '%s' "$AGENT_TYPE" | sed "s/'/''/g")
PROJECT_SQL=$(printf '%s' "$PROJECT_PATH" | sed "s/'/''/g")
REGISTRATION=$(sqlite3 :memory: "SELECT json_object('type', '$AGENT_TYPE_SQL', 'project', '$PROJECT_SQL');")
REGISTRATION_ESCAPED=$(printf '%s' "$REGISTRATION" | sed "s/'/''/g")

EXISTING=$(agmsg_sqlite_mem "
  WITH cfg AS (SELECT CAST(readfile('$CONFIG_SQL') AS TEXT) AS json)
  SELECT value
  FROM cfg, json_each(json_extract(cfg.json, '\$.agents'))
  WHERE key = '$AGENT_ID_SQL';
")

if [ -z "$EXISTING" ] || [ "$EXISTING" = "null" ]; then
  AGENT_WAS_NEW=1
  AGENT_OBJ=$(sqlite3 :memory: "SELECT json_object('registrations', json_array(json('$REGISTRATION_ESCAPED')));")
else
  AGENT_WAS_NEW=0
  EXISTING_ESCAPED=$(printf '%s' "$EXISTING" | sed "s/'/''/g")
  NORMALIZED=$(agmsg_sqlite_mem "
    WITH agent(a) AS (SELECT '$EXISTING_ESCAPED')
    SELECT CASE
      WHEN json_type(json_extract(a, '\$.registrations')) = 'array' THEN a
      ELSE json_object(
        'registrations',
        json_array(json_object(
          'type', json_extract(a, '\$.type'),
          'project', json_extract(a, '\$.project')
        ))
      )
    END
    FROM agent;
  ")
  NORMALIZED_ESCAPED=$(printf '%s' "$NORMALIZED" | sed "s/'/''/g")

  HAS_REGISTRATION=$(agmsg_sqlite_mem "
    SELECT EXISTS(
      SELECT 1
      FROM json_each(json_extract('$NORMALIZED_ESCAPED', '\$.registrations'))
      WHERE json_extract(value, '\$.type') = '$AGENT_TYPE_SQL'
        AND json_extract(value, '\$.project') = '$PROJECT_SQL'
    );
  ")

  if [ "$HAS_REGISTRATION" = "1" ]; then
    AGENT_OBJ="$NORMALIZED"
  else
    AGENT_OBJ=$(agmsg_sqlite_mem "
      SELECT json_set(
        '$NORMALIZED_ESCAPED',
        '\$.registrations[' || json_array_length(json_extract('$NORMALIZED_ESCAPED', '\$.registrations')) || ']',
        json('$REGISTRATION_ESCAPED')
      );
    ")
  fi
fi

AGENT_OBJ_ESCAPED=$(printf '%s' "$AGENT_OBJ" | sed "s/'/''/g")
UPDATED=$(agmsg_sqlite_mem \
  "WITH cfg AS (SELECT CAST(readfile('$CONFIG_SQL') AS TEXT) AS json)
  SELECT json_set(
    cfg.json,
    '\$.agents',
    json_patch(
      CASE
        WHEN json_type(json_extract(cfg.json, '\$.agents')) = 'object' THEN json_extract(cfg.json, '\$.agents')
        ELSE json('{}')
      END,
      json_object('$AGENT_ID_SQL', json('$AGENT_OBJ_ESCAPED'))
    )
  )
  FROM cfg;")
echo "$UPDATED" > "$TEAM_CONFIG"

echo "Joined team $TEAM as $AGENT_ID"

agmsg_join_register_pane() {
  declare -F agmsg_pane_registry_write >/dev/null 2>&1 || return 0
  declare -F agmsg_pane_registry_read >/dev/null 2>&1 || return 0

  if ! agmsg_pane_registry_write "$TEAM" "$AGENT_ID" "$AGENT_TYPE" "$PROJECT_PATH" 2>/dev/null; then
    return 0
  fi

  local info backend addr project type
  if ! info="$(agmsg_pane_registry_read "$TEAM" "$AGENT_ID" 2>/dev/null)"; then
    return 0
  fi

  IFS=$'\t' read -r backend addr project type <<< "$info"
  [ -n "$backend" ] && [ -n "$addr" ] || return 0
  echo "Pane registered for $AGENT_ID: $backend $addr (turn-mode push enabled)"
}

agmsg_join_announce() {
  [ "${AGMSG_ANNOUNCE_JOIN:-1}" != "0" ] || return 0
  [ "${AGENT_WAS_NEW:-0}" = "1" ] || return 0

  local leader="${AGMSG_TEAM_LEADER:-planner}"
  [ -n "$leader" ] || return 0
  [ "$leader" != "$AGENT_ID" ] || return 0

  local leader_sql leader_exists
  leader_sql=$(printf '%s' "$leader" | sed "s/'/''/g")
  leader_exists=$(agmsg_sqlite_mem "
    WITH cfg AS (SELECT CAST(readfile('$CONFIG_SQL') AS TEXT) AS json)
    SELECT EXISTS(
      SELECT 1
      FROM cfg, json_each(json_extract(cfg.json, '\$.agents'))
      WHERE key = '$leader_sql'
    );
  " 2>/dev/null || true)
  [ "$leader_exists" = "1" ] || return 0

  bash "$SCRIPT_DIR/send.sh" \
    "$TEAM" \
    "$AGENT_ID" \
    "$leader" \
    "[JOIN] $AGENT_ID ($AGENT_TYPE) joined team $TEAM — project=$PROJECT_PATH" \
    >/dev/null 2>&1 || true
}

agmsg_join_register_pane || true
agmsg_join_announce || true
