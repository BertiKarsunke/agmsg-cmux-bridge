#!/usr/bin/env bats

load test_helper

setup() {
  export FAKE_HOME="$(mktemp -d)"
  export REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export SK="$FAKE_HOME/.agents/skills/agmsg"
  export AGMSG_AGENT_PID=""
  export AGMSG_PANE_BACKEND=none
}

teardown() {
  rm -rf "$FAKE_HOME"
}

@test "uninstall: removes only owned role blocks and keeps user additions" {
  HOME="$FAKE_HOME" bash "$REPO_ROOT/install.sh" --cmd agmsg
  printf 'user agents note\n' >> "$FAKE_HOME/.codex/AGENTS.md"
  printf 'user planner note\n' >> "$FAKE_HOME/.codex/agmsg/planner.md"
  printf 'user claude main note\n' >> "$FAKE_HOME/.claude/CLAUDE.md"
  printf 'user claude role note\n' >> "$FAKE_HOME/.claude/CLAUDE-agmsg.md"

  HOME="$FAKE_HOME" bash "$SK/uninstall.sh" --yes

  grep -q '^user agents note$' "$FAKE_HOME/.codex/AGENTS.md"
  grep -q '^user planner note$' "$FAKE_HOME/.codex/agmsg/planner.md"
  grep -q '^user claude main note$' "$FAKE_HOME/.claude/CLAUDE.md"
  grep -q '^user claude role note$' "$FAKE_HOME/.claude/CLAUDE-agmsg.md"
  ! rg -q 'agmsg:ROLE-ENTRY|agmsg:ROLE-DOC|agmsg:IMPORT|agmsg:CLAUDE-ROLE-DOC' \
    "$FAKE_HOME/.codex/AGENTS.md" "$FAKE_HOME/.codex/agmsg/planner.md" \
    "$FAKE_HOME/.claude/CLAUDE.md" "$FAKE_HOME/.claude/CLAUDE-agmsg.md"
  [ ! -e "$FAKE_HOME/.codex/agmsg/workers.md" ]
  [ ! -e "$FAKE_HOME/.codex/agmsg/options/scout.yaml" ]
}

@test "uninstall: malformed managed role block is preserved" {
  HOME="$FAKE_HOME" bash "$REPO_ROOT/install.sh" --cmd agmsg
  printf '<!-- agmsg:ROLE-ENTRY:START -->\n' >> "$FAKE_HOME/.codex/AGENTS.md"
  cp "$FAKE_HOME/.codex/AGENTS.md" "$BATS_TEST_TMPDIR/agents.before"

  run env HOME="$FAKE_HOME" bash "$SK/uninstall.sh" --yes
  [ "$status" -eq 0 ]
  [[ "$output" =~ "malformed or duplicate managed markers" ]]
  cmp "$BATS_TEST_TMPDIR/agents.before" "$FAKE_HOME/.codex/AGENTS.md"
}

@test "uninstall: a block owned by another command is not removed" {
  HOME="$FAKE_HOME" bash "$REPO_ROOT/install.sh" --cmd agmsg
  sed 's/agmsg:owner=agmsg/agmsg:owner=other/' "$FAKE_HOME/.codex/AGENTS.md" > "$BATS_TEST_TMPDIR/agents.changed"
  mv "$BATS_TEST_TMPDIR/agents.changed" "$FAKE_HOME/.codex/AGENTS.md"

  run env HOME="$FAKE_HOME" bash "$SK/uninstall.sh" --yes
  [ "$status" -eq 0 ]
  [[ "$output" =~ "not owned by command 'agmsg'" ]]
  grep -q '<!-- agmsg:owner=other -->' "$FAKE_HOME/.codex/AGENTS.md"
  grep -q '<!-- agmsg:ROLE-ENTRY:START -->' "$FAKE_HOME/.codex/AGENTS.md"
}

@test "install then uninstall restores shared files without final newlines and their modes" {
  mkdir -p "$FAKE_HOME/.codex" "$FAKE_HOME/.claude"
  printf 'user codex body' > "$FAKE_HOME/.codex/AGENTS.md"
  printf '@USER.md' > "$FAKE_HOME/.claude/CLAUDE.md"
  chmod 640 "$FAKE_HOME/.codex/AGENTS.md" "$FAKE_HOME/.claude/CLAUDE.md"
  cp -p "$FAKE_HOME/.codex/AGENTS.md" "$BATS_TEST_TMPDIR/agents.before"
  cp -p "$FAKE_HOME/.claude/CLAUDE.md" "$BATS_TEST_TMPDIR/claude.before"

  HOME="$FAKE_HOME" bash "$REPO_ROOT/install.sh" --cmd agmsg
  HOME="$FAKE_HOME" bash "$SK/uninstall.sh" --yes

  cmp "$BATS_TEST_TMPDIR/agents.before" "$FAKE_HOME/.codex/AGENTS.md"
  cmp "$BATS_TEST_TMPDIR/claude.before" "$FAKE_HOME/.claude/CLAUDE.md"
  [ "$(ls -l "$FAKE_HOME/.codex/AGENTS.md" | cut -c1-10)" = "$(ls -l "$BATS_TEST_TMPDIR/agents.before" | cut -c1-10)" ]
  [ "$(ls -l "$FAKE_HOME/.claude/CLAUDE.md" | cut -c1-10)" = "$(ls -l "$BATS_TEST_TMPDIR/claude.before" | cut -c1-10)" ]
}
