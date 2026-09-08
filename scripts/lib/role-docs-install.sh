#!/usr/bin/env bash
# Managed role-document install/uninstall helpers.
#
# Only the shared Codex/Claude entrypoints accept a managed block beside user
# content. Companion role documents are whole-file assets: create them when
# absent and update them only when their existing managed block proves that
# the same command owns them.

[ -n "${_AGMSG_ROLE_DOCS_INSTALL_SH:-}" ] && return 0
_AGMSG_ROLE_DOCS_INSTALL_SH=1

agmsg_role_docs_render() {
  local template="$1" output="$2" cmd="$3" skill_dir="$4" role_dir="$5" claude_doc="$6"
  local line
  : > "$output"
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line//__CMD_NAME__/$cmd}"
    line="${line//__SKILL_DIR__/$skill_dir}"
    line="${line//__ROLE_DIR__/$role_dir}"
    line="${line//__CLAUDE_ROLE_DOC__/$claude_doc}"
    printf '%s\n' "$line" >> "$output"
  done < "$template"
}

agmsg_role_docs_marker_state() {
  local target="$1" start="$2" end="$3"
  awk -v start="$start" -v end="$end" '
    $0 == start { starts++; if (inside) invalid=1; inside=1; next }
    $0 == end { ends++; if (!inside) invalid=1; inside=0; next }
    END {
      if (inside) invalid=1
      printf "%d %d %d\n", starts + 0, ends + 0, invalid + 0
    }
  ' "$target"
}

agmsg_role_docs_owner() {
  local target="$1" start="$2" end="$3"
  awk -v start="$start" -v end="$end" '
    $0 == start { inside=1; next }
    $0 == end { inside=0 }
    inside && /agmsg:owner=/ {
      line=$0
      sub(/^.*agmsg:owner=/, "", line)
      sub(/[;[:space:]].*$/, "", line)
      sub(/-->.*/, "", line)
      print line
      exit
    }
  ' "$target"
}

agmsg_role_docs_note_skip() {
  local target="$1" reason="$2"
  echo "  ! role docs: $reason in $target; preserved" >&2
  AGMSG_ROLE_DOCS_SKIPPED="${AGMSG_ROLE_DOCS_SKIPPED}${AGMSG_ROLE_DOCS_SKIPPED:+
}$target"
}

agmsg_role_docs_make_block() {
  local output="$1" start="$2" end="$3" cmd="$4" body="$5" owner_extra="${6:-}"
  {
    printf '%s\n' "$start"
    case "$start" in
      '# '*)
        printf '# agmsg:owner=%s\n' "$cmd"
        [ -n "$owner_extra" ] && printf '# agmsg:%s\n' "${owner_extra#;}"
        ;;
      *)
        printf '<!-- agmsg:owner=%s -->\n' "$cmd"
        [ -n "$owner_extra" ] && printf '<!-- agmsg:%s -->\n' "${owner_extra#;}"
        ;;
    esac
    cat "$body"
    printf '%s\n' "$end"
  } > "$output"
}

# Replace an existing line-delimited block without reserializing the rest of
# the file. cp -p gives the same-directory temporary file the target's mode;
# head/tail copy the prefix and suffix bytes, including a missing final newline.
agmsg_role_docs_replace_block() {
  local target="$1" start="$2" end="$3" block="$4"
  local start_line end_line tmp target_dir
  start_line=$(awk -v marker="$start" '$0 == marker { print NR; exit }' "$target")
  end_line=$(awk -v marker="$end" '$0 == marker { print NR; exit }' "$target")
  target_dir=$(dirname "$target")
  tmp=$(mktemp "$target_dir/.agmsg-role-docs.XXXXXX") || return 1
  cp -p "$target" "$tmp" || { rm -f "$tmp"; return 1; }
  : > "$tmp"
  if [ "$start_line" -gt 1 ]; then
    head -n "$((start_line - 1))" "$target" >> "$tmp"
  fi
  cat "$block" >> "$tmp"
  tail -n "+$((end_line + 1))" "$target" >> "$tmp"
  mv "$tmp" "$target"
}

# Shared entrypoints may contain arbitrary user text around our block.
agmsg_role_docs_upsert_shared_block() {
  local target="$1" start="$2" end="$3" cmd="$4" body="$5"
  local starts ends invalid existing_owner block tmp target_dir owner_extra last_byte
  mkdir -p "$(dirname "$target")"

  if [ -f "$target" ]; then
    read -r starts ends invalid <<EOF
$(agmsg_role_docs_marker_state "$target" "$start" "$end")
EOF
  else
    starts=0; ends=0; invalid=0
  fi

  if [ "$invalid" -ne 0 ] || [ "$starts" -ne "$ends" ] || [ "$starts" -gt 1 ]; then
    agmsg_role_docs_note_skip "$target" "malformed or duplicate managed markers"
    return 0
  fi

  if [ "$starts" -eq 1 ]; then
    existing_owner=$(agmsg_role_docs_owner "$target" "$start" "$end")
    if [ "$existing_owner" != "$cmd" ]; then
      if [ -n "$existing_owner" ]; then
        agmsg_role_docs_note_skip "$target" "managed by command '$existing_owner'; '$cmd' skipped"
      else
        agmsg_role_docs_note_skip "$target" "managed block has no matching owner for command '$cmd'"
      fi
      return 0
    fi
    if awk -v start="$start" -v end="$end" '
      $0 == start { inside=1; next }
      $0 == end { inside=0 }
      inside && /agmsg:prefix-newline=added/ { found=1 }
      END { exit(found ? 0 : 1) }
    ' "$target"; then
      owner_extra=";prefix-newline=added"
    elif awk -v start="$start" -v end="$end" '
      $0 == start { inside=1; next }
      $0 == end { inside=0 }
      inside && /agmsg:created-file=1/ { found=1 }
      END { exit(found ? 0 : 1) }
    ' "$target"; then
      owner_extra=";created-file=1"
    else
      owner_extra=""
    fi
  elif [ ! -f "$target" ]; then
    owner_extra=";created-file=1"
  elif [ -s "$target" ]; then
    # The separator is part of our managed addition. Recording it lets
    # uninstall restore even a pre-existing file with no final newline exactly.
    owner_extra=";prefix-newline=added"
  else
    owner_extra=""
  fi

  block=$(mktemp "${TMPDIR:-/tmp}/agmsg-role-docs-block.XXXXXX") || return 1
  agmsg_role_docs_make_block "$block" "$start" "$end" "$cmd" "$body" "$owner_extra"

  if [ "$starts" -eq 1 ]; then
    agmsg_role_docs_replace_block "$target" "$start" "$end" "$block"
    rm -f "$block"
    return 0
  fi

  target_dir=$(dirname "$target")
  tmp=$(mktemp "$target_dir/.agmsg-role-docs.XXXXXX") || { rm -f "$block"; return 1; }
  if [ -f "$target" ]; then
    cp -p "$target" "$tmp" || { rm -f "$block" "$tmp"; return 1; }
  else
    : > "$tmp"
  fi
  if [ "$owner_extra" = ";prefix-newline=added" ]; then
    printf '\n' >> "$tmp"
  fi
  cat "$block" >> "$tmp"
  mv "$tmp" "$target"
  rm -f "$block"
}

# Companion files are never adopted. A pre-existing markerless, malformed, or
# differently-owned file is byte-for-byte preserved and reported as skipped.
agmsg_role_docs_install_owned_file() {
  local target="$1" start="$2" end="$3" cmd="$4" body="$5"
  local starts ends invalid existing_owner block
  mkdir -p "$(dirname "$target")"

  if [ -f "$target" ]; then
    read -r starts ends invalid <<EOF
$(agmsg_role_docs_marker_state "$target" "$start" "$end")
EOF
    if [ "$invalid" -ne 0 ] || [ "$starts" -ne 1 ] || [ "$ends" -ne 1 ]; then
      if [ "$starts" -eq 0 ] && [ "$ends" -eq 0 ] && [ "$invalid" -eq 0 ]; then
        agmsg_role_docs_note_skip "$target" "unmanaged companion file"
      else
        agmsg_role_docs_note_skip "$target" "malformed or duplicate managed markers"
      fi
      return 0
    fi
    existing_owner=$(agmsg_role_docs_owner "$target" "$start" "$end")
    if [ "$existing_owner" != "$cmd" ]; then
      if [ -n "$existing_owner" ]; then
        agmsg_role_docs_note_skip "$target" "managed by command '$existing_owner'; '$cmd' skipped"
      else
        agmsg_role_docs_note_skip "$target" "managed block has no matching owner for command '$cmd'"
      fi
      return 0
    fi
  else
    starts=0
  fi

  block=$(mktemp "${TMPDIR:-/tmp}/agmsg-role-docs-block.XXXXXX") || return 1
  agmsg_role_docs_make_block "$block" "$start" "$end" "$cmd" "$body"
  if [ "$starts" -eq 0 ]; then
    cp "$block" "$target"
  else
    agmsg_role_docs_replace_block "$target" "$start" "$end" "$block"
  fi
  rm -f "$block"
}

agmsg_role_docs_install() {
  local templates="$1" cmd="$2" skill_dir="$3"
  local role_dir="$HOME/.codex/$cmd" claude_doc="$HOME/.claude/CLAUDE-$cmd.md"
  local rendered name
  AGMSG_ROLE_DOCS_SKIPPED=""
  rendered=$(mktemp "${TMPDIR:-/tmp}/agmsg-role-docs-render.XXXXXX") || return 1

  mkdir -p "$role_dir/options" "$HOME/.claude"

  agmsg_role_docs_render "$templates/codex-agents.md" "$rendered" "$cmd" "$skill_dir" "$role_dir" "$claude_doc"
  agmsg_role_docs_upsert_shared_block "$HOME/.codex/AGENTS.md" '<!-- agmsg:ROLE-ENTRY:START -->' '<!-- agmsg:ROLE-ENTRY:END -->' "$cmd" "$rendered"

  for name in planner workers README; do
    agmsg_role_docs_render "$templates/codex-$name.md" "$rendered" "$cmd" "$skill_dir" "$role_dir" "$claude_doc"
    agmsg_role_docs_install_owned_file "$role_dir/$name.md" '<!-- agmsg:ROLE-DOC:START -->' '<!-- agmsg:ROLE-DOC:END -->' "$cmd" "$rendered"
  done
  for name in scout executor; do
    agmsg_role_docs_render "$templates/codex-$name-options.yaml" "$rendered" "$cmd" "$skill_dir" "$role_dir" "$claude_doc"
    agmsg_role_docs_install_owned_file "$role_dir/options/$name.yaml" '# agmsg:ROLE-OPTIONS:START' '# agmsg:ROLE-OPTIONS:END' "$cmd" "$rendered"
  done

  agmsg_role_docs_render "$templates/claude-role.md" "$rendered" "$cmd" "$skill_dir" "$role_dir" "$claude_doc"
  agmsg_role_docs_install_owned_file "$claude_doc" '<!-- agmsg:CLAUDE-ROLE-DOC:START -->' '<!-- agmsg:CLAUDE-ROLE-DOC:END -->' "$cmd" "$rendered"

  printf '@CLAUDE-%s.md\n' "$cmd" > "$rendered"
  agmsg_role_docs_upsert_shared_block "$HOME/.claude/CLAUDE.md" '<!-- agmsg:IMPORT:START -->' '<!-- agmsg:IMPORT:END -->' "$cmd" "$rendered"

  rm -f "$rendered"
  if [ -n "$AGMSG_ROLE_DOCS_SKIPPED" ]; then
    echo "  ! installed role guidance with skipped unmanaged/conflicting files:" >&2
    while IFS= read -r target; do
      [ -n "$target" ] && echo "    - $target" >&2
    done <<EOF
$AGMSG_ROLE_DOCS_SKIPPED
EOF
  else
    echo "  + installed managed Codex and Claude role guidance"
  fi
}

agmsg_role_docs_remove_block() {
  local target="$1" start="$2" end="$3" cmd="$4" delete_empty="${5:-0}"
  local starts ends invalid existing_owner tmp start_line end_line target_dir
  local remove_prefix_newline=0 remove_created_file=0 prefix_bytes
  [ -f "$target" ] || return 0
  read -r starts ends invalid <<EOF
$(agmsg_role_docs_marker_state "$target" "$start" "$end")
EOF
  [ "$starts" -gt 0 ] || return 0
  if [ "$invalid" -ne 0 ] || [ "$starts" -ne 1 ] || [ "$ends" -ne 1 ]; then
    echo "  ! role docs: malformed or duplicate managed markers in $target; preserved" >&2
    return 0
  fi
  existing_owner=$(agmsg_role_docs_owner "$target" "$start" "$end")
  if [ "$existing_owner" != "$cmd" ]; then
    echo "  ! role docs: $target is not owned by command '$cmd'; preserved" >&2
    return 0
  fi
  if awk -v start="$start" -v end="$end" '
    $0 == start { inside=1; next }
    $0 == end { inside=0 }
    inside && /agmsg:prefix-newline=added/ { found=1 }
    END { exit(found ? 0 : 1) }
  ' "$target"; then
    remove_prefix_newline=1
  fi
  if awk -v start="$start" -v end="$end" '
    $0 == start { inside=1; next }
    $0 == end { inside=0 }
    inside && /agmsg:created-file=1/ { found=1 }
    END { exit(found ? 0 : 1) }
  ' "$target"; then
    remove_created_file=1
  fi

  start_line=$(awk -v marker="$start" '$0 == marker { print NR; exit }' "$target")
  end_line=$(awk -v marker="$end" '$0 == marker { print NR; exit }' "$target")
  target_dir=$(dirname "$target")
  tmp=$(mktemp "$target_dir/.agmsg-role-docs.XXXXXX") || return 1
  cp -p "$target" "$tmp" || { rm -f "$tmp"; return 1; }
  : > "$tmp"
  if [ "$start_line" -gt 1 ]; then
    if [ "$remove_prefix_newline" -eq 1 ]; then
      prefix_bytes=$(head -n "$((start_line - 1))" "$target" | wc -c | tr -d '[:space:]')
      if [ "$prefix_bytes" -gt 1 ]; then
        head -c "$((prefix_bytes - 1))" "$target" >> "$tmp"
      fi
    else
      head -n "$((start_line - 1))" "$target" >> "$tmp"
    fi
  fi
  tail -n "+$((end_line + 1))" "$target" >> "$tmp"
  mv "$tmp" "$target"

  if { [ "$delete_empty" -eq 1 ] || [ "$remove_created_file" -eq 1 ]; } && [ ! -s "$target" ]; then
    rm -f "$target"
  fi
}

agmsg_role_docs_uninstall() {
  local cmd="$1"
  local role_dir="$HOME/.codex/$cmd" claude_doc="$HOME/.claude/CLAUDE-$cmd.md"
  local name
  agmsg_role_docs_remove_block "$HOME/.codex/AGENTS.md" '<!-- agmsg:ROLE-ENTRY:START -->' '<!-- agmsg:ROLE-ENTRY:END -->' "$cmd" 0
  for name in planner workers README; do
    agmsg_role_docs_remove_block "$role_dir/$name.md" '<!-- agmsg:ROLE-DOC:START -->' '<!-- agmsg:ROLE-DOC:END -->' "$cmd" 1
  done
  for name in scout executor; do
    agmsg_role_docs_remove_block "$role_dir/options/$name.yaml" '# agmsg:ROLE-OPTIONS:START' '# agmsg:ROLE-OPTIONS:END' "$cmd" 1
  done
  agmsg_role_docs_remove_block "$claude_doc" '<!-- agmsg:CLAUDE-ROLE-DOC:START -->' '<!-- agmsg:CLAUDE-ROLE-DOC:END -->' "$cmd" 1
  agmsg_role_docs_remove_block "$HOME/.claude/CLAUDE.md" '<!-- agmsg:IMPORT:START -->' '<!-- agmsg:IMPORT:END -->' "$cmd" 0
  rmdir "$role_dir/options" "$role_dir" 2>/dev/null || true
  rmdir "$HOME/.codex" "$HOME/.claude" 2>/dev/null || true
}
