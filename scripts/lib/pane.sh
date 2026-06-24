#!/usr/bin/env bash

[ -n "${_AGMSG_PANE_SH:-}" ] && return 0
_AGMSG_PANE_SH=1

agmsg_pane_skill_dir() {
  if [ -n "${SKILL_DIR:-}" ]; then
    printf '%s\n' "${SKILL_DIR%/}"
    return 0
  fi

  if [ -n "${BASH_SOURCE[0]:-}" ]; then
    local lib_dir
    lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || return 1
    cd "$lib_dir/../.." && pwd
    return 0
  fi

  return 1
}

agmsg_pane_sql_readfile_path() {
  local path="$1"
  if command -v cygpath >/dev/null 2>&1; then
    path="$(cygpath -w "$path" 2>/dev/null || printf '%s' "$path")"
  fi
  printf '%s' "$path" | sed "s/'/''/g"
}

agmsg_pane_sql_quote() {
  printf '%s' "$1" | sed "s/'/''/g"
}

agmsg_pane_json_extract() {
  local json="$1"
  local path="$2"
  command -v sqlite3 >/dev/null 2>&1 || return 1
  sqlite3 :memory: \
    ".param set :json '$(agmsg_pane_sql_quote "$json")'" \
    "SELECT COALESCE(json_extract(:json, '$path'), '');" | tr -d '\r'
}

agmsg_pane_cmux_has_context() {
  [ -n "${CMUX_SURFACE_ID:-}" ] && return 0
  command -v cmux >/dev/null 2>&1 || return 1

  local json caller
  if ! json="$(cmux identify --json 2>/dev/null)"; then
    return 1
  fi
  caller="$(agmsg_pane_json_extract "$json" '$.caller.surface_ref' 2>/dev/null || true)"
  [ -n "$caller" ]
}

agmsg_pane_backend() {
  if [ -n "${AGMSG_PANE_BACKEND+x}" ]; then
    printf '%s\n' "$AGMSG_PANE_BACKEND"
    return 0
  fi

  if [ -n "${TMUX:-}" ] && command -v tmux >/dev/null 2>&1; then
    printf 'tmux\n'
    return 0
  fi

  if command -v cmux >/dev/null 2>&1 && agmsg_pane_cmux_has_context; then
    printf 'cmux\n'
    return 0
  fi

  printf 'none\n'
}

agmsg_pane_self() {
  local backend="${1:-}"
  if [ -n "${AGMSG_PANE_SELF:-}" ]; then
    printf '%s\n' "$AGMSG_PANE_SELF"
    return 0
  fi

  if [ -z "$backend" ]; then
    backend="$(agmsg_pane_backend)"
  fi

  case "$backend" in
    tmux)
      [ -n "${TMUX_PANE:-}" ] || return 1
      printf '%s\n' "$TMUX_PANE"
      ;;
    cmux)
      local json surface
      if json="$(cmux identify --json 2>/dev/null)"; then
        surface="$(agmsg_pane_json_extract "$json" '$.caller.surface_ref' 2>/dev/null || true)"
        if [ -n "$surface" ]; then
          printf '%s\n' "$surface"
          return 0
        fi
      fi
      [ -n "${CMUX_SURFACE_ID:-}" ] || return 1
      printf '%s\n' "$CMUX_SURFACE_ID"
      ;;
    *)
      return 1
      ;;
  esac
}

agmsg_pane_commit_delay() {
  local delay="${AGMSG_PANE_COMMIT_DELAY:-0.4}"
  case "$delay" in
    ''|*[!0-9.]*|*.*.*)
      echo "agmsg pane: AGMSG_PANE_COMMIT_DELAY must be a non-negative number" >&2
      return 1
      ;;
  esac
  printf '%s\n' "$delay"
}

agmsg_pane_inject() {
  local backend="${1:?Usage: agmsg_pane_inject BACKEND ADDR TEXT}"
  local addr="${2:?Missing pane address}"
  local text="${3-}"
  local delay
  delay="$(agmsg_pane_commit_delay)" || return 1

  case "$backend" in
    tmux)
      tmux send-keys -t "$addr" -l -- "$text" || return 1
      sleep "$delay"
      tmux send-keys -t "$addr" Enter || return 1
      sleep "$delay"
      tmux send-keys -t "$addr" Enter
      ;;
    cmux)
      cmux send --surface "$addr" -- "$text" || return 1
      sleep "$delay"
      cmux send-key --surface "$addr" -- Enter || return 1
      sleep "$delay"
      cmux send-key --surface "$addr" -- Enter
      ;;
    *)
      echo "agmsg pane: unsupported backend: $backend" >&2
      return 1
      ;;
  esac
}

agmsg_pane_alive() {
  local backend="${1:?Usage: agmsg_pane_alive BACKEND ADDR}"
  local addr="${2:?Missing pane address}"

  case "$backend" in
    tmux)
      command -v tmux >/dev/null 2>&1 || return 1
      tmux list-panes -a -F '#{pane_id}' 2>/dev/null | grep -Fx -- "$addr" >/dev/null
      ;;
    cmux)
      command -v cmux >/dev/null 2>&1 || return 1
      cmux read-screen --surface "$addr" >/dev/null 2>&1 && return 0
      cmux list-panels 2>/dev/null | grep -F -- "$addr" >/dev/null
      ;;
    *)
      return 1
      ;;
  esac
}

agmsg_pane_registry_path() {
  local team="${1:?Usage: agmsg_pane_registry_path TEAM NAME}"
  local name="${2:?Missing agent name}"
  local skill_dir run_dir
  skill_dir="$(agmsg_pane_skill_dir)" || return 1
  run_dir="$skill_dir/run"
  mkdir -p "$run_dir" || return 1
  printf '%s/pane.%s.%s.json\n' "$run_dir" "$team" "$name"
}

agmsg_pane_registry_json() {
  local backend="$1"
  local addr="$2"
  local project="$3"
  local type="$4"
  local registered_at="$5"

  if command -v sqlite3 >/dev/null 2>&1; then
    sqlite3 :memory: \
      ".param set :backend '$(agmsg_pane_sql_quote "$backend")'" \
      ".param set :addr '$(agmsg_pane_sql_quote "$addr")'" \
      ".param set :project '$(agmsg_pane_sql_quote "$project")'" \
      ".param set :type '$(agmsg_pane_sql_quote "$type")'" \
      ".param set :registered_at '$(agmsg_pane_sql_quote "$registered_at")'" \
      "SELECT json_object('backend', :backend, 'addr', :addr, 'project', :project, 'type', :type, 'registered_at', :registered_at);" | tr -d '\r'
    return 0
  fi

  return 1
}

agmsg_pane_registry_write() {
  local team="${1:?Usage: agmsg_pane_registry_write TEAM NAME [TYPE] [PROJECT]}"
  local name="${2:?Missing agent name}"
  local type="${3:-}"
  local project="${4:-$(pwd)}"
  local backend addr path registered_at json

  backend="$(agmsg_pane_backend)"
  [ -n "$backend" ] && [ "$backend" != "none" ] || return 1

  addr="$(agmsg_pane_self "$backend" 2>/dev/null)" || return 1
  [ -n "$addr" ] || return 1

  path="$(agmsg_pane_registry_path "$team" "$name")" || return 1
  registered_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  json="$(agmsg_pane_registry_json "$backend" "$addr" "$project" "$type" "$registered_at")" || return 1

  printf '%s\n' "$json" > "$path"
}

agmsg_pane_registry_read() {
  local team="${1:?Usage: agmsg_pane_registry_read TEAM NAME}"
  local name="${2:?Missing agent name}"
  local path sql_path sep

  path="$(agmsg_pane_registry_path "$team" "$name")" || return 1
  [ -f "$path" ] || return 1
  command -v sqlite3 >/dev/null 2>&1 || return 1

  sql_path="$(agmsg_pane_sql_readfile_path "$path")"
  sep="$(printf '\t')"
  sqlite3 -separator "$sep" :memory: \
    "SELECT
       COALESCE(json_extract(readfile('$sql_path'), '$.backend'), ''),
       COALESCE(json_extract(readfile('$sql_path'), '$.addr'), ''),
       COALESCE(json_extract(readfile('$sql_path'), '$.project'), ''),
       COALESCE(json_extract(readfile('$sql_path'), '$.type'), '');" | tr -d '\r'
}

agmsg_pane_registry_clear() {
  local team="${1:?Usage: agmsg_pane_registry_clear TEAM NAME}"
  local name="${2:?Missing agent name}"
  local path

  path="$(agmsg_pane_registry_path "$team" "$name")" || return 1
  rm -f "$path"
}
