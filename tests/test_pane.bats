#!/usr/bin/env bats

load test_helper

setup() {
  setup_test_env
}

teardown() {
  teardown_test_env
}

_install_fake_tmux() {
  mkdir -p "$TEST_SKILL_DIR/bin"
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' 'case "$1" in'
    printf '%s\n' '  list-panes) printf '"'"'%%9\n'"'"' ;;'
    printf '%s\n' '  *) exit 0 ;;'
    printf '%s\n' 'esac'
  } > "$TEST_SKILL_DIR/bin/tmux"
  chmod +x "$TEST_SKILL_DIR/bin/tmux"
  export PATH="$TEST_SKILL_DIR/bin:$PATH"
}

_install_fake_wezterm() {
  mkdir -p "$TEST_SKILL_DIR/bin"
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' 'if [ -n "${WEZTERM_EXPECT_SOCKET:-}" ] && [ "${WEZTERM_UNIX_SOCKET:-}" != "$WEZTERM_EXPECT_SOCKET" ]; then exit 7; fi'
    printf '%s\n' 'if [ "$1" = cli ] && [ "$2" = list ]; then printf '"'"'[{"pane_id":6}]\n'"'"'; exit 0; fi'
    printf '%s\n' 'if [ "$1" = cli ] && [ "$2" = send-text ]; then case " $* " in *" -- "*) exit 0 ;; *) cat >/dev/null || true; exit 0 ;; esac; fi'
    printf '%s\n' 'exit 0'
  } > "$TEST_SKILL_DIR/bin/wezterm"
  chmod +x "$TEST_SKILL_DIR/bin/wezterm"
  export PATH="$TEST_SKILL_DIR/bin:$PATH"
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
  [ "$output" = $'tmux\t%9\t/tmp/x\tcodex\t' ]
}

@test "pane: registry_write stores owner and clear-if-owner guards newer registrations" {
  run env AGMSG_PANE_BACKEND=tmux AGMSG_PANE_SELF=%9 bash -c 'source "$1/lib/pane.sh"; agmsg_pane_registry_write opus48 executor codex /tmp/x owner-a; agmsg_pane_registry_owner opus48 executor' _ "$SCRIPTS"
  [ "$status" -eq 0 ]
  [ "$output" = "owner-a" ]

  run bash -c 'source "$1/lib/pane.sh"; agmsg_pane_registry_clear_if_owner opus48 executor owner-b || true; agmsg_pane_registry_read opus48 executor' _ "$SCRIPTS"
  [ "$status" -eq 0 ]
  [ "$output" = $'tmux\t%9\t/tmp/x\tcodex\t' ]

  run bash -c 'source "$1/lib/pane.sh"; agmsg_pane_registry_clear_if_owner opus48 executor owner-a; agmsg_pane_registry_read opus48 executor' _ "$SCRIPTS"
  [ "$status" -ne 0 ]
}

@test "pane: clear-if-owner removes legacy ownerless registrations" {
  AGMSG_PANE_BACKEND=tmux AGMSG_PANE_SELF=%9 bash -c 'source "$1/lib/pane.sh"; agmsg_pane_registry_write opus48 executor codex /tmp/x' _ "$SCRIPTS"

  run bash -c 'source "$1/lib/pane.sh"; agmsg_pane_registry_clear_if_owner opus48 executor owner-a; agmsg_pane_registry_read opus48 executor' _ "$SCRIPTS"
  [ "$status" -ne 0 ]
}

@test "pane: registry_write stores wezterm socket" {
  run env AGMSG_PANE_BACKEND=wezterm AGMSG_PANE_SELF=6 KAKU_UNIX_SOCKET=/tmp/kaku.sock bash -c 'source "$1/lib/pane.sh"; agmsg_pane_registry_write opus48 executor codex /tmp/x; agmsg_pane_registry_read opus48 executor' _ "$SCRIPTS"
  [ "$status" -eq 0 ]
  [ "$output" = $'wezterm\t6\t/tmp/x\tcodex\t/tmp/kaku.sock' ]
}

@test "pane: cli lookup prints machine-readable registration" {
  AGMSG_PANE_BACKEND=tmux AGMSG_PANE_SELF=%9 bash "$SCRIPTS/pane.sh" register opus48 executor codex /tmp/x >/dev/null

  run bash "$SCRIPTS/pane.sh" lookup opus48 executor
  [ "$status" -eq 0 ]
  [ "$output" = $'tmux\t%9\t/tmp/x\tcodex\t' ]
}

@test "pane: status defaults to current project teams and --all keeps global view" {
  local project_a="$BATS_TEST_TMPDIR/project-a"
  local project_b="$BATS_TEST_TMPDIR/project-b"
  mkdir -p "$project_a" "$project_b"
  AGMSG_ANNOUNCE_JOIN=0 bash "$SCRIPTS/join.sh" opus48 executor codex "$project_a" >/dev/null
  AGMSG_ANNOUNCE_JOIN=0 bash "$SCRIPTS/join.sh" my1pick scout codex "$project_b" >/dev/null
  AGMSG_PANE_BACKEND=tmux AGMSG_PANE_SELF=%9 bash "$SCRIPTS/pane.sh" register opus48 executor codex "$project_a" >/dev/null
  AGMSG_PANE_BACKEND=tmux AGMSG_PANE_SELF=%10 bash "$SCRIPTS/pane.sh" register my1pick scout codex "$project_b" >/dev/null

  run env PROJECT="$project_a" SCRIPTS="$SCRIPTS" bash -c 'cd "$PROJECT" && bash "$SCRIPTS/pane.sh" status'
  [ "$status" -eq 0 ]
  [[ "$output" == *$'opus48\texecutor'* ]]
  [[ "$output" != *"my1pick"* ]]

  run env PROJECT="$project_a" SCRIPTS="$SCRIPTS" bash -c 'cd "$PROJECT" && bash "$SCRIPTS/pane.sh" status --all'
  [ "$status" -eq 0 ]
  [[ "$output" == *$'opus48\texecutor'* ]]
  [[ "$output" == *$'my1pick\tscout'* ]]
}

@test "pane: doctor defaults to current project teams and --all keeps global collision checks" {
  _install_fake_tmux
  local project_a="$BATS_TEST_TMPDIR/project-a"
  local project_b="$BATS_TEST_TMPDIR/project-b"
  mkdir -p "$project_a" "$project_b"
  AGMSG_ANNOUNCE_JOIN=0 bash "$SCRIPTS/join.sh" opus48 executor codex "$project_a" >/dev/null
  AGMSG_ANNOUNCE_JOIN=0 bash "$SCRIPTS/join.sh" my1pick scout codex "$project_b" >/dev/null
  AGMSG_PANE_BACKEND=tmux AGMSG_PANE_SELF=%9 bash "$SCRIPTS/pane.sh" register opus48 executor codex "$project_a" >/dev/null
  AGMSG_PANE_BACKEND=tmux AGMSG_PANE_SELF=%9 bash "$SCRIPTS/pane.sh" register my1pick scout codex "$project_b" >/dev/null

  run env PROJECT="$project_a" SCRIPTS="$SCRIPTS" AGMSG_PANE_BACKEND=tmux AGMSG_PANE_SELF=%9 TMUX=tmux-session TMUX_PANE=%9 bash -c 'cd "$PROJECT" && bash "$SCRIPTS/pane.sh" doctor'
  [ "$status" -eq 0 ]
  [[ "$output" =~ "registry opus48/executor: present" ]]
  [[ "$output" != *"my1pick"* ]]
  [[ "$output" != *"COLLISION"* ]]
  [[ "$output" =~ "verdict: ok" ]]

  run env PROJECT="$project_a" SCRIPTS="$SCRIPTS" AGMSG_PANE_BACKEND=tmux AGMSG_PANE_SELF=%9 TMUX=tmux-session TMUX_PANE=%9 bash -c 'cd "$PROJECT" && bash "$SCRIPTS/pane.sh" doctor --all'
  [ "$status" -eq 0 ]
  [[ "$output" =~ "registry opus48/executor: present" ]]
  [[ "$output" =~ "registry my1pick/scout: present" ]]
  [[ "$output" =~ "COLLISION" ]]
  [[ "$output" =~ "verdict: collision (duplicate pane addr:" ]]
}

@test "pane: cli unregister clears registration" {
  AGMSG_PANE_BACKEND=tmux AGMSG_PANE_SELF=%9 bash "$SCRIPTS/pane.sh" register opus48 executor codex /tmp/x >/dev/null

  run bash "$SCRIPTS/pane.sh" unregister opus48 executor
  [ "$status" -eq 0 ]

  run bash "$SCRIPTS/pane.sh" lookup opus48 executor
  [ "$status" -ne 0 ]
}

@test "pane: test reports responsive when ping is consumed" {
  _install_fake_tmux
  AGMSG_PANE_BACKEND=tmux AGMSG_PANE_SELF=%9 bash "$SCRIPTS/pane.sh" register opus48 executor codex /tmp/x owner-a >/dev/null

  (
    for _ in {1..30}; do
      out="$(bash "$SCRIPTS/inbox.sh" opus48 executor --quiet 2>/dev/null || true)"
      case "$out" in
        *"ctrl:ping "*) exit 0 ;;
      esac
      sleep 0.1
    done
    exit 1
  ) &
  local consumer=$!

  run env AGMSG_PANE_COMMIT_DELAY=0 bash "$SCRIPTS/pane.sh" test --timeout 5 opus48 executor
  wait "$consumer" || true
  [ "$status" -eq 0 ]
  [[ "$output" =~ "status=responsive" ]]
}

@test "pane: test reports unresponsive without consuming ping" {
  _install_fake_tmux
  AGMSG_PANE_BACKEND=tmux AGMSG_PANE_SELF=%9 bash "$SCRIPTS/pane.sh" register opus48 executor codex /tmp/x owner-a >/dev/null

  run env AGMSG_PANE_COMMIT_DELAY=0 bash "$SCRIPTS/pane.sh" test --timeout 0 opus48 executor
  [ "$status" -eq 0 ]
  [[ "$output" =~ "status=unresponsive" ]]
  [[ "$output" =~ "reason=ping-timeout" ]]
}

@test "pane: test reports unresponsive when registered pane is gone" {
  _install_fake_tmux
  AGMSG_PANE_BACKEND=tmux AGMSG_PANE_SELF=%10 bash "$SCRIPTS/pane.sh" register opus48 executor codex /tmp/x owner-a >/dev/null

  run bash "$SCRIPTS/pane.sh" test --timeout 0 opus48 executor
  [ "$status" -eq 0 ]
  [[ "$output" =~ "status=unresponsive" ]]
  [[ "$output" =~ "reason=pane-not-alive" ]]
}

@test "pane: doctor exits zero and reports missing backend" {
  run env AGMSG_PANE_BACKEND=none bash "$SCRIPTS/pane.sh" doctor
  [ "$status" -eq 0 ]
  [[ "$output" =~ "detected backend: none" ]]
  [[ "$output" =~ "self addr: (none)" ]]
  [[ "$output" =~ "env hints: (none)" ]]
  [[ "$output" =~ "registry: none" ]]
  [[ "$output" =~ "verdict: no tmux/cmux pane backend detected" ]]
}

@test "pane: doctor reports injected backend self and env hints without cmux" {
  run env AGMSG_PANE_BACKEND=cmux AGMSG_PANE_SELF=surface:42 CMUX_SURFACE_ID=surface:42 bash "$SCRIPTS/pane.sh" doctor
  [ "$status" -eq 0 ]
  [[ "$output" =~ "detected backend: cmux" ]]
  [[ "$output" =~ "self addr: surface:42" ]]
  [[ "$output" =~ "env hints: CMUX_SURFACE_ID=surface:42" ]]
  [[ "$output" =~ "registry: none" ]]
  [[ "$output" =~ "verdict: no pane registered" ]]
}

@test "pane: doctor reports specific registry and alive state" {
  _install_fake_tmux
  AGMSG_PANE_BACKEND=tmux AGMSG_PANE_SELF=%9 bash "$SCRIPTS/pane.sh" register opus48 executor codex /tmp/x >/dev/null

  run env AGMSG_PANE_BACKEND=tmux AGMSG_PANE_SELF=%9 TMUX=tmux-session TMUX_PANE=%9 bash "$SCRIPTS/pane.sh" doctor opus48 executor
  [ "$status" -eq 0 ]
  [[ "$output" =~ "detected backend: tmux" ]]
  [[ "$output" =~ "self addr: %9" ]]
  [[ "$output" =~ "env hints: TMUX=tmux-session TMUX_PANE=%9" ]]
  [[ "$output" =~ "registry opus48/executor: present" ]]
  [[ "$output" =~ "registry opus48/executor backend: tmux" ]]
  [[ "$output" =~ "registry opus48/executor addr: %9" ]]
  [[ "$output" =~ "registry opus48/executor project: /tmp/x" ]]
  [[ "$output" =~ "registry opus48/executor alive: alive" ]]
  [[ "$output" =~ "verdict: ok" ]]
}

@test "pane: doctor flags two members sharing one addr as a collision" {
  # Two workers registered to the same cmux surface — the pane-push collision
  # from BUG-spawn-shared-pane-collision. doctor must not report "ok".
  AGMSG_PANE_BACKEND=cmux AGMSG_PANE_SELF=surface:11 bash "$SCRIPTS/pane.sh" register my1pick scout codex /tmp/x >/dev/null
  AGMSG_PANE_BACKEND=cmux AGMSG_PANE_SELF=surface:11 bash "$SCRIPTS/pane.sh" register my1pick executor codex /tmp/x >/dev/null

  run env AGMSG_PANE_BACKEND=cmux AGMSG_PANE_SELF=surface:11 CMUX_SURFACE_ID=surface:11 bash "$SCRIPTS/pane.sh" doctor --all
  [ "$status" -eq 0 ]
  [[ "$output" =~ "COLLISION" ]]
  [[ "$output" =~ "verdict: collision (duplicate pane addr:" ]]
}

@test "pane: doctor reports missing specific registry" {
  run env AGMSG_PANE_BACKEND=wezterm AGMSG_PANE_SELF=6 bash "$SCRIPTS/pane.sh" doctor opus48 executor
  [ "$status" -eq 0 ]
  [[ "$output" =~ "detected backend: wezterm" ]]
  [[ "$output" =~ "self addr: 6" ]]
  [[ "$output" =~ "registry opus48/executor: missing" ]]
  [[ "$output" =~ "verdict: no pane registered" ]]
}

@test "pane: doctor and test use stored wezterm socket" {
  _install_fake_wezterm
  AGMSG_PANE_BACKEND=wezterm AGMSG_PANE_SELF=6 KAKU_UNIX_SOCKET=/tmp/kaku.sock bash "$SCRIPTS/pane.sh" register opus48 executor codex /tmp/x >/dev/null

  run env AGMSG_PANE_BACKEND=wezterm AGMSG_PANE_SELF=6 WEZTERM_PANE=6 KAKU_UNIX_SOCKET=/tmp/kaku.sock WEZTERM_EXPECT_SOCKET=/tmp/kaku.sock bash "$SCRIPTS/pane.sh" doctor opus48 executor
  [ "$status" -eq 0 ]
  [[ "$output" =~ "detected backend: wezterm" ]]
  [[ "$output" =~ "self addr: 6" ]]
  [[ "$output" =~ "env hints: WEZTERM_PANE=6 KAKU_UNIX_SOCKET=/tmp/kaku.sock" ]]
  [[ "$output" =~ "registry opus48/executor: present" ]]
  [[ "$output" =~ "registry opus48/executor backend: wezterm" ]]
  [[ "$output" =~ "registry opus48/executor addr: 6" ]]
  [[ "$output" =~ "registry opus48/executor project: /tmp/x" ]]
  [[ "$output" =~ "registry opus48/executor alive: alive" ]]
  [[ "$output" =~ "verdict: ok" ]]

  run env AGMSG_PANE_TEST_TIMEOUT=0 AGMSG_PANE_COMMIT_DELAY=0 WEZTERM_EXPECT_SOCKET=/tmp/kaku.sock bash "$SCRIPTS/pane.sh" test opus48 executor
  [ "$status" -eq 0 ]
  [[ "$output" =~ "status=unresponsive" ]]
}
