English | [한국어](README.ko.md) | [日本語](README.ja.md)

# agmsg-cmux

## Summary

agmsg-cmux is a fork of `fujibee/agmsg` that adds tmux/cmux turn-mode pane-push: CLI AI agents such as Claude Code, Codex, and Gemini CLI can message each other through local SQLite without a daemon or network service.

## What This Fork Adds

The original agmsg stores and reads messages through local scripts and SQLite. This fork adds best-effort turn-mode pane-push: after `scripts/send.sh` stores a message, it checks whether the recipient has a registered tmux or cmux pane and injects a short prompt asking that agent to run its agmsg skill and read the inbox.

Pane registrations follow the role lifecycle:

- `scripts/join.sh` tries to register the current pane after the agent joins a team.
- For Claude Code, `scripts/actas-claim.sh` refreshes the registration to the current pane after an `actas` claim succeeds.
- Turn-mode agents such as Codex, Gemini, Copilot, Cursor, OpenCode, Antigravity, and Hermes re-register the current pane with `scripts/pane.sh register` inside their own `actas` skill command flow.
- `scripts/reset.sh`, used by reset/drop flows, clears the pane registration for the removed role.

That lets agmsg-cmux track the live pane for a role as the role joins, switches, and drops.

## How It Works

Pane support lives in `scripts/lib/pane.sh` and `scripts/pane.sh`. The backend is detected automatically: tmux uses `$TMUX_PANE` when `$TMUX` and `tmux` are available; cmux uses `cmux identify --json` and its `caller.surface_ref` value, with `$CMUX_SURFACE_ID` as a fallback; WezTerm/Kaku uses `$WEZTERM_PANE` and the `$WEZTERM_UNIX_SOCKET` or `$KAKU_UNIX_SOCKET` socket.

Registrations are written under the installed skill directory as:

```text
run/pane.<team>.<name>.json
```

Each record stores the backend, pane address, project, agent type, and registration timestamp. When pane-push is active, `scripts/send.sh` verifies that the registered pane is still alive and injects an inbox-check prompt. Injection sends the text, waits for `AGMSG_PANE_COMMIT_DELAY`, sends Enter, waits again, then sends a second Enter.

## Installation

Requirements: `bash` and `sqlite3`. macOS includes both; minimal Linux environments may need a package such as `sqlite3`.

For the agmsg-cmux fork, install from this checkout so the pane-push scripts are included:

```bash
git clone <this-repository-url>
cd agmsg-cmux
./install.sh
```

`install.sh` installs the skill to `~/.agents/skills/<cmd>/`, where `<cmd>` defaults to `agmsg`. Useful options from the script are:

```bash
./install.sh --cmd m
./install.sh --agent-type gemini
./install.sh --agent-type opencode
./install.sh --update
```

After installation, restart the agent CLI so it discovers the skill, then run `/agmsg` in Claude Code or `$agmsg` in Codex, Gemini CLI, Antigravity, or OpenCode.

Current `setup.sh` behavior is upstream-specific: it clones `https://github.com/fujibee/agmsg.git` at `${AGMSG_REF:-main}` and runs that checkout's `install.sh`. Use `setup.sh` only when you intentionally want the canonical upstream installer, unless it is changed to point at this fork.

## Usage

Basic agmsg flow:

```bash
~/.agents/skills/agmsg/scripts/join.sh <team> <agent_name> <type> "$(pwd)"
~/.agents/skills/agmsg/scripts/send.sh <team> <from_agent> <to_agent> "<message>"
~/.agents/skills/agmsg/scripts/inbox.sh <team> <agent_name>
~/.agents/skills/agmsg/scripts/history.sh <team> [agent_name] [limit]
```

Pane commands:

```bash
~/.agents/skills/agmsg/scripts/pane.sh register <team> <name> [type] [project]
~/.agents/skills/agmsg/scripts/pane.sh status [<team> <name>]
~/.agents/skills/agmsg/scripts/pane.sh lookup <team> <name>
~/.agents/skills/agmsg/scripts/pane.sh test <team> <name>
~/.agents/skills/agmsg/scripts/pane.sh unregister <team> <name>
```

Command summary:

- `join.sh`: joins or creates a team and, when possible, registers the current pane for turn-mode pane-push.
- `send.sh`: stores a message in SQLite and nudges the recipient's registered pane when pane-push is enabled and the pane is alive.
- `inbox.sh`: reads new messages for an agent and marks them as read.
- `history.sh`: prints message history for a team.
- `pane.sh register`: records the current tmux/cmux pane for a role.
- `pane.sh status`: lists pane registrations, or one registration when team and name are supplied.
- `pane.sh lookup`: prints the registered backend, address, project, and type in a machine-readable form.
- `pane.sh test`: injects a test ping into the registered live pane.
- `pane.sh unregister`: removes the pane registration for a role.

## Environment Variables

| Variable | Default | Purpose |
| --- | --- | --- |
| `AGMSG_PANE_PUSH` | `1` | Set to `0` to disable send-time pane injection while keeping normal SQLite messaging. |
| `AGMSG_PANE_COMMIT_DELAY` | `0.4` | Delay, in seconds, between injected text and the two Enter key sends used to commit the prompt. |

## Credits and License

agmsg-cmux is based on `fujibee/agmsg`, licensed under MIT. The pane integration pattern is borrowed from `paichi/cmux-bridge`, also licensed under MIT.

See `CREDITS.md` for attribution details and `LICENSE` for the MIT license text.
