# Deploys

A decision record. Nothing in it is built yet. It settles how merging and
deploying become separate steps: the Pis upgrade only to revisions Nick has
signed off, through a signed tag per host that fleet-deploy writes, rather
than to main's head when their timer fires. The follow-up pull requests build
it rather than re-argue it.

## The question

The Pis' `nixos-upgrade` fetches `github:nnorx/nix-config`
(`system.autoUpgrade.flake` in [`modules/baseline.nix`](../modules/baseline.nix))
at the times in [`hosts/common/pi.nix`](../hosts/common/pi.nix), so a merge
reaches every Pi that night. Much of how this repo is worked exists because of
that:

- CLAUDE.md's "Deploying and merging": a merge needs Nick at hand that night
  when it touches a Pi's boot path, networking or logins, and a change to
  addressing reaches the Pis unattended, possibly before gate is deployed to
  match.
- Preflight's verdict, `routine`, `review` or `be there`, is phrased as
  whether merging needs Nick at hand tonight.
- `flake.lock` bumps are merged early in the day, since an upgrade that runs
  before cache.yml has built a Pi kernel fails.
- fleet-deploy waits on cache.yml for main, and a broken main is re-applied
  every night, on top of a host just recovered by hand included
  ([recovery.md](recovery.md)).

The goal, as a property of the design: **the Pis upgrade only to revisions
Nick has signed off, and merging and deploying are separate steps.** A merge
changes main. A deploy is Nick choosing a revision of main for a host, with a
hardware key, and the host checking that choice before it runs it.

## In short

| | Decision |
|---|---|
| The ref | A signed annotated tag per host per deploy, `deploy/<host>/<UTC stamp>`, in this repository |
| Who signs | Nick, with the resident `ed25519-sk` signing key on either hardware key, a touch per tag ([keys.md](keys.md), "Signing") |
| Who writes it | fleet-deploy, from Nick's terminal, pushing over HTTPS through gh's credential helper |
| The signers a Pi trusts | `lib/signing-keys.nix`, built into the system the Pi is running |
| Where verification runs | A unit of its own, `deploy-ref`, as the first step of `nixos-upgrade`, so the timer and the deploy login both go through it |
| A tag that fails a check | Never deployed, and reported at high priority through `fleetAlerts`. It cannot block a valid deploy either |
| Rollback | A new tag on an older revision of main. Every earlier deploy stays as a tag |
| The nightly run | Applies only what Nick has signed. Nothing signs on a server |
| Recovery | The admin login with sudo deploys any revision by hand, outside the verifier. No Pi is ever left needing a card pull |
| gate | The same scheme in its own namespace, verified by hand before `nrs`, adopted with the guided gate flow |
| main | Unchanged: pull requests only, squash merges, `check` and `flake-check` required |
| New secrets on the Pis | None. Verification uses public keys alone |
| New hosts a Pi reaches | None. GitHub and the caches, as now |

## What it defends against

A revision Nick did not sign does not reach a Pi. Writing to the repository,
by any account, token or workflow, is not enough to choose which revision a
Pi runs: that takes a signature from a hardware key in Nick's hand, checked on
the Pi against signers built into the system it already runs.

GitHub and the binary cache are trusted as hosts, as for every other fetch:
GitHub to serve a commit as it is, and the cache to serve a path as it was
built ([keys.md](keys.md), "The cache's signing key"). The signature settles
which revision a Pi runs, and the Pi evaluates that revision itself, so the
store paths it asks for follow from what Nick signed.

## The ref

### Options

**A branch whose head commit is signed.** fleet-deploy would move a `deploy`
branch and sign its head. But a signed commit is a new commit, and every commit
changes every toplevel through `system.configurationRevision`. The Pi would
need a closure cache.yml never built, for a commit that is not on main. The
alternative, signing main's own commits, does not survive a squash merge,
which writes a new commit ([keys.md](keys.md), "Signing"). **Rejected.**

**A signed file naming a revision.** A small statement, `{host, revision,
sequence}`, signed with `ssh-keygen -Y sign` and published somewhere the Pi
reads. It works, but it reinvents what a signed tag already is, and every place
to put it is worse: a commit on main changes main and starts cache.yml for
nothing, an orphan branch is a second history to keep straight, and another
repository is a second set of write access to reason about. **Rejected.**

**A signed annotated tag per deploy.** git makes, signs, pushes, lists and
verifies them natively: `git tag -s`, `git verify-tag` with
`gpg.format = ssh` and an allowed-signers file. The tag points at main's own
commit, so the toplevel is the one cache.yml built. Each deploy is a new tag,
so the history of deploys is the list of tags. **Chosen.**

### One tag per host

`deploy/<host>/<stamp>`, for example `deploy/lifeline/20260101T120000Z`. A Pi
reads only its own namespace.

Per host rather than one tag for the fleet, because fleet-deploy deploys one
host at a time and stops at the first that does not come back right, so that a
bad revision reaches one resolver and not both. With one tag for all three, a
deploy stopped at lifeline would still leave core4 and core5 a signed tag to
take that night. With a tag per host, core4's tag does not exist until lifeline
has come back on the same revision, and the touch that signs it is the
go-ahead for core4. The cost is a touch per host, which fleet-deploy asks for
at the same moment as its confirmation.

The stamp makes names sort by time, for people and for the alert below. The Pi
does not trust the name for ordering: it uses the tagger date inside the signed
object.

### What fleet-deploy writes

For each host it deploys, after the brief and the go-ahead:

```
git tag -s -u <signing key> -m <message> deploy/<host>/<stamp> <revision>
git push origin refs/tags/deploy/<host>/<stamp>
```

The message says what was deployed and from where: the revision, the revision
the host ran, and the brief's verdict for that host. It is public, so it
carries nothing preflight's brief would not.

fleet-deploy signs only a commit on main. A Pi does not check that itself,
since it would need main's history, and the signature already says Nick chose
the commit.

**The push** is fleet-deploy's first write to GitHub. forge has no GitHub SSH
key (`home/git.nix`), so it goes over HTTPS, through gh's credential helper,
from Nick's terminal. In Claude's sandbox gh's token is hidden
(`lib/claude-sandbox.nix`), so a push from a command fails: the third of the
guards under "Signing".

### Earlier deploys, and rollback

Every deploy stays a tag. `git for-each-ref --sort=-taggerdate
refs/tags/deploy/lifeline` lists lifeline's, newest first, each with its
message.

Rolling back is a deploy: fleet-deploy signs a new tag, dated now, on the older
revision. A tag is never moved or deleted to roll back, so the newest tag is
always what the host should run, and the list reads as what happened.

An older revision's closure may have left the cache. cache.yml's
`workflow_dispatch` builds whatever ref it is run on, so it can be run on the
new tag, and fleet-deploy's cache wait finds that run by the tag's commit.

### What stops a tag moving

The Pi does not rely on GitHub for this. It checks that a tag's signed name is
the ref it was read from, and remembers the tagger date of the last tag it
accepted, so a tag moved onto another signed object, replayed under another
name, or deleted to expose an older one, cannot take it backwards.

A tag rule on `refs/tags/deploy/**` that refuses updates and deletion keeps the
history intact as well. That is a GitHub setting, and under "For Nick".

## Signing

[keys.md](keys.md) settles the key: one resident `ed25519-sk` signing key per
hardware key, made with `-O application=ssh:signing`, a touch per signature,
their public halves in a new `lib/signing-keys.nix`. Its order of work leaves
that file "with the Deploy pipeline's verifier" to this design, which takes it
up in the migration below.

`lib/signing-keys.nix` holds one entry per hardware key, named for the key, as
`lib/ssh-keys.nix` does per machine. The Pis build their allowed-signers file
from it, and so does Home Manager on each admin machine, for
`gpg.ssh.allowedSignersFile`, so that `git verify-tag` on forge checks a tag
the way a Pi will. Each line is limited to `namespaces="git"`, which is the
namespace git signs in, so these keys verify tags and nothing else here.

**Agents cannot sign, for three reasons, any one of which suffices:**

1. The private key is on the hardware key. The handle on forge is useless
   without it. The sandbox denies the FIDO2 device nodes ([keys.md](keys.md),
   order of work, step 1) and the SSH agent's socket
   (`lib/claude-sandbox.nix`), so a command cannot reach the device.
2. Every signature takes a touch. An attempt shows as an unexpected blink, not
   a tag.
3. A signed tag still has to be pushed, and the sandbox hides gh's token.

fleet-deploy itself reaches the Pis only from outside the sandbox, so it runs
from Nick's terminal and nowhere else (`home/fleet-deploy.nix`).

No commit is signed. `commit.gpgSign` would make every agent commit on forge
wait on a touch, and a squash merge would discard the signature anyway.

## Verification on the Pis

### Where it runs

The deploy login's `upgrade` takes no argument. It is a forced command with
fixed verbs ([`modules/deploy-agent.nix`](../modules/deploy-agent.nix)), and
it starts `nixos-upgrade.service`, the unit the nightly timer starts. So the
verification belongs in that unit, and then neither path can skip it.

It is a unit of its own, `deploy-ref.service`, which `nixos-upgrade` starts
and waits for as its first step. It runs as its own unprivileged system user,
with a state directory under `/var/lib/deploy-ref`, since it parses what
GitHub sends. Nothing running as root parses a tag: root reads one line, the
revision, and refuses it unless it is 40 hex digits.

fleet-deploy cannot hand a Pi a revision through the login, and that stays so.
Its job is to push the signed tag and then call `upgrade` as it does now. The
Pi reads the revision from the tag it verifies.

### Where it reads the ref

From GitHub, over the same HTTPS the flake fetch already uses, with no
credential: `git ls-remote https://github.com/nnorx/nix-config
'refs/tags/deploy/<host>/*'`, then a shallow `git fetch` of the tags it has not
seen into a bare repository in its state directory. That fetch brings each
tag's commit and tree too, which is a few megabytes.

### The signers it trusts

The allowed-signers file is a store path in the system the Pi is running,
built from `lib/signing-keys.nix` at that revision. It is never fetched beside
what it verifies: a signer list read from GitHub would let whoever wrote the
tag supply the key that signed it.

So a change to the signers takes effect on a Pi only once a revision carrying
it has been deployed there, by a tag that the previous signers signed.

### The checks

A tag is a candidate when it is in the host's namespace and its tagger date is
later than that of the last tag the host accepted, or, before the first, later
than the floor described below. Each candidate is checked:

1. **Signature.** `git verify-tag`, with `gpg.format = ssh` and
   `gpg.ssh.allowedSignersFile` set on the command line to the pinned file, in
   a repository the verifier created, so nothing fetched can change the
   configuration. git checks the signer's `valid-after` and `valid-before`
   against the tag's date.
2. **Name.** The `tag` line inside the signed object equals the ref it was
   read from, under `deploy/<this host>/`. This is what stops lifeline's tag
   being replayed as core4's, or an old tag under a new name.
3. **Type.** It tags a commit.
4. **Date.** Its tagger date is no more than an hour past the Pi's clock.
   `deploy-ref` runs after `time-sync.target`, so the clock is synchronized. A
   tag dated further ahead waits for a later run rather than counting as
   forged. Without this, a signing machine with a wrong clock could sign a tag
   dated next year, and every later tag would look older than it.

The newest candidate that passes all four is accepted: its name, tagger date
and revision go into the state directory. A candidate that fails 1, 2 or 3 is
reported.

A Pi that has accepted nothing yet, freshly installed or running `deploy-ref`
for the first time, takes as its floor the commit date of the revision it runs
(the flake's `lastModified`, built into the system), and the revision itself
stands as accepted. So the first run re-applies what is there, and a tag
signed before that commit, such as one fleet-deploy wrote in step 3 of the
migration while the Pis still followed main, can never take it back to a
revision older than the one it was installed or moved over on. A rollback is
still possible, since its tag is dated when Nick signs it.

### How the revision reaches the upgrade

The upgrade runs `nixos-rebuild` with `--flake github:nnorx/nix-config/<rev>`,
the accepted revision, where it now names main. That is the same flake URL
fleet-deploy and preflight evaluate, so the toplevel is the one cache.yml
pushed and fleet-deploy waited for. nixpkgs' unit puts `--flake` into its
script unquoted, so the revision can come from the unit's environment at run
time; the implementation chooses between that and replacing the script.

`git+file://` of the verifier's own repository at that revision was
considered: it would tie the source to the signed commit hash rather than to
GitHub's archive of it. It was set aside because it is a second fetcher for
the one path that runs unattended, which the brief and fleet-deploy would have
to mirror, and the archive is GitHub's to serve, which this design trusts. See
"What would reopen this".

### When something fails

- **A tag fails a check.** It is never deployed. `deploy-ref` exits failed
  after writing what it did accept, and is in `fleetAlerts.failure` without
  the upgrade's quiet priority, so the push goes out at high priority naming
  `deploy-ref` on that host. The upgrade still runs, to the newest tag that
  passed, or to the revision already accepted. A forged tag can neither deploy
  nor hold back a valid one. It stays a candidate, and alerts on every run,
  until Nick signs a newer deploy for that host or removes it.
- **GitHub cannot be read.** Not a verification failure: the upgrade fails at
  its own fetch, quietly, as it does when it outruns cache.yml, and the next
  night tries again.
- **`deploy-ref` itself is broken.** It fails on every run, so its push goes
  out every time, and the host keeps re-applying its accepted revision without
  taking a new one. The way forward is a deploy by hand over the admin login,
  as under "Rotation and recovery" below.

### What the nightly run does

The timer still runs every night. Usually there is no new tag, and the run
re-applies the accepted revision: a switch that changes nothing, or, for a
kernel staged by a daytime deploy, the reboot inside the window that it does
today. It also applies a tag that was signed and pushed but never upgraded by
day. The heartbeat keeps meaning what it does: a night with no successful run.

## Rotation and recovery

**Adding a signer.** A pull request adds the public half to
`lib/signing-keys.nix`. Once merged, fleet-deploy deploys it with a tag signed
by an existing signer. From then on that host accepts the new key.

**Removing a signer that was lost but not leaked.** The same, the other way: a
pull request removes the line, and a remaining signer deploys it. With two
hardware keys enrolled, losing one is this.

**Removing a signer that leaked.** Until the removal is running on a host, a
tag signed with the leaked key passes there, so the order matters:

1. `fleet-deploy hold` every Pi. A held upgrade does not run, from the timer
   or the deploy login, so no tag is applied meanwhile.
2. Merge the removal.
3. On each Pi, deploy that revision by hand over the admin login, naming it
   explicitly, rather than through a tag, since a tag from the leaked key
   could be dated later than Nick's.
4. Sign a tag for that revision with a remaining key, then `fleet-deploy
   release` each Pi. Tags from the leaked key now fail the signature check, and
   are reported until a later deploy of Nick's is dated past them.

**Losing every signing key.** No tag can be signed. A new key goes into
`lib/signing-keys.nix` and is merged. Nick signs a tag for that revision with
the new key, which no Pi trusts yet, then deploys the revision by hand on each
Pi. The next run finds the new key in the running system and accepts the tag.

**Why a Pi is never stranded.** The verifier gates the unattended path and the
deploy login, never the admin's. A Pi whose admin login works, with sudo, can
always run `nixos-rebuild switch --flake github:nnorx/nix-config/<rev>` by
hand, whatever its signers or its verifier. A deploy by hand lasts until the
next run, which returns the host to its accepted revision, so it is paired with
a tag for the same revision, as in the steps above. If the admin login is lost
as well, which in keys.md's target state means both hardware keys, the
console with the sudo password is the way in. Neither is a card pull.

## Nightly policy

**Every deploy goes through fleet-deploy. Nothing signs automatically.**

The alternative weighed was keeping hands-off nights for merges whose verdict
is `routine`: a job would sign a tag for main's head each evening when
preflight's brief said `routine`. Its key would live on a server, CI or core5,
and sign without a touch. Whatever can reach that key, or change what the job
runs, deploys. The verdict itself comes from code in the commit being judged:
preflight's rules are in the repository, so a commit can rewrite the rules
that call it routine. That gives back exactly the property this design exists
for.

What hands-off nights bought, and what replaces it:

- **Not having to be there for a change that needs no one.** fleet-deploy
  takes minutes by day for a routine change, a touch per host.
- **Letting the night do a reboot.** `fleet-deploy --tonight` signs each Pi's
  tag and pushes it without calling `upgrade`, so the timers apply it in the
  night, an hour apart, a kernel reboot inside the window. That is the old
  nightly behaviour, chosen per deploy. The stagger is not a canary
  (`hosts/common/pi.nix`): a deploy that wants lifeline proven first runs by
  day. A run that starts before cache.yml has finished fails, as now, and the
  next night retries.

The deploy login keeps its verbs. Its key brings forward the deploy of what
Nick has already signed for that host, reboots it when nothing would be cut
off, or holds its upgrades, and chooses no revision.

## Required checks on main

main takes changes only through pull requests, squash-merged, with `check` and
`flake-check` as required checks, and refuses force pushes and deletion. That
is a repository ruleset, and it is part of this design rather than a decision
in it.

It guards against merging a red pull request by mistake. It is a setting of
the repository, which the account that owns it can change, so it says nothing
about who chose a deploy. That is the signature's job.

`check` and `flake-check` run on every pull request under fixed names, which
is what a required check needs. `build-etc` and `vm-tests` are matrices named
per entry (`vm-tests (<name>)`), so requiring them would mean listing each
entry, and a new VM test would go unrequired until added. They stay advisory.
For the Pis, the build gate is cache.yml anyway: it builds each Pi's whole
toplevel on main, and fleet-deploy does not upgrade a host until its toplevel
is in the cache.

The weekly flake-update pull requests get their checks. update-flake.yml opens
them with its own token rather than the run's `GITHUB_TOKEN`, because GitHub
starts no workflows for a pull request that a run's `GITHUB_TOKEN` opens; with
its own token, `check` and `flake-check` run on them like any other.

## gate

gate deploys by hand and stays that way: no timer and no deploy login.

**It uses the same scheme, in its own namespace, `deploy/gate/<stamp>`.** gate
runs the same verifier by hand: on gate, `nrs` and `nrb` verify gate's newest
tag against the signers in gate's running system and rebuild that revision.
The signature adds less on gate than on the Pis, since its deploys already
take Nick at a sudo prompt. What it adds is that gate runs what Nick looked at
and signed, not main as it stands when `nrs` fetches it.

It is adopted with the planned guided gate flow, which is where signing gate's
tag fits: the flow shows preflight's brief for gate, signs the tag, arms
`deploy-guard` where the change needs it, runs the rebuild of the verified
revision, and confirms. Until then gate's `nrs` stays as it is.

`deploy-guard` and the planned switch rollback act after a revision is chosen,
and return gate to a generation, which is local, not to a revision. Neither
needs the ref. After a rollback gate runs an older generation than its newest
tag, and the reminder below reports that until gate is deployed again.

The explicit form, `nixos-rebuild switch --flake
github:nnorx/nix-config/<rev>`, stays available on gate with sudo, as on the
Pis, and the recovery USB does not touch any of this.

## What assumes the Pis follow main

Each place that does, and what it becomes. `git grep -n -E
'github:nnorx/nix-config|ls-remote|origin/main|origin main|head_sha'`, and a
search for "tonight", "that night" and "main's head", find these.

| Where | Now | Becomes |
|---|---|---|
| `modules/baseline.nix`, `system.autoUpgrade.flake` and its comments | `github:nnorx/nix-config`, main's head, and "a run that outruns cache.yml fails and the next night retries" | `github:nnorx/nix-config/<rev>`, the revision `deploy-ref` accepted, on hosts that run it |
| `modules/baseline.nix`, `nrs` and `nrb` | Deploy main, "so the two cannot disagree about where main lives" | On the Pis, and on gate once it adopts the scheme, deploy the accepted revision, so they still agree with the upgrade. forge keeps main |
| `hosts/common/pi.nix` | Turns on the upgrade, from main | Also turns on `deploy-ref`. The comment that the stagger is not a canary stays true |
| `modules/deploy-agent.nix`, header | What gets deployed is "`main` on GitHub" | The host's newest tag that verifies. `status` gains a `deploy-tag` line, the accepted tag. `run()`'s note that a run in progress "fetched main when it began" becomes "verified its tags when it began" |
| `modules/alerting.nix`, `fleet-main-revision` | `git ls-remote ... HEAD`, main's head; `repo` from `removePrefix "github:"` of the flake, and an assertion that it is a `github:` flake | Also reads `refs/tags/deploy/*`, peeled, and exports each host's newest tag's revision. `repo` comes from its own binding, since the flake string now carries a revision |
| `modules/alert-rules.nix`, `RevisionBehind` and `RevisionCheckStale` | Every host judged against main's head: 36 hours for the Pis, 7 days for gate | A Pi is judged against its own newest deploy tag at 36 hours: it has not applied what Nick signed. Every host, gate included, is judged against main's head at 7 days, as a reminder that merges are waiting for a deploy. `RevisionCheckStale` covers both reads |
| `tests/alert-rules.nix`, `tests/alerting.nix` | Series and a flake string for main's head | The same for the deploy tags |
| `modules/alerts.nix` | The upgrade in `failure` and `heartbeat`, at quiet priority | `deploy-ref` in `failure`, at high priority. The upgrade's note on failing before cache.yml finishes stays |
| `modules/host-status.nix` | "fleet-status compares it with main from outside" | Prints the accepted tag and its revision too, from the state directory, so a host's running revision is compared with what it should run without asking GitHub |
| `home/ssh.nix`, `fleet-status` | `compare/<rev>...main` per host | Running against accepted, from host-status, and against main as a second column: behind main means merges waiting for a deploy |
| `home/fleet-deploy.sh` | `git fetch --quiet origin main`, the deploy's target | The target revision: main's head by default, or one named for a rollback |
| `home/fleet-deploy.sh`, the host list | From main's `autoUpgrade.enable`, through `github:nnorx/nix-config/$main` | From the target revision, the same way, so a Pi added or retimed there is deployed as that revision has it |
| `home/fleet-deploy.sh`, the brief | `preflight --base <running> --head <main>` in a worktree at main | `--head <target>`, in a worktree at main's head, so the rules are the newest whatever the target |
| `home/fleet-deploy.sh`, the cache wait | cache.yml's run by `head_sha=$main` | By the target's commit, which also finds a dispatched run for a rollback |
| `home/fleet-deploy.sh`, success | "the host runs main", "already on main", "staged for main" | Each against the target revision. "Already on" means its accepted tag is on the target and it runs it. New: the tag signed and pushed before `upgrade`, and `--tonight` |
| `tests/fleet-deploy/run.sh` | Seeds a fake remote's main | Also its tags, and the signing step |
| `scripts/preflight.sh`, `--base` | Defaults to where the branch left `origin/main` | Unchanged: a pull request's brief is what it changes in main. Its header's "the Pis, which upgrade from main the same night" changes |
| `scripts/preflight-brief.jq` | "Reboots tonight", "Merge when you can be at hand tonight", "Merge early in the day", "still upgrades from main" | The same findings, phrased for the deploy: "reboots when deployed", "deploy when you can be at hand". The early-in-the-day finding becomes "fleet-deploy waits for cache.yml to build this, 2 to 5 hours". A host removed from the flake keeps its accepted revision and gets no further tags, so that finding becomes a review note |
| `.github/workflows/cache.yml` | Builds every Pi's toplevel on push to main | Unchanged, so a revision's closure is ready before Nick deploys it. `workflow_dispatch` on a deploy tag rebuilds an older revision for a rollback |
| `.github/workflows/cache-vm-tests.yml`, comment | cache.yml's result says the Pis can substitute "tonight's upgrade" | "the next deploy" |
| `.github/workflows/check.yml`, comment | "preflight has origin/main" | Unchanged |
| `home/pr-handoff.sh`, merge comment | "Merging deploys the Pis that night" | Merged code is what fleet-deploy offers to deploy, so a push since the review still must not ride along |
| `lib/hardening.nix`, comment | "the read of main's head" | "the reads of main's head and the deploy tags" |
| CLAUDE.md, preflight and "Deploying and merging" | Merging deploys the Pis that night; the verdict is about merging; merge lock bumps early; publishing stays Nick's because a merge deploys | Merging deploys nothing; fleet-deploy signs and deploys; the verdict is about deploying; the lock-bump rule goes; publishing stays Nick's, with its reason restated for this design |
| README, "Deploying", "SSH access", the CI table and preflight's paragraph | "Merging to `main` deploys the Pis that night" and its two consequences; a new key "merge. The Pis pick it up that night" | A deploy is fleet-deploy. An addressing change reaches each Pi as fleet-deploy reaches it, so gate goes first. A new key reaches the Pis at their next deploy |
| [recovery.md](recovery.md), "When sudo is the thing that broke" and "The silent wrong boot" | A re-key "merged to `main`" could reach core5 unattended; a recovered Pi "pulls `main` again"; `fleet-status` compares with main | Nothing reaches a Pi unsigned; a recovered Pi re-applies its accepted revision, so a fix is a signed deploy, or a hold first; compared with its accepted tag |
| [home-assistant.md](home-assistant.md), restoring | "First stop main from undoing it. core5's 05:00 upgrade builds main" | core5 re-applies its accepted revision, so a rollback is a deploy tag on the older revision, or a hold |
| [keys.md](keys.md) | The roots, the deploy key's row, the GitHub account's row and the theft list's "Merge, which reaches the Pis that night" | The signing keys among the roots; the deploy key's row as under "Nightly policy"; a theft's key removals reach the Pis through a signed deploy |
| [observability.md](observability.md), "The wrong boot" and the alert table; [fleet-agent.md](fleet-agent.md), the evidence table | `RevisionBehind` against main's head | Against each host's deploy tag, and the 7-day reminder against main |
| [privacy.md](privacy.md), "Flake fetches" | `nrs`, `nrb` and the upgrade fetch `github:nnorx/nix-config` | Each fetch names a revision, and the upgrade also lists and fetches its tags. GitHub sees the same |
| [pi-install.md](pi-install.md), first deploy | `nixos-rebuild build` and `boot` from `github:nnorx/nix-config#lifeline` | Unchanged. A new Pi accepts nothing until fleet-deploy signs its first tag, and meanwhile re-applies what it runs |
| [device-identity.md](device-identity.md) step 5, [power.md](power.md), [fleet-agent.md](fleet-agent.md)'s milestones, [services.md](services.md)'s order, [privacy.md](privacy.md)'s order | "Merging deploys it that night" for steps not yet done | "Deploying it", where the step is still ahead when that record's pull request is written |

`pkgs/night-shift/night-shift.sh` and `tests/night-shift/run.sh` read the
default branch to make worktrees from, [ipv6.md](ipv6.md) tests a branch by
name, and [device-identity.md](device-identity.md)'s options say that `nrs` on
gate fetches from GitHub, which stays true. None of them assumes the Pis
follow main.

## What does not change

- forge rebuilds itself from its checkout, with `hms` and its own `nrs`.
- cache.yml's trigger, its runners, and the Pis' substitute-only upgrade.
- The deploy login's verbs and its forced command, and fleet-deploy's
  `status`, `hold` and `release`.
- The upgrade times and the reboot window.
- preflight's checks, and its brief's default base.

## Migration order

One pull request per step. No step leaves a Pi unable to upgrade: until step
5, every Pi follows main exactly as now, and from step 5 each host moves alone,
lifeline first, with the way back written down.

**The way back, at any step that changes a Pi.** `fleet-deploy hold <pi>`, so
the night does not repeat what went wrong. Merge the revert. Deploy it on the
held Pi by hand over the admin login, naming the revision, or pick the previous
generation ([recovery.md](recovery.md), "Picking an older generation"). Then
`fleet-deploy release <pi>`.

0. **Before any of it**, keys.md's order of work as far as its step 1, the
   sandbox denying the FIDO2 device nodes, and the signing keys enrolled on
   both hardware keys. Those are the Keys & identity project's.
1. **`docs/deploys: ...`**, this record. No host changes. Expected verdict:
   `routine`.
2. **`home: verify deploy tags against lib/signing-keys.nix`.** The new lib
   file with both public halves, and Home Manager setting `gpg.format = ssh`
   and `gpg.ssh.allowedSignersFile` from it on each admin machine. Nothing
   signs yet. Only Home Manager configs change: `routine`.
3. **`home/fleet-deploy: sign and push a tag per host before upgrading it`.**
   fleet-deploy still deploys main, and now tags each host on main's head as
   it goes. The Pis ignore the tags, so this exercises the touch, the push and
   `git verify-tag` on forge with nothing depending on it. `routine`.
4. **`fleet: deploy-ref, off by default`.** `modules/deploy-ref.nix`, its
   option off everywhere, and a VM test that serves a repository locally
   (the repository URL is an option) and checks every rule above: a valid tag
   accepted; unsigned, unknown signer, another host's tag replayed, older than
   accepted, and dated ahead each refused or deferred; a rejected tag
   alerting while a valid one still deploys; no tag at all re-applying the
   running revision; on the first run, a valid tag signed before the running
   commit ignored. No toplevel changes: `routine`.
5. **`lifeline: follow its deploy tag`.** `deploy-ref` on for lifeline alone,
   with the flake string, `nrs`, host-status's line and the deploy login's
   `deploy-tag`. Expected verdict: `review`, since lifeline's upgrade itself
   changes. If the brief shows core4 or core5 changing too, hold them before
   merging and release them once lifeline has run a night on its tag. After
   merging, `fleet-deploy lifeline` the same day: it signs lifeline's tag on
   the merge commit and upgrades lifeline through the old unit, which lands it
   on that same commit, now running `deploy-ref`. Merged in the evening
   without a deploy, lifeline takes it from main that night instead, and
   re-applies it every night after until its first tag. Then, before step 6:
   - the next night's run accepts the tag, and host-status shows it;
   - two later deploys go through the tag, one of them staging a kernel;
   - a drill: Nick pushes a `deploy/lifeline/` tag signed by a key not in
     `lib/signing-keys.nix`, sees the high-priority push and no upgrade to it,
     then signs a newer deploy and sees the alert stop.

   Until step 7, `RevisionBehind` still judges lifeline against main, so a
   merge that waits more than 36 hours for its deploy fires it. Deploying
   lifeline clears it.
6. **`pis: core4 and core5 follow their deploy tags`.** The same switch for
   both, after step 5's checks. `review`. From here no merge reaches a Pi
   unsigned.
7. **`core5: judge each Pi against its deploy tag`.** `fleet-main-revision`
   reads the tags, `RevisionBehind` splits into the 36-hour judgment against
   each Pi's tag and the 7-day reminder against main for every host, with
   their tests. Expected verdict: `routine` or `review`, since core5 switches
   and its alerting units restart. The same pull request moves `fleet-status`
   in `home/ssh.nix`.
8. **`home/fleet-deploy: deploy a chosen revision, and --tonight`.** Rollback
   by revision, with cache.yml dispatched for one that left the cache, and
   signing without upgrading. `routine`.
9. **`preflight: the brief speaks of deploying, not merging`.** The jq
   wording and preflight's header. Host toplevels do not change: `routine`.
10. **`CLAUDE.md`, `README` and the runbooks.** Everything in the table above
    that is prose: CLAUDE.md's "Deploying and merging", the README's
    "Deploying", recovery.md, home-assistant.md, keys.md, observability.md,
    fleet-agent.md, services.md and privacy.md. `routine`. Only after step 6,
    since until then merging still deploys core4 and core5.
11. **gate, with the guided gate flow.** `deploy-ref` on gate without a timer,
    and gate's `nrs` and `nrb` verifying first. gate changes only when Nick
    deploys it, with the brief's verdict for gate in the pull request.

The tag rule under "For Nick" belongs before step 5.

## For Nick

1. **A tag rule on `refs/tags/deploy/**`.** Recommended: refuse updates and
   deletion, and leave creation open. The Pi checks every tag's signature, so
   an unsigned one only alerts, while a rule on creation would need an
   exception for fleet-deploy's push. With deletion refused, removing a bad
   tag starts with a deliberate change to the rule.
2. **A third, offline signer.** keys.md keeps the `nick` age key as an offline
   third recipient beside the two hardware keys. The same is possible here: a
   file signing key, generated offline and kept like `nick`, listed in
   `lib/signing-keys.nix`, for when both hardware keys are lost. This record
   recommends against it: the deploy by hand under "Rotation and recovery"
   already covers that case without a key that signs with no touch, and
   losing both hardware keys costs the admin login too, which needs the
   console either way.

## What would reopen this

- A need for deploys that happen without Nick, such as a security update
  that cannot wait for him. That brings back an automatic signer, and the
  argument under "Nightly policy" against one.
- A Pi that must deploy from somewhere other than GitHub, such as a mirror,
  which moves where `deploy-ref` reads and what it trusts.
- GitHub's archive of a commit, or the cache's paths for a revision, becoming
  something this design has to verify rather than trust. The first moves the
  upgrade to `git+file://` of the verified commit; the second is a question
  for the binary cache's own design.
- Squash merging ending, if main's own commits were ever made by Nick's key.
  A signed commit on main would then be checkable in place, and a tag might
  not be needed.

This file changes no host. The migration's modules will carry the details.
