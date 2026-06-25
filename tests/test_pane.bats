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

@test "pane: cli unregister clears registration" {
  AGMSG_PANE_BACKEND=tmux AGMSG_PANE_SELF=%9 bash "$SCRIPTS/pane.sh" register opus48 executor codex /tmp/x >/dev/null

  run bash "$SCRIPTS/pane.sh" unregister opus48 executor
  [ "$status" -eq 0 ]

  run bash "$SCRIPTS/pane.sh" lookup opus48 executor
  [ "$status" -ne 0 ]
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

  run env AGMSG_PANE_COMMIT_DELAY=0 WEZTERM_EXPECT_SOCKET=/tmp/kaku.sock bash "$SCRIPTS/pane.sh" test opus48 executor
  [ "$status" -eq 0 ]
}
