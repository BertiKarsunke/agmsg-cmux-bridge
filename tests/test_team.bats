#!/usr/bin/env bats

load test_helper

setup() {
  setup_test_env
  export AGMSG_PANE_PUSH=0
}

teardown() {
  teardown_test_env
}

# --- join.sh ---

@test "join: creates team and adds agent" {
  run bash "$SCRIPTS/join.sh" myteam alice claude-code /tmp/proj
  [ "$status" -eq 0 ]
  [[ "$output" =~ "Joined team myteam as alice" ]]
}

@test "join: creates team config on first join" {
  bash "$SCRIPTS/join.sh" newteam first claude-code /tmp/proj
  [ -f "$TEST_SKILL_DIR/teams/newteam/config.json" ]
}

@test "join: adds multiple agents to same team" {
  bash "$SCRIPTS/join.sh" myteam alice claude-code /tmp/proj-a
  bash "$SCRIPTS/join.sh" myteam bob codex /tmp/proj-b
  run bash "$SCRIPTS/team.sh" myteam
  [[ "$output" =~ "alice" ]]
  [[ "$output" =~ "bob" ]]
  [[ "$output" =~ "2 member" ]]
}

@test "join: re-join with same name adds registration instead of duplicate agent" {
  bash "$SCRIPTS/join.sh" myteam alice claude-code /tmp/proj-a
  bash "$SCRIPTS/join.sh" myteam alice claude-code /tmp/proj-b
  run bash "$SCRIPTS/team.sh" myteam
  [ "$status" -eq 0 ]
  [[ "$output" =~ "alice" ]]
  [[ "$output" =~ "1 member" ]]
  [[ "$output" =~ "+1 more" ]]
}

@test "join: announces newly joined members to planner" {
  bash "$SCRIPTS/join.sh" myteam planner claude-code /tmp/proj-planner
  bash "$SCRIPTS/join.sh" myteam executor codex /tmp/proj-executor
  run bash "$SCRIPTS/inbox.sh" myteam planner
  [ "$status" -eq 0 ]
  [[ "$output" =~ "1 new message" ]]
  [[ "$output" == *"[JOIN] executor (codex) joined team myteam"* ]]
  [[ "$output" == *"project=/tmp/proj-executor"* ]]
}

@test "join: does not announce when join announcements are disabled" {
  bash "$SCRIPTS/join.sh" myteam planner claude-code /tmp/proj-planner
  AGMSG_ANNOUNCE_JOIN=0 bash "$SCRIPTS/join.sh" myteam executor codex /tmp/proj-executor
  run bash "$SCRIPTS/inbox.sh" myteam planner
  [ "$status" -eq 0 ]
  [[ "$output" =~ "No new messages." ]]
}

@test "join: does not announce existing members rejoining" {
  bash "$SCRIPTS/join.sh" myteam planner claude-code /tmp/proj-planner
  bash "$SCRIPTS/join.sh" myteam executor codex /tmp/proj-executor
  bash "$SCRIPTS/inbox.sh" myteam planner >/dev/null
  bash "$SCRIPTS/join.sh" myteam executor codex /tmp/proj-executor-2
  run bash "$SCRIPTS/inbox.sh" myteam planner
  [ "$status" -eq 0 ]
  [[ "$output" =~ "No new messages." ]]
}

@test "join: does not announce when planner is absent or is the joining member" {
  bash "$SCRIPTS/join.sh" noleader executor codex /tmp/proj-executor
  run bash "$SCRIPTS/inbox.sh" noleader planner
  [ "$status" -eq 0 ]
  [[ "$output" =~ "No new messages." ]]

  bash "$SCRIPTS/join.sh" selfteam planner claude-code /tmp/proj-planner
  run bash "$SCRIPTS/inbox.sh" selfteam planner
  [ "$status" -eq 0 ]
  [[ "$output" =~ "No new messages." ]]
}

@test "join: concurrent joins to the same team do not lose registrations (#141)" {
  # A fan-out of background joins spawning sqlite3.exe per call is slow and
  # timing-sensitive on the Windows runner (the experimental full leg); the lock
  # itself is exercised on Linux/macOS where the contention is reliable.
  skip_on_windows "concurrency fan-out is too slow/timing-sensitive on the Windows runner"
  # The registry config.json was read-modify-written with no serialization, so
  # concurrent joins clobbered each other and silently dropped agents. Launch a
  # fan-out of joins at once; every one must survive. This fails (count < N+1) if
  # the per-team lock regresses.
  local n=12
  bash "$SCRIPTS/join.sh" race seed claude-code /tmp/seed
  local pids=() i
  for i in $(seq 1 "$n"); do
    bash "$SCRIPTS/join.sh" race "agent$i" claude-code "/tmp/p$i" >/dev/null 2>&1 &
    pids+=($!)
  done
  for i in "${pids[@]}"; do wait "$i"; done

  local cfg="$TEST_SKILL_DIR/teams/race/config.json"
  run sqlite_mem "SELECT count(*) FROM json_each(json_extract(CAST(readfile('$(rf "$cfg")') AS TEXT), '\$.agents'));"
  [ "$status" -eq 0 ]
  [ "$output" -eq $((n + 1)) ]
}

@test "join: releases its lock (no .config.lock left behind)" {
  bash "$SCRIPTS/join.sh" myteam alice claude-code /tmp/proj
  [ ! -e "$TEST_SKILL_DIR/teams/myteam/.config.lock" ]
}

# --- leave.sh ---

@test "leave: removes agent from team" {
  bash "$SCRIPTS/join.sh" myteam alice claude-code /tmp/proj
  bash "$SCRIPTS/join.sh" myteam bob claude-code /tmp/proj-b
  run bash "$SCRIPTS/leave.sh" myteam alice
  [ "$status" -eq 0 ]
  [[ "$output" =~ "Left team myteam" ]]
  run bash "$SCRIPTS/team.sh" myteam
  [[ ! "$output" =~ "alice" ]]
  [[ "$output" =~ "bob" ]]
}

@test "leave: removes team dir when last member leaves" {
  bash "$SCRIPTS/join.sh" myteam alice claude-code /tmp/proj
  bash "$SCRIPTS/leave.sh" myteam alice
  [ ! -d "$TEST_SKILL_DIR/teams/myteam" ]
}

# --- team.sh ---

@test "team: shows team members with types" {
  bash "$SCRIPTS/join.sh" myteam alice claude-code /tmp/proj-a
  bash "$SCRIPTS/join.sh" myteam bob codex /tmp/proj-b
  run bash "$SCRIPTS/team.sh" myteam
  [ "$status" -eq 0 ]
  [[ "$output" =~ "alice" ]]
  [[ "$output" =~ "claude-code" ]]
  [[ "$output" =~ "bob" ]]
  [[ "$output" =~ "codex" ]]
}

# --- whoami.sh ---

record_whoami_binding() {
  local team="$1" agent="$2" sid="$3" project="$4" type="$5"
  SKILL_DIR="$TEST_SKILL_DIR" bash -c '
    source "$SKILL_DIR/scripts/lib/role-session.sh"
    agmsg_role_session_record "$1" "$2" "$3" "$4" "$5"
  ' _ "$team" "$agent" "$sid" "$project" "$type"
}

@test "whoami: returns agent identity" {
  bash "$SCRIPTS/join.sh" myteam alice claude-code /tmp/proj
  record_whoami_binding myteam alice session-1 /tmp/proj claude-code
  CLAUDE_CODE_SESSION_ID=session-1 run bash "$SCRIPTS/whoami.sh" /tmp/proj claude-code
  [ "$status" -eq 0 ]
  [[ "$output" =~ "agent=alice" ]]
  [[ "$output" =~ "teams=myteam" ]]
}

@test "whoami: a stored registration without a session binding is only a candidate" {
  local project="$TEST_SKILL_DIR/myteam"
  mkdir -p "$project"
  bash "$SCRIPTS/join.sh" myteam alice claude-code "$project"
  run env -u CLAUDE_CODE_SESSION_ID bash "$SCRIPTS/whoami.sh" "$project" claude-code
  [ "$status" -eq 0 ]
  [[ "$output" =~ "selection_required=true" ]]
  [[ "$output" =~ "reason=project_team_requires_agent" ]]
  [[ "$output" =~ "candidate_agents=alice" ]]
  [[ "$output" =~ "candidate_teams=myteam" ]]
  [[ "$output" =~ "selected_team=myteam" ]]
  [[ "$output" =~ "team_source=project" ]]
  [[ ! "$output" =~ "agent=alice" ]]
}

@test "whoami: resolves project paths containing single quotes" {
  local project="$TEST_SKILL_DIR/pro'j"
  mkdir -p "$project/subdir"
  bash "$SCRIPTS/join.sh" myteam alice claude-code "$project"
  record_whoami_binding myteam alice quote-session "$project" claude-code
  CLAUDE_CODE_SESSION_ID=quote-session run bash "$SCRIPTS/whoami.sh" "$project/subdir" claude-code
  [ "$status" -eq 0 ]
  [[ "$output" =~ "agent=alice" ]]
  [[ "$output" =~ "teams=myteam" ]]
  [[ "$output" =~ "project=$project" ]]
  [[ ! "$output" =~ "not_joined=true" ]]
  [[ ! "$output" =~ ".parameter" ]]
}

@test "whoami: resolves team and agent names containing single quotes" {
  local team="O'Brien"
  local agent="al'ice"
  bash "$SCRIPTS/join.sh" "$team" "$agent" claude-code /tmp/proj
  record_whoami_binding "$team" "$agent" quote-session /tmp/proj claude-code
  CLAUDE_CODE_SESSION_ID=quote-session run bash "$SCRIPTS/whoami.sh" /tmp/proj claude-code
  [ "$status" -eq 0 ]
  [[ "$output" =~ "agent=$agent" ]]
  [[ "$output" =~ "teams=$team" ]]
  [[ ! "$output" =~ ".parameter" ]]
}

@test "whoami: ignores malformed team configs without sqlite parameter output" {
  mkdir -p "$TEST_SKILL_DIR/teams/bad"
  printf '{' > "$TEST_SKILL_DIR/teams/bad/config.json"
  run bash "$SCRIPTS/whoami.sh" /tmp/proj claude-code
  [ "$status" -eq 0 ]
  [[ "$output" =~ "not_joined=true" ]]
  [[ ! "$output" =~ ".parameter" ]]
  [[ ! "$output" =~ "malformed JSON" ]]
}

@test "whoami: returns not_joined when no match" {
  run bash "$SCRIPTS/whoami.sh" /tmp/unknown claude-code
  [ "$status" -eq 0 ]
  [[ "$output" =~ "not_joined=true" ]]
  [[ "$output" =~ "selected_team=unknown" ]]
  [[ "$output" =~ "team_source=project" ]]
}

@test "whoami: an old exact registration cannot replace the project basename team" {
  local project="$TEST_SKILL_DIR/current-project"
  mkdir -p "$project"
  bash "$SCRIPTS/join.sh" opus48 executor codex "$project"
  run env -u CODEX_THREAD_ID bash "$SCRIPTS/whoami.sh" "$project" codex
  [ "$status" -eq 0 ]
  [[ "$output" =~ "not_joined=true" ]]
  [[ "$output" =~ "selected_team=current-project" ]]
  [[ "$output" =~ "team_source=project" ]]
  [[ ! "$output" =~ "executor" ]]
}

@test "whoami: resolved project root basename is stable from a subdirectory" {
  local project="$TEST_SKILL_DIR/folder-team"
  mkdir -p "$project/sub/dir"
  bash "$SCRIPTS/join.sh" folder-team executor codex "$project"
  run env -u CODEX_THREAD_ID bash "$SCRIPTS/whoami.sh" "$project/sub/dir" codex
  [ "$status" -eq 0 ]
  [[ "$output" =~ "selection_required=true" ]]
  [[ "$output" =~ "candidate_agents=executor" ]]
  [[ "$output" =~ "selected_team=folder-team" ]]
  [[ "$output" =~ "project=$project" ]]
}

@test "whoami: returns all candidates when multiple identities are unbound" {
  bash "$SCRIPTS/join.sh" proj alice claude-code /tmp/proj
  bash "$SCRIPTS/join.sh" proj reviewer claude-code /tmp/proj
  run env -u CLAUDE_CODE_SESSION_ID bash "$SCRIPTS/whoami.sh" /tmp/proj claude-code
  [ "$status" -eq 0 ]
  [[ "$output" =~ "selection_required=true" ]]
  [[ "$output" =~ "reason=project_team_requires_agent" ]]
  [[ "$output" =~ "alice" ]]
  [[ "$output" =~ "reviewer" ]]
}

@test "whoami: explicit team is a hard candidate filter and does not infer an unbound sole role" {
  bash "$SCRIPTS/join.sh" opus48 old-executor codex /tmp/proj
  bash "$SCRIPTS/join.sh" agmsg-cmux executor codex /tmp/proj
  run bash "$SCRIPTS/whoami.sh" /tmp/proj codex --team agmsg-cmux
  [ "$status" -eq 0 ]
  [[ "$output" =~ "selection_required=true" ]]
  [[ "$output" =~ "reason=explicit_team_requires_agent" ]]
  [[ "$output" =~ "candidate_agents=executor" ]]
  [[ "$output" =~ "candidate_teams=agmsg-cmux" ]]
  [[ "$output" =~ "selected_team=agmsg-cmux" ]]
  [[ ! "$output" =~ "old-executor" ]]
}

@test "whoami: explicit team returns its single valid current-session binding" {
  bash "$SCRIPTS/join.sh" opus48 old-executor codex /tmp/proj
  bash "$SCRIPTS/join.sh" agmsg-cmux executor codex /tmp/proj
  record_whoami_binding agmsg-cmux executor current-thread /tmp/proj codex
  CODEX_THREAD_ID=current-thread run bash "$SCRIPTS/whoami.sh" /tmp/proj codex --team agmsg-cmux
  [ "$status" -eq 0 ]
  [[ "$output" =~ "agent=executor" ]]
  [[ "$output" =~ "teams=agmsg-cmux" ]]
  [[ ! "$output" =~ "selection_required=true" ]]
  [[ ! "$output" =~ "old-executor" ]]
}

@test "whoami: positional team filter remains supported" {
  bash "$SCRIPTS/join.sh" myteam alice codex /tmp/proj
  run bash "$SCRIPTS/whoami.sh" /tmp/proj codex myteam
  [ "$status" -eq 0 ]
  [[ "$output" =~ "selection_required=true" ]]
  [[ "$output" =~ "candidate_agents=alice" ]]
  [[ "$output" =~ "selected_team=myteam" ]]
}

@test "whoami: explicit team with no project registration does not fall back" {
  bash "$SCRIPTS/join.sh" opus48 old-executor codex /tmp/proj
  run bash "$SCRIPTS/whoami.sh" /tmp/proj codex --team agmsg-cmux
  [ "$status" -eq 0 ]
  [[ "$output" =~ "not_joined=true" ]]
  [[ "$output" =~ "selected_team=agmsg-cmux" ]]
  [[ ! "$output" =~ "old-executor" ]]
}

@test "whoami: rejects an empty explicit team" {
  run bash "$SCRIPTS/whoami.sh" /tmp/proj codex --team ""
  [ "$status" -eq 2 ]
  [[ "$output" =~ "Usage:" ]]
}

@test "whoami: ignores a stale session binding" {
  bash "$SCRIPTS/join.sh" proj alice codex /tmp/proj
  record_whoami_binding proj alice old-thread /tmp/proj codex
  CODEX_THREAD_ID=new-thread run bash "$SCRIPTS/whoami.sh" /tmp/proj codex
  [ "$status" -eq 0 ]
  [[ "$output" =~ "selection_required=true" ]]
  [[ "$output" =~ "reason=project_team_requires_agent" ]]
}

@test "whoami: ignores bindings whose recorded project or type is wrong" {
  bash "$SCRIPTS/join.sh" proj alice codex /tmp/proj
  record_whoami_binding proj alice thread-1 /tmp/other codex
  CODEX_THREAD_ID=thread-1 run bash "$SCRIPTS/whoami.sh" /tmp/proj codex
  [[ "$output" =~ "selection_required=true" ]]

  record_whoami_binding proj alice thread-1 /tmp/proj claude-code
  CODEX_THREAD_ID=thread-1 run bash "$SCRIPTS/whoami.sh" /tmp/proj codex
  [[ "$output" =~ "selection_required=true" ]]
}

@test "whoami: ignores an unregistered role-session record" {
  bash "$SCRIPTS/join.sh" proj alice codex /tmp/proj
  record_whoami_binding proj ghost thread-1 /tmp/proj codex
  CODEX_THREAD_ID=thread-1 run bash "$SCRIPTS/whoami.sh" /tmp/proj codex
  [ "$status" -eq 0 ]
  [[ "$output" =~ "selection_required=true" ]]
  [[ "$output" =~ "candidate_agents=alice" ]]
  [[ ! "$output" =~ "ghost" ]]
}

@test "whoami: rejects multiple valid bindings for the current session" {
  bash "$SCRIPTS/join.sh" team-a alice codex /tmp/proj
  bash "$SCRIPTS/join.sh" team-b bob codex /tmp/proj
  record_whoami_binding team-a alice shared-thread /tmp/proj codex
  record_whoami_binding team-b bob shared-thread /tmp/proj codex
  CODEX_THREAD_ID=shared-thread run bash "$SCRIPTS/whoami.sh" /tmp/proj codex
  [ "$status" -eq 0 ]
  [[ "$output" =~ "selection_required=true" ]]
  [[ "$output" =~ "reason=ambiguous_session_binding" ]]
  [[ "$output" =~ "candidate_agents=alice,bob" ]]
  [[ "$output" =~ "candidate_teams=team-a,team-b" ]]
}

@test "whoami: same role in multiple teams is ambiguous until its bound team is explicit" {
  bash "$SCRIPTS/join.sh" team-a executor codex /tmp/proj
  bash "$SCRIPTS/join.sh" team-b executor codex /tmp/proj
  record_whoami_binding team-a executor shared-thread /tmp/proj codex
  record_whoami_binding team-b executor shared-thread /tmp/proj codex
  CODEX_THREAD_ID=shared-thread run bash "$SCRIPTS/whoami.sh" /tmp/proj codex
  [[ "$output" =~ "reason=ambiguous_session_binding" ]]

  CODEX_THREAD_ID=shared-thread run bash "$SCRIPTS/whoami.sh" /tmp/proj codex --team team-b
  [[ "$output" =~ "agent=executor" ]]
  [[ "$output" =~ "teams=team-b" ]]
  [[ ! "$output" =~ "team-a" ]]
}

@test "whoami: lists available teams when not joined" {
  bash "$SCRIPTS/join.sh" team1 alice claude-code /tmp/other
  run bash "$SCRIPTS/whoami.sh" /tmp/nothere claude-code
  [[ "$output" =~ "available_teams=team1" ]]
}

@test "whoami: finds re-joined agent in another project registration" {
  bash "$SCRIPTS/join.sh" myteam alice claude-code /tmp/proj-a
  bash "$SCRIPTS/join.sh" myteam alice claude-code /tmp/proj-b
  record_whoami_binding myteam alice session-b /tmp/proj-b claude-code
  CLAUDE_CODE_SESSION_ID=session-b run bash "$SCRIPTS/whoami.sh" /tmp/proj-b claude-code
  [ "$status" -eq 0 ]
  [[ "$output" =~ "agent=alice" ]]
  [[ "$output" =~ "teams=myteam" ]]
}

@test "whoami: registrations elsewhere do not override the project basename team" {
  bash "$SCRIPTS/join.sh" myteam alice claude-code /tmp/proj-a
  run bash "$SCRIPTS/whoami.sh" /tmp/proj-b claude-code
  [ "$status" -eq 0 ]
  [[ "$output" =~ "not_joined=true" ]]
  [[ "$output" =~ "selected_team=proj-b" ]]
  [[ "$output" =~ "team_source=project" ]]
  [[ ! "$output" =~ "agents=alice" ]]
  [[ "$output" =~ "available_teams=myteam" ]]
}

@test "whoami: auto-detects claude-code from CLAUDE_CODE_SESSION_ID env" {
  bash "$SCRIPTS/join.sh" myteam alice claude-code /tmp/proj
  record_whoami_binding myteam alice test-session /tmp/proj claude-code
  CLAUDE_CODE_SESSION_ID=test-session run bash "$SCRIPTS/whoami.sh" /tmp/proj
  [ "$status" -eq 0 ]
  [[ "$output" =~ "agent=alice" ]]
  [[ "$output" =~ "type=claude-code" ]]
}

@test "whoami: auto-detects codex from CODEX_SANDBOX env" {
  bash "$SCRIPTS/join.sh" proj bob codex /tmp/proj
  # Unset CLAUDE_CODE_SESSION_ID: bats can run under a CC session that
  # already exports it, which would shadow the codex signal under the
  # CLAUDE_CODE_SESSION_ID-first detection order.
  unset CLAUDE_CODE_SESSION_ID
  CODEX_SANDBOX=seatbelt run bash "$SCRIPTS/whoami.sh" /tmp/proj
  [ "$status" -eq 0 ]
  [[ "$output" =~ "selection_required=true" ]]
  [[ "$output" =~ "candidate_agents=bob" ]]
  [[ "$output" =~ "type=codex" ]]
}

@test "whoami: auto-detects codex from CODEX_THREAD_ID env" {
  bash "$SCRIPTS/join.sh" myteam bob codex /tmp/proj
  record_whoami_binding myteam bob some-thread /tmp/proj codex
  unset CLAUDE_CODE_SESSION_ID
  CODEX_THREAD_ID=some-thread run bash "$SCRIPTS/whoami.sh" /tmp/proj
  [ "$status" -eq 0 ]
  [[ "$output" =~ "agent=bob" ]]
  [[ "$output" =~ "type=codex" ]]
}

@test "whoami: defaults to claude-code when no env vars set" {
  bash "$SCRIPTS/join.sh" proj alice claude-code /tmp/proj
  unset CLAUDE_CODE_SESSION_ID CODEX_SANDBOX CODEX_THREAD_ID GEMINI_API_KEY GOOGLE_GEMINI_CLI
  local fake_bin="$BATS_TEST_TMPDIR/no-proc-detect-bin"
  mkdir -p "$fake_bin"
  cat > "$fake_bin/ps" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
  chmod +x "$fake_bin/ps"
  PATH="$fake_bin:$PATH" run bash "$SCRIPTS/whoami.sh" /tmp/proj
  [ "$status" -eq 0 ]
  [[ "$output" =~ "selection_required=true" ]]
  [[ "$output" =~ "candidate_agents=alice" ]]
  [[ "$output" =~ "type=claude-code" ]]
}

@test "whoami: explicit type overrides auto-detection" {
  bash "$SCRIPTS/join.sh" proj alice claude-code /tmp/proj
  bash "$SCRIPTS/join.sh" myteam bob codex /tmp/proj
  CODEX_SANDBOX=test run bash "$SCRIPTS/whoami.sh" /tmp/proj claude-code
  [ "$status" -eq 0 ]
  [[ "$output" =~ "selection_required=true" ]]
  [[ "$output" =~ "candidate_agents=alice" ]]
  [[ "$output" =~ "type=claude-code" ]]
}

# --- reset.sh ---

@test "reset: unbound candidate requires an explicit agent id" {
  bash "$SCRIPTS/join.sh" proj alice claude-code /tmp/proj
  run env -u CLAUDE_CODE_SESSION_ID bash "$SCRIPTS/reset.sh" /tmp/proj claude-code
  [ "$status" -eq 1 ]
  [[ "$output" =~ "Identity selection is required" ]]
  [[ "$output" =~ "Pass an agent_id explicitly" ]]
  run bash "$SCRIPTS/team.sh" proj
  [[ "$output" =~ "alice" ]]
}

@test "reset: removes only current project registration" {
  bash "$SCRIPTS/join.sh" myteam alice claude-code /tmp/proj-a
  bash "$SCRIPTS/join.sh" myteam alice claude-code /tmp/proj-b
  run bash "$SCRIPTS/reset.sh" /tmp/proj-a claude-code alice
  [ "$status" -eq 0 ]
  [[ "$output" =~ "removed 1 registration" ]]
  run bash "$SCRIPTS/whoami.sh" /tmp/proj-a claude-code
  [[ "$output" =~ "not_joined=true" ]]
  record_whoami_binding myteam alice session-b /tmp/proj-b claude-code
  CLAUDE_CODE_SESSION_ID=session-b run bash "$SCRIPTS/whoami.sh" /tmp/proj-b claude-code
  [[ "$output" =~ "agent=alice" ]]
}

@test "reset: removes agent when last registration is cleared" {
  bash "$SCRIPTS/join.sh" myteam alice claude-code /tmp/proj-a
  run bash "$SCRIPTS/reset.sh" /tmp/proj-a claude-code alice
  [ "$status" -eq 0 ]
  [[ "$output" =~ "removed 1 registration" ]]
  [ ! -d "$TEST_SKILL_DIR/teams/myteam" ]
}

# --- rename-team.sh ---

@test "rename-team: renames the team dir and updates config.json name" {
  bash "$SCRIPTS/join.sh" oldteam alice claude-code /tmp/proj
  run bash "$SCRIPTS/rename-team.sh" oldteam newteam
  [ "$status" -eq 0 ]
  [[ "$output" =~ "Renamed team oldteam → newteam" ]]
  [ ! -d "$TEST_SKILL_DIR/teams/oldteam" ]
  [ -f "$TEST_SKILL_DIR/teams/newteam/config.json" ]
  run sqlite_mem "SELECT json_extract(readfile('$(rf "$TEST_SKILL_DIR/teams/newteam/config.json")'), '\$.name');"
  [ "$output" = "newteam" ]
}

@test "rename-team: preserves agents in the team" {
  bash "$SCRIPTS/join.sh" oldteam alice claude-code /tmp/proj-a
  bash "$SCRIPTS/join.sh" oldteam bob   codex       /tmp/proj-b
  bash "$SCRIPTS/rename-team.sh" oldteam newteam
  run bash "$SCRIPTS/team.sh" newteam
  [ "$status" -eq 0 ]
  [[ "$output" =~ "alice" ]]
  [[ "$output" =~ "bob" ]]
  [[ "$output" =~ "2 member" ]]
}

@test "rename-team: migrates messages to the new team name" {
  bash "$SCRIPTS/join.sh" oldteam alice claude-code /tmp/proj-a
  bash "$SCRIPTS/join.sh" oldteam bob   claude-code /tmp/proj-b
  bash "$SCRIPTS/send.sh" oldteam alice bob "hello"
  bash "$SCRIPTS/rename-team.sh" oldteam newteam
  run bash "$SCRIPTS/inbox.sh" newteam bob
  [ "$status" -eq 0 ]
  [[ "$output" =~ "hello" ]]
}

@test "rename-team: fails when old team is missing" {
  run bash "$SCRIPTS/rename-team.sh" nope newname
  [ "$status" -ne 0 ]
  [[ "$output" =~ "Team not found: nope" ]]
}

@test "rename-team: fails when new team already exists" {
  bash "$SCRIPTS/join.sh" team-a alice claude-code /tmp/proj-a
  bash "$SCRIPTS/join.sh" team-b bob   claude-code /tmp/proj-b
  run bash "$SCRIPTS/rename-team.sh" team-a team-b
  [ "$status" -ne 0 ]
  [[ "$output" =~ "Team already exists: team-b" ]]
}

@test "rename-team: an inert empty target dir does not block the rename" {
  # The target is reserved by holding teams/<new>/.config.lock, so an existing
  # but config-less dir (e.g. left by an aborted rename) must not count as a team.
  bash "$SCRIPTS/join.sh" oldteam alice claude-code /tmp/proj
  mkdir -p "$TEST_SKILL_DIR/teams/newteam"
  run bash "$SCRIPTS/rename-team.sh" oldteam newteam
  [ "$status" -eq 0 ]
  [ -f "$TEST_SKILL_DIR/teams/newteam/config.json" ]
  [ ! -e "$TEST_SKILL_DIR/teams/newteam/.config.lock" ]
  run bash "$SCRIPTS/team.sh" newteam
  [[ "$output" =~ "alice" ]]
}

@test "rename-team: fails when old and new are identical" {
  bash "$SCRIPTS/join.sh" sameteam alice claude-code /tmp/proj
  run bash "$SCRIPTS/rename-team.sh" sameteam sameteam
  [ "$status" -ne 0 ]
  [[ "$output" =~ "same" ]]
}

@test "join: rejects unknown agent type" {
  run bash "$SCRIPTS/join.sh" myteam alice claude /tmp/proj
  [ "$status" -ne 0 ]
  [[ "$output" =~ "Unknown agent type" ]]
}

@test "join: accepts claude-code" {
  run bash "$SCRIPTS/join.sh" myteam alice claude-code /tmp/proj
  [ "$status" -eq 0 ]
}

@test "join: accepts codex" {
  run bash "$SCRIPTS/join.sh" myteam alice codex /tmp/proj
  [ "$status" -eq 0 ]
}

@test "join: accepts gemini" {
  run bash "$SCRIPTS/join.sh" myteam alice gemini /tmp/proj
  [ "$status" -eq 0 ]
}

@test "join: accepts antigravity" {
  run bash "$SCRIPTS/join.sh" myteam alice antigravity /tmp/proj
  [ "$status" -eq 0 ]
}

@test "join: accepts opencode" {
  run bash "$SCRIPTS/join.sh" myteam alice opencode /tmp/proj
  [ "$status" -eq 0 ]
}
# --- #140: team-name path traversal ---

@test "join: rejects a team name with path traversal (../)" {
  run bash "$SCRIPTS/join.sh" "../../escape-join" alice claude-code /tmp/proj
  [ "$status" -eq 1 ]
  [[ "$output" =~ "path traversal" ]]
  # Nothing was created outside teams/.
  [ ! -f "$(dirname "$TEST_SKILL_DIR")/escape-join/config.json" ]
}

@test "join: rejects '..' and '.' as team names" {
  run bash "$SCRIPTS/join.sh" ".." alice claude-code /tmp/proj
  [ "$status" -eq 1 ]
  [[ "$output" =~ "not allowed" ]]
  run bash "$SCRIPTS/join.sh" "." alice claude-code /tmp/proj
  [ "$status" -eq 1 ]
}

@test "join: rejects a team name starting with '-'" {
  run bash "$SCRIPTS/join.sh" "-rf" alice claude-code /tmp/proj
  [ "$status" -eq 1 ]
  [[ "$output" =~ "must not start with" ]]
}

@test "join: rejects an empty team name" {
  run bash "$SCRIPTS/join.sh" "" alice claude-code /tmp/proj
  [ "$status" -ne 0 ]
}

@test "team: rejects a traversal team name" {
  run bash "$SCRIPTS/team.sh" "../../escape-team"
  [ "$status" -eq 1 ]
  [[ "$output" =~ "path traversal" ]]
}

@test "leave: rejects a traversal team name" {
  run bash "$SCRIPTS/leave.sh" "../../escape-leave" alice
  [ "$status" -eq 1 ]
  [[ "$output" =~ "path traversal" ]]
}

@test "rename: rejects a traversal team name" {
  run bash "$SCRIPTS/rename.sh" "../../escape-rename" old new
  [ "$status" -eq 1 ]
  [[ "$output" =~ "path traversal" ]]
}

@test "rename-team: rejects traversal on the new name and does not move outside teams/" {
  bash "$SCRIPTS/join.sh" srcteam bob claude-code /tmp/proj
  run bash "$SCRIPTS/rename-team.sh" srcteam "../../escape-renamed"
  [ "$status" -eq 1 ]
  [[ "$output" =~ "path traversal" ]]
  [ ! -f "$(dirname "$TEST_SKILL_DIR")/escape-renamed/config.json" ]
  # Source team is untouched.
  [ -f "$TEST_SKILL_DIR/teams/srcteam/config.json" ]
}

@test "rename-team: rejects traversal on the old name" {
  run bash "$SCRIPTS/rename-team.sh" "../../escape-old" newteam
  [ "$status" -eq 1 ]
  [[ "$output" =~ "path traversal" ]]
}

@test "join: still accepts a UTF-8 (Japanese) team name" {
  run bash "$SCRIPTS/join.sh" "テストチーム" alice claude-code /tmp/proj
  [ "$status" -eq 0 ]
  [ -f "$TEST_SKILL_DIR/teams/テストチーム/config.json" ]
}

@test "join: accepts hermes" {
  run bash "$SCRIPTS/join.sh" myteam alice hermes /tmp/proj
  [ "$status" -eq 0 ]
  [ -f "$TEST_SKILL_DIR/teams/myteam/config.json" ]
}

@test "join: accepts grok-build" {
  run bash "$SCRIPTS/join.sh" myteam alice grok-build /tmp/proj
  [ "$status" -eq 0 ]
  [ -f "$TEST_SKILL_DIR/teams/myteam/config.json" ]
}
