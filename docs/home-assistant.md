# Home Assistant

Runs on core5 as a native NixOS service, from
[`modules/home-assistant.nix`](../modules/home-assistant.nix), at
`http://192.168.20.49:8123`. It replaces Google Home: lights, automations and,
in later phases, Zigbee buttons and voice, with no vendor cloud in the path.

Reachable from `trusted` only. core5 opens the port on its wired interface, and
gate forwards into `servers` from `trusted` in full but from iot and work only
on port 53, so no other segment can load it. The exception is `servers` itself,
which reaches core5 directly without crossing gate: the other Pis, the switch
and AP, and anything plugged into a switch port left on the untagged default
(see [network.md](network.md#switch-topology)). WireGuard peers cannot load it
either: `grants` in [`hosts/gate/wireguard.nix`](../hosts/gate/wireguard.nix)
has no entry for it, so there is no way in from outside the house. Adding one is
its own decision, and the place to make it.

## Native, and from `unstable`

Both decided on evidence; the module header has the detail.

**Native rather than a container**, the reverse of [UniFi](unifi.md). Home
Assistant is free software that Hydra builds, so the nixpkgs module gives a
declarative config and a closure CI can cache, with no Docker in the path.

**The package comes from `unstable`, not core5's own package set.** core5
evaluates against nixos-raspberrypi's nixpkgs, which replaces ffmpeg with
Raspberry Pi's fork. Home Assistant links ffmpeg, so on that package set it and
several of its Python dependencies miss cache.nixos.org and CI would rebuild
them. `unstable` carries no overlay and substitutes. The only thing built is the
Home Assistant package itself, with its test suite switched off.

## First run

From a machine on `trusted`, open `http://192.168.20.49:8123`.

1. **Create the owner account locally.** Nothing in onboarding needs a Home
   Assistant Cloud account, and none is wanted.
2. **Set the location, time zone and units here, in the UI.** They are
   deliberately absent from the Nix config: Home Assistant treats any of those
   keys in YAML as locking the whole location editor, and the house's
   coordinates do not belong in a public repo. They are kept in
   `/var/lib/hass/.storage`.
3. **Leave analytics off.** It is opt-in, so this means declining the prompt.

## Phones

Install the Home Assistant Companion app (iOS and Android) and point it at
`http://192.168.20.49:8123`. It works while the phone is on the trusted SSID,
and not through the tunnel, for the reason above.

Plain HTTP is acceptable while only trusted devices can reach the port. It stops
being acceptable the day anything else can.

## Adding an integration

**Add its domain to `extraComponents` first, then add it in the UI.** nixpkgs
builds Home Assistant with the Python dependencies of the listed integrations
and no others. An integration added in the UI without that fails at setup with
a missing module, not with a message that points here. The domain is the last
path segment of the integration's documentation URL.

The list replaces the module's default rather than extending it, which is why
the first four entries restate that default.

## What is state

Everything made in the UI lives in `/var/lib/hass`: users, integrations,
devices, dashboards, and the automations, scenes and scripts in their YAML files
there. `home-assistant_v2.db` is the recorder's history. None of it is in this
repo. Everything but the history is copied off-box daily; see
[Backups](#backups).

`configuration.yaml` is the exception. It is a symlink into the Nix store,
rewritten on every start, so edits made to it on the host do not survive.

## Upgrades and rollback

**Home Assistant moves whenever `flake.lock` moves `nixpkgs-unstable`**, and
core5's automatic upgrade applies that at 05:00 without anyone present. Merge
lock bumps early in the day, as with any other.

**Treat an upgrade as one-way.** Home Assistant migrates the recorder database
forward on start and does not support downgrades. Rolling core5 back a
generation across a Home Assistant version change puts an older binary in front
of a newer schema. Before doing that, restore a backup taken by the older
version, as [Restoring](#restoring) describes, rather than rolling back blind.

## Backups

Home Assistant writes its own backups, and
[`modules/home-assistant-backup.nix`](../modules/home-assistant-backup.nix)
pushes the newest one to the private `homelab-state` repo every day at 07:00,
age-encrypted, the same way and to the same repo as
[UniFi's](unifi.md#the-automated-copy). It is a no-op when the newest backup is
one it has already pushed.

### Setting up the automatic backup

Nothing is pushed until Home Assistant has written a backup, and until then
`home-assistant-backup` fails, saying so. In Settings > System > Backups, set up
automatic backups as follows:

- **Daily, at a custom time of 06:15.** The default is 04:45 plus up to an hour
  of random delay, which overlaps core5's 05:00 upgrade, and that upgrade may
  restart Home Assistant or reboot the Pi. A custom time has no random delay.
  It is in Home Assistant's own time zone, the one set during onboarding, so
  that has to match the house's.
- **Settings only. Leave the history (the database) out.** Every version stays
  in the repo's history for good, and the database grows without bound. The
  unit refuses any backup over 50 MiB, which is what it would look like.
  Restoring without history loses the graphs, not the setup.
- **This system only, with encryption off for it.** age encrypts the copy that
  leaves the host, to the same key as everything else, so Home Assistant's own
  encryption would add a second key to keep and nothing else. The local copy is
  readable only by `hass`.
- **Keep three copies** locally. The off-box history keeps the rest.

**Enabled is not the same as having run.** After the first 06:15, check that
`/var/lib/hass/backups` has a `.tar` and that the next 07:00 run pushed it:

```bash
ssh core5 'sudo ls -l /var/lib/hass/backups; systemctl status home-assistant-backup'
```

**Check the size too.** Home Assistant rewrites files under `.storage` all the
time, so no two daily backups match and each one is a new commit, kept for
good. At a few MB that is about a GB a year in `homelab-state`, and in core5's
clone of it. If the first backup is over about 1 MB, revisit the daily
schedule.

**Only automatic backups are pushed**, by their filename. A manual backup taken
before a risky change may include the database or Home Assistant's own
encryption, so it stays local. Leave the automatic backup's name at its
default for the same reason.

Home Assistant keeps its backups private to `hass`, so a root step copies the
chosen file to the `core5` user and does nothing else. The push itself runs as
`core5`, like UniFi's. Running it as `hass` would put the deploy key in reach
of Home Assistant, and running it as root would put git and ssh on the network
as root. Its other properties, and the ruleset that stops a compromised core5
from erasing history, are the UniFi copy's, described in [unifi.md](unifi.md).

**Alerts.** As with UniFi, a failed run sends a push notification, a day
without a successful one alerts from healthchecks.io (`modules/alerts.nix`),
and a newest backup more than two days old fails the run, so Home Assistant
quietly no longer backing up is caught too.

### Restoring

**`latest` is not always the one you want.** For a rollback, pick the last
backup the older version took. After a rebuild, pick the last one from before
the loss: a fresh install's first backup is of an empty setup, and it lands on
top.

```bash
git clone git@github.com:nnorx/homelab-state.git && cd homelab-state
git log --format='%h %ad %s' --date=short -- home-assistant/latest.tar.age
git show <commit>:home-assistant/latest.tar.age > pick.tar.age
age --decrypt --identity ~/.config/sops/age/keys.txt pick.tar.age > restore.tar
```

Then restore onto an empty setup running the same version that took the
backup, or a newer one:

1. `systemctl stop home-assistant-backup.timer home-assistant` on core5, so
   nothing lands on top meanwhile.
2. Move `/var/lib/hass` aside rather than deleting it, then recreate it empty:
   `install -d -o hass -g hass -m 0700 /var/lib/hass && systemd-tmpfiles --create`.
   The unit does not create its own directory, and Home Assistant will not
   start without the include files tmpfiles seeds.
3. For a rollback, first stop main from undoing it. core5's 05:00 upgrade
   builds main, so the next one would bring the newer version back, migrate
   the restored data forward again, and push that as `latest`. Revert the
   `flake.lock` bump that brought the newer version. Then roll core5 back to
   the generation that took the backup. If the revert is not merged yet, run
   `systemctl stop nixos-upgrade.timer` after the rollback, not before it,
   since a generation switch may start the timer again. Stopping it holds only
   until core5 next reboots.
4. Start `home-assistant`. With an empty directory it opens onboarding, which
   offers to restore from an uploaded backup. Upload `restore.tar`.
5. Start the timer again after Home Assistant's next 06:15 backup, not before.
   The timer catches up on a missed 07:00 as soon as it starts, and until then
   the newest file in `/var/lib/hass/backups` may be the one just uploaded,
   which would go off-box as today's `latest`.

**A backup nobody has restored is not a backup.** This path has not been
drilled yet.

## Troubleshooting

```bash
ssh core5 'systemctl status home-assistant; journalctl -u home-assistant -n 50'
```

**Wait two minutes after "Back up now" before running the push by hand.** The
push only takes a backup at least two minutes old, so that it never copies one
Home Assistant is still writing. Started sooner, it skips the new file: with no
older one it fails with `no Automatic_backup_*.tar older than two minutes`, and
otherwise it picks the previous backup, which is usually already pushed. Choose
an automatic backup in that dialog, since a manual one is never pushed. Then:

```bash
ssh core5 'sudo systemctl start home-assistant-backup'
```

core5 runs a 16K page-size kernel, so if Home Assistant or one of its
dependencies crashes in a way that makes no sense, suspect that first. Upstream
builds, and their memory allocators in particular, mostly assume 4K pages.
