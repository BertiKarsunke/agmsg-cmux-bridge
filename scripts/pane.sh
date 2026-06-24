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
  IFS=$'\t' read -r backend addr saved_project saved_type < <(agmsg_pane_registry_read "$team" "$name")
  printf 'registered backend=%s addr=%s project=%s type=%s\n' "$backend" "$addr" "$saved_project" "$saved_type"
}

cmd_status_one() {
  local team="$1" name="$2"
  local backend addr project type
  IFS=$'\t' read -r backend addr project type < <(agmsg_pane_registry_read "$team" "$name") || return 1
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

  local backend addr project type
  if ! IFS=$'\t' read -r backend addr project type < <(agmsg_pane_registry_read "$1" "$2"); then
    echo "agmsg pane: no pane registration for $1/$2" >&2
    return 1
  fi
  if ! agmsg_pane_alive "$backend" "$addr"; then
    echo "agmsg pane: registered pane is not alive: $backend $addr" >&2
    return 1
  fi
  agmsg_pane_inject "$backend" "$addr" "[agmsg-cmux] pane test ping"
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
