# nix-config

Reproducible configuration for a small homelab: a NixOS fleet of three
Raspberry Pis and an x86 router, plus Home Manager for the machines I develop
on. One flake, shared modules, and a single source of truth for network
addressing.

## The fleet

| Host | Hardware | Address | Role |
|---|---|---|---|
| **gate** | CWWK N100, 4x Intel i226 | `.1` in every segment | The router. nftables, NAT, Kea DHCP across five VLANs, its own recursive Unbound, and WireGuard for remote access |
| **core4** | Raspberry Pi 4 (8GB) | 192.168.20.32 | AdGuard Home + Unbound, pimon agent, node_exporter, DNS metrics |
| **lifeline** | Raspberry Pi 4 | 192.168.20.11 | AdGuard Home + Unbound, pimon agent, node_exporter, DNS metrics. An independent second DNS path |
| **core5** | Raspberry Pi 5, NVMe | 192.168.20.49 | Home Assistant, UniFi controller, pimon collector, the metrics store and Grafana, Docker |

```
   internet ── modem ── gate ─┬─ lan1 ── wired machine        (untagged trusted)
                              │
                              └─ lan0 ── Flex switch ─┬─ core4, lifeline, core5
                                  802.1Q trunk        └─ U7 Pro ── tagged SSIDs
                                  untagged = servers
```

Alongside the fleet, **forge** is a Framework 16 laptop running NixOS as a
desktop: Plasma, Steam, LUKS and Secure Boot. It is not a server and does not
share `hosts/common`; see [docs/laptop.md](docs/laptop.md).

Six segments: trusted (10), servers (20), iot (30), guest (40), work (50), and
vpn (60) for WireGuard peers, which is not a VLAN.
core4 and lifeline share no state, so either can serve DNS alone. gate resolves
through its own Unbound so it can be rebuilt while both are down.

**[docs/network.md](docs/network.md) is the real description**: segments, port
roles, the switch topology and the invariant that keeps it bootstrappable, how
DNS flows, and what deliberately stays out of this public repo.

Addressing lives in [`lib/net.nix`](lib/net.nix) and reaches every host through
`specialArgs`. Nothing else in the tree hardcodes an address, so renumbering is
a one-file change, and [`modules/net-assertions.nix`](modules/net-assertions.nix)
fails the build if that file stops agreeing with itself.

## Layout

```
flake.nix              Inputs, hosts, installer images
lib/net.nix            Network topology: segments, addresses, NICs, ports
lib/ssh-keys.nix       Admin machines' SSH public keys, one per machine
lib/deploy-keys.nix    Their keys for the Pis' deploy login, one per machine
lib/wireguard-keys.nix WireGuard public keys: gate and each remote peer
lib/claude-sandbox.nix Claude Code's sandbox policy, in user and managed settings
.sops.yaml             Which age keys can decrypt which secrets
secrets/               Per-host encrypted secrets

hosts/
  common/              Fleet-wide: locale, users, addressing, deploy aliases
    pi.nix             Pi-only boot and SD-card layout
    resolver.nix       AdGuard + Unbound, on each host in net.resolvers
  core4/ lifeline/     The resolvers
  core5/               Home Assistant, UniFi, pimon collector, metrics, NVMe root
  gate/                The router
    routing.nix        VLANs, NAT, firewall policy, Kea
    wireguard.nix      Remote peers and what each may reach
    govee.nix          Home Assistant's Govee scan routed into iot
    ddns.nix           Keeps the WAN address in DNS on Cloudflare
  forge/               The laptop: disko layout, Secure Boot, NVIDIA, Plasma,
                       the night shift

modules/
  adguardhome.nix      AGH in front of Unbound: privacy settings, blocklists,
                       its counts for the metrics store
  unbound.nix          Recursive resolver, DNSSEC, cache persistence, exporter
  unifi.nix            Controller as two pinned containers
  unifi-backup.nix     Its state, pushed off-box (core5 only)
  home-assistant.nix   Home Assistant, native, from unstable (core5 only)
  home-assistant-backup.nix  Its state, pushed off-box (core5 only)
  offbox-push.nix      Both pushes: newest backup, age-encrypted, to a private repo
  alerts.nix           Push notifications and heartbeats for the jobs above and upgrades
  pimon.nix            Monitoring agent or collector
  metrics.nix          VictoriaMetrics and Grafana, scraping the fleet (core5 only)
  blackbox.nix         Its probes: each resolver on port 53, and pings out of the house
  dashboards.nix       Its Grafana dashboards, Fleet and DNS, laid out in reading order
  node-exporter.nix    Host metrics and host-status facts, on each scraped host
  firewall.nix         Default-deny. SSH scoped per interface, never globally
  ssh.nix              Key-only auth, modern crypto
  fail2ban.nix         Brute-force protection
  deploy-guard.nix     Automatic rollback for reboots that go wrong (gate only)
  net-assertions.nix   Consistency checks for lib/net.nix
  sops-assertions.nix  Every declared secret is in its host's sops file
  baseline.nix         Nix settings, caches, sysctl hardening, gc, journald
  docker.nix           Docker daemon (core5 only)

home/                  Home Manager. common.nix everywhere, default.nix on dev
                       hosts (adds dev-tools, ssh agent, Claude Code)
pkgs/night-shift/      The night shift's dispatcher, for forge and the Mac
docs/                  Runbooks, see below
scripts/               preflight, the check every change gets; dns-top-domains
.github/workflows/     Evaluation gate, binary cache builds, weekly lock bumps
```

## Runbooks

| | |
|---|---|
| [network.md](docs/network.md) | The network as it is: segments, trunk, DNS, policy |
| [router.md](docs/router.md) | How gate was built, and what is still open |
| [pi-install.md](docs/pi-install.md) | Flashing a Pi, NVMe migration, EEPROM boot order |
| [recovery.md](docs/recovery.md) | deploy-guard, generation rollback, the rescue USB |
| [unifi.md](docs/unifi.md) | Controller, backups, adopting and re-adopting devices |
| [home-assistant.md](docs/home-assistant.md) | First run, phones, adding integrations, upgrades |
| [laptop.md](docs/laptop.md) | Installing forge, enabling Secure Boot, preparing for Windows |
| [observability.md](docs/observability.md) | The metrics and alerting design: store, collection, alerts, access |
| [night-shift.md](docs/night-shift.md) | Agents on forge, and in a sandbox on the work Mac, working issues queued in Linear |
| [fleet-agent.md](docs/fleet-agent.md) | A read-only agent that answers an alert with a diagnosis: the design |
| [privacy.md](docs/privacy.md) | What leaves the house, per host and service, and what could stop |
| [device-identity.md](docs/device-identity.md) | Naming devices in rules without publishing their MACs: the design |
| [ipv6.md](docs/ipv6.md) | IPv6 on gate: probing the ISP, the design, and the PRs in order |
| [power.md](docs/power.md) | A UPS for the rack: what it carries, which host talks to it, the shutdown order, and the PRs in order |
| [keys.md](docs/keys.md) | Every key, token and password hash: what each unlocks, rotating it, the hardware-key plan, rebuilding forge |
| [services.md](docs/services.md) | The house's web UIs by name over TLS, wired from one registry: the design |
| [deploys.md](docs/deploys.md) | Separating deploying from merging: a signed tag per host that the Pis verify, and the PRs in order |

## Deploying

Every host has two aliases, from `hosts/common`:

```bash
nrs    # nixos-rebuild switch --flake github:nnorx/nix-config --accept-flake-config --refresh
nrb    # nixos-rebuild boot, same flags
```

`nixos-rebuild` resolves the flake attribute from the hostname, so one literal
string is correct everywhere. `--refresh` matters: `github:` refs are cached for
an hour, so without it you can silently deploy a stale `main`.

**Use `nrb` plus a reboot, not `nrs`, for anything that reconfigures the
interface you are connected over.** A static address moving, an interface
rename, or gate's routing. `switch` would pull the network out from under the
session mid-activation.

On gate, put risky reboots behind the guard, because there is no fallback
router:

```bash
sudo deploy-guard arm 15
nrb && sudo reboot
sudo deploy-guard confirm    # or it rolls itself back
```

To deploy from a workstation, or to target a host explicitly:

```bash
sudo nixos-rebuild switch --flake github:nnorx/nix-config#core4 --accept-flake-config --refresh
```

To deploy main to the Pis by day rather than waiting for the night, run
`fleet-deploy` from a checkout on an admin machine
([`home/fleet-deploy.sh`](home/fleet-deploy.sh)). It goes through each Pi's
deploy login, one host at a time and lifeline first. Before each host it shows
preflight's brief against what that host runs, and asks to go ahead, wanting the
host's name typed where the brief says `be there`. It waits for `cache.yml` to
push main, starts the nightly upgrade, and offers the reboot that a new kernel
needs. The first host that does not end on main stops the run.

```bash
fleet-deploy                  # every Pi; or name them: fleet-deploy core5
fleet-deploy status           # each Pi's deploy login: revision, staged kernel, hold
```

If a Pi resolves through itself and cannot reach GitHub, override DNS first:

```bash
sudo bash -c 'echo "nameserver 1.1.1.1" > /etc/resolv.conf'
```

**Merging to `main` deploys the Pis that night.** They upgrade automatically
from `github:nnorx/nix-config`, an hour apart and lifeline first, at the times
in `hosts/common/pi.nix`. A change to the kernel, its modules or the initrd
reboots the host, only inside the window in `modules/baseline.nix`; anything
else is switched in place. Upgrades substitute from the cache or fail, and
never compile on the host. gate has no upgrade timer and is always deployed by
hand.

Two consequences follow:

- **A change to addressing or interfaces reaches the Pis unattended**, as a
  `switch`, and possibly before gate has been deployed to match. That is the
  case the `nrb` rule above exists for. Merge it when you will deploy gate the
  same evening, or first hold each Pi's upgrades through its deploy login, and
  release them once gate is deployed:

  ```bash
  fleet-deploy hold             # every Pi, or name them; and `release`
  ```

  A hold lasts until it is released, across deploys and reboots. A held night
  skips the upgrade, so healthchecks.io reports it the next day.
- **A broken `main` is re-applied every night**, including on top of a host
  just recovered by hand. See [recovery.md](docs/recovery.md).

```bash
ssh lifeline 'systemctl list-timers nixos-upgrade; journalctl -u nixos-upgrade -n 30'
```

## SSH access

Each admin machine has its own key, generated on it, and
[`lib/ssh-keys.nix`](lib/ssh-keys.nix) lists the public halves. Every host, the
Pi installers and the recovery ISO trust exactly that list. Today it is WSL and
forge. The work Mac is deliberately not one.

To add a machine, generate its key, with a passphrase, under the name every
machine uses:

```bash
ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519_pis -C nick@<machine>
```

Add the `.pub` line to `lib/ssh-keys.nix` and merge. The Pis pick it up that
night, and gate needs `nrs`. Revoking a machine is deleting its line the same
way.

A machine that deploys the Pis by day also gets a key for their deploy login
(`modules/deploy-agent.nix`), which can start the nightly upgrade, reboot, or
hold the nightly upgrade, and nothing more. Give it the same passphrase, and
name both keys when loading them after a boot, which then asks once:

```bash
ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519_deploy -C nick@<machine>-deploy
ssh-add ~/.ssh/id_ed25519_pis ~/.ssh/id_ed25519_deploy
```

Its `.pub` line goes in `lib/deploy-keys.nix`, and is revoked the same way.

**Images keep the list they were built with.** A rescue USB or SD image made
before a change still trusts the old keys: after revoking one, rebuild and
rewrite it, or the revoked key still opens it.

On the Linux dev hosts, Home Manager generates `~/.ssh/config` with an entry per
fleet host, so `ssh core4` or `ssh gate` uses the right address, user and key.
Other hosts go in `~/.ssh/config.local`, which it includes. Home Manager will
not replace a hand-written `~/.ssh/config`, so on a machine that has one, rename
it to `config.local` before the first switch and delete its fleet entries,
which would otherwise win.

gate has two entries, `gate` at home and `gate-vpn` over WireGuard. The second
checks gate's host key under the home address, so a machine that trusts gate
at home trusts it through the tunnel too. `fleet-status` asks `gate-vpn` on
its own while forge's tunnel is up.

## Remote access

WireGuard terminates on gate, on UDP 443. Peers land on the `vpn` segment, and
every peer gets the fleet's DNS, and `grants` in
[`hosts/gate/wireguard.nix`](hosts/gate/wireguard.nix) is the rest of what each
may reach: forge adds the AdGuard UI, SSH to the fleet and a full-tunnel exit,
and the phone has nothing more. Neither gets the UniFi UI. The design and its
reasoning are
"Inbound remote access" in [docs/router.md](docs/router.md).

Keys follow the SSH model. A peer generates its own key pair and only the
public half goes in [`lib/wireguard-keys.nix`](lib/wireguard-keys.nix). gate's
private key and a pre-shared key per peer are in `secrets/gate.yaml`.

To add a peer:

1. Give it an address in `net.segments.vpn.peers` and an entry in `grants`,
   `[ ]` for DNS only.
2. Generate a pre-shared key into sops, so it is never written out in the
   clear:
   ```bash
   wg genpsk | sed 's/.*/"&"/' | sops set --value-stdin secrets/gate.yaml '["wireguard-psk-<peer>"]'
   ```
   The peer needs the same key. A peer built from this repo reads its own copy
   from its secrets file, as forge does from `wireguard-psk` in
   `secrets/forge.yaml`, so set both from one `wg genpsk` and keep them equal
   when rotating. Any other peer receives it inside its config, like the
   phone's QR code, and needs its MTU set to `vpnMtu` from `lib/net.nix`
   (1280) by hand; see the comment there for why.
3. Generate the peer's key pair on the peer, and add its public key to
   `lib/wireguard-keys.nix`. gate refuses to evaluate with a key that has no
   address or no grants.
4. Merge and deploy gate behind `deploy-guard`, since it changes the firewall.

Revoking a peer is deleting its key line and deploying gate. Nothing expires a
WireGuard key, so that is the only revocation there is.

forge connects with two NetworkManager profiles, split and full tunnel; using
them, and why neither works from inside the house, is "Remote access" in
[docs/laptop.md](docs/laptop.md).

## Secrets

`sops-nix`, with age keys derived from each machine's SSH host key, so there is
no key material to distribute. Secrets are decrypted at activation and never
reach the Nix store in plaintext: `modules/adguardhome.nix`, for instance, puts
a well-formed sentinel hash in the store and splices the real one in at start.

Each host is a recipient only on its own file, so compromising one box does not
expose another's. Every rule also includes the `nick` key, so secrets stay
editable from a dev machine; the private half lives at
`~/.config/sops/age/keys.txt` and is backed up offline.

```bash
sops secrets/core4.yaml      # edit
```

**Re-imaging a host regenerates its host key**, which changes its age recipient
and makes its secrets undecryptable by it. Re-derive, update `.sops.yaml`, and
rekey:

```bash
ssh-keyscan -t ed25519 <host> | cut -d' ' -f2,3 | ssh-to-age
sops updatekeys secrets/<host>.yaml
```

The failure mode if you skip this is an unrelated-looking deploy error much
later, not a clear message at the point of the mistake.

## Alerts

[`modules/alerts.nix`](modules/alerts.nix) covers the jobs that otherwise fail
only into the journal: each Pi's automatic upgrade and core5's off-box
backups. A failure sends a push notification through ntfy.sh, and each success
pings healthchecks.io, which alerts when a job goes a day without one. That
catches a timer that never fired or a host that is off. Both services are
hosted, so they still work when the house is down. Only the host's and unit's
names leave the host.

Each covered host needs two secrets, and evaluation fails without them. sops-nix
would only notice when the system is built, after CI, which only evaluates, had
let the change merge, and the Pis would then stop upgrading with nothing
installed yet to say so. From the repo, in your own terminal, inside `nix
shell nixpkgs#sops nixpkgs#openssl` if either is missing. The first half makes
one random topic for the whole fleet, so the phone needs one subscription, and
prints it: note it before the end clears it. At `read`, paste the
healthchecks.io project's ping key, from its settings page; it does not echo.
The block has no comments, since interactive zsh runs a pasted `#` line as a
command.

```bash
topic=$(openssl rand -hex 16)
for h in core4 lifeline core5; do
  printf '"https://ntfy.sh/%s"' "$topic" | sops set --value-stdin secrets/$h.yaml '["ntfy-url"]'
done
echo "subscribe the ntfy app to: $topic"

read -rs key
for h in core4 lifeline core5; do
  printf '"%s"' "$key" | sops set --value-stdin secrets/$h.yaml '["healthchecks-ping-key"]'
done
unset topic key
```

Checks appear in healthchecks.io on their first ping, named `<host>-<unit>`,
with its default one-day period. Raise each one's grace from the default hour
to 6 hours when it appears, since a ping cannot set it. Healthy gaps run past
25 hours: the timers keep local time, so the night the clocks go back is 25
hours long; the backups add up to 20 minutes of random delay; and an upgrade
pings when it finishes, which a large download onto an SD card can push back
by an hour or more. A night with no success still alerts, about 30 hours after
the last one. Point the project's notifications at the same
ntfy topic so both kinds of alert arrive in one place. To cover another unit,
add it to `fleetAlerts.failure` or `fleetAlerts.heartbeat` in its host.

The metrics have alerts of their own, on core5 (`modules/alerting.nix`, rules
in `modules/alert-rules.nix`): vmalert and Alertmanager, pushing to the same
topic, once per incident. A `Watchdog` alert pings healthchecks.io every 5
minutes as `core5-metrics-watchdog`, so the stack going quiet alerts from
outside. Its check appears at the first ping with the one-day default; set its
period to 15 minutes and its grace to 5 when it appears.

## Metrics

core5 scrapes node_exporter on every host in `metricsTargets` (`lib/net.nix`)
every 30 seconds, into VictoriaMetrics, which keeps 12 months. Grafana is at
core5's address on `ports.grafana`, http://192.168.20.49:3030, reachable from
trusted and servers. Its Fleet dashboard shows whether each host is up and
what it runs. [docs/observability.md](docs/observability.md) has the design,
and the alert rules over it ("Alerts" above).

Each host also exports host-status's two facts: `fleet_revision_info`, whose
`revision` label is the commit it is running, and `fleet_root_device_info`,
whose `device` label is where its root is mounted from. So the store sees a
host on the wrong system. Queries for Grafana's Explore view:

```
up{job="node"}               # 1 per host it can scrape, 0 for one it cannot
fleet_revision_info          # each host's running revision
fleet_root_device_info       # each host's root device
```

gate is scraped at its servers gateway, and answers the router's questions
(`hosts/gate/metrics.nix`):

```
node_network_carrier{instance="gate",device="wan"}     # 1 while the WAN link is up
fleet_wan_addresses                                    # 1 while wan holds a DHCP lease
fleet_wan_lease_remaining_seconds                      # reset by each renewal
fleet_wan_default_routes                               # 1 while the default route is out wan
node_nf_conntrack_entries{instance="gate"} / node_nf_conntrack_entries_limit{instance="gate"}
rate(node_network_receive_bytes_total{instance="gate"}[5m]) * 8   # bits/s in, per interface
rate(node_network_transmit_bytes_total{instance="gate"}[5m]) * 8  # and out
rate(node_network_receive_errs_total{instance="gate"}[5m])        # errors, per interface
kea_dhcp4_addresses_assigned_total{pool=""} / kea_dhcp4_addresses_total{pool=""}   # pool used, per subnet
time() - fleet_wireguard_last_handshake_timestamp_seconds  # seconds since each peer's handshake
```

A handshake timestamp of 0 means the peer has not completed one since `wg0`
last came up, so its age reads as decades.

Grafana's `admin` password is a secret on core5, and evaluation fails without
it. Grafana reads it once, when it creates the account on its first start, so
changing the secret later changes nothing: change it in Grafana's own profile
page, and the secret to match. To set it, from the repo, in your own
terminal, with the password from the password manager at the prompt:

```bash
read -rs pw
printf '%s' "$pw" | jq -R . | sops set --value-stdin secrets/core5.yaml '["grafana-admin-password"]'
unset pw
```

VictoriaMetrics listens on core5's loopback alone. For its own query UI,
`ssh -L 8428:127.0.0.1:8428 core5` and then http://localhost:8428/vmui.

## CI and the binary cache

| Workflow | Trigger | What it does |
|---|---|---|
| `check.yml` | PR, and push to `main` | `nix run .#preflight`, and its brief on what the change touches in the run's summary. Its `nix flake check` runs beside the rest as `flake-check`, on a runner of its own |
| `check.yml`, `build-etc` | PR | Builds each fleet host's `/etc` (the Pis on an aarch64 runner, gate on x86), so a script that fails shellcheck or a ruleset that fails its check turns the PR red instead of `cache.yml` after merge. `/etc` has every service but not the kernel, so it takes minutes |
| `check.yml`, `vm-tests` | PR | Builds, and so runs, every NixOS VM test in the flake's `checks.x86_64-linux`, each on a runner of its own with KVM and reported as its own check, `vm-tests (<name>)`. They cover gate's firewall and DNS rules and its exporters, the resolvers' DNS metrics, and forge's DNS away from home, and `check` only evaluates them, so without this a change that breaks one merges green. A test whose inputs the PR leaves alone is copied from Cachix rather than run |
| `cache.yml` | push to `main` | Builds every Pi's system closure on native aarch64 runners, pushes to Cachix |
| `cache-vm-tests.yml` | push to `main` | Builds every VM test and pushes the results to Cachix, for `vm-tests` to copy. Separate from `cache.yml`, so the tests do not wait behind a kernel compile |
| `update-flake.yml` | Mondays 12:00 UTC | Opens a PR bumping `flake.lock` |
| `image-updates.yml` | Tuesdays 12:00 UTC | Keeps an `images` issue open while a pinned container image is behind its registry |

**Run `nix run .#preflight` before pushing.** It is exactly what the check gate
runs: formatting, `nix flake check`, every host's toplevel and every Home
Manager config evaluated, and a brief on which of them the change touches.
For each host it says whether merging reboots it that night, changes its boot
path, networking or logins, which services restart and which packages move,
and it ends on a verdict: `routine`, `review`, or `be there`, for a change to
merge only when someone can be at home while the Pis upgrade. The verdict is
advice and never fails the check. The rules are in
[`scripts/preflight-brief.jq`](scripts/preflight-brief.jq).

`cache.yml` exists because `linux_rpi4` is in no public cache. Without it a
kernel bump costs each Pi 4 roughly 9 to 15 hours of compiling, separately, with
no shared output between them. It also builds what core5's 16K page size moves
off cache.nixos.org: rustc's jemalloc, and so the Rust toolchain and programs
built with it, in a job of its own. The caches are written once, in `flake.nix`'s
`nixConfig`, and applied in two ways, both needed: as flake settings, which
are client-supplied, so Nix ignores them for anyone outside `trusted-users`, and
through `modules/baseline.nix`, which reads that list and is what actually
lands in each host's `nix.conf`.

GitHub Actions are pinned to commit SHAs. That token signs into a cache every
host trusts as root, so the blast radius of a compromised action is the whole
fleet. Dependabot closes the staleness side of that trade.

## Dev environment

Three Home Manager profiles:

| Profile | Used by | Contents |
|---|---|---|
| `home/common.nix` | every host; on the Pis and gate the only one, embedded in NixOS | zsh/bash + starship, git, nano, tmux, CLI tools, vulnix |
| `home/default.nix` | WSL (`nick`), macOS (`nicknorcross`), and forge through NixOS | common, plus Node, Rust, Docker CLI, direnv, keychain ssh-agent, Claude Code |
| `home/darwin.nix` | macOS only | GNU coreutils, and the night shift's work mode with its sandbox (`home/night-shift.nix`) |
| `home/wsl.nix` | WSL only | What Claude Code's sandbox hides on WSL: interop, Docker Desktop and WSLg sockets |

First run on a new WSL or macOS machine:

```bash
git clone https://github.com/nnorx/nix-config.git ~/projects/nix-config
cd ~/projects/nix-config
nix run home-manager -- switch --flake .   # picks the config matching your username
exec $SHELL -l
```

After that, `hms` applies changes and `nfu && hms` updates everything first.
The NixOS hosts have no standalone config: their Home Manager comes with the
system, so a rebuild applies it.

Package lists live in `home/common-tools.nix` and `home/dev-tools.nix` rather
than being mirrored here, where they would rot.

Per-project toolchains are not here. Each project carries its own `flake.nix`
and an `.envrc` with `use flake`, and direnv with nix-direnv loads it on `cd`,
so a project pins its own versions without touching every machine's profile.
Run `direnv allow` once in a fresh clone.

## Commands

| Command | Description |
|---|---|
| `nrs` / `nrb` | Rebuild a NixOS host, switch or boot (on the host) |
| `hms` | Apply Home Manager config (WSL, macOS); on forge, rebuild the system from the local checkout |
| `nfu` | `nix flake update` |
| `ngc` | Garbage collect, 30+ days |
| `nix run .#preflight` | What CI runs: format, check, evaluate everything, report what changed |
| `nix fmt` | Format alone |
| `pr-handoff` / `pr-handoff merge <N>` | Publish or squash-merge a PR that Claude prepared, after showing what it will send. Answer `d` at its prompt to page through the full diff first, or `g` to open it in GitLens |
| `ph` / `phm <N>` | Short for `pr-handoff` and `pr-handoff merge <N>` |
| `phd` / `phds` | What the current branch changes since it left the default branch, in full or as a file list: what its PR will show |
| `phg [<base>]` | The same change opened in GitLens, in the VS Code window already open, so you can move between files; against `<base>` for a stacked branch |
| `wt [query]` | cd into an agent's worktree, picked with fzf; a query that matches one jumps straight there (dev hosts) |
| `ns`, `nsr`, `nss`, `nsf` | `night-shift`, and its `run`, `status` and `file` (`nsf` on forge only) |
| `nsres <ID> "<answer>"` | Resume a night-shift agent that stopped, with your answer (Mac) |
| `cld-safe` | Claude Code in the night shift's sandbox, for an interactive session on the Mac |
| `claude --bg -w <name> "<task>"` | Start a background agent in its own worktree. `claude agents` lists them (Enter opens one, ← goes back), `claude attach <name>` opens one from the shell, `claude rm <id>` removes one once its PR has merged |
| `agents-status [--offline]` | Each agent branch's handoff, PR and checks, conflicts with main and with each other, and what to merge next |
| `fleet-status [host...]` | Every fleet host's running revision against main, root device, last upgrade and failed units (Linux dev hosts) |
| `vulnix-scan` / `vulnix-scan-system` | CVE scan the HM closure or the running system |
| `nix run .#dns-top-domains` | Top domains per segment from the resolvers' query logs, without client addresses ([privacy.md](docs/privacy.md)) |
| `nix build .#packages.aarch64-linux.<host>-installer` | Pi SD image |
| `nix build .#packages.x86_64-linux.recovery-iso` | Headless x86 rescue ISO |

## Troubleshooting

**WSL: "cannot connect to socket" after installing Nix.** The daemon is not
running. Enable systemd in `/etc/wsl.conf` with `[boot]` / `systemd=true` and
`wsl --shutdown`, or start it by hand:

```bash
sudo /nix/var/nix/profiles/default/bin/nix-daemon &
```

**Command not found after a switch.** `exec $SHELL -l`.

**A host compiles instead of substituting.** It is missing the caches. On a
freshly flashed host `modules/baseline.nix` has not landed yet, so pass
`--accept-flake-config`, which is already in the `nrs`/`nrb` aliases.

---

Inspired by [clvx/nix-files](https://github.com/clvx/nix-files).
