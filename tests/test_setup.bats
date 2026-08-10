#!/usr/bin/env bats

load test_helper

setup() {
  setup_test_env
  export SETUP_CALLS="$TEST_SKILL_DIR/setup-calls"
}

teardown() {
  teardown_test_env
}

@test "agmsg-setup: spawns planner, scout, and executor in order" {
  cat > "$SCRIPTS/spawn.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SETUP_CALLS"
EOF
  chmod +x "$SCRIPTS/spawn.sh"

  local project="$TEST_SKILL_DIR/project with spaces"
  mkdir -p "$project"

  run bash "$SCRIPTS/agmsg-setup.sh" myteam --project "$project"
  [ "$status" -eq 0 ]

  run cat "$SETUP_CALLS"
  [ "$status" -eq 0 ]
  [ "$output" = "claude-code planner --team myteam --project $project
codex scout --team myteam --project $project
codex executor --team myteam --project $project" ]
}

@test "agmsg-setup: stops after the first failed spawn and reports its stage" {
  cat > "$SCRIPTS/spawn.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SETUP_CALLS"
[ "$1/$2" != "codex/scout" ] || exit 42
EOF
  chmod +x "$SCRIPTS/spawn.sh"

  run bash "$SCRIPTS/agmsg-setup.sh" myteam --project "$TEST_SKILL_DIR/project"
  [ "$status" -eq 42 ]
  [[ "$output" == *"spawn failed at codex/scout (exit 42)"* ]]

  run cat "$SETUP_CALLS"
  [ "$status" -eq 0 ]
  [ "$output" = "claude-code planner --team myteam --project $TEST_SKILL_DIR/project
codex scout --team myteam --project $TEST_SKILL_DIR/project" ]
  [[ "$output" != *"executor"* ]]
}
