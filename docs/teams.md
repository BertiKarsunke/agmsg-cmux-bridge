# Team operations

The [README](../README.md) covers the slash-command flow most users need. This page collects the rest: identity model, joining the same team from a second project, multi-name workspaces, and clearing or resetting registrations.

You don't need to call shell scripts to do any of this. Talk to your agent or use the slash-command forms below.

## How identity works

Agents join teams by **identity**: `(agent name, team)`. Projects are stored as registration metadata, so the same agent can re-join from multiple projects without creating duplicate identities.

This is what makes "same agent on two laptops / two repos" work without forking your inbox. Messages addressed to `alice` reach whichever live session is registered as `alice`, regardless of which project that session is in.

## Joining a team

In your project:

```
/agmsg
```

On first use it prompts for a team name (joins existing or creates new) and an agent name. That's the whole onboarding.

## Joining the same team from a second project

Open the second project in your agent and run `/agmsg`. When it asks for the agent name, give the same name you used before. agmsg recognizes the existing identity and registers the new project against it — your inbox stays unified.

## Multiple agent names on one project

You can register more than one name in the same project (e.g. `cc` and `reviewer`). Run `/agmsg` and answer with each name in turn. After the second join, `/agmsg` detects multiple identities on this project and asks which one to use for the current session.

For the case where one workspace plays multiple *roles* (e.g. a `tech-lead` identity and a `biz-analyst` identity sharing the same checkout), use `actas` instead:

```
/agmsg actas tech-lead
/agmsg actas biz-analyst
/agmsg drop biz-analyst
```

`actas` is the right tool when the roles are mutually exclusive across sessions — see [docs/actas.md](actas.md).

## Clearing a project's registrations

```
/agmsg reset
```

Removes the current project's registrations without leaving the team identity entirely. Useful before moving the project or starting a clean rejoin. Other projects' registrations of the same identity are untouched.

To remove a single role:

```
/agmsg drop <name>
```

To wipe every agent registered to the current project/type at once, ask your agent to run `reset.sh <project> <type> all`. Registrations of the same agents on *other* projects/types are untouched; a team left with no members is removed.

## Leaving a team entirely

There's no slash-command shortcut for "leave team X across all projects". Ask your agent to leave — it knows the script (`leave.sh <team> <agent>`) and will run it for you. All registrations across all projects for that `(team, agent)` pair are removed; messages already in the DB stay.

To tear down a whole team in one shot, run `leave.sh <team> all` — it removes every agent and deletes the team. Unlike `reset.sh … all` (which is scoped to one project/type), this drops the agents regardless of which projects they were registered to.

### Leaving automatically on session exit

By default a session ending does **not** leave the team — registrations persist so the agent rejoins as the same role on the next launch. Set `AGMSG_LEAVE_ON_EXIT=1` (export it in your shell profile so the SessionEnd hook process inherits it) to instead clear this project/type's registration when the session ends. Two caveats: it only fires on a *graceful* exit — a hard kill, crash, or abruptly closed terminal never runs the SessionEnd hook, so dead-process cleanup still relies on liveness GC — and it no-ops when the project/type has more than one identity, since the hook can't tell which role this session was.

### Liveness tags and GC on `team`

`team.sh` tags each member by the liveness of its pane marker (`run/pane.<team>.<agent>.json`, the same signal `send.sh` uses for pane-push):

- `[live]` — the member's pane is alive on this host.
- `[stale]` — the marker's backend tool is on this host and the pane is gone.
- *(no tag)* — no marker (an idle/persistent registration), or the marker's backend tool isn't on this host (a pane on another machine). Both deliberately abstain.

Listing is read-only by default. Set `AGMSG_GC_ON_LIST=1` to also *remove* the `[stale]` members as a side effect of listing — the lazy backstop for the hard kills `AGMSG_LEAVE_ON_EXIT` misses. Only `[stale]` members are dropped; `[live]` and untagged members are never touched.

Limits worth knowing: a pane being alive only proves the *terminal pane* exists, not that the agent CLI is still running inside it (an agent quit but its pane left open reads as `[live]`); and because there is a single pane marker per `(team, agent)`, GC'ing a `[stale]` member drops all of that agent's registrations on this team, including any on a project that's actually still live elsewhere. GC is intentionally opt-in for these reasons.

## Renaming a team

Same idea: ask your agent to rename the team. It will move the team directory, update the config, and migrate the messages. Existing members keep their registrations and history under the new name. Any already-running session keeps the old cached name until it re-resolves identity — running `/agmsg` again is enough to pick up the new name.

## See also

- [docs/actas.md](actas.md) — multi-role mechanics, exclusivity locks, Codex caveat.
- [README — Shell (any agent)](../README.md#shell-any-agent) — script quick-reference for automation, CI, sandboxes.
