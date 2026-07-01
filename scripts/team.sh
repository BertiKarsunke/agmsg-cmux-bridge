#!/usr/bin/env bash
set -euo pipefail

# Usage: team.sh <team>
# Shows team members.

TEAM="${1:?Usage: team.sh <team>}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Reject team names that would escape teams/ as a path segment (#140).
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/validate.sh"
agmsg_validate_team_name "$TEAM" || exit 1

# Pane registry powers the per-member liveness tag (and opt-in GC). Best-effort:
# if the lib can't load, member_liveness() falls back to "unknown" and the
# listing behaves exactly as before.
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/pane.sh" 2>/dev/null || true

# Liveness of one member, from its pane.<team>.<name>.json marker:
#   live    — marker present and its pane is alive on this host
#   stale   — marker present, backend tool is on THIS host, pane is gone
#   unknown — no marker, or the marker's backend tool isn't on this host
# The "unknown" cases deliberately abstain: a registered-but-idle member (no
# marker, the normal persistent state) and a member whose pane lives on another
# host (backend tool absent here) must never be judged dead. See docs/teams.md.
member_liveness() {
  local team="$1" name="$2" line backend addr socket
  declare -F agmsg_pane_registry_read >/dev/null 2>&1 || { echo unknown; return; }
  line="$(agmsg_pane_registry_read "$team" "$name" 2>/dev/null)" || { echo unknown; return; }
  backend="$(agmsg_pane_registry_field "$line" 1)"
  addr="$(agmsg_pane_registry_field "$line" 2)"
  socket="$(agmsg_pane_registry_field "$line" 5)"
  [ -n "$backend" ] && [ -n "$addr" ] || { echo unknown; return; }
  command -v "$backend" >/dev/null 2>&1 || { echo unknown; return; }
  if agmsg_pane_alive "$backend" "$addr" "$socket"; then echo live; else echo stale; fi
}

CONFIG="$SCRIPT_DIR/../teams/$TEAM/config.json"

if [ ! -f "$CONFIG" ]; then
  echo "Team not found: $TEAM"
  exit 1
fi

echo "Team: $TEAM"
echo ""

COUNT=0
STALE=()
while IFS='	' read -r name types project registrations; do
  suffix=""
  [ "${registrations:-0}" -gt 1 ] && suffix=" (+$((registrations - 1)) more)"
  case "$(member_liveness "$TEAM" "$name")" in
    live)  tag=" [live]" ;;
    stale) tag=" [stale]"; STALE+=("$name") ;;
    *)     tag="" ;;
  esac
  echo "  $name ($types) — $project$suffix$tag"
  COUNT=$((COUNT + 1))
# tr -d '\r': sqlite3.exe on Windows emits CRLF rows; the trailing CR would make
# the `registrations` field "N\r" and trip the integer test in the loop (#130).
done < <(sqlite3 -separator '	' :memory: \
  ".param set :json '$(sed "s/'/''/g" "$CONFIG")'" \
  "WITH agents AS (
     SELECT
       key AS name,
       CASE
         WHEN json_type(json_extract(value, '$.registrations')) = 'array' THEN json_extract(value, '$.registrations')
         ELSE json_array(json_object('type', json_extract(value, '$.type'), 'project', json_extract(value, '$.project')))
       END AS registrations
     FROM json_each(json_extract(:json, '$.agents'))
   )
   SELECT
     name,
     group_concat(DISTINCT json_extract(r.value, '$.type')),
     COALESCE((
       SELECT json_extract(r2.value, '$.project')
       FROM json_each(agents.registrations) AS r2
       ORDER BY CAST(r2.key AS INTEGER) DESC
       LIMIT 1
     ), '?'),
     json_array_length(registrations)
   FROM agents, json_each(agents.registrations) AS r
   GROUP BY name, registrations;" | tr -d '\r')

echo ""

# Opt-in liveness GC: drop members whose pane marker proves their session died
# on this host (the [stale] ones). OFF by default — listing is read-only unless
# AGMSG_GC_ON_LIST is set. Only [stale] members are touched; [live] and the
# abstaining [unknown] (idle/persistent or another host) are never removed.
REMOVED=0
case "${AGMSG_GC_ON_LIST:-}" in
  1|true|yes|on)
    for name in "${STALE[@]:-}"; do
      [ -n "$name" ] || continue
      bash "$SCRIPT_DIR/leave.sh" "$TEAM" "$name" >/dev/null 2>&1 || continue
      declare -F agmsg_pane_registry_clear >/dev/null 2>&1 \
        && agmsg_pane_registry_clear "$TEAM" "$name" 2>/dev/null || true
      echo "  (gc) removed stale member: $name"
      REMOVED=$((REMOVED + 1))
    done
    [ "$REMOVED" -gt 0 ] && echo ""
    ;;
esac

echo "$((COUNT - REMOVED)) member(s)"
