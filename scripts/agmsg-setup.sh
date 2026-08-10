#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SPAWN="$SCRIPT_DIR/spawn.sh"

usage() {
  echo "Usage: agmsg-setup.sh <team> [--project <path>]"
}

die() {
  echo "agmsg-setup: $*" >&2
  exit 1
}

TEAM="${1:-}"
if [ -z "$TEAM" ]; then
  usage >&2
  exit 2
fi
shift

PROJECT="$PWD"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --project)
      [ "$#" -ge 2 ] || die "--project requires a path"
      PROJECT="$2"
      shift 2
      ;;
    *)
      usage >&2
      die "unknown option: $1"
      ;;
  esac
done

[ -x "$SPAWN" ] || die "spawn.sh is missing or not executable: $SPAWN"

run_spawn() {
  local type="$1" name="$2" rc=0
  "$SPAWN" "$type" "$name" --team "$TEAM" --project "$PROJECT" || rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "agmsg-setup: spawn failed at $type/$name (exit $rc)" >&2
    return "$rc"
  fi
}

run_spawn claude-code planner
run_spawn codex scout
run_spawn codex executor
