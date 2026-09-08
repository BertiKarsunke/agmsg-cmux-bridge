#!/usr/bin/env bash
set -euo pipefail

# Show the identity bound to this CLI session, or candidates that require an
# explicit role selection. Persistent registrations are candidates, not proof
# that the current session owns a role.
# Bound identity:  agent=<name> teams=<team> type=<type> project=<path>
# Candidates:      selection_required=true candidate_agents=<...> candidate_teams=<...> ...
# Not joined:      not_joined=true selected_team=<team> team_source=<...> ...
#
# Usage: whoami.sh <project_path> [type] [--team <team>|<team>]
#   type: claude-code, codex, gemini, antigravity, copilot, opencode
#   team: optional explicit team filter; never falls back to another team
#   If type is omitted, auto-detect from env vars and process tree.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/type-registry.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/compat.sh"

# Auto-detect CLI type from environment variables and the process tree, driven by
# the per-type manifests' `detect=` (env-var names) and `detect_proc=` (process
# name globs) keys — no hardcoded type list lives here.
detect_cli_type() {
  # `detect=` / `detect_proc=` tokens are split with `read -ra` (IFS word-split,
  # NO pathname expansion) rather than an unquoted `for x in $list` — a file in
  # the caller's cwd matching a pattern like `claude-*` must not glob-eat the
  # pattern. (Plain `set -f` can't be used here: agmsg_known_types discovers types
  # via a `*/` glob that must keep working.)

  # 1. Environment variables. Sorted registry order preserves the historical
  # precedence: a runtime's own session vars (CLAUDE_CODE_SESSION_ID, CODEX_*) are
  # checked before the GEMINI_* family, which users also set for the SDK without
  # the CLI. `detect=explicit` (and types with no detect=) are never auto-detected.
  local _t _v _detect _toks
  while IFS= read -r _t; do
    [ -n "$_t" ] || continue
    _detect="$(agmsg_type_get "$_t" detect)"
    if [ -z "$_detect" ] || [ "$_detect" = "explicit" ]; then
      continue
    fi
    read -ra _toks <<<"$_detect"
    for _v in "${_toks[@]}"; do
      if [ -n "${!_v:-}" ]; then
        echo "$_t"
        return 0
      fi
    done
  done <<EOF
$(agmsg_known_types | sort -u)
EOF

  # 2. Process-tree detection via each type's `detect_proc=` name globs. Walk up
  # from this process; at each ancestor the first type whose glob matches wins
  # (the globs are disjoint, so order within a level is irrelevant).
  local pid=$$ max_depth=10 depth=0 proc_name _pats _pat
  while [ $depth -lt $max_depth ] && [ "$pid" != "1" ] && [ -n "$pid" ]; do
    proc_name=$(compat_get_comm "$pid" 2>/dev/null || true)
    if [ -n "$proc_name" ]; then
      while IFS= read -r _t; do
        [ -n "$_t" ] || continue
        _pats="$(agmsg_type_get "$_t" detect_proc)"
        [ -n "$_pats" ] || continue
        read -ra _toks <<<"$_pats"
        for _pat in "${_toks[@]}"; do
          # $_pat is intentionally an UNQUOTED glob pattern matched against the
          # process name; read -ra already kept it out of pathname expansion.
          # shellcheck disable=SC2254
          case "$proc_name" in
            $_pat) echo "$_t"; return 0 ;;
          esac
        done
      done <<EOF
$(agmsg_known_types | sort -u)
EOF
    fi

    # Move to parent process
    pid=$(compat_get_ppid "$pid" 2>/dev/null || true)
    depth=$((depth + 1))
  done

  # Default fallback
  echo "claude-code"
}

usage() {
  echo "Usage: whoami.sh <project_path> [type] [--team <team>|<team>]" >&2
  exit 2
}

PROJECT_PATH="${1:-}"
[ -n "$PROJECT_PATH" ] || usage
shift

AGENT_TYPE=""
TEAM_FILTER=""
TEAM_FILTER_SET=0
if [ "$#" -gt 0 ]; then
  case "$1" in
    --team|--team=*) ;;
    *) AGENT_TYPE="$1"; shift ;;
  esac
fi
AGENT_TYPE="${AGENT_TYPE:-$(detect_cli_type)}"

if [ "$#" -gt 0 ]; then
  case "$1" in
    --team)
      [ "$#" -ge 2 ] || usage
      TEAM_FILTER="$2"
      TEAM_FILTER_SET=1
      shift 2
      ;;
    --team=*)
      TEAM_FILTER="${1#--team=}"
      TEAM_FILTER_SET=1
      shift
      ;;
    *)
      # Backward-compatible optional positional team argument.
      TEAM_FILTER="$1"
      TEAM_FILTER_SET=1
      shift
      ;;
  esac
fi
[ "$#" -eq 0 ] || usage
[ "$TEAM_FILTER_SET" -eq 0 ] || [ -n "$TEAM_FILTER" ] || usage

# SCRIPT_DIR is already resolved above (before sourcing the type registry).
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TEAMS_DIR="$SCRIPT_DIR/../teams"

# Resolve the session's real project root from the passed pwd (see #92): a cd
# into a subdir/worktree must not be treated as a fresh, unregistered project.
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/resolve-project.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/storage.sh"
PROJECT_PATH="$(agmsg_resolve_project "$PROJECT_PATH" "$AGENT_TYPE")"
PROJECT_TEAM="$(basename "$PROJECT_PATH")"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/role-session.sh"

if [ ! -d "$TEAMS_DIR" ]; then
  if [ "$TEAM_FILTER_SET" -eq 1 ]; then
    echo "not_joined=true selected_team=$TEAM_FILTER team_source=explicit type=$AGENT_TYPE project=$PROJECT_PATH available_teams=none"
  else
    echo "not_joined=true selected_team=$PROJECT_TEAM team_source=project type=$AGENT_TYPE project=$PROJECT_PATH available_teams=none"
  fi
  exit 0
fi

# Exact (project, type) matches come from the shared identities helper.
# Format: each line "<team>\t<agent>".
EXACT_MATCHES="$("$SCRIPT_DIR/identities.sh" "$PROJECT_PATH" "$AGENT_TYPE")"

# An explicit team is a hard boundary. Never select or suggest a registration
# from another team just because it is the only stored match.
if [ "$TEAM_FILTER_SET" -eq 1 ] && [ -n "$EXACT_MATCHES" ]; then
  FILTERED_MATCHES=""
  while IFS=$'\t' read -r match_team match_agent; do
    [ "$match_team" = "$TEAM_FILTER" ] || continue
    FILTERED_MATCHES="${FILTERED_MATCHES:+$FILTERED_MATCHES
}${match_team}"$'\t'"${match_agent}"
  done <<< "$EXACT_MATCHES"
  EXACT_MATCHES="$FILTERED_MATCHES"
fi

# List all registered teams for the not-joined guidance.
ALL_TEAMS=""

for config_file in "$TEAMS_DIR"/*/config.json; do
  [ -f "$config_file" ] || continue
  cfg_sql=$(agmsg_sql_readfile_path "$config_file")
  TEAM_NAME=$(agmsg_sqlite_mem "
    WITH raw(json) AS (SELECT CAST(readfile('$cfg_sql') AS TEXT)),
    cfg(json) AS (SELECT CASE WHEN json_valid(json) THEN json END FROM raw)
    SELECT json_extract(json, '\$.name') FROM cfg;
  ")
  if [ -n "$TEAM_NAME" ] && [ "$TEAM_NAME" != "null" ]; then
    ALL_TEAMS="${ALL_TEAMS:+$ALL_TEAMS,}$TEAM_NAME"
  fi

done

if [ "$TEAM_FILTER_SET" -eq 1 ] && [ -z "$EXACT_MATCHES" ]; then
  echo "not_joined=true selected_team=$TEAM_FILTER team_source=explicit type=$AGENT_TYPE project=$PROJECT_PATH available_teams=${ALL_TEAMS:-none}"
  exit 0
fi

# EXACT_MATCHES from identities.sh is "team\tagent" per line. These are only
# candidates until a role-session record proves this exact CLI session owns one.
# Resolve current session-id values from this type's data-driven `detect=`
# manifest field. Only variables named as session/thread ids are identity
# evidence; generic detection hints such as sandbox flags or API keys are not.
CURRENT_SESSION_IDS=""
DETECT_VARS="$(agmsg_type_get "$AGENT_TYPE" detect)"
read -ra SESSION_VAR_NAMES <<< "$DETECT_VARS"
for session_var_name in "${SESSION_VAR_NAMES[@]}"; do
  case "$session_var_name" in
    *SESSION_ID|*THREAD_ID)
      session_var_value="${!session_var_name:-}"
      [ -n "$session_var_value" ] || continue
      session_var_value="$(agmsg_instance_bare_sid "$session_var_value")"
      CURRENT_SESSION_IDS="${CURRENT_SESSION_IDS:+$CURRENT_SESSION_IDS
}$session_var_value"
      ;;
  esac
done

BOUND_MATCHES=""
if [ -n "$CURRENT_SESSION_IDS" ]; then
  while IFS=$'\t' read -r match_team match_agent; do
    [ -n "$match_team" ] && [ -n "$match_agent" ] || continue
    record_sid="$(agmsg_role_session_get "$match_team" "$match_agent" session)"
    record_team="$(agmsg_role_session_get "$match_team" "$match_agent" team)"
    record_agent="$(agmsg_role_session_get "$match_team" "$match_agent" agent)"
    record_type="$(agmsg_role_session_get "$match_team" "$match_agent" type)"
    record_project="$(agmsg_role_session_get "$match_team" "$match_agent" project)"
    session_matches=0
    while IFS= read -r current_session_id; do
      if [ -n "$current_session_id" ] && [ "$record_sid" = "$current_session_id" ]; then
        session_matches=1
        break
      fi
    done <<< "$CURRENT_SESSION_IDS"
    [ "$session_matches" -eq 1 ] || continue
    [ "$record_team" = "$match_team" ] || continue
    [ "$record_agent" = "$match_agent" ] || continue
    [ "$record_type" = "$AGENT_TYPE" ] || continue
    [ -n "$record_project" ] || continue
    [ "$(agmsg_canonical_path "$record_project")" = "$(agmsg_canonical_path "$PROJECT_PATH")" ] || continue
    BOUND_MATCHES="${BOUND_MATCHES:+$BOUND_MATCHES
}${match_team}"$'\t'"${match_agent}"
  done <<< "$EXACT_MATCHES"
fi

BOUND_COUNT=0
[ -z "$BOUND_MATCHES" ] || BOUND_COUNT=$(printf '%s\n' "$BOUND_MATCHES" | awk 'NF { count++ } END { print count + 0 }')
if [ "$BOUND_COUNT" -eq 1 ]; then
  BOUND_TEAM=$(printf '%s\n' "$BOUND_MATCHES" | cut -f1)
  BOUND_AGENT=$(printf '%s\n' "$BOUND_MATCHES" | cut -f2)
  echo "agent=$BOUND_AGENT teams=$BOUND_TEAM type=$AGENT_TYPE project=$PROJECT_PATH"
  exit 0
fi

if [ "$BOUND_COUNT" -gt 1 ]; then
  TEAM_NAMES=$(echo "$EXACT_MATCHES" | cut -f1 | awk '!seen[$0]++' | paste -sd, -)
  AGENT_NAMES=$(echo "$EXACT_MATCHES" | cut -f2 | awk '!seen[$0]++' | paste -sd, -)
  SELECTION_OUTPUT="selection_required=true reason=ambiguous_session_binding candidate_agents=$AGENT_NAMES candidate_teams=$TEAM_NAMES type=$AGENT_TYPE project=$PROJECT_PATH"
  if [ "$TEAM_FILTER_SET" -eq 1 ]; then
    SELECTION_OUTPUT="$SELECTION_OUTPUT selected_team=$TEAM_FILTER team_source=explicit"
  fi
  echo "$SELECTION_OUTPUT"
  exit 0
fi

if [ "$TEAM_FILTER_SET" -eq 1 ]; then
  TEAM_NAMES=$(echo "$EXACT_MATCHES" | cut -f1 | awk '!seen[$0]++' | paste -sd, -)
  AGENT_NAMES=$(echo "$EXACT_MATCHES" | cut -f2 | awk '!seen[$0]++' | paste -sd, -)
  echo "selection_required=true reason=explicit_team_requires_agent candidate_agents=$AGENT_NAMES candidate_teams=$TEAM_NAMES type=$AGENT_TYPE project=$PROJECT_PATH selected_team=$TEAM_FILTER team_source=explicit"
  exit 0
fi

# With no explicit team and no unique current-session binding, use the resolved
# project basename as the default team. Other stored registrations are neither
# selected nor suggested as a replacement for that team.
PROJECT_MATCHES=""
while IFS=$'\t' read -r match_team match_agent; do
  [ "$match_team" = "$PROJECT_TEAM" ] || continue
  PROJECT_MATCHES="${PROJECT_MATCHES:+$PROJECT_MATCHES
}${match_team}"$'\t'"${match_agent}"
done <<< "$EXACT_MATCHES"

if [ -z "$PROJECT_MATCHES" ]; then
  echo "not_joined=true selected_team=$PROJECT_TEAM team_source=project type=$AGENT_TYPE project=$PROJECT_PATH available_teams=${ALL_TEAMS:-none}"
  exit 0
fi

TEAM_NAMES=$(echo "$PROJECT_MATCHES" | cut -f1 | awk '!seen[$0]++' | paste -sd, -)
AGENT_NAMES=$(echo "$PROJECT_MATCHES" | cut -f2 | awk '!seen[$0]++' | paste -sd, -)
echo "selection_required=true reason=project_team_requires_agent candidate_agents=$AGENT_NAMES candidate_teams=$TEAM_NAMES type=$AGENT_TYPE project=$PROJECT_PATH selected_team=$PROJECT_TEAM team_source=project"
