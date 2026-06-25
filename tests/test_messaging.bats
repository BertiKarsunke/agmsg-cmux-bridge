#!/usr/bin/env bats

load test_helper

setup() {
  setup_test_env
  export AGMSG_PANE_BACKEND=none
  # Create a team and two agents
  bash "$SCRIPTS/join.sh" testteam alice claude-code /tmp/project-a
  bash "$SCRIPTS/join.sh" testteam bob claude-code /tmp/project-b
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
    printf '%s\n' '  send-keys) exit 0 ;;'
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

# --- send.sh ---

@test "send: delivers a message" {
  run bash "$SCRIPTS/send.sh" testteam alice bob "hello"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "Sent to bob" ]]
}

@test "send: warns when target has no pane registration" {
  run bash "$SCRIPTS/send.sh" testteam alice bob "hello without pane"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "pane-push: no pane registered for bob (delivered via inbox only)" ]]
}

@test "send: warns when pane registration has no backend or address" {
  mkdir -p "$TEST_SKILL_DIR/run"
  printf '%s\n' '{"backend":"","addr":"","project":"/tmp/project-b","type":"claude-code"}' > "$TEST_SKILL_DIR/run/pane.testteam.bob.json"

  run bash "$SCRIPTS/send.sh" testteam alice bob "hello with empty pane"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "pane-push: no pane registered for bob (delivered via inbox only)" ]]
}

@test "send: stays silent when pane push is disabled or self-sending" {
  run env AGMSG_PANE_PUSH=0 bash "$SCRIPTS/send.sh" testteam alice bob "disabled"
  [ "$status" -eq 0 ]
  [[ ! "$output" =~ pane-push: ]]

  run bash "$SCRIPTS/send.sh" testteam alice alice "self"
  [ "$status" -eq 0 ]
  [[ ! "$output" =~ pane-push: ]]
}

@test "send: nudges registered live pane" {
  _install_fake_tmux
  AGMSG_PANE_BACKEND=tmux AGMSG_PANE_SELF=%9 bash "$SCRIPTS/pane.sh" register testteam bob claude-code /tmp/project-b >/dev/null

  run env AGMSG_PANE_COMMIT_DELAY=0 bash "$SCRIPTS/send.sh" testteam alice bob "hello live pane"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "pane-push: nudged bob (tmux %9)" ]]
}

@test "send: nudges registered wezterm pane with stored socket" {
  _install_fake_wezterm
  AGMSG_PANE_BACKEND=wezterm AGMSG_PANE_SELF=6 KAKU_UNIX_SOCKET=/tmp/kaku.sock bash "$SCRIPTS/pane.sh" register testteam bob claude-code /tmp/project-b >/dev/null

  run env AGMSG_PANE_COMMIT_DELAY=0 WEZTERM_EXPECT_SOCKET=/tmp/kaku.sock bash "$SCRIPTS/send.sh" testteam alice bob "hello wezterm pane"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "pane-push: nudged bob (wezterm 6)" ]]
}

@test "send: fails without required args" {
  run bash "$SCRIPTS/send.sh"
  [ "$status" -ne 0 ]
}

# --- inbox.sh ---

@test "inbox: shows no messages when empty" {
  run bash "$SCRIPTS/inbox.sh" testteam alice
  [ "$status" -eq 0 ]
  [[ "$output" =~ "No new messages" ]]
}

@test "inbox: shows received message" {
  bash "$SCRIPTS/send.sh" testteam alice bob "hello bob"
  run bash "$SCRIPTS/inbox.sh" testteam bob
  [ "$status" -eq 0 ]
  [[ "$output" =~ "hello bob" ]]
  [[ "$output" =~ "alice" ]]
}

@test "inbox: marks messages as read" {
  bash "$SCRIPTS/send.sh" testteam alice bob "read me"
  bash "$SCRIPTS/inbox.sh" testteam bob >/dev/null
  run bash "$SCRIPTS/inbox.sh" testteam bob
  [ "$status" -eq 0 ]
  [[ "$output" =~ "No new messages" ]]
}

@test "inbox: --quiet suppresses output when no messages" {
  run bash "$SCRIPTS/inbox.sh" testteam alice --quiet
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "inbox: --quiet shows output when messages exist" {
  bash "$SCRIPTS/send.sh" testteam bob alice "ping"
  run bash "$SCRIPTS/inbox.sh" testteam alice --quiet
  [ "$status" -eq 0 ]
  [[ "$output" =~ "ping" ]]
}

@test "inbox: handles multiline message body" {
  bash "$SCRIPTS/send.sh" testteam alice bob "line1
line2
line3"
  run bash "$SCRIPTS/inbox.sh" testteam bob
  [ "$status" -eq 0 ]
  [[ "$output" =~ "1 new message" ]]
  [[ "$output" =~ "alice" ]]
}

@test "history: handles multiline message body" {
  bash "$SCRIPTS/send.sh" testteam alice bob "multi
line"
  run bash "$SCRIPTS/history.sh" testteam
  [ "$status" -eq 0 ]
  [[ "$output" =~ "alice" ]]
  [[ "$output" =~ "bob" ]]
}

# --- history.sh ---

@test "history: shows message history" {
  bash "$SCRIPTS/send.sh" testteam alice bob "msg1"
  bash "$SCRIPTS/send.sh" testteam bob alice "msg2"
  run bash "$SCRIPTS/history.sh" testteam
  [ "$status" -eq 0 ]
  [[ "$output" =~ "msg1" ]]
  [[ "$output" =~ "msg2" ]]
}

@test "history: filters by agent" {
  bash "$SCRIPTS/send.sh" testteam alice bob "for bob"
  bash "$SCRIPTS/send.sh" testteam bob alice "for alice"
  run bash "$SCRIPTS/history.sh" testteam alice
  [ "$status" -eq 0 ]
  [[ "$output" =~ "for" ]]
}

@test "history: respects limit" {
  bash "$SCRIPTS/send.sh" testteam alice bob "msg1"
  bash "$SCRIPTS/send.sh" testteam alice bob "msg2"
  bash "$SCRIPTS/send.sh" testteam alice bob "msg3"
  # limit=1 should return exactly 1 line with arrow
  run bash "$SCRIPTS/history.sh" testteam "" 1
  [ "$status" -eq 0 ]
  local count=$(echo "$output" | grep -c "→")
  [ "$count" -eq 1 ]
}

@test "history: shows no history message when empty" {
  run bash "$SCRIPTS/history.sh" testteam
  [ "$status" -eq 0 ]
  [[ "$output" =~ "No message history" ]]
}
