# The NAS

A decision record. Nothing in it is bought or built. It settles what the NAS
is for, what it is built from, how its data is laid out, encrypted and backed
up, where it sits in the network, and what does not run on it, so that the
follow-up pull requests build it rather than re-argue it. This file changes no
host.

## The question

Several records already wait on a NAS that does not exist:

- [power.md](power.md) puts it on the UPS beside core5, sheds it first at 5
  minutes on battery, wakes it by Wake-on-LAN, and leaves its step 9 to this
  project.
- [fleet-agent.md](fleet-agent.md) named it the agent's long-term home.
- [services.md](services.md) expects its services in the registry, Immich
  first, each behind a proxy on the NAS.
- [observability.md](observability.md) expects it to import the drive-health
  module, and to need a check of its own, since its data disks are not its
  root.
- [keys.md](keys.md) and [privacy.md](privacy.md) gain rows for whatever it
  holds and sends.
- NNO-79, parked, would put a binary cache, a CI runner and a git mirror on it
  if this repo ever goes private.

The house's data is under 1 TB today: photos, which move off the photo cloud
to Immich; the cloud drive's files; a music collection; and phone backups.

So the NAS has two jobs: hold that data, with copies that survive losing the
house, and keep forge's backups, which cover what keys.md lists as lost with
forge, most of it work not yet pushed. This record also decides what it is
not for, since "always on, x86, plenty of disk" attracts every other job in
the fleet.

## In short

| | Decision |
|---|---|
| Roles | Data and the services over it: storage, forge's backups, the offsite copies, Immich, and later passive roles such as a git mirror or cache storage |
| Not on it | Nothing model-driven and no pull-request code: no night shift, no fleet agent, no CI runner |
| The fleet agent | A new Raspberry Pi 5 (8 GB), always on, holding no personal data, built like core5 |
| The night shift | Stays on forge, until an agents box: x86, 64 GB, 8 cores or more, its own segment |
| Hardware | An Intel desktop CPU with integrated graphics, a DDR4 board that reuses the owned 16 GB, two new 8 TB-class CMR NAS drives, the owned NVMe. ECC is not required |
| Storage | btrfs raid1 across the two drives, for originals. The NVMe holds the system, Immich's database, thumbnails and transcodes |
| Encryption | LUKS2 on every disk. The NVMe unlocks at boot through Tang on core5 and lifeline, either one sufficing; the array from a key file on the NVMe. A passphrase on each, typed at the console when no Tang server answers |
| Network | servers, a static address in `lib/net.nix`, SSH on its wired interface alone, every UI behind its own Caddy. No port on gate's `wan` |
| Deploys | By hand, as gate is, so Immich's database migrates when Nick has a fresh backup |
| Backups | restic for every copy. forge to the NAS through an append-only rest-server; the NAS to an object store daily, and to two rotated drives by hand |
| Immich | The NixOS module behind the proxy. Machine learning on the CPU, transcoding on the integrated graphics. The phone through the tunnel, by a grant. Photos move only after backups are drilled |
| Alerts | Drive health, array state, scrub, Tang bindings and backup freshness, through the existing rules and fleetAlerts |

## Roles

### What runs on it

**Data, and the services over that data.**

- **Storage**: the photos, the drive's files, the music and the phone
  backups, on a mirror.
- **forge's backups**, into a repository forge can add to and not delete
  from.
- **The offsite copies**, of everything above.
- **Immich**, over the photos.
- **Later, passive roles**: a git mirror, storage behind a binary cache. They
  serve bytes that something else produced, and run nothing those bytes
  contain.

### What does not, and why the line is there

**Nothing model-driven and no pull-request code.** That rules out the night
shift, the fleet agent and a CI runner. Each runs code nobody reviewed first:

| Role | Runs unreviewed | Where it runs |
|---|---|---|
| The night shift | A model's tool calls, in a sandbox, on issues Nick queued | forge, then the agents box |
| The fleet agent | A model's tool calls, after reading text devices chose ([fleet-agent.md](fleet-agent.md), "Untrusted input") | Its own Pi |
| A CI runner | Every branch's build, by construction | The agents box, if NNO-79 is ever built |

Each of those designs has its own containment, and none of them is wrong. The
point is where they run. The NAS holds every irreplaceable file the house
has, and the backup of forge besides, and the cost of a containment failing
is set by what sits beside it. On forge, a sandbox escape reaches forge. On
the NAS it would reach everything, and the offsite credentials too.

The line also keeps the NAS small. With no agents and no flake evaluation,
its memory is Immich's and the filesystem's, which is why the owned 16 GB
suffices (below) and a 64 GB box can wait.

### What the Pis take instead

So the NAS is not asked for what a Pi already does well:

- **The fleet agent fits a Pi.** It needs a Claude Code process, outbound
  HTTPS and SSH to each host, and a few megabytes of state
  ([fleet-agent.md](fleet-agent.md), "Where it runs"). A new Pi 5 takes it
  ("The fleet agent's Pi" below).
- **Tang fits a Pi.** It is a few kilobytes of keys and a socket-activated
  daemon. core5 and lifeline serve it ("Encryption and boot").
- **The UPS server is already a Pi's**, core5's ([power.md](power.md)).
- **Pi kernels are built already.** `cache.yml` builds the Pi 4 kernel and,
  through core5, the Pi 5 kernel from nixos-raspberrypi, so another Pi 5 adds
  no new kernel build.

And what a Pi cannot take: building the x86 hosts. aarch64 cannot build gate,
forge or the NAS, nor run the x86 VM tests, so CI for this repo needs an x86
machine. That is the agents box, not the NAS.

### NNO-79's roles

NNO-79 plans for this repo going private: its binary cache, CI and a git
mirror would leave GitHub's free public tiers. This record places them and
builds none of them.

| Role | Where | Why |
|---|---|---|
| Git mirror | The NAS | Passive. It fetches and serves, and runs nothing it fetches. It would hold `homelab-state` too |
| Cache storage | The NAS | Passive storage behind a cache server. It accepts paths only from the builder's credential, which can add and not delete, as forge's backups are |
| CI runner | The agents box | It builds every branch, which is pull-request code |
| Building what the cache serves | The agents box | The same |

## Hardware

### Requirements

Requirements, not models. Choosing parts is a session with web access, with
Nick, against this table.

| Part | Requirement | Why |
|---|---|---|
| CPU | Intel desktop, 12th to 14th generation, with integrated graphics: not an F model. 6 performance cores preferred over 4. 65 W class or lower | Quick Sync transcodes Immich's video. Immich's machine learning runs on the CPU here ("Machine learning and transcoding"), so cores shorten its first pass. The graphics also drive the console, where the fallback passphrase is typed, with no card |
| CPU firmware | A 13th or 14th-generation part needs a board firmware that carries Intel's 2024 microcode fix for the degradation those generations showed. The parts session checks whether the chosen part is affected | A NAS runs for years at the same voltage curve |
| Board | DDR4, B760 class, four DIMM slots | Reuses the owned 2 x 8 GB of DDR4 desktop memory, with two slots left to reach 32 GB |
| SATA | At least 4 ports | Two for the mirror, two for growing it. The offsite drives go by USB |
| M.2 | At least 2 slots, one NVMe at PCIe 3.0 or better | The owned NVMe, and a second for mirroring the system later |
| NIC | Intel, 2.5 GbE preferred, with Wake-on-LAN from soft-off | gate's i226 already runs on the same driver. power.md wakes the NAS by Wake-on-LAN |
| USB | 10 Gbps ports, at least two | The rotated drives' enclosures |
| Video out | HDMI or DisplayPort from the integrated graphics | The console |
| Case | At least two 3.5" bays with room for two more, and airflow over the drives | The mirror, then growth |
| PSU | 300 to 550 W, efficient at low load: a rating measured at 10% load, such as Cybenetics' | The NAS idles near 30 W, where an oversized supply wastes most. Active PFC, which power.md's pure sine UPS was bought for |
| Idle power | Under 35 W at the wall, both drives spinning, measured by the UPS (power.md, step 4) | It runs all year. power.md planned 35 to 60 W with four drives |

### ECC

**Not required.** It is weighed here because a checksumming filesystem is
only as good as the memory the data passes through before it is checksummed,
and a NAS is where that is usually raised.

- **What ECC would catch**: a bit flipped in memory between an upload
  arriving and btrfs checksumming it. btrfs then stores the flipped bit, with
  a valid checksum, and scrub never sees it.
- **What it costs here**: on Intel's desktop parts, ECC needs a workstation
  chipset board and ECC modules. Neither reuses the owned memory, and new
  memory at 2026-10 costs 3 to 8 times its mid-2025 price.
- **What stands in for it**: a memory test at assembly, before any data
  arrives, which catches a module faulty from the start; memory at its
  JEDEC speed, not an overclocking profile; and copies made at different
  times through different buffers, so a flip while one copy is read leaves the
  others whole. A flip on the way in, before anything has checksummed the
  data, is what remains, and what ECC would remove.

Revisited when memory prices ease, at the next build.

### Drives

**Two new CMR NAS drives, 8 TB class, as a mirror.** NAS-class for 24-hour
duty, vibration tolerance beside each other, and error recovery limited in
time, so a bad sector stalls the mirror for seconds rather than minutes. CMR
because a mirror rewrites in place, during scrubs and rebuilds, which
shingled drives do slowly. 8 TB leaves the house's data, under 1 TB, room
to grow several times over.

**The inherited drives are not the array.** Three 6 TB SMR desktop drives and
one 4 TB CMR desktop drive, of unknown age:

1. Each gets a SMART long test, and its power-on hours, reallocated, pending
   and offline-uncorrectable counts are read.
2. The two healthiest become the **rotated offsite drives**, in USB
   enclosures. A drive with pending or offline-uncorrectable sectors, or
   reallocated sectors that grow during the test, is out. Fewer power-on hours
   break a tie.
3. The rest are overwritten once in full, or erased by their own secure erase,
   and retired.

SMR is fine for the offsite drives: restic writes pack files of a few
megabytes each, in sequence, and rewrites little. The new drives get the same
long test and a full write-and-read pass before the array is made. At 8 TB
that pass takes days.

**The owned NVMe**, about 1 TB, is unverified. Its SMART log is read at
assembly, before it is trusted with the system.

### Firmware settings

Set at the keyboard, at assembly, and recorded in the host's runbook:

- **Restore on AC power loss: power on.** power.md's outlet cycle brings every
  host back this way.
- **ErP or EuP: off**, and **Wake on LAN from S5: on.** ErP cuts the NIC's
  standby power, and with it the Wake-on-LAN that power.md sends after a shed.
- **ASPM and package C-states: on**, for idle power.
- **UEFI only, CSM off. SATA in AHCI mode.** Boot from the NVMe first.
- **Memory at JEDEC speed**, not an overclocking profile.
- **The integrated graphics enabled**, with no monitor attached.

### What it costs

Prices at 2026-10, US listings, given where they carry a decision.

- **Memory decides the platform.** 64 GB of DDR5 SODIMM is about $740 to
  $1,100, and 32 GB of DDR4 desktop memory about $180 to $250. Nick owns 16 GB
  of DDR4 desktop memory, which makes a DDR4 desktop board (about $110 to
  $150) the platform, over a mini PC.
- **Drives are half the build.** 8 TB CMR NAS drives are about $330 to $375
  each, which is why there are two, and why the inherited drives are the
  offsite copies rather than new ones.
- **The NAS comes to about $1,100 to $1,400**: the drives, the board, a CPU
  with integrated graphics at about $130 to $200, a case and a supply.
- **The fleet agent's Pi**, a Pi 5 8 GB at about $180, is about $250 with
  storage and power.
- **An agents box with 64 GB** is about $1,200 to $1,700, most of it memory,
  which is why it waits.

## Storage

### btrfs raid1 or a ZFS mirror

| | btrfs raid1 | ZFS mirror |
|---|---|---|
| Where it lives | In the kernel | An out-of-tree module, built per kernel |
| Kernel at the pin | Any | nixos-26.05 at `6fcc160` ships ZFS 2.4.4, which declares kernels up to 7.2. The default kernel is 6.18.55, and the newest packaged 7.2.9. A kernel newer than ZFS supports waits for ZFS |
| In this fleet | forge's root, since its install | No host. `flake.nix` drops ZFS from the Pi installers and the rescue ISO, which would then be unable to import the array |
| Checksums, scrub, self-heal from the mirror | Yes | Yes |
| Snapshots | Subvolume snapshots, read-only, with btrbk in nixpkgs | Dataset snapshots, with sanoid |
| Send to another disk | `btrfs send`, unencrypted, onto LUKS | `zfs send --raw`, encrypted in transit |
| Memory | The page cache | Its own ARC, sized apart from the page cache |
| Losing one of two disks | The filesystem mounts only with `-o degraded`, by hand | The pool imports degraded on its own |

**btrfs raid1.** The deciding facts are on the first three rows. The NAS
holds the house's data, and a filesystem that a kernel upgrade can leave
unmountable until another package catches up is a dependency this fleet has
avoided everywhere so far. btrfs is what forge already runs, so its tools,
its failure modes and its rescue are known here, and the recovery ISO mounts
it as it is. raid1 with two devices is btrfs's settled profile. Its parity
profiles, raid5 and raid6, are not, and are not used.

ZFS's real advantages are raw encrypted send and degraded import. The first
matters for replicating to a disk or host that should not hold the key. Here
every copy goes through restic, which encrypts on its own, so it is not
needed. The second is weighed under "When a disk fails" below, where mounting
degraded only by hand is the behaviour wanted.

### Layout

**The NVMe**, as forge's disk is laid out (`hosts/forge/disko.nix`): a 1 GB
ESP, then LUKS2, then btrfs with `compress=zstd` and `noatime`.

| Subvolume | Mounted at | Holds | Backed up |
|---|---|---|---|
| `/root` | `/` | The system's state, Immich's PostgreSQL and machine-learning models among it | Its database through Immich's dump, below. The rest is rebuilt from this repo |
| `/nix` | `/nix` | The store | No |
| `/log` | `/var/log` | Journals | No |
| `/derived` | `/var/lib/immich-derived` | Immich's thumbnails and transcoded video | No: Immich regenerates them |

Swap is zram.

**The array**: each new drive gets one GPT partition, then LUKS2, then one
btrfs filesystem across the two LUKS devices, data and metadata both raid1,
with `compress=zstd` and `noatime`. Its subvolumes, each mounted under
`/srv`:

| Subvolume | Holds | Snapshots |
|---|---|---|
| `photos` | Immich's originals, its uploads, profile images and its own database dumps | Yes |
| `drive` | The cloud drive's files | Yes |
| `music` | The music collection | Yes |
| `phones` | Phone backups | Yes |
| `backups` | forge's restic repository, served by rest-server | No: it is append-only already, and restic's packs never change |
| `snapshots` | btrbk's snapshots of the above | |

Immich keeps everything under one media folder. That folder is
`/srv/photos/immich`, on the array, and its `thumbs` and `encoded-video`
folders are bind mounts from `/derived` on the NVMe. Originals stay on the
mirror, and what Immich reads and writes most stays on flash.

### Snapshots and scrub

**Snapshots**: btrbk, from nixpkgs, takes a read-only snapshot of `photos`,
`drive`, `music` and `phones` every night, and keeps 14 daily and 8 weekly.
They are on the same disks, so they are not a backup. They undo a deletion or
an overwrite, by Nick or by an app, for two months. The nightly snapshot is
also what the offsite copy reads ("Backups"), so each copy is one moment of
the data, with Immich's database dump inside it.

**Scrub**: monthly, through NixOS's `services.btrfs.autoScrub`, on a weekday
morning, away from the night's backups. A scrub reads every block on both
disks and checks it against its checksum, repairing a bad copy from the good
one. At under 1 TB used it takes a couple of hours. Its result, and the
filesystem's error counters, reach the metrics ("Observability").

### When a disk fails

btrfs will not mount a raid1 filesystem with a device missing unless told to
with `-o degraded`. The array's mount is `nofail`, so the NAS still boots, and
SSH and the metrics work. The array stays unmounted, every service that uses
it stays stopped (each unit carries `RequiresMountsFor` on its paths, so none
writes into an empty mountpoint on the NVMe), and `ArrayDegraded` fires.

**Mounting degraded is Nick's step, not the boot's.** A mirror running on one
disk is one failure from losing everything on it since the last offsite
copy. Making that a decision means a new disk is ordered before anything is
written to the survivor. The runbook will be: mount degraded, `btrfs replace`
onto the new disk, scrub, remount normally. Until then the data is readable
from the survivor and from the offsite copies.

## Encryption and boot

### LUKS on every disk

- **The NVMe**: LUKS2, unlocked in the initrd, through Tang or the
  passphrase.
- **The array's two drives**: LUKS2 each, unlocked after the root is mounted,
  from a random key file on the NVMe's encrypted root
  (`/var/lib/nas-keys/array.key`, root-only). The key file is generated on the
  NAS when the array is made, and never leaves it, like every key here.
- **A passphrase slot on all three**, the same passphrase, kept in the
  password manager and offline. Whoever can type it at the NVMe's prompt can
  read the key file anyway, so a second passphrase would protect nothing. The
  array's slot is what reads the mirror if the NVMe dies.
- **Header backups** of all three, taken at install with `cryptsetup
  luksHeaderBackup`, kept beside the passphrase. A damaged header with no
  backup is a lost disk.

### Tang

**The NVMe is bound to two Tang servers, on core5 and lifeline, through
clevis, with a threshold of one.** Either answering unlocks the NAS.

Tang holds a key pair; clevis, at bind time, derives the disk's unlock secret
from the server's public key and stores a recovery blob in the LUKS2 header.
At boot, clevis and Tang run an exchange that recovers the secret without
Tang ever seeing it, and without anything on the wire that would let an
observer recover it, which is why Tang serves plain HTTP. The blob alone opens
nothing. It needs a Tang server that holds the matching key to answer.

Read at the pinned nixpkgs, `6fcc160` (clevis 22, tang 15):

- **`boot.initrd.clevisLuksAskpass`**, not `boot.initrd.clevis`. Both unlock
  LUKS with clevis in the initrd. `clevis` decrypts a JWE file built into the
  initrd, once: clevis's tang pin makes one request with a 10-second connect
  timeout, and if that fails, boot falls to the passphrase. The askpass
  module, which requires the systemd initrd, runs upstream's
  `clevis-luks-askpass -l` against bindings in the LUKS header. It answers the
  passphrase request from Tang, retrying every half second until it succeeds,
  while the console prompt stays open beside it. That retry is what the
  boot order below needs.
- **Networking in the initrd**: systemd-networkd with the NAS's static
  address from `lib/net.nix`, and the NIC's driver in the initrd's modules.
  The module warns without it.
- **The binding is made on the NAS**, by hand, after the install:

  ```
  clevis luks bind -d <the NVMe's LUKS partition> sss \
    '{"t":1,"pins":{"tang":[{"url":"http://<core5>:<port>"},{"url":"http://<lifeline>:<port>"}]}}'
  ```

  clevis shows each server's key thumbprint and asks to trust it. Each is
  compared with `tang-show-keys <port>` on that host, which asks its own Tang
  over loopback, and never accepted with `-y`. The binding lives in the LUKS
  header, so neither the blob nor the servers' addresses are in this repo or
  the store.

**Why core5 and lifeline.** Two hosts, so one Pi down for an upgrade, a dead
card or a reinstall does not stop the NAS booting.

- **core5** is on NVMe and is the last host down in a power cut, and it is
  already the NAS's power peer: the UPS server that sheds it and wakes it.
- **lifeline** is the fleet's independent second path, on a different Pi from
  core5, and the least loaded of the three.
- **Not gate.** A Tang listener on gate is a change to the router's firewall,
  behind `deploy-guard`, for a role two Pis cover. power.md and
  observability.md kept daemons that answer the network off gate for the same
  reason.

On each, `services.tang` listens on `ports.tang` (upstream's 7654) on the
host's address and loopback, with `ipAddressAllow` set to the NAS's address
and loopback, and the firewall opens the port on the host's wired interface
from the NAS's address alone, as node_exporter's rule opens to the
collector. Tang's keys are made by tangd on its first start, in its state
directory, and are not backed up: a Tang host that is reinstalled has new
keys, and the NAS's binding to it is renewed with `clevis luks regen`, using
the other server or the passphrase.

### When no Tang server answers

The NAS waits in the initrd. The passphrase prompt is on the console, and
clevis keeps asking both servers every half second, so whichever comes first,
a Tang host returning or Nick typing, unlocks it. There is no SSH in the
initrd: an initrd host key would sit unencrypted on the ESP, and the case it
would serve, both Tang hosts down while Nick is away, can wait for him.

### After a power cut

power.md's boot order, with the NAS in it:

| Case | What happens |
|---|---|
| The NAS alone was shed | core5 sends Wake-on-LAN once mains has held for 10 minutes. core5 and lifeline are up, so the NAS unlocks within seconds of its initrd's network coming up |
| The whole rack went down | The UPS cycles its outlets. gate, the switch and the NAS power on together. The Pis boot a few minutes later, when the switch powers its PoE ports. The NAS's initrd is up first, and clevis retries until core5's or lifeline's Tang answers, then unlocks. No one is needed |
| Mains returns while the Pis are still down | The same: the NAS waits for a Pi |

Tang's URLs are addresses, not names, so unlocking needs neither DNS nor
gate's resolvers, only the servers segment. Renumbering the NAS or a Tang
host means renewing the binding, which network.md's "Renumbering" gains as a
step.

### What it protects

The protection is the NAS apart from both Tang hosts: its disks, or the whole
box, taken out of the house, read as ciphertext without the passphrase. Inside
the house the NAS unlocks itself, by design, so that it needs nobody after a
power cut. Tang's keys are on core5 and lifeline, in the same rack. A third
pin, such as the board's TPM required beside Tang, or a Tang host away from
the rack, would narrow that, and is in "What would reopen this".

## Network

### Place and address

**On servers, with the Pis.** power.md's Wake-on-LAN is a broadcast on the
NAS's segment from core5; Tang, the scrapes and the backups all stay inside
servers with no rule at gate; and trusted already reaches servers in full,
so forge and the phones at home reach the NAS through gate's existing policy.
It takes a free switch port, untagged, as the Pis do ([network.md](network.md),
"Switch topology").

Its address is a static one in `lib/net.nix`, `hosts.<name>` with `ip`,
`iface`, `segment = "servers"` and `sshInterfaces = [ <iface> ]`, decided in
its own pull request. Adding a host with an `ip` on servers changes more than
the NAS: gate's `servers-egress` lets it out to the internet
(`hosts/gate/routing.nix`), gate's tunnel rules let forge's `ssh` grant reach
it, forge's tunnel routes it, and each dev machine's SSH config gains an entry.
So that pull request deploys gate.

### Logins

It imports `hosts/common`, as the Pis and gate do, so it has the fleet's
logins as they stand when it is built: Nick's user, SSH on `sshInterfaces`
alone (`modules/firewall.nix`), fail2ban, and whatever has landed of keys.md's
`diag` login and fleet-agent.md's `triage` login. For `triage`, Immich's
journal arrives as counts, never lines, since it carries file and album names
that phones chose.

Nick reaches the drive's files, the music and the phone backups over SSH,
with SFTP or sshfs, which sshd already serves. A share, SMB, NFS or WebDAV, is
a listener with its own logins, and waits until one is wanted.

### UIs behind the proxy

Each UI joins services.md's registry and sits behind a Caddy on the NAS,
bound to loopback, with 443 opened on the NAS's wired interface: Immich, and
rest-server for forge's backups. Both entries name segments `trusted`. The
registry's `backup` field names an `offboxPush` entry today; the NAS's
copies are restic jobs, so the field widens to accept them in Immich's pull
request. This needs services.md's proxy module, its steps 2 to 6, in place
first.

No port opens on gate's `wan`. The phone and forge reach the NAS from away
through the tunnel, by grants ("The phone", below).

### Deploying it

| | By hand, as gate | Nightly, as the Pis |
|---|---|---|
| When Immich's database migrates | When Nick runs `nrs`, after checking that night's backups | At whatever night a merged `flake.lock` bump moves Immich |
| Rolling back | A generation, with the database restored from the dump taken before the deploy | A generation, with a database that may already have migrated forward: Immich's migrations are one-way |
| Staying current | Needs Nick. `RevisionBehind`'s 7-day reminder, as for gate | Automatic |
| Its closure | Built on the NAS, from cache.nixos.org for nearly all of it, as gate is | `cache.yml` would build and push it, for a substitute-only upgrade: a new x86 job, and Immich's closure in a public cache |

**By hand.** The NAS holds what cannot be rebuilt, and the risky part of
upgrading it is a one-way migration of Immich's database, which a generation
rollback does not undo. Nick deploys after the night's dump and offsite copy
have succeeded, with preflight's brief saying whether Immich or PostgreSQL
moves. Security fixes wait for him, which is acceptable for a host with no
port on `wan`.

When [deploys.md](deploys.md)'s signed deploys are built, the NAS joins them
as gate will: its own `deploy/<name>/` tags, verified before its `nrs`. That
keeps the choice of revision Nick's either way. Nick chose by hand
("Decided").

## Backups

### Three copies, two offsite

| | On the NAS | The object store | A rotated drive |
|---|---|---|---|
| forge's files | forge's restic repository, append-only | Its snapshots, copied | Its snapshots, copied |
| Photos: Immich's originals, uploads and its database dump | The mirror, and its snapshots | Yes | Yes |
| The drive's files, the music, the phone backups | The mirror, and its snapshots | Yes | Yes |
| Immich's thumbnails, transcodes and models | The NVMe | No: regenerated | No |
| The NAS's system | This repo | | |

For the house's data that is three copies, the mirror's and two away from
it. forge's files have four, with forge itself.

**restic for every copy**, so there is one tool, one format and one restore
procedure. It encrypts and authenticates on the client, deduplicates, and
checks its own repositories. nixpkgs at the pin has restic 0.18.1, rest-server
0.14.0, and NixOS modules for both.

### forge to the NAS

**forge backs up into a repository on the NAS served by rest-server in
append-only mode.** forge runs agents, so a credential on forge must not be
able to erase history. Through rest-server in append-only mode, forge's
credential can add snapshots and read its own repository, and cannot delete
or overwrite anything in it.

- **rest-server** on the NAS: `services.restic.server`, with `appendOnly`
  and `privateRepos`, listening on loopback at `ports.resticServer`, behind
  the NAS's Caddy, so forge's login travels over TLS. Its data directory is
  `/srv/backups`. forge's login is `forge`, and `privateRepos` keeps it to
  `/forge/`.
- **forge's client**: `services.restic.backups` as a system service on forge,
  run as root, so its credentials sit in root-only sops files that Nick's
  user, and the agents running as it, cannot read. Hourly while on AC
  (`ConditionACPower`), and quietly failing when the NAS is out of reach.
- **What it takes**: `/home/nick`, less caches and build output (`~/.cache`,
  Steam's library, `node_modules`, `target`, `.direnv`, `result` links), and
  less every credential: the paths `lib/claude-sandbox.nix` lists as
  `keyDirs` and `credentialPaths`, read from that file, so the two lists
  cannot drift. Keys stay on the machine that made them. That includes the
  worktrees, `.git/pr-handoff/`, `.git/night-shift/` and
  `~/.local/state/night-shift/` that keys.md lists as lost with forge.
  forge's system is rebuilt from this repo.
- **Pruning runs on the NAS**, as root, against the repository's path on
  disk, which append-only mode does not govern. Weekly. It needs forge's
  repository password, which the NAS holds in sops for that reason.
- **Away from home**, forge reaches it through the tunnel once it holds a
  grant for the service, which comes with Immich's grant for the phone, in
  one deploy of gate.

### The object store

**The NAS backs up nightly to a restic repository in an object store,
encrypted before it leaves, with the store's own deletion protection on.**

- **What**: the nightly snapshots of `photos`, `drive`, `music` and `phones`,
  read from btrbk's read-only snapshot, and forge's snapshots, with `restic
  copy` from the local repository into this one. A copy rather than the
  repository's files: restoring forge from the store is then one step, and a
  pack damaged on the NAS fails the copy rather than travelling.
- **Deletion protection**: the store keeps every deleted or overwritten
  object as a prior version for 30 days, through versioning with a
  lifecycle rule, or object lock where it offers that. The NAS's credential
  is scoped to the one bucket, and within it may list, read, write and
  delete objects, and nothing else: it cannot delete or overwrite a prior
  version, and cannot change the bucket's versioning, lifecycle, lock or
  access settings. Those belong to the store's account, with Nick. A
  credential stolen from the NAS can then hide data, but not destroy it, for
  30 days, which `BackupStale` and the drills are there to notice inside.
- **Pruning**: monthly, from the NAS, with the same credential. What it
  deletes lingers as prior versions for the 30 days, then ages out.
- **The store**, with no provider named here: one restic supports natively
  (S3-compatible, or one of restic's own backends), with versioning or object
  lock, a credential scopable to one bucket and to object operations alone,
  as above, and its price per terabyte
  stored and per terabyte restored, since a full restore reads it all back.
  Chosen by Nick ("For Nick").

### The rotated drives

**Two LUKS-encrypted drives, from the inherited four, rotated by hand: one
away from the house, one at home and unplugged.** Monthly, Nick plugs in the
one at home. The NAS sees its LUKS label, `offsite-a` or `offsite-b`, unlocks
it with a key file on the NAS (generated on the NAS, never leaving it), runs a
SMART check, backs up to the restic repository on it, checks a subset of the
repository, unmounts and locks it, and pushes that it is done. Nick takes that
drive away and brings the other home.

- **What**: the same as the object store's copy: the nightly snapshot of the
  data, and forge's snapshots copied in.
- **Why LUKS beneath restic**, whose repository is encrypted already: a drive
  outside the house shows nothing, not even that it holds a restic
  repository, and retiring it is wiping one header. Its passphrase slot is
  what restores it on any machine without the NAS.
- **When the newest copy ages**: the NAS records each drive's last success.
  `BackupStale` fires when the newest across both drives is over 35 days old,
  a missed month, and when either drive's own is over 70 days, a drive that
  missed its turn.

### Retention

| Where | Kept | Pruned |
|---|---|---|
| btrbk snapshots on the mirror | 14 daily, 8 weekly | Nightly, by btrbk |
| forge's repository on the NAS | 14 daily, 8 weekly, 24 monthly | Weekly, on the NAS |
| The object store | 14 daily, 8 weekly, 24 monthly | Monthly, from the NAS, and 30 days of prior versions after |
| Each rotated drive | Its last 12 runs, two years at a run every other month | At each run |

### Order of a night

Times are the NAS's. It has no upgrade timer and no reboot window, so nothing
else needs to fit around them.

1. **02:00**: Immich dumps its database into `photos`, with its own backup
   job, in the format its own restore expects. The NAS does not dump it a
   second way, for offbox-push.nix's reason: one path into a database whose
   migrations are one-way.
2. **02:30**: btrbk snapshots the data subvolumes, and the dump with them.
3. **02:45**: restic backs up the snapshot to the object store, then copies
   forge's new snapshots. Before it starts, it checks that the newest dump is
   under 26 hours old, and fails otherwise.

### Restore drills

A copy is trusted once it has been restored from.

| Copy | Monthly, automatic | Drill, by hand |
|---|---|---|
| forge's repository | `restic check --read-data-subset=1/12` on the NAS, so the whole repository is read once a year | Quarterly: restore a directory to a scratch path on forge and compare it with the original |
| The object store | The same check against the store | Twice a year, from forge, not the NAS: restore Immich's newest dump and an album into a scratch Immich, and open it. This proves the copy restores without the NAS and with only what is in the password manager |
| Each rotated drive | A check of a subset at each run | Yearly: unlock it on forge with its passphrase, and restore a directory |

Before any photo moves to Immich, each copy gets its first drill ("Order").

### Passwords and where they live

Each repository has its own password. Every one is in the NAS's sops file
where the NAS uses it, and **in the password manager**, never only on the NAS:
a dead NAS must not take the means of reading its backups with it.

| Secret | Held | For |
|---|---|---|
| `restic-forge-password` | forge's and the NAS's sops files, the password manager | forge's repository: forge writes, the NAS prunes and copies |
| `restic-offsite-password` | The NAS's, the password manager | The object store's repository |
| `restic-drive-password` | The NAS's, the password manager | Both drives' repositories |
| `rest-server-forge-password`, `rest-server-htpasswd` | forge's (the password), the NAS's (its bcrypt line) | forge's login to rest-server, a pair as AdGuard's metrics login is ([observability.md](observability.md), "The metrics login") |
| `offsite-store-credential` | The NAS's | Writing to the one bucket. Remade in the store's account if lost |

### core5's pushes to homelab-state

**Unchanged.** core5 pushes UniFi's and Home Assistant's backups,
age-encrypted, to the private `homelab-state` repository every day
(`modules/offbox-push.nix`). They are small, already off the house, and
restore without the NAS, which matters most when the house is being rebuilt.
Folding them into the NAS's copies would add a dependency and remove none.
The git mirror, when it exists, holds `homelab-state` too, as a third copy.

## Immich

### Module and storage

`services.immich` from nixpkgs, Immich 2.7.5 at the pin. It runs its own
PostgreSQL with the vector extensions it needs and its own Redis, on unix
sockets, both set up by the module. The server binds loopback on
`ports.immich` (upstream's 2283), behind the NAS's Caddy, and its machine
learning listens on loopback at 3003, which the module fixes, so that number
goes in `ports` as `immichMachineLearning`. `mediaLocation` is
`/srv/photos/immich`, with the bind mounts from the NVMe above. Each Immich
unit carries `RequiresMountsFor` on the array.

Settings are declared, `services.immich.settings`, so the UI cannot drift from
the repo, and they include the database backup's schedule and count (14).

### Machine learning and transcoding

- **Transcoding on the integrated graphics.** nixpkgs builds Immich with
  jellyfin-ffmpeg, which drives Intel's Quick Sync through VA-API.
  `accelerationDevices` names the render node, and the module keeps every
  other device from Immich.
- **Machine learning on the CPU.** nixpkgs' onnxruntime builds with CUDA or
  ROCm as options and without OpenVINO, which is what Immich uses for Intel
  graphics. So face detection and search run on the CPU. The first pass over
  the library takes hours, perhaps a day; after that, each upload is seconds.
  An OpenVINO build in nixpkgs would reopen this.

### What it reaches outside the house

| Connection | From | Decision |
|---|---|---|
| Version check, to GitHub | The server | Off. The NixOS module's default, `newVersionCheck.enabled = false`, kept |
| Reverse geocoding data | | None at runtime: nixpkgs bundles the place-name data into the package at build |
| Machine-learning models, from Hugging Face | The server, at first use of each model | Allowed. Downloaded once into `/var/cache/immich` on the NVMe, and again only when a model setting changes |
| Map tiles and style, from Immich's own tile service | The browser and the phone app, when showing a map | Off, in settings. Each tile request says which area is being looked at. Turning it on is one setting and a privacy.md row |
| Sharing links | | No external domain is set, so links resolve only through the house's own names |

privacy.md gains each of the NAS's rows in the pull request that opens the
connection: the object store with the offsite copy, and these, with the CA
and DNS API through services.md's proxy, with Immich.

### The phone

At home, the app reaches `https://immich.<domain>` directly, since trusted
reaches servers. Away, through the tunnel, by an `immich` grant for the
phone in `segments.vpn.grants`, per services.md. The phone's tunnel then
reaches the NAS's 443 and Caddy admits it to Immich alone. The app backs up
the camera roll in the background.

A lost phone with the tunnel up and the app signed in reaches the photos.
Revoking is services.md's two steps: the phone's key at gate, and the app's
session in Immich's account settings.

### Order

1. Backups working and drilled: forge's repository, the object store and both
   drives, each restored from once.
2. Immich running, its own database dump in the nightly copies, and a restore
   of Immich itself from the object store, onto a scratch install, done once.
3. Then the photos move: the photo cloud's export archive imported with
   immich-go, from nixpkgs, and the phone's app switched over. The cloud copy
   is kept until the first full offsite copy of the imported library has been
   drilled.

## Observability

- **Node metrics**: node_exporter from `hosts/common`, and the NAS in
  `metricsTargets`. Its firewall opens 9100 to core5 alone, as every host's
  does.
- **Drive health**: `modules/smartctl.nix`, with the two array drives and the
  NVMe. First the exporter binds the NAS's address, as node_exporter does,
  and its assertion that the collector is its own host relaxes, as
  observability.md said it would. SATA drives report SMART attributes rather
  than an NVMe health log, so one rule is added: **`DriveSectorsFailing`**,
  warning, when a drive's reallocated, pending or offline-uncorrectable count
  has risen above its lowest in the last day. `DriveFailing` already reads
  the SMART verdict for any drive. SATA kernel names can swap between boots;
  every rule reads all of a host's drives, so a swap moves a series, not an
  alert. The rotated drives are checked by their backup run, since they are
  absent most of the time and `DriveUnread` would fire for them.
- **The array**: smartctl_exporter goes on serving a drive's last reading
  after it drops off its bus (observability.md, "What none of this
  watches"), and a dropped data disk takes no root with it. So a root timer,
  `fleet-btrfs`, writes the array's state to node_exporter's textfile
  directory every 5 minutes: whether it is mounted, how many devices it
  expects and has, each device's error counters, and the last scrub's end time
  and result. Rules:
  - **`ArrayDegraded`**, critical, for 5 minutes: a device missing, or the
    array not mounted on a NAS that is up.
  - **`ArrayErrors`**, warning: any device's read, write, flush, corruption
    or generation errors risen above their lowest in the last hour.
  - **`ScrubStale`**, warning: no completed scrub in 40 days.
- **Tang bindings**: a daily unit on the NAS runs `clevis luks report` on the
  NVMe and writes, per server, whether the binding still matches that
  server's keys. **`TangBindingStale`**, warning, when one does not: a Tang
  host was reinstalled, and the NAS now unlocks through the other alone.
- **Backup freshness**: the nightly offsite run, the weekly prune and the
  monthly checks are in `fleetAlerts.failure` and `fleetAlerts.heartbeat`,
  so a failure pushes and a missed run alerts from healthchecks.io, outside
  the house (the weekly and monthly checks have their periods set by hand).
  forge's repository and the drives have no nightly job to heartbeat, so the
  NAS writes the newest snapshot's time per repository and source to its
  textfile directory, and **`BackupStale`**, warning, fires for forge's
  repository at 7 days, and for the drives as above.
- **`HostDown` and the shed**: power.md's `UpsOnBattery` holds `HostDown`
  back for hosts it sheds, while on battery and for 30 minutes after. The NAS
  is woken 10 minutes after mains holds and unlocks within a minute or two,
  inside that. A NAS still down past it is `HostDown`, rightly. A NAS off on
  purpose, for maintenance, is a silence set by hand in Alertmanager.
- **`RevisionBehind`**: its 7-day threshold, which reads the router's name
  today, widens to every host deployed by hand.

The rules come with their cases in `tests/alert-rules.nix`, and the Fleet
dashboard gains the NAS's drives and array in a row.

## Keys and secrets

Each gets a row in keys.md in the pull request that makes it. None of their
values are here.

| Credential | Host | For | Made | Kept |
|---|---|---|---|---|
| The NAS's SSH host key | NAS | Its identity, and its sops age recipient | Generated before install, as forge's was (laptop.md, step 1) | `/etc/ssh` on the NAS |
| The disk passphrase | NAS | Every LUKS device on the NAS, at the console | Chosen at install | The password manager, and offline |
| The array key file | NAS | The array, after the root is up | On the NAS | The NVMe's encrypted root, root-only |
| The rotated drives' key file and passphrase | NAS | Both drives | On the NAS; the passphrase chosen | The key file on the NAS; the passphrase in the password manager |
| Tang's keys | core5, lifeline | Answering the NAS's unlock | By tangd, at first start | Each host's tang state directory. Never copied |
| `restic-forge-password`, `restic-offsite-password`, `restic-drive-password` | forge, NAS | Each repository | Generated | sops, and the password manager |
| `rest-server-forge-password`, `rest-server-htpasswd` | forge, NAS | forge's login to rest-server | Generated, a pair | sops |
| `offsite-store-credential` | NAS | Writing to the bucket | The store's account | The NAS's sops file |
| `user-password-hash`, `ntfy-url`, `healthchecks-ping-key`, `services-domain`, `services-dns-token` | NAS | As on the Pis | As on the Pis | The NAS's sops file |
| The object store account | | The bucket, its protection, its credentials | | The password manager |
| The agent Pi's host key, `anthropic-api-key`, its triage key | The agent's Pi | fleet-agent.md, "Credentials" | | |

## The fleet agent's Pi

**A Raspberry Pi 5 with 8 GB, on servers, always on, holding no personal
data.** It runs fleet-agent.md's poller from milestone 3, and nothing else.

- **Built like core5**: nixos-raspberrypi, whose Pi 5 kernel `cache.yml`
  already builds, with storage and power as core5 has them. So no new
  platform, and no new kernel to compile.
- **A Pi deployed as the Pis are**: `hosts/common` and `hosts/common/pi.nix`,
  an upgrade time of its own in `upgradeTimes`, a job in `cache.yml`, and the
  deploy login. Its tools only read, and what its API key can spend is capped
  by its workspace's limit.
- **On the UPS through the switch's PoE**, as the others, and a client of
  core5's NUT server, halting with stage 2.
- **Its name and address are Nick's** ("For Nick"). It needs a free PoE port
  on the switch.

fleet-agent.md's "Where it runs" and milestone 3 now name it, and say why
not the NAS.

## The agents box, later

**An x86 machine with no personal data, for the night shift and later CI.**
Its own design is for when it is bought. What it must meet:

- **64 GB of memory.** Two night-shift agents at about 12 GB each, and
  preflight's flake check peaking near 12 GB, can run at once, with the
  store's builds beside them.
- **8 cores or more**, for two evaluations at once and the VM tests.
- **x86_64 with hardware virtualisation**, to build gate, forge and the NAS
  and run the VM tests under KVM, which no Pi can.
- **Fast NVMe**, 1 to 2 TB, for its store.
- **Its own place in the network**: a segment of its own, with outbound
  limited at gate to what agents need, GitHub, the caches, the model API and
  Linear, and no reach into trusted or servers beyond what a later design
  grants.
- **No personal data and no publishing credential.** Publishing stays on
  forge, with Nick, as now.

**What triggers buying it**: memory prices easing, since at 2026-10 a 64 GB
box is $1,200 to $1,700, most of it memory; or forge's night shift costing
more than it is worth, in a laptop that must stay awake, on AC and at home,
and in memory taken from Nick's own work.

## The PRs, in order

Each after the one before, except where it says so. The NAS deploys by hand,
so no NAS pull request changes it on merge; Nick runs `nrs` there. A change
to a Pi's firewall rates `be there`, since the Pi applies it that night.
gate's pull requests go behind `deploy-guard`.

1. **`docs/nas: design the home nas, its backups, and where agents run
   instead`.** This file, its row in the README, and fleet-agent.md's
   "Where it runs" and milestone 3. No host changes: `routine`.
2. **Hands-on: buy the parts, assemble, firmware, test the drives**, as "What
   Nick does by hand" lists.
3. **`net: addresses for the nas and the agent's pi`.** Both hosts in
   `lib/net.nix`. gate's servers egress and tunnel SSH rules gain them, so gate
   deploys, behind `deploy-guard`; forge's tunnel routes and the dev machines'
   SSH configs gain them. The brief should show the Pis unchanged.
4. **`pis: tang on core5 and lifeline, for the nas alone`.** `services.tang`
   on both, `ports.tang`, the allowlist and the firewall rule from the NAS's
   address. Firewall on two Pis: `be there`.
5. **`nas: host config, disk layout, luks unlocked through tang`.**
   `hosts/<name>`, its disko layout for the NVMe and the array, the systemd
   initrd with `clevisLuksAskpass` and its network, the array's crypttab and
   mounts, btrbk and scrub, `RevisionBehind` widened to hosts deployed by
   hand, its sops file and recipient, `nixosConfigurations.<name>`. A VM test
   of the unlock: a Tang server answering unlocks, none answering leaves the
   prompt waiting, and a server arriving later still unlocks. No existing host
   changes: `routine`. Then by hand: the install, the array, the binding.
6. **`nas: drive health, array state and tang binding alerts`.** smartctl on
   the NAS's address, `fleet-btrfs`, the Tang check, the NAS in
   `metricsTargets`, and the four rules with their tests. core5 restarts its
   scrape and rules: `routine`. Nick deploys the NAS.
7. **`nas: an append-only backup server`.** rest-server behind the NAS's
   Caddy, its registry entry, pruning and checks, `BackupStale` for forge's
   repository. Needs services.md's steps 2 to 6. The NAS by hand; core5's
   rules: `routine`.
8. **`forge: back up home to the nas`.** forge's restic client. forge rebuilds
   itself. Then the first drill.
9. **`nas: nightly offsite copy to an object store`.** The job, its secrets,
   its fleetAlerts. Then the drill from forge.
10. **`nas: rotated offsite drives`.** The udev rule and the run on plug-in,
    the drives' freshness and its rule. Then each drive's first run and drill.
11. **`nas: immich behind caddy`.** Immich, the storage split, settings, the
    dump in the nightly order, the registry entry, privacy.md's and keys.md's
    rows. Then the restore of Immich from the object store, once.
12. **`gate: immich for the phone, and backups for forge, through the
    tunnel`.** The two grants. Behind `deploy-guard`. Then the photos move.
13. **`nas: shed at 5 minutes on battery, and wake when mains returns`.**
    power.md's step 9, after its steps 3 to 8. Firewall on core5: `be there`.
14. **`<pi>: the fleet agent's pi`.** The host, its `cache.yml` job, its
    upgrade time, pi-install.md's steps for it. Its first deploy is by hand,
    as for any new Pi. Then fleet-agent.md's milestone 3 builds on it.

Steps 4 to 10 can run while Immich waits, and step 14 is independent of
everything after step 3.

## What Nick does by hand

- **Buy the parts**, from the parts session's list against "Requirements".
- **Assemble it**, and run a memory test for a full pass before installing.
- **Set the firmware** as "Firmware settings" lists, and check Wake-on-LAN
  from soft-off works before power.md's step 9.
- **Test every drive**: a SMART long test and the counts on each inherited
  drive, and the long test and a full write-and-read pass on each new one,
  before any data. Read the NVMe's SMART log.
- **Pick the two offsite drives**, put them in enclosures, and wipe and retire
  the others.
- **Install**, the way forge was (laptop.md): the host key and its
  recipient first, the passphrase into a file with no newline, nixos-anywhere
  from forge against the recovery ISO. Then the array on the NAS itself, its
  key file generated there, the header backups, and the clevis binding with
  each thumbprint checked. Then a reboot with core5's Tang stopped and one with
  lifeline's, and one with both, typing the passphrase.
- **Write the secrets**, each from a generator or a prompt that does not echo,
  with the commands each pull request gives. The repository passwords go in
  the password manager as they are made.
- **Make the object store account** and its bucket, versioning or object lock,
  the lifecycle rule, and the scoped credential, checked by trying a
  version delete with it, which must be refused.
- **Measure forge's home**, without the excluded paths, before the first
  backup, to confirm the offsite drives' room.
- **Export the photo cloud's and the cloud drive's archives**, and import
  them, after the drills.
- **Rotate the drives** monthly, and run the drills on their schedule.

## Decided

Nick's answers, on 2026-10-18, each as the record already argues:

- **The NAS deploys by hand**, as gate does ("Deploying it").
- **ECC is not required** ("ECC").
- **Immich's map is off** ("What it reaches outside the house").
- **The drives rotate monthly**, and the object store keeps 30 days of prior
  versions ("The rotated drives", "The object store").
- **fleet-agent.md's milestone 4**, its item and its row in "Ports, grants
  and logins, by milestone", moves off the NAS to the agent's Pi in the
  grants pull request, which edits that row anyway.

## For Nick

1. **Names and addresses.** The NAS's host name, which `mac-nas` in power.md
   follows, and the agent Pi's. Both addresses go in step 3.
2. **Phone backups.** What makes them, and how they reach the NAS. Each way is
   a new listener: an SFTP login, WebDAV, or a sync daemon. The record leaves
   it open.
3. **Two free switch ports.** The NAS needs one, untagged, and the agent's
   Pi a PoE port, within the switch's PoE budget. network.md records ports 5
   to 9 in use. Is there room? And the switch's port speed, which says
   whether a 2.5 GbE NIC on the NAS earns anything now.
4. **The object store's provider**, against "The object store"'s
   requirements.

## What would reopen this

- **The data passing half the mirror**, or half the smaller offsite drive:
  bigger drives, or more of them.
- **An OpenVINO build of onnxruntime in nixpkgs**, which moves Immich's
  machine learning onto the integrated graphics.
- **A share or a sync**, for forge's files or anyone else's: listeners and
  logins on the NAS, and a design of their own.
- **Someone besides Nick using Immich**: accounts, sharing beyond the house,
  and services.md's single sign-on question.
- **The repo going private (NNO-79)**: the git mirror and cache storage
  arrive here, and the builder and CI runner on the agents box.
- **The agents box bought**: the night shift moves, and this record's
  requirements become its design.
- **Narrowing what unlocks the NAS**: a TPM pin required beside Tang, a Tang
  host away from the rack, or Secure Boot over the initrd.
- **btrfs raid1 misbehaving**, or a need to replicate to a place that must not
  hold the key, which is ZFS's raw send.
- **Memory prices easing**, for ECC at the next build.
