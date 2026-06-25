#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/pane.sh"

usage() {
  cat <<'EOF'
Usage: pane.sh <command> [args...]

Commands:
  register <team> <name> [type] [project]
  status [<team> <name>]
  doctor [<team> <name>]
  lookup <team> <name>
  test <team> <name>
  unregister <team> <name>
EOF
}

cmd_register() {
  if [ "$#" -lt 2 ] || [ "$#" -gt 4 ]; then
    usage >&2
    return 2
  fi

  local team="$1" name="$2" type="${3:-}" project="${4:-$(pwd)}"
  if ! agmsg_pane_registry_write "$team" "$name" "$type" "$project"; then
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

cmd_status() {
  if [ "$#" -eq 2 ]; then
    cmd_status_one "$1" "$2"
    return
  fi
  if [ "$#" -ne 0 ]; then
    usage >&2
    return 2
  fi

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
      cmd_status_one "$team" "$name" || true
    done
  fi
  if [ "$found" -eq 0 ]; then
    echo "No pane registrations."
  fi
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

cmd_doctor_registry_one() {
  local team="$1" name="$2" info backend addr project socket alive
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
  [ "$alive" = "alive" ]
}

cmd_doctor_registries() {
  DOCTOR_REGISTRY_STATE="ok"
  if [ "$#" -eq 2 ]; then
    cmd_doctor_registry_one "$1" "$2" || true
    return
  fi

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
      cmd_doctor_registry_one "$team" "$name" || true
    done
  fi
  if [ "$found" -eq 0 ]; then
    echo "registry: none"
    DOCTOR_REGISTRY_STATE="missing"
  fi
}

cmd_doctor() {
  if [ "$#" -ne 0 ] && [ "$#" -ne 2 ]; then
    usage >&2
    return 2
  fi

  local backend
  backend="$(agmsg_pane_backend 2>/dev/null || echo none)"
  cmd_doctor_header
  cmd_doctor_registries "$@"

  if [ "$backend" = "none" ]; then
    echo "verdict: no tmux/cmux pane backend detected"
  elif [ "${DOCTOR_REGISTRY_STATE:-ok}" = "missing" ]; then
    echo "verdict: no pane registered"
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
  if [ "$#" -ne 2 ]; then
    usage >&2
    return 2
  fi

  local backend addr socket info
  if ! info="$(agmsg_pane_registry_read "$1" "$2")"; then
    echo "agmsg pane: no pane registration for $1/$2" >&2
    return 1
  fi
  backend="$(agmsg_pane_registry_field "$info" 1)"
  addr="$(agmsg_pane_registry_field "$info" 2)"
  socket="$(agmsg_pane_registry_field "$info" 5)"
  if ! agmsg_pane_alive "$backend" "$addr" "$socket"; then
    echo "agmsg pane: registered pane is not alive: $backend $addr" >&2
    return 1
  fi
  agmsg_pane_inject "$backend" "$addr" "[agmsg-cmux] pane test ping" "$socket"
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
