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

  if [ "${HERDR_ENV:-}" = "1" ] && [ -n "${HERDR_PANE_ID:-}" ] && command -v herdr >/dev/null 2>&1; then
    printf 'herdr\n'
    return 0
  fi

  if command -v cmux >/dev/null 2>&1 && agmsg_pane_cmux_has_context; then
    printf 'cmux\n'
    return 0
  fi

  if command -v wezterm >/dev/null 2>&1 && [ -n "${WEZTERM_PANE:-}" ]; then
    printf 'wezterm\n'
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
    herdr)
      [ -n "${HERDR_PANE_ID:-}" ] || return 1
      printf '%s\n' "$HERDR_PANE_ID"
      ;;
    cmux)
      # Prefer the surface UUID: it is globally unique and stable, whereas cmux
      # short refs (surface:N) are positional and can shift or collide across
      # surfaces — which let two spawned workers register the same addr and made
      # pane-push always nudge one pane (see BUG-spawn-shared-pane-collision).
      # Fall back to identify's caller ref only when the env var is absent.
      if [ -n "${CMUX_SURFACE_ID:-}" ]; then
        printf '%s\n' "$CMUX_SURFACE_ID"
        return 0
      fi
      local json surface
      if json="$(cmux identify --json 2>/dev/null)"; then
        surface="$(agmsg_pane_json_extract "$json" '$.caller.surface_ref' 2>/dev/null || true)"
        if [ -n "$surface" ]; then
          printf '%s\n' "$surface"
          return 0
        fi
      fi
      return 1
      ;;
    wezterm)
      [ -n "${WEZTERM_PANE:-}" ] || return 1
      printf '%s\n' "$WEZTERM_PANE"
      ;;
    *)
      return 1
      ;;
  esac
}

agmsg_pane_socket() {
  local backend="${1:-}"
  case "$backend" in
    herdr)
      printf '%s\n' "${HERDR_SOCKET_PATH:-}"
      ;;
    wezterm)
      printf '%s\n' "${WEZTERM_UNIX_SOCKET:-${KAKU_UNIX_SOCKET:-}}"
      ;;
    *)
      printf '\n'
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
  local socket="${4:-}"
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
    herdr)
      agmsg_pane_herdr "$socket" pane send-text "$addr" "$text" >/dev/null || return 1
      sleep "$delay"
      agmsg_pane_herdr "$socket" pane send-keys "$addr" enter >/dev/null || return 1
      sleep "$delay"
      agmsg_pane_herdr "$socket" pane send-keys "$addr" enter >/dev/null
      ;;
    cmux)
      cmux send --surface "$addr" -- "$text" >/dev/null || return 1
      sleep "$delay"
      cmux send-key --surface "$addr" -- Enter >/dev/null || return 1
      sleep "$delay"
      cmux send-key --surface "$addr" -- Enter >/dev/null
      ;;
    wezterm)
      agmsg_pane_wezterm "$socket" cli send-text --pane-id "$addr" --no-paste -- "$text" || return 1
      sleep "$delay"
      printf '\r' | agmsg_pane_wezterm "$socket" cli send-text --pane-id "$addr" --no-paste || return 1
      sleep "$delay"
      printf '\r' | agmsg_pane_wezterm "$socket" cli send-text --pane-id "$addr" --no-paste
      ;;
    *)
      echo "agmsg pane: unsupported backend: $backend" >&2
      return 1
      ;;
  esac
}

agmsg_pane_wezterm() {
  local socket="$1"
  shift
  if [ -n "$socket" ]; then
    WEZTERM_UNIX_SOCKET="$socket" wezterm "$@"
  else
    wezterm "$@"
  fi
}

agmsg_pane_herdr() {
  local socket="$1"
  shift
  if [ -n "$socket" ]; then
    HERDR_SOCKET_PATH="$socket" herdr "$@"
  else
    herdr "$@"
  fi
}

agmsg_pane_alive() {
  local backend="${1:?Usage: agmsg_pane_alive BACKEND ADDR}"
  local addr="${2:?Missing pane address}"
  local socket="${3:-}"

  case "$backend" in
    tmux)
      command -v tmux >/dev/null 2>&1 || return 1
      tmux list-panes -a -F '#{pane_id}' 2>/dev/null | grep -Fx -- "$addr" >/dev/null
      ;;
    herdr)
      command -v herdr >/dev/null 2>&1 || return 1
      agmsg_pane_herdr "$socket" pane get "$addr" >/dev/null 2>&1
      ;;
    cmux)
      command -v cmux >/dev/null 2>&1 || return 1
      cmux read-screen --surface "$addr" >/dev/null 2>&1 && return 0
      cmux list-panels 2>/dev/null | grep -F -- "$addr" >/dev/null
      ;;
    wezterm)
      command -v wezterm >/dev/null 2>&1 || return 1
      local panes found
      if panes="$(agmsg_pane_wezterm "$socket" cli list --format json 2>/dev/null)"; then
        found="$(sqlite3 :memory: \
          ".param set :json '$(agmsg_pane_sql_quote "$panes")'" \
          ".param set :addr '$(agmsg_pane_sql_quote "$addr")'" \
          "SELECT EXISTS(
             SELECT 1
             FROM json_each(:json)
             WHERE CAST(COALESCE(json_extract(value, '$.pane_id'), json_extract(value, '$.paneId'), '') AS TEXT) = :addr
           );" 2>/dev/null | tr -d '\r' || true)"
        [ "$found" = "1" ] && return 0
      fi
      panes="$(agmsg_pane_wezterm "$socket" cli list 2>/dev/null)" || return 1
      printf '%s\n' "$panes" | grep -E "(^|[[:space:]])${addr}($|[[:space:]])" >/dev/null
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
  local socket="$6"
  local owner="${7:-}"

  if command -v sqlite3 >/dev/null 2>&1; then
    local backend_q addr_q project_q type_q registered_at_q socket_q owner_q
    backend_q="$(agmsg_pane_sql_quote "$backend")"
    addr_q="$(agmsg_pane_sql_quote "$addr")"
    project_q="$(agmsg_pane_sql_quote "$project")"
    type_q="$(agmsg_pane_sql_quote "$type")"
    registered_at_q="$(agmsg_pane_sql_quote "$registered_at")"
    socket_q="$(agmsg_pane_sql_quote "$socket")"
    owner_q="$(agmsg_pane_sql_quote "$owner")"
    sqlite3 :memory: \
      "SELECT json_object('backend', '$backend_q', 'addr', '$addr_q', 'project', '$project_q', 'type', '$type_q', 'registered_at', '$registered_at_q', 'socket', '$socket_q', 'owner', '$owner_q');" | tr -d '\r'
    return 0
  fi

  return 1
}

agmsg_pane_registry_write() {
  local team="${1:?Usage: agmsg_pane_registry_write TEAM NAME [TYPE] [PROJECT] [OWNER]}"
  local name="${2:?Missing agent name}"
  local type="${3:-}"
  local project="${4:-$(pwd)}"
  local owner="${5:-${AGMSG_PANE_OWNER:-}}"
  local backend addr path registered_at json socket

  backend="$(agmsg_pane_backend)"
  [ -n "$backend" ] && [ "$backend" != "none" ] || return 1

  addr="$(agmsg_pane_self "$backend" 2>/dev/null)" || return 1
  [ -n "$addr" ] || return 1
  socket="$(agmsg_pane_socket "$backend")"

  path="$(agmsg_pane_registry_path "$team" "$name")" || return 1
  registered_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  json="$(agmsg_pane_registry_json "$backend" "$addr" "$project" "$type" "$registered_at" "$socket" "$owner")" || return 1

  printf '%s\n' "$json" > "$path"
}

agmsg_pane_registry_field() {
  local line="$1"
  local index="$2"
  local tab rest i
  tab="$(printf '\t')"
  rest="$line"
  i=1
  while [ "$i" -lt "$index" ]; do
    case "$rest" in
      *"$tab"*) rest="${rest#*$tab}" ;;
      *) printf '\n'; return 0 ;;
    esac
    i=$((i + 1))
  done
  case "$rest" in
    *"$tab"*) printf '%s\n' "${rest%%$tab*}" ;;
    *) printf '%s\n' "$rest" ;;
  esac
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
       COALESCE(json_extract(readfile('$sql_path'), '$.type'), ''),
       COALESCE(json_extract(readfile('$sql_path'), '$.socket'), '');" | tr -d '\r'
}

agmsg_pane_registry_owner() {
  local team="${1:?Usage: agmsg_pane_registry_owner TEAM NAME}"
  local name="${2:?Missing agent name}"
  local path sql_path

  path="$(agmsg_pane_registry_path "$team" "$name")" || return 1
  [ -f "$path" ] || return 1
  command -v sqlite3 >/dev/null 2>&1 || return 1

  sql_path="$(agmsg_pane_sql_readfile_path "$path")"
  sqlite3 :memory: \
    "SELECT COALESCE(json_extract(readfile('$sql_path'), '$.owner'), '');" | tr -d '\r'
}

agmsg_pane_registry_clear() {
  local team="${1:?Usage: agmsg_pane_registry_clear TEAM NAME}"
  local name="${2:?Missing agent name}"
  local path

  path="$(agmsg_pane_registry_path "$team" "$name")" || return 1
  rm -f "$path"
}

agmsg_pane_registry_clear_if_owner() {
  local team="${1:?Usage: agmsg_pane_registry_clear_if_owner TEAM NAME OWNER}"
  local name="${2:?Missing agent name}"
  local owner="${3:-}"
  local path stored_owner

  path="$(agmsg_pane_registry_path "$team" "$name")" || return 1
  [ -f "$path" ] || return 0

  stored_owner="$(agmsg_pane_registry_owner "$team" "$name" 2>/dev/null || true)"
  if [ -z "$stored_owner" ] || [ "$stored_owner" = "$owner" ]; then
    rm -f "$path"
    return 0
  fi
  return 1
}
