# The night shift

Issues queued in Linear, worked by background Claude Code agents on forge while
you are away from the desk, each ending in a PR handoff for you to publish.
[`hosts/forge/night-shift.nix`](../hosts/forge/night-shift.nix) runs it and
says why it is built the way it is; [`night-shift.sh`](../pkgs/night-shift/night-shift.sh)
is the dispatcher. The same dispatcher runs on the work Mac against a shared
team, in a sandbox of its own: "On a Mac (work mode)" below.

Every 10 minutes while forge is awake, a user timer takes finished work back
to Linear and starts what is queued, two agents at most. Each agent gets its own
worktree off the repo's default branch and a `claude --bg` session, under your
settings, sandbox and auto mode, so `claude agents` and `claude attach` work on
them as on any other. Nothing it does publishes, merges or deploys.

```
Queued ──▶ Running ──▶ Handoff ready ──▶ (you publish and merge) ──▶ Done
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
  answer. `claude attach <name>` is the other way in: what the agent reports
  after you answer there is posted by the next run, as is a handed-off
  agent's when you ask it for more. An agent lands here too when its session
  ends or waits on a prompt without writing a result, seen on two runs, or
  has no result after 4 hours of work. Only time forge is awake counts toward
  the 4 hours.
- **Re-queue while it runs:** to add something mid-task, comment and move the
  issue to `Queued`. It stays there, and once the agent's result is in, the
  result is posted and the session resumed with your comment.
- **Only your issues, only by you.** An issue someone else created or moved
  to `Queued`, or one synced in from a public repo, is sent to `Needs you`
  untouched: the agent is given its description as your task. So is one
  whose last move to `Queued` Linear records with no person, as for an
  automation's, even on an issue you created. Only an issue created straight
  into `Queued` counts as queued by its creator.
- **Reviewing a branch:** each time an agent is started or resumed, the
  issue as it was handed over, with its title, URL, state, description and
  your comments, is written to `.git/night-shift/<ID>.issue.md` in the repo,
  next to the agent's result. A Claude session reviewing the branch cannot
  reach Linear, so point it there to check the work against the task rather
  than against memory. It stays under `.git/` and nothing publishes it.
- **Merged:** after you merge a handoff's PR, the next run moves the issue to
  the team's completed state, with a comment naming the PR, and cleans up:
  the agent's worktree, its branch and the branch's section in
  `.git/config`, every session in that worktree, and the issue's state file,
  issue text and old results.
  The worktree goes only if the branch's tip is the head the PR merged, and
  nothing in it is uncommitted, and no session there is still working.
  Otherwise all of it stays and the comment says why. Nothing is pushed,
  since you did the merge.
- **Done or canceled** by your hand, issues are forgotten, along with their
  issue text and old results in `.git/night-shift/`. Their worktrees are left
  for `claude rm` or the git cleanup.
- **The backlog, for Claude:** after every run and every `night-shift file`,
  each open issue (state, priority, repo, project and description) is
  written to `~/.local/state/night-shift/backlog.md` on forge. A Claude
  session cannot reach Linear, and has no key for it on purpose, since one
  acting as you could queue work for the night shift; this file is how a
  session sees what is filed, read-only. It is your plan text, so it stays
  outside every repo.
- `night-shift status` lists what each agent is doing.
- Shortcuts: `nsr`, `nss` and `nsf` are `night-shift run`, `status` and
  `file`, and `wt nno-20` cds into NNO-20's worktree.

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

- It runs only while forge is awake and you are logged in. While an agent
  works on AC, the night shift keeps forge from idle sleep (Plasma's 15
  minutes), so locking the screen and walking away is enough; the screen
  still turns off. A closed lid still suspends it, and on battery forge idles
  to sleep as usual. Either way the agents pause, and the timer catches up
  after.
- Comments come from your own key, so Linear does not notify you of them. The
  push from ntfy is the notification. Titled "Night shift", it names the
  issue by its identifier and what happened, "NNO-12: Handoff ready
  (routine)" or "NNO-12: Needs you", and a tap opens the issue in Linear. It
  never carries the issue's title: ntfy.sh is a third party, and a title can
  describe the house.
- A run that cannot reach Linear, or whose key Linear refuses, fails without
  touching any issue. When the third timer run in a row fails, 20 minutes
  after the first, ntfy pushes "Night shift is failing" once, and
  `journalctl --user -u night-shift` says why. Nothing more is pushed until a
  run succeeds, which starts the count over and sends nothing. Runs you start
  from a shell with `night-shift run` are not counted.
- The verdict needs preflight, so only nix-config has one. Other repos get the
  agent's own account of what it verified.
- Merges are seen through GitHub's public API, without a login, once a run
  for each issue in `Handoff ready`. A private repository answers as if it
  did not exist, so its issues are left for you to close. GitHub allows 60
  such requests an hour from forge's address, Claude's own included; when it
  refuses, the rest wait for a later run, the longest unasked first.

## On a Mac (work mode)

The same dispatcher runs on a Mac, from launchd every 10 minutes, against a
Linear team you share. [`home/night-shift.nix`](../home/night-shift.nix) runs
it, and "Work mode" in `night-shift.sh` has the details. The team's workflow
and issues are shared, so it changes as little in Linear as it can:

- **Queue.** An issue assigned to you that carries your label, which you
  added yourself, with no one else changing the title or description since.
  An issue it refuses gets one notification, and is looked at again only
  when you add the label again.
- **Linear.** The one write is a move to the team's started state. Results,
  questions and refusals go to a desktop notification and
  `~/.local/state/night-shift/<ID>.report.md`, which `night-shift status`
  shows.
- **Answering.** `night-shift resume <ID> "<answer>"` resumes the agent on
  the next run, or add the label again.
- **Done.** Once Linear completes the issue and gh finds the merged PR from
  its branch, the worktree, branch and sessions are removed as on forge.

### The sandbox

The Mac's own Claude sessions have no sandbox. The night shift's agents run
in one, from settings Nix writes, passed with `--settings` and copied into
the worktree's `.claude/settings.local.json`. `cld-safe` starts an
interactive session in the same sandbox.

- Commands cannot read your credentials or most of `~/Library`.
  `~/Library/Keychains` must stay hidden: with it readable, `security` finds
  every item in the login keychain.
- Commands may write only in the worktree, under `~/.cache/night-shift`, and
  in Claude's temporary directory, and reach only the hosts listed in
  `home/night-shift.nix` and the config.
- No Unix sockets, Apple Events or MCP servers. Hooks are off, and so is
  every plugin but the one the agents use, since hooks, LSP servers and
  helper commands run outside the sandbox.
- A repository whose settings change the sandbox, or name a helper command
  such as `apiKeyHelper`, is refused.

### Setting it up on the Mac

1. In Linear, make the label and a personal API key that can read and
   update issues.
2. Put the key in the login keychain, pasting it at the prompt in your own
   terminal:

   ```
   security add-generic-password -s night-shift-linear -a "$USER" -w
   ```

3. Write `~/.config/night-shift/config.json`, which stays outside this repo:

   ```json
   {
     "label": "agent",
     "startedState": "In Progress",
     "path": ["<where the repositories' tools are>"],
     "repos": {
       "<TEAM KEY>": {
         "dir": "~/projects/<repo>",
         "branch": "<prefix>/{ID}/{slug}",
         "bootstrap": ["<setup commands>"],
         "checks": "<checks that need no running services>",
         "sandbox": { "allowedDomains": [], "allowWrite": [], "denyRead": [], "allowLocalBinding": false, "env": {} }
       }
     }
   }
   ```

   `bootstrap` runs in each new worktree before the agent starts, outside
   the sandbox. `sandbox` can only add to the base, which reaches GitHub
   alone: list the package registries a repository needs in its
   `allowedDomains`. Keep `{ID}` in `branch` so the PR links to the issue. `max` and `stallHours` are optional.
4. Run `claude` in each repository once and accept the trust prompt.
5. Run `hms`, then `night-shift check`. With no config the launchd job does
   nothing, so switching first is safe.

### Publishing from an agent's worktree

In a worktree under `.claude/worktrees/`, `pr-handoff` runs git with hooks
off, lists changed files that run code on your machine, and refuses to push
if the `.lfsconfig` there is not the base branch's. Read the diff with `phd`
or `phg` before opening the worktree in an editor or running git in it.

### Limits on the Mac

- It runs only while you are logged in and the Mac is awake.
- Agents cannot run docker or anything that needs running services.
- The log is `~/Library/Logs/night-shift.log`. The third failed run in a row
  sends one notification.
- `cld-safe` turns hooks off but not a repository's plugins.
- `night-shift file` and the backlog snapshot are forge's.
