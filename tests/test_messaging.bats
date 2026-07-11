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

_install_fake_cmux() {
  mkdir -p "$TEST_SKILL_DIR/bin"
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' 'case "$1" in'
    printf '%s\n' '  read-screen) exit 0 ;;'
    printf '%s\n' '  send|send-key) printf '"'"'OK surface:6 workspace:3\n'"'"'; exit 0 ;;'
    printf '%s\n' '  *) exit 0 ;;'
    printf '%s\n' 'esac'
  } > "$TEST_SKILL_DIR/bin/cmux"
  chmod +x "$TEST_SKILL_DIR/bin/cmux"
  export PATH="$TEST_SKILL_DIR/bin:$PATH"
}

_install_fake_herdr() {
  mkdir -p "$TEST_SKILL_DIR/bin"
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' 'if [ "$1" = pane ] && [ "$2" = get ]; then [ "$3" = w1:p1 ] && exit 0 || exit 1; fi'
    printf '%s\n' 'if [ "$1" = pane ] && { [ "$2" = send-text ] || [ "$2" = send-keys ]; }; then exit 0; fi'
    printf '%s\n' 'exit 0'
  } > "$TEST_SKILL_DIR/bin/herdr"
  chmod +x "$TEST_SKILL_DIR/bin/herdr"
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

@test "send: suppresses cmux command stdout while nudging" {
  _install_fake_cmux
  AGMSG_PANE_BACKEND=cmux AGMSG_PANE_SELF=surface:6 bash "$SCRIPTS/pane.sh" register testteam bob claude-code /tmp/project-b >/dev/null

  run env AGMSG_PANE_COMMIT_DELAY=0 bash "$SCRIPTS/send.sh" testteam alice bob "hello cmux pane"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "pane-push: nudged bob (cmux surface:6)" ]]
  [[ "$output" != *"OK surface:"* ]]
}

@test "send: nudges registered herdr pane with stored socket" {
  _install_fake_herdr
  AGMSG_PANE_BACKEND=herdr AGMSG_PANE_SELF=w1:p1 HERDR_SOCKET_PATH=/tmp/herdr.sock \
    bash "$SCRIPTS/pane.sh" register testteam bob claude-code /tmp/project-b >/dev/null

  run env AGMSG_PANE_COMMIT_DELAY=0 HERDR_SOCKET_PATH=/tmp/herdr.sock bash "$SCRIPTS/send.sh" testteam alice bob "hello herdr pane"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "pane-push: nudged bob (herdr w1:p1)" ]]
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

@test "inbox: a crafted agent arg cannot inject SQL to delete other messages (#87)" {
  bash "$SCRIPTS/send.sh" testteam alice bob "keepme"
  run bash "$SCRIPTS/inbox.sh" testteam "bob' AND read_at IS NULL; DELETE FROM messages; --"
  [ "$status" -eq 0 ]
  run bash "$SCRIPTS/inbox.sh" testteam bob
  [[ "$output" =~ "keepme" ]]
}

@test "inbox: an agent name containing a quote still receives its own messages (#87)" {
  bash "$SCRIPTS/join.sh" testteam "o'brien" claude-code /tmp/project-c
  bash "$SCRIPTS/send.sh" testteam alice "o'brien" "for quote"
  run bash "$SCRIPTS/inbox.sh" testteam "o'brien"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "for quote" ]]
}

@test "check-inbox: a team name containing a quote still delivers without a SQL error (#87)" {
  local project; project="$(mktemp -d)"
  bash "$SCRIPTS/join.sh" "te'am" carol claude-code "$project"
  bash "$SCRIPTS/send.sh" "te'am" alice carol "quoted team delivery"
  run bash -c "echo '{}' | bash '$SCRIPTS/check-inbox.sh' claude-code '$project'"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "quoted team delivery" ]]
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

@test "history: a non-numeric limit falls back to the default instead of injecting SQL (#87)" {
  bash "$SCRIPTS/send.sh" testteam alice bob "msg1"
  bash "$SCRIPTS/send.sh" testteam alice bob "msg2"
  run bash "$SCRIPTS/history.sh" testteam bob "1; DELETE FROM messages; --"
  [ "$status" -eq 0 ]
  run bash "$SCRIPTS/history.sh" testteam
  [[ "$output" =~ "msg1" ]]
  [[ "$output" =~ "msg2" ]]
}

@test "history: a team/agent name containing a quote does not break the query (#87)" {
  bash "$SCRIPTS/join.sh" testteam "o'brien" claude-code /tmp/project-c
  bash "$SCRIPTS/send.sh" testteam alice "o'brien" "for quote"
  run bash "$SCRIPTS/history.sh" testteam "o'brien"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "for quote" ]]
}
