# nix-config

Reproducible configuration for a small homelab: a NixOS fleet of three
Raspberry Pis and an x86 router, plus Home Manager for the machines I develop
on. One flake, shared modules, and a single source of truth for network
addressing.

## The fleet

| Host | Hardware | Address | Role |
|---|---|---|---|
| **gate** | CWWK N100, 4x Intel i226 | `.1` in every segment | The router. nftables, NAT, Kea DHCP across five VLANs, and its own recursive Unbound |
| **core4** | Raspberry Pi 4 (8GB) | 192.168.20.32 | AdGuard Home + Unbound, pimon agent |
| **lifeline** | Raspberry Pi 4 | 192.168.20.11 | AdGuard Home + Unbound, pimon agent. An independent second DNS path |
| **core5** | Raspberry Pi 5, NVMe | 192.168.20.49 | UniFi controller, pimon collector, Docker |

```
   internet ── modem ── gate ─┬─ lan1 ── wired machine        (untagged trusted)
                              │
                              └─ lan0 ── Flex switch ─┬─ core4, lifeline, core5
                                  802.1Q trunk        └─ U7 Pro ── tagged SSIDs
                                  untagged = servers
```

Five segments: trusted (10), servers (20), iot (30), guest (40), work (50).
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
flake.nix              Inputs, hosts, installer images, dev shells
lib/net.nix            Network topology: segments, addresses, NICs, ports
.sops.yaml             Which age keys can decrypt which secrets
secrets/               Per-host encrypted secrets

hosts/
  common/              Fleet-wide: locale, users, addressing, deploy aliases
    pi.nix             Pi-only boot and SD-card layout
  core4/ lifeline/     AdGuard + Unbound
  core5/               UniFi controller, pimon collector, NVMe root
  gate/                The router
    routing.nix        VLANs, NAT, firewall policy, Kea

modules/
  adguardhome.nix      Parameterised AGH: upstreams, caching, DNSSEC, blocklists
  unbound.nix          Recursive resolver, DNSSEC, cache persistence
  unifi.nix            Controller as two pinned containers
  pimon.nix            Monitoring agent or collector
  firewall.nix         Default-deny. SSH scoped per interface, never globally
  ssh.nix              Key-only auth, modern crypto
  fail2ban.nix         Brute-force protection
  deploy-guard.nix     Automatic rollback for reboots that go wrong (gate only)
  net-assertions.nix   Consistency checks for lib/net.nix
  baseline.nix         Nix settings, caches, sysctl hardening, gc, journald
  docker.nix           Docker daemon (core5 only)

home/                  Home Manager. common.nix everywhere, default.nix on dev
                       hosts (adds dev-tools, ssh agent, Claude Code)
docs/                  Runbooks, see below
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

If a Pi resolves through itself and cannot reach GitHub, override DNS first:

```bash
sudo bash -c 'echo "nameserver 1.1.1.1" > /etc/resolv.conf'
```

Automatic upgrades are **off** fleet-wide in `modules/baseline.nix`. Unattended
3am reboots are hard to tell apart from a fault while hardware is being moved
around.

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

## CI and the binary cache

| Workflow | Trigger | What it does |
|---|---|---|
| `check.yml` | every push and PR | `nix flake check --all-systems --no-build`, then `nix fmt -- --ci .` |
| `cache.yml` | push to `main` | Builds every Pi's system closure on native aarch64 runners, pushes to Cachix |
| `update-flake.yml` | Mondays 12:00 UTC | Opens a PR bumping `flake.lock` |

**Run `nix fmt` before pushing.** The check gate fails on formatting and says so
nowhere else.

`cache.yml` exists because `linux_rpi4` is in no public cache. Without it a
kernel bump costs each Pi 4 roughly 9 to 15 hours of compiling, separately, with
no shared output between them. The caches are declared twice, in `flake.nix`'s
`nixConfig` and in `modules/baseline.nix`, and both are needed: the flake copy
is client-supplied, so Nix ignores it for anyone outside `trusted-users`, while
the baseline copy is what actually lands in each host's `nix.conf`.

GitHub Actions are pinned to commit SHAs. That token signs into a cache every
host trusts as root, so the blast radius of a compromised action is the whole
fleet. Dependabot closes the staleness side of that trade.

## Dev environment

Three Home Manager profiles:

| Profile | Used by | Contents |
|---|---|---|
| `home/common.nix` | every host, including the Pis and gate | zsh/bash + starship, git, nano, tmux, CLI tools, vulnix |
| `home/default.nix` | WSL (`nick`), macOS (`nicknorcross`) | common, plus Node, Rust, Docker CLI, direnv, keychain ssh-agent, Claude Code |
| `home/darwin.nix` | macOS only | GNU coreutils |

First run on a new machine:

```bash
git clone https://github.com/nnorx/nix-config.git ~/projects/nix-config
cd ~/projects/nix-config
nix run home-manager -- switch --flake .   # picks the config matching your username
exec $SHELL -l
```

After that, `hms` applies changes and `nfu && hms` updates everything first.

Package lists live in `home/common-tools.nix` and `home/dev-tools.nix` rather
than being mirrored here, where they would rot.

## Commands

| Command | Description |
|---|---|
| `nrs` / `nrb` | Rebuild a NixOS host, switch or boot (on the host) |
| `hms` | Apply Home Manager config |
| `nfu` | `nix flake update` |
| `ngc` | Garbage collect, 30+ days |
| `nix flake check --all-systems --no-build` | What CI runs |
| `nix fmt` | Format, also a CI gate |
| `vulnix-scan` / `vulnix-scan-system` | CVE scan the HM closure or the running system |
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
