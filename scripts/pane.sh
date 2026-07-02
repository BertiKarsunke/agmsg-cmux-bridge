#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="${SKILL_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"
source "$SCRIPT_DIR/lib/pane.sh"
source "$SCRIPT_DIR/lib/type-registry.sh"
source "$SCRIPT_DIR/lib/resolve-project.sh"
source "$SCRIPT_DIR/lib/storage.sh"

usage() {
  cat <<'EOF'
Usage: pane.sh <command> [args...]

Commands:
  register <team> <name> [type] [project] [owner]
  status [--all|<team> <name>]
  doctor [--all|<team> <name>]
  lookup <team> <name>
  test [--timeout <seconds>] <team> <name>
  unregister <team> <name>
EOF
}

cmd_register() {
  if [ "$#" -lt 2 ] || [ "$#" -gt 5 ]; then
    usage >&2
    return 2
  fi

  local team="$1" name="$2" type="${3:-}" project="${4:-$(pwd)}" owner="${5:-${AGMSG_PANE_OWNER:-}}"
  if ! agmsg_pane_registry_write "$team" "$name" "$type" "$project" "$owner"; then
    echo "agmsg pane: no active tmux/cmux pane detected; registration not written" >&2
    return 1
  fi

  local backend addr saved_project saved_type
  local info
  info="$(agmsg_pane_registry_read "$team" "$name")"
  backend="$(agmsg_pane_registry_field "$info" 1)"
  addr="$(agmsg_pane_registry_field "$info" 2)"
  saved_project="$(agmsg_pane_registry_field "$info" 3)"
  saved_type="$(agmsg_pane_registry_field "$info" 4)"
  printf 'registered backend=%s addr=%s project=%s type=%s\n' "$backend" "$addr" "$saved_project" "$saved_type"
}

cmd_status_one() {
  local team="$1" name="$2"
  local backend addr project type info
  info="$(agmsg_pane_registry_read "$team" "$name")" || return 1
  backend="$(agmsg_pane_registry_field "$info" 1)"
  addr="$(agmsg_pane_registry_field "$info" 2)"
  project="$(agmsg_pane_registry_field "$info" 3)"
  type="$(agmsg_pane_registry_field "$info" 4)"
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$team" "$name" "$backend" "$addr" "$project" "$type"
}

cmd_registry_pairs_all() {
  local skill_dir run_dir found file base rest team name
  skill_dir="$(agmsg_pane_skill_dir)"
  run_dir="$skill_dir/run"
  found=0
  if [ -d "$run_dir" ]; then
    for file in "$run_dir"/pane.*.*.json; do
      [ -e "$file" ] || continue
      found=1
      base="$(basename "$file")"
      rest="${base#pane.}"
      rest="${rest%.json}"
      team="${rest%%.*}"
      name="${rest#*.}"
      printf '%s\t%s\n' "$team" "$name"
    done
  fi
  [ "$found" -eq 1 ]
}

cmd_current_project_teams() {
  local start="${1:-$(pwd)}" type project team name
  while IFS= read -r type; do
    [ -n "$type" ] || continue
    project="$(agmsg_resolve_project "$start" "$type" 2>/dev/null || printf '%s' "$start")"
    while IFS='	' read -r team name; do
      [ -n "$team" ] || continue
      printf '%s\n' "$team"
    done < <("$SKILL_DIR/scripts/identities.sh" "$project" "$type")
  done < <(agmsg_known_types | sort -u)
}

cmd_dedupe_lines() {
  awk 'NF && !seen[$0]++'
}

cmd_team_in_scope() {
  local team="$1" scoped_teams="$2"
  printf '%s\n' "$scoped_teams" | grep -Fx -- "$team" >/dev/null
}

cmd_status_all() {
  local found team name
  found=0
  while IFS='	' read -r team name; do
    [ -n "$team" ] || continue
    found=1
    cmd_status_one "$team" "$name" || true
  done < <(cmd_registry_pairs_all || true)
  if [ "$found" -eq 0 ]; then
    echo "No pane registrations."
  fi
}

cmd_status_scoped() {
  local scoped_teams found team name
  scoped_teams="$(cmd_current_project_teams "$(pwd)" | cmd_dedupe_lines)"
  [ -n "$scoped_teams" ] || return 0

  found=0
  while IFS='	' read -r team name; do
    [ -n "$team" ] || continue
    cmd_team_in_scope "$team" "$scoped_teams" || continue
    found=1
    cmd_status_one "$team" "$name" || true
  done < <(cmd_registry_pairs_all || true)
  if [ "$found" -eq 0 ]; then
    echo "No pane registrations."
  fi
}

cmd_status() {
  if [ "$#" -eq 1 ] && [ "$1" = "--all" ]; then
    cmd_status_all
    return
  fi
  if [ "$#" -eq 2 ]; then
    cmd_status_one "$1" "$2"
    return
  fi
  if [ "$#" -ne 0 ]; then
    usage >&2
    return 2
  fi

  cmd_status_scoped
}

cmd_doctor_header() {
  local backend self env_key env_parts
  backend="$(agmsg_pane_backend 2>/dev/null || echo none)"
  self="$(agmsg_pane_self "$backend" 2>/dev/null || true)"
  [ -n "$self" ] || self="(none)"

  echo "detected backend: $backend"
  echo "self addr: $self"

  env_parts=""
  local -a env_keys=(TMUX TMUX_PANE CMUX_SURFACE_ID WEZTERM_PANE WEZTERM_UNIX_SOCKET KAKU_UNIX_SOCKET)
  for env_key in "${env_keys[@]}"; do
    if [ -n "${!env_key+x}" ]; then
      env_parts="${env_parts:+$env_parts }$env_key=${!env_key}"
    fi
  done
  echo "env hints: ${env_parts:-"(none)"}"
}

# Print "team/name" of OTHER registrations sharing the same backend+addr — a
# pane-push collision (two agents nudged as one). See BUG-spawn-shared-pane-collision.
cmd_doctor_addr_siblings() {
  local self_team="$1" self_name="$2" backend="$3" addr="$4"
  local scoped_teams="${5:-}"
  [ -n "$addr" ] || return 0
  local skill_dir run_dir file base rest team name info b a
  skill_dir="$(agmsg_pane_skill_dir)"
  run_dir="$skill_dir/run"
  [ -d "$run_dir" ] || return 0
  for file in "$run_dir"/pane.*.*.json; do
    [ -e "$file" ] || continue
    base="$(basename "$file")"
    rest="${base#pane.}"
    rest="${rest%.json}"
    team="${rest%%.*}"
    name="${rest#*.}"
    { [ "$team" = "$self_team" ] && [ "$name" = "$self_name" ]; } && continue
    if [ -n "$scoped_teams" ]; then
      cmd_team_in_scope "$team" "$scoped_teams" || continue
    fi
    info="$(agmsg_pane_registry_read "$team" "$name" 2>/dev/null)" || continue
    b="$(agmsg_pane_registry_field "$info" 1)"
    a="$(agmsg_pane_registry_field "$info" 2)"
    [ "$b" = "$backend" ] && [ "$a" = "$addr" ] && printf '%s/%s\n' "$team" "$name"
  done
}

cmd_doctor_registry_one() {
  local team="$1" name="$2" scoped_teams="${3:-}"
  local info backend addr project socket alive siblings
  if ! info="$(agmsg_pane_registry_read "$team" "$name" 2>/dev/null)"; then
    printf 'registry %s/%s: missing\n' "$team" "$name"
    DOCTOR_REGISTRY_STATE="missing"
    return 1
  fi

  backend="$(agmsg_pane_registry_field "$info" 1)"
  addr="$(agmsg_pane_registry_field "$info" 2)"
  project="$(agmsg_pane_registry_field "$info" 3)"
  socket="$(agmsg_pane_registry_field "$info" 5)"
  if agmsg_pane_alive "$backend" "$addr" "$socket" 2>/dev/null; then
    alive="alive"
  else
    alive="dead"
    [ "${DOCTOR_REGISTRY_STATE:-ok}" = "missing" ] || DOCTOR_REGISTRY_STATE="stale"
  fi

  printf 'registry %s/%s: present\n' "$team" "$name"
  printf 'registry %s/%s backend: %s\n' "$team" "$name" "$backend"
  printf 'registry %s/%s addr: %s\n' "$team" "$name" "$addr"
  printf 'registry %s/%s project: %s\n' "$team" "$name" "$project"
  printf 'registry %s/%s alive: %s\n' "$team" "$name" "$alive"

  siblings="$(cmd_doctor_addr_siblings "$team" "$name" "$backend" "$addr" "$scoped_teams")"
  if [ -n "$siblings" ]; then
    printf 'registry %s/%s COLLISION: shares %s addr %s with %s\n' \
      "$team" "$name" "$backend" "$addr" "$(printf '%s' "$siblings" | paste -sd, -)"
    DOCTOR_COLLISION="${DOCTOR_COLLISION:+$DOCTOR_COLLISION }$team/$name"
  fi

  [ "$alive" = "alive" ]
}

cmd_doctor_registries_all() {
  local found team name
  found=0
  while IFS='	' read -r team name; do
    [ -n "$team" ] || continue
    found=1
    cmd_doctor_registry_one "$team" "$name" || true
  done < <(cmd_registry_pairs_all || true)
  if [ "$found" -eq 0 ]; then
    echo "registry: none"
    DOCTOR_REGISTRY_STATE="missing"
  fi
}

cmd_doctor_registries_scoped() {
  local scoped_teams found team name
  scoped_teams="$(cmd_current_project_teams "$(pwd)" | cmd_dedupe_lines)"
  if [ -z "$scoped_teams" ]; then
    echo "registry: none"
    DOCTOR_REGISTRY_STATE="missing"
    return
  fi

  found=0
  while IFS='	' read -r team name; do
    [ -n "$team" ] || continue
    cmd_team_in_scope "$team" "$scoped_teams" || continue
    found=1
    cmd_doctor_registry_one "$team" "$name" "$scoped_teams" || true
  done < <(cmd_registry_pairs_all || true)
  if [ "$found" -eq 0 ]; then
    echo "registry: none"
    DOCTOR_REGISTRY_STATE="missing"
  fi
}

cmd_doctor_registries() {
  DOCTOR_REGISTRY_STATE="ok"
  DOCTOR_COLLISION=""
  if [ "$#" -eq 1 ] && [ "$1" = "--all" ]; then
    cmd_doctor_registries_all
    return
  fi
  if [ "$#" -eq 2 ]; then
    cmd_doctor_registry_one "$1" "$2" || true
    return
  fi

  cmd_doctor_registries_scoped
}

cmd_doctor() {
  if [ "$#" -eq 1 ] && [ "$1" = "--all" ]; then
    local scope_arg="--all"
    set --
  else
    local scope_arg=""
  fi

  if [ "$#" -ne 0 ] && [ "$#" -ne 2 ]; then
    usage >&2
    return 2
  fi

  local backend
  backend="$(agmsg_pane_backend 2>/dev/null || echo none)"
  cmd_doctor_header
  if [ -n "$scope_arg" ]; then
    cmd_doctor_registries "$scope_arg"
  else
    cmd_doctor_registries "$@"
  fi

  if [ "$backend" = "none" ]; then
    echo "verdict: no tmux/cmux pane backend detected"
  elif [ "${DOCTOR_REGISTRY_STATE:-ok}" = "missing" ]; then
    echo "verdict: no pane registered"
  elif [ -n "${DOCTOR_COLLISION:-}" ]; then
    echo "verdict: collision (duplicate pane addr: ${DOCTOR_COLLISION})"
  elif [ "${DOCTOR_REGISTRY_STATE:-ok}" = "stale" ]; then
    echo "verdict: registered pane is stale (re-register needed)"
  else
    echo "verdict: ok"
  fi
}

cmd_lookup() {
  if [ "$#" -ne 2 ]; then
    usage >&2
    return 2
  fi
  agmsg_pane_registry_read "$1" "$2"
}

cmd_test() {
  local timeout="${AGMSG_PANE_TEST_TIMEOUT:-15}"
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --timeout)
        timeout="${2:?--timeout requires seconds}"
        shift 2
        ;;
      --timeout=*)
        timeout="${1#--timeout=}"
        shift
        ;;
      --)
        shift
        break
        ;;
      -*)
        usage >&2
        return 2
        ;;
      *)
        break
        ;;
    esac
  done

  if [ "$#" -ne 2 ]; then
    usage >&2
    return 2
  fi
  case "$timeout" in
    ''|*[!0-9]*)
      echo "agmsg pane: --timeout must be a non-negative whole number" >&2
      return 2
      ;;
  esac

  local team="$1" name="$2" backend addr socket info
  if ! info="$(agmsg_pane_registry_read "$1" "$2")"; then
    echo "agmsg pane: no pane registration for $1/$2" >&2
    return 1
  fi
  backend="$(agmsg_pane_registry_field "$info" 1)"
  addr="$(agmsg_pane_registry_field "$info" 2)"
  socket="$(agmsg_pane_registry_field "$info" 5)"
  if ! agmsg_pane_alive "$backend" "$addr" "$socket"; then
    printf 'status=unresponsive team=%s name=%s reason=pane-not-alive backend=%s addr=%s timeout=%s\n' \
      "$team" "$name" "$backend" "$addr" "$timeout"
    return 0
  fi

  local db token body id team_sql name_sql body_sql elapsed read_at
  db="$(agmsg_db_path)"
  [ -f "$db" ] || bash "$SCRIPT_DIR/internal/init-db.sh" >/dev/null
  token="$(date +%s).$$.${RANDOM:-0}"
  body="ctrl:ping $token"
  team_sql="$(printf '%s' "$team" | sed "s/'/''/g")"
  name_sql="$(printf '%s' "$name" | sed "s/'/''/g")"
  body_sql="$(printf '%s' "$body" | sed "s/'/''/g")"
  id="$(agmsg_sqlite "$db" "
    INSERT INTO messages (team, from_agent, to_agent, body)
    VALUES ('$team_sql', '__pane_test__', '$name_sql', '$body_sql');
    SELECT last_insert_rowid();
  " | tail -1 | tr -d '\r')"
  case "$id" in
    ''|*[!0-9]*)
      echo "agmsg pane: failed to create ping message" >&2
      return 1
      ;;
  esac

  if ! agmsg_pane_inject "$backend" "$addr" "[agmsg-cmux] pane diagnostic ping for $team/$name. Run your agmsg skill to read the inbox; no reply needed." "$socket"; then
    agmsg_sqlite "$db" "UPDATE messages SET read_at=strftime('%Y-%m-%dT%H:%M:%SZ','now') WHERE id=$id;" >/dev/null 2>&1 || true
    echo "agmsg pane: failed to nudge registered pane: $backend $addr" >&2
    return 1
  fi

  elapsed=0
  while :; do
    read_at="$(agmsg_sqlite "$db" "SELECT COALESCE(read_at, '') FROM messages WHERE id=$id;" 2>/dev/null | tr -d '\r' || true)"
    if [ -n "$read_at" ]; then
      printf 'status=responsive team=%s name=%s after=%ss message_id=%s\n' "$team" "$name" "$elapsed" "$id"
      return 0
    fi
    [ "$elapsed" -ge "$timeout" ] && break
    sleep 1
    elapsed=$((elapsed + 1))
  done

  agmsg_sqlite "$db" "UPDATE messages SET read_at=strftime('%Y-%m-%dT%H:%M:%SZ','now') WHERE id=$id AND read_at IS NULL;" >/dev/null 2>&1 || true
  printf 'status=unresponsive team=%s name=%s reason=ping-timeout timeout=%ss message_id=%s\n' "$team" "$name" "$timeout" "$id"
}

cmd_unregister() {
  if [ "$#" -ne 2 ]; then
    usage >&2
    return 2
  fi
  agmsg_pane_registry_clear "$1" "$2"
  printf 'unregistered %s/%s\n' "$1" "$2"
}

main() {
  local command="${1:-}"
  if [ -z "$command" ]; then
    usage >&2
    return 2
  fi
  shift

  case "$command" in
    register) cmd_register "$@" ;;
    status) cmd_status "$@" ;;
    doctor) cmd_doctor "$@" ;;
    lookup) cmd_lookup "$@" ;;
    test) cmd_test "$@" ;;
    unregister) cmd_unregister "$@" ;;
    -h|--help|help) usage ;;
    *)
      echo "agmsg pane: unknown command: $command" >&2
      usage >&2
      return 2
      ;;
  esac
}

main "$@"
