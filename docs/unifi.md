# UniFi controller

Runs on core5 as two pinned containers, the Network Application and its
MongoDB, on a private Docker network. Only the application publishes ports; the
database is reachable from nothing but the other container. See
[`modules/unifi.nix`](../modules/unifi.nix).

It manages the Flex switch and the U7 Pro. Its database holds adoption state,
SSIDs, PSKs, VLAN assignments and port profiles, none of which are in this repo
under any approach, which makes [backups](#backups) the part that matters.

## Containers rather than `services.unifi`

Decided on evidence rather than taste. Both `unifi` and `mongodb` are unfree
(Ubiquiti's EULA and the SSPL), so Hydra does not build them and
`cache.nixos.org` does not carry them. The module path would mean core5
compiling MongoDB from source, CI attempting the same inside its 350-minute cap,
and the result being pushed to a *public* Cachix, which is redistribution of
both.

It also decouples controller upgrades from `nix flake update`. UniFi's database
migrations are one-way, so a lock bump that moved the controller would leave a
generation rollback facing a newer schema with an older binary, which does not
start.

MongoDB 5+ requires ARMv8.2-A. The Pi 5's Cortex-A76 has it and the Pi 4's
Cortex-A72 does not, so this cannot move to core4 or lifeline without changing
database.

## First login

**Take the local admin option, not a Ubiquiti account.** Signing in with a UI
account ties the controller to their cloud, which is the thing moving off Google
was meant to avoid. If it happens by accident the association lives in the
database, so the fix is to stop both containers, empty `/var/lib/unifi/db` *and*
`/var/lib/unifi/config`, and start again. Emptying `db` matters as much as
`config`: the MongoDB init hook only runs against an empty data directory, and
that is what recreates the application user.

Then two settings, neither expressible in Nix because they live in the
controller's own database:

1. Settings > System: turn **off** Remote Management and Analytics. Otherwise
   Google's telemetry has been swapped for Ubiquiti's.
2. Settings > System > Backups: set a schedule. See
   [the automated copy](#the-automated-copy) for what its interval costs.

The inform host used to be a third. The controller advertises an address for
devices to report to, and on a bridge network that is its container address in
172.16/12, which nothing on the LAN can reach. The symptom is not an error:
adoption appears to begin and then loops forever. `modules/unifi.nix` now seeds
`system_ip` into `system.properties` before every start, from `lib/net.nix`, so
it survives a volume wipe and follows the host if it renumbers.

## Backups

Adoption state, SSIDs, PSKs and VLAN assignments live in MongoDB. The controller
writes its own backups to `/var/lib/unifi/config/data/backup/`, owned by the
`core5` user so they can be copied without root:

```bash
scp -r core5:/var/lib/unifi/config/data/backup/ ./unifi-backup-$(date +%F)/
```

**Treat those as sensitive.** They contain Wi-Fi PSKs and device credentials, so
they do not belong in this repo or any public location.

This is state that lives outside the flake and is not reproducible from Nix.

### The automated copy

[`modules/unifi-backup.nix`](../modules/unifi-backup.nix) takes the newest file
the controller wrote, encrypts it to the `nick` age recipient, and pushes it to
a private repo. A daily timer on core5, and a no-op when the newest backup is
one it has already pushed.

It does not make a backup of its own. The controller's `.unf` is the format its
restore flow expects, and a `mongodump` would be a second, unsupported path
into a database whose migrations are one-way. The module's only job is moving
a file that already exists off the host that holds the original.

**It depends on the controller's own schedule**, and the schedule's interval
bounds how stale the off-box copy can be: on a monthly schedule, a change made
on the 2nd is not off the box until the 1st of the following month. Until the
first scheduled run, `config/data/backup/autobackup/` is empty and the unit
fails loudly saying so, rather than exiting cleanly on nothing.

Two things on that settings page are easy to misread:

- **The tooltip's path is wrong for this install.** It names
  `/var/lib/unifi/backup/autobackup`, the location on a Debian package install,
  which does not exist in this container. The real directory is
  `/config/data/backup/autobackup`, on the volume, so scheduled files survive
  the container being recreated.
- **Enabled is not the same as having run.** `logs/backup.log` records every
  run. On 2026-09-12 it held three, all manual exports, beside a schedule that
  had been switched on after its first possible run time and so had never
  fired.

**Backup Retention: Settings Only** is the right choice. It keeps a backup
around 30 KB, and settings are what a rebuild needs; statistics history is not.

age encryption needs only the public half of the key, so core5 holds nothing
that can read these back. That is what makes a private repo an acceptable
destination for a file carrying Wi-Fi PSKs: the destination is untrusted by
construction, and the private half is in Bitwarden and
`~/.config/sops/age/keys.txt`.

The plaintext hash is what decides whether to commit, not the encrypted blob.
The timer runs daily while the controller writes a new file only on its own
schedule, and age uses a fresh ephemeral key per run, so the same file encrypts
differently every time. Comparing ciphertext would re-commit an already-pushed
backup every day.

**Known gap: a silent stop.** Nothing alerts on the unit failing.
`systemctl status unifi-backup` on core5 is the manual check until the Phase 8
monitoring work in [router.md](router.md) covers it.

Whether the repo can stand in for that check is not yet confirmed. If the
controller writes a byte-different file on every run, as it probably does since
the archive records when it was made, every scheduled run produces a commit,
and a repo quiet for longer than one interval means the pipeline is broken. If
identical settings produce identical files, commits happen only on real changes
and a quiet repo proves nothing. Two consecutive scheduled files with different
hashes and no config change between them settles it.

### Restoring

```bash
age --decrypt --identity ~/.config/sops/age/keys.txt \
  unifi/latest.unf.age > restore.unf
```

Then a fresh controller, and Settings > System > Backups > Restore. Expect to
re-adopt: a restore brings back the saved device config, which is the thing
that stranded the switch on 2026-09-04, so read the re-adoption section below
before assuming it will come back clean.

**A backup nobody has restored is not a backup.** This path has not been
drilled yet.

## Upgrading

Change the digest in `modules/unifi.nix`. Get the new one with:

```bash
nix run nixpkgs#skopeo -- inspect --format '{{.Digest}}' \
  docker://lscr.io/linuxserver/unifi-network-application:<version>
```

Read Ubiquiti's release notes first. Downgrading needs a restore from backup,
not a generation rollback, because the migrations are one-way.

## Device firmware

Automatic device updates are off, deliberately. The Flex switch supplies PoE to
all three Pis, so updating its firmware drops power to the entire DNS layer.
That reboot is deferred, not avoided.

Do it on its own evening, with a client pointed at a public resolver first, and
expect every Pi to hard-reset.

## Re-adopting the Flex switch

The switch became unadoptable on 2026-09-02 and stayed that way. Three
independent blockers, each of whose obvious fix needs one of the others already
cleared, which is why this needs a deliberate order rather than an attempt.

1. Its stored inform URL pointed at a retired address that no longer exists
2. Device SSH is disabled on it, so `set-inform` cannot repair that in place,
   and enabling device SSH is itself a setting pushed over inform
3. Its management rides the untagged native VLAN

**A reset device needs a pool to come back on, and there is not one by
default.** `servers` deliberately carries no DHCP pool, for the reasons in
[network.md](network.md). So step 0 is putting one back, temporarily: add to the
`servers` segment in `lib/net.nix`, deploy gate, and remove it again afterwards.

```nix
      pool = {
        first = "192.168.20.100";
        last = "192.168.20.150";
      };
```

Without it a factory-defaulted UniFi device gets no lease and falls back to its
built-in `192.168.1.20`, which gate does not address. Leaving the pool in place
permanently trades a rare bootstrap problem for a constant one on every client
VLAN, which is the wrong way round.

Then:

1. **Forget the device in the controller first**, then factory reset the switch.
   Order matters, and this is the step that was missed: two resets in a row
   appeared to fail because the controller still held the device record and
   auto-re-adopted within seconds, pushing the same broken saved config back
   every time. Forgetting deletes the saved config so the reset has something to
   stick to.

   Hold reset until the LED changes, roughly ten seconds. **Watch the LED, not
   the clock: white means it worked, blue means it did not.** A short press only
   reboots, and the two are easy to confuse because both make the device drop
   and return.
2. Nothing to do on gate. `servers` is the untagged native VLAN and a
   factory-default switch tags nothing, so the two already agree.
3. Adopt the switch in the controller. Discovery is L2 and everything shares a
   VLAN at this point, so it should appear on its own.
4. **Change no native network on any port.** Add only tagged trusted, iot, work
   and guest to gate's uplink port and the AP's port, which is what SSIDs need.
   Everything else stays on the factory default. Setting a port's native network
   to the `servers` network object splits its traffic onto VLAN 20, away from
   the switch's own management and every port still on the default.
5. Set the statics: switch `.2`, AP `.3`. Then remove the transitional pool.

### While working

A factory-default UniFi device beacons for a controller on **UDP 10001** every
few seconds. A switch sending only STP and LLDP, with no DHCP and no beacon, is
not waiting for adoption however default it looks:

```bash
ssh gate 'tcpdump -i lan0 -nn -e ether host <switch-mac>'
```

That answers it in twenty seconds and is worth reaching for before trying
another reset.

**A config change made while the controller cannot reach a device is queued, not
lost.** It applies whenever contact resumes, which may be much later and during
something unrelated. On 2026-09-04 a port profile set while core5 was down
landed minutes afterwards, mid-way through an unrelated gate deploy, and flipped
that port from tagged to untagged between two packet captures. It looked exactly
like the deploy had broken the network. If a change appears not to have applied,
assume it is pending rather than lost, and do not stack another change on top
of it.

Do not reassure yourself that port profiles live in the controller and come back
on adoption. They do, and on 2026-09-04 that was the problem rather than the
consolation: the saved profiles were what kept stranding the switch, and
discarding them via Forget is what finally broke the loop.
