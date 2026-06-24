#!/usr/bin/env bats

load test_helper

setup() {
  setup_test_env
}

teardown() {
  teardown_test_env
}

@test "pane: registry_path uses run file under skill dir" {
  run bash -c 'source "$1/lib/pane.sh"; agmsg_pane_registry_path opus48 executor' _ "$SCRIPTS"
  [ "$status" -eq 0 ]
  [ "$output" = "$TEST_SKILL_DIR/run/pane.opus48.executor.json" ]
  [ -d "$TEST_SKILL_DIR/run" ]
}

@test "pane: registry_write and read round-trip with overrides" {
  run env AGMSG_PANE_BACKEND=tmux AGMSG_PANE_SELF=%9 bash -c 'source "$1/lib/pane.sh"; agmsg_pane_registry_write opus48 executor codex /tmp/x; agmsg_pane_registry_read opus48 executor' _ "$SCRIPTS"
  [ "$status" -eq 0 ]
  [ "$output" = $'tmux\t%9\t/tmp/x\tcodex' ]
}

@test "pane: cli lookup prints machine-readable registration" {
  AGMSG_PANE_BACKEND=tmux AGMSG_PANE_SELF=%9 bash "$SCRIPTS/pane.sh" register opus48 executor codex /tmp/x >/dev/null

  run bash "$SCRIPTS/pane.sh" lookup opus48 executor
  [ "$status" -eq 0 ]
  [ "$output" = $'tmux\t%9\t/tmp/x\tcodex' ]
}

@test "pane: cli unregister clears registration" {
  AGMSG_PANE_BACKEND=tmux AGMSG_PANE_SELF=%9 bash "$SCRIPTS/pane.sh" register opus48 executor codex /tmp/x >/dev/null

  run bash "$SCRIPTS/pane.sh" unregister opus48 executor
  [ "$status" -eq 0 ]

  run bash "$SCRIPTS/pane.sh" lookup opus48 executor
  [ "$status" -ne 0 ]
}
