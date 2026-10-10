# The night shift

Issues queued in Linear, worked by background Claude Code agents on forge while
you are away from the desk, each ending in a PR handoff for you to publish.
[`hosts/forge/night-shift.nix`](../hosts/forge/night-shift.nix) runs it and
says why it is built the way it is; [`night-shift.sh`](../hosts/forge/night-shift.sh)
is the dispatcher.

Every 10 minutes while forge is awake, a user timer takes finished work back
to Linear and starts what is queued, two agents at most. Each agent gets its own
worktree off the repo's default branch and a `claude --bg` session, under your
settings, sandbox and auto mode, so `claude agents` and `claude attach` work on
them as on any other. Nothing it does publishes, merges or deploys.

```
Queued ──▶ Running ──▶ Handoff ready ──▶ (you publish, then Done)
   ▲            │
   │            └────▶ Needs you
   └─── you answer in a comment and move it back
```

## Setting it up

### In Linear

1. In each team you will queue from, add four workflow states, names exact:
   `Queued` (type Unstarted), and `Running`, `Handoff ready`, `Needs you`
   (type Started).
2. Make a label group called `repo`, with one label per repository you want
   worked, named as its directory under `~/projects`: `nix-config`,
   `claude-plugins`.
3. Make a personal API key, in your account's security settings. If it offers
   scopes, it needs to read issues and to write issues and comments, for those
   teams only.

### On forge

The key and the ntfy topic go in `secrets/forge.yaml`; evaluation fails until
both are there. From the repo, in your own terminal, inside `nix shell
nixpkgs#sops nixpkgs#jq` if either is missing. At `read`, paste the key; it does
not echo. The second line reuses the fleet's ntfy topic, so the phone needs no
new subscription. No comments in the block, since interactive zsh runs a pasted
`#` line as a command.

```bash
read -rs key && printf '"%s"' "$key" | sops set --value-stdin secrets/forge.yaml '["linear-api-key"]'; unset key
sops decrypt --extract '["ntfy-url"]' secrets/core5.yaml | jq -R . | sops set --value-stdin secrets/forge.yaml '["ntfy-url"]'
[[ $(sops decrypt --extract '["ntfy-url"]' secrets/forge.yaml) == $(sops decrypt --extract '["ntfy-url"]' secrets/core5.yaml) ]] && echo "ntfy-url matches"
```

Then try the branch with `nixos-rebuild test --sudo --flake .#forge` from the
checkout. `test` is the right first step here: the same change keeps
`/run/secrets.d` from Claude's sandbox (`hosts/forge/claude.nix`), and if that
broke every sandboxed command, a reboot undoes it.

### First run

1. In a Claude Code session, have it run `ls /run/secrets.d` and an ordinary
   command such as `git status`. The first should find nothing or be refused,
   the second should work.
2. `night-shift check` confirms the key, the four states in each team, the
   `repo` labels and the directories they name, `claude` on the service's
   PATH, and the ntfy topic.
3. Queue something small: an issue with a `repo` label, moved to `Queued` by
   you. Then `systemctl --user start night-shift` rather than waiting, and
   `journalctl --user -u night-shift` to watch the run.

What only a live run shows, since none of it can be tried from the sandbox:
`claude --bg` started from a systemd user service with no terminal, and later
`--resume`; the session surviving the service's exit, in a scope of its own;
auto mode holding up with nobody to ask; and the agent writing its result into
the repo's `.git/night-shift/`. If one of them fails, the issue lands in
`Needs you` with what failed, and the journal has the rest.

## Using it

- **Queue:** give an issue a `repo` label and move it to `Queued`, from the
  phone or anywhere. Priority decides what starts first. Write the issue for a
  reader who knows only the repo: the agent sees its title, description and
  your comments, nothing else.
- **Handoff ready:** the comment says what changed, what the agent verified,
  and for nix-config, preflight's verdict on the branch, worked out by the
  dispatcher rather than taken from the agent. Evaluating the branch runs code
  the agent wrote, with the network on, so that preflight runs under
  bubblewrap with Claude's sandbox denies and your credentials hidden
  (`hidden` in `hosts/forge/night-shift.nix`). Publish with the command in the
  comment, `cd <worktree> && pr-handoff`.
- **Needs you:** the agent's questions are in the comment. Answer in a comment
  and move the issue back to `Queued`; the same session resumes with your
  answer. `claude attach <name>` is the other way in. An agent with no result
  after 4 hours lands here too.
- **Re-queue while it runs:** to add something mid-task, comment and move the
  issue to `Queued`. It stays there, and once the agent's result is in, the
  result is posted and the session resumed with your comment.
- **Only your issues, only by you.** An issue someone else created or moved
  to `Queued`, or one synced in from a public repo, is sent to `Needs you`
  untouched: the agent is given its description as your task.
- **Done or canceled** issues are forgotten. Their worktrees are left for
  `claude rm` or the git cleanup.
- `night-shift status` lists what each agent is doing.

To start an issue over rather than resume it, remove its worktree and branch,
and `~/.local/state/night-shift/<ID>.json`.

### Filing issues from drafts

Rather than paste issues into Linear, have Claude write them as drafts, one
file each, in the repository's `.git/linear-handoff/` (any `.md` name):

```markdown
---
title: forge: push to ntfy when night-shift runs keep failing
priority: high
project: Night shift
---

Goal: ...
```

`repo` defaults to the repository the draft is in, so a draft for another
repo names it. `priority` is urgent, high, medium, low or none; `project`
must already exist in the team; `team` is needed only with more than one.
The front matter takes those keys only, and no comments.

`night-shift file` collects the drafts from every repository in
`~/projects` and checks them all first, so one mistake files none. A draft
with control or invisible characters is refused, since what you read must be
what is filed. It then shows each draft in full, with when it was written
and the state it will land in, and asks about that one; a draft you skip
stays. Each becomes an issue created by you, in the team's backlog, its
description ending "Filed from a draft with `night-shift file`", and its
draft is deleted. Nothing is ever filed into `Queued`: moving an issue there
is still your hand, in Linear. Read each draft before you answer, since
filing it as you is what lets the night shift take it later, and agents
working in a repository can write drafts there too.

If Linear does not answer, a draft may have been filed anyway, so it is left
as `<name>.filing` rather than offered again; check Linear, then delete it or
rename it back.

## Limits

- It runs only while forge is awake and you are logged in. A closed lid pauses
  it, and the timer catches up after.
- Comments come from your own key, so Linear does not notify you of them. The
  push from ntfy is the notification.
- A run that cannot reach Linear, or whose key Linear refuses, fails without
  touching any issue. When the third timer run in a row fails, 20 minutes
  after the first, ntfy pushes "Night shift is failing" once, and
  `journalctl --user -u night-shift` says why. Nothing more is pushed until a
  run succeeds, which starts the count over and sends nothing. Runs you start
  from a shell with `night-shift run` are not counted.
- The verdict needs preflight, so only nix-config has one. Other repos get the
  agent's own account of what it verified.
