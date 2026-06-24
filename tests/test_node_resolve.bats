#!/usr/bin/env bats

setup() {
  SCRIPTS="$BATS_TEST_DIRNAME/../scripts"
  FAKE_HOME="$(mktemp -d)"
}

teardown() {
  [ -n "${FAKE_HOME:-}" ] && rm -rf "$FAKE_HOME"
}

make_fake_node() {  # $1 = path to create as an executable stub
  mkdir -p "$(dirname "$1")"
  printf '#!/bin/sh\necho fake-node\n' > "$1"
  chmod +x "$1"
}

@test "resolve_node: prefers node on PATH over a version-manager node" {
  make_fake_node "$FAKE_HOME/.nvm/versions/node/v18.0.0/bin/node"
  # A real node is on the test runner's PATH; it must win.
  run bash -c 'source "'"$SCRIPTS"'/lib/node.sh"; HOME="'"$FAKE_HOME"'" agmsg_resolve_node'
  [ "$status" -eq 0 ]
  [ "$output" = "$(command -v node)" ]
}

@test "resolve_node: finds the newest version-manager node when PATH lacks node" {
  make_fake_node "$FAKE_HOME/.nvm/versions/node/v18.4.0/bin/node"
  make_fake_node "$FAKE_HOME/.nvm/versions/node/v20.11.0/bin/node"
  make_fake_node "$FAKE_HOME/.nvm/versions/node/v9.9.0/bin/node"
  run env -i HOME="$FAKE_HOME" PATH=/usr/bin:/bin bash -c 'source "'"$SCRIPTS"'/lib/node.sh"; agmsg_resolve_node'
  [ "$status" -eq 0 ]
  # Version sort, not lexical: v20.11.0 beats v9.9.0 and v18.4.0.
  [ "$output" = "$FAKE_HOME/.nvm/versions/node/v20.11.0/bin/node" ]
}

@test "resolve_node: honours an explicit AGMSG_NODE override" {
  make_fake_node "$FAKE_HOME/custom/node"
  run env -i HOME="$FAKE_HOME" PATH=/usr/bin:/bin AGMSG_NODE="$FAKE_HOME/custom/node" \
    bash -c 'source "'"$SCRIPTS"'/lib/node.sh"; agmsg_resolve_node'
  [ "$status" -eq 0 ]
  [ "$output" = "$FAKE_HOME/custom/node" ]
}
