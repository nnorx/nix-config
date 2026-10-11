# What leaves the house

Every outbound flow this repo causes, per host and service: where it goes,
what it carries, why it exists, and whether it could be narrowed or turned
off. It is the evidence the Privacy project's issues start from. The repo
side was read from `main` at 6e1014b, on 2026-10-10, and each claim below
names the file it comes from. Defaults the repo does not set were read from
the pinned nixpkgs rather than assumed.

What the repo cannot show is what the devices in the house talk to. That is
[the device side](#the-device-side), from the resolvers' query logs.

Each flow is marked with one of three verdicts:

- **needed**: the flow is the point of the service, or the cost of something
  the fleet depends on. Nothing to file.
- **narrow**: it could carry less or go to fewer places. A follow-up is
  suggested.
- **off**: it could be turned off without losing anything wanted. A
  follow-up is suggested.

The follow-ups are collected, as issue titles, at the end.

## Summary

| Host | Flow | Destination | Verdict |
|---|---|---|---|
| every NixOS host | Binary substitution | cache.nixos.org, two Cachix caches | needed |
| every NixOS host | Flake fetches | GitHub | needed |
| every NixOS host | Time | NixOS's NTP pool | needed |
| gate | Recursive DNS | Root, TLD and authoritative servers | needed |
| gate | DDNS | Cloudflare's API | needed |
| gate | DHCP on `wan` | The ISP | narrow (F12) |
| core4, lifeline | Recursive DNS | Root, TLD and authoritative servers | needed |
| core4, lifeline | AdGuard fallback DNS | Cloudflare and Quad9, plaintext | narrow (F6) |
| core4, lifeline | Blocklist downloads | Eight list operators | narrow (F7) |
| Pis | Nightly upgrade | GitHub and the caches | needed |
| Pis | Alerts and heartbeats | ntfy.sh, healthchecks.io | needed |
| core5 | All of its DNS | Cloudflare and Quad9, plaintext | narrow (F5) |
| core5 | Off-box backups | A private GitHub repo, age-encrypted | needed |
| core5 | Container image pulls | Docker Hub, lscr.io | needed |
| core5 | UniFi controller and devices | Ubiquiti | narrow (F10) |
| core5 | Home Assistant weather | api.met.no | narrow (F8) |
| core5 | Home Assistant's other defaults | Home Assistant's servers | off (F9) |
| guest segment | All of its DNS | Cloudflare and Quad9 | needed |
| forge | Firefox | Mozilla, and its DoH resolver | off (F1) |
| forge | Brave | Brave | off (F2) |
| forge | VS Code | Microsoft, the extension marketplace | off (F4) |
| forge, WSL, Mac | Claude Code | Anthropic | off (F3) for telemetry |
| forge | Night shift | Linear, ntfy.sh, GitHub's API | narrow (F14) |
| forge | Firmware metadata | LVFS | needed |
| forge | Location lookups | beacondb | off (F13) |
| forge | DNS away from home | Whatever network it is on | narrow (F11) |
| forge | Steam, Plasma | Valve, KDE | needed |
| GitHub Actions | CI, cache, lock bumps | GitHub, Cachix, registries | needed |

## Every NixOS host

gate, the three Pis and forge all import `modules/baseline.nix`.

**Binary substitution.** `nix.settings.substituters` is
`nixos-raspberrypi.cachix.org`, `nnorx-nix-config.cachix.org`, and
cache.nixos.org, which NixOS adds after them. Each build or upgrade asks the
caches for the store paths it needs, which tells them what the host is
installing, and downloads what they have. The source address is the house's
WAN address. **needed**: a Pi that cannot substitute compiles its kernel for
half a day (README, "CI and the binary cache").

**Flake fetches.** `nrs`, `nrb` and the Pis' upgrade fetch
`github:nnorx/nix-config` with `--refresh`, so GitHub sees each deploy. Inputs
in `flake.lock` come from GitHub too, and `nix run nixpkgs#...` reads the flake
registry from channels.nixos.org. **needed**.

**Time.** `services.timesyncd` with NixOS's default servers,
`0-3.nixos.pool.ntp.org`, which nothing in the repo overrides. NTP carries no
payload beyond timestamps; each pool server sees the house's address.
**needed**. gate could serve time to the Pis, which would turn three hosts'
NTP traffic into one, but the pool learns nothing from three that it does not
learn from one.

## gate

**Recursive DNS.** gate resolves only through its own Unbound
(`hosts/gate/default.nix`, `modules/unbound.nix`), which recurses from the
root servers with no forwarder. Every cache miss goes, in plaintext, to the
authoritative servers for that name, with `qname-minimisation` limiting each
server to the labels it needs. `unbound-anchor` keeps the DNSSEC root key
current over DNS, and reaches data.iana.org over HTTPS only if the stored key
is unusable. **needed**: it is what lets gate be rebuilt with both Pis down
(docs/network.md, "DNS").

Recursion trades one resolver operator's view of everything for each zone's
operator seeing its own names, and the ISP can read the names on the wire
either way. Forwarding to an encrypted resolver would hide them from the ISP
and give them all to that resolver. That is a decision rather than a
follow-up, and docs/network.md records why the fleet recurses.

**DDNS.** `hosts/gate/ddns.nix` runs `cloudflare-ddns` every five minutes
against Cloudflare's API, with a token scoped to DNS edit on one zone. It
reads the WAN address locally rather than asking a third party, and writes
the A record only when it changes. Cloudflare sees the token, the hostname and
the address, which is what an A record is. **needed**: WireGuard peers dial
that name.

**DHCP on `wan`.** gate takes its address from the ISP with dhcpcd, whose
NixOS-generated config starts with `hostname`, so each request tells the ISP
gate's hostname. The MAC address is in every request regardless. **narrow**
(F12), and low value: the name is `gate`.

**The guest segment** gets Cloudflare and Quad9 from DHCP rather than the
fleet's resolvers (`publicResolverSegments` in `hosts/gate/routing.nix`), so
visitors' lookups go there, from the house's address. **needed**: that is what
keeps guest isolated.

## core4 and lifeline

Both run AdGuard Home in front of their own Unbound (`hosts/core4`,
`hosts/lifeline`, `modules/adguardhome.nix`).

**Recursive DNS.** As on gate, for every name the house looks up that neither
AdGuard nor Unbound has cached. **needed**.

**AdGuard's fallback.** `fallback_dns` is `net.publicResolvers`, Cloudflare and
Quad9, used only when the local Unbound does not answer within
`upstreamTimeout`. Those queries are plaintext, carry the client's query name,
and go from the house's address. `bootstrap_dns` names the same two, but only
resolves DoH or DoT upstream names, and there are none. **narrow** (F6): the
fallback could use DNS-over-TLS to the same two operators, addressed by IP,
which needs no bootstrap and hides the names from the path.

**Blocklist downloads.** 23 lists, refreshed by each resolver at AdGuard's
default interval of 24 hours, from eight operators:
raw.githubusercontent.com, v.firebog.net, pgl.yoyo.org,
hostfiles.frogeye.fr, phishing.army, urlhaus.abuse.ch, lists.cyberhost.uk and
gitlab.com. Each sees two fetches a day from the house's address and
AdGuard's user agent. AdGuard's own update check is off: the NixOS module
passes `--no-check-update`. Parental control is off in the repo, and safe
browsing, AdGuard's other lookup service, is left at its default, off.
**narrow** (F7): nine lists come from v.firebog.net and eight from GitHub,
and the other six each bring an operator of their own for a single list.
Whether those six add coverage the rest lack is the question.

## The Pis

**The nightly upgrade** (`hosts/common/pi.nix`, `modules/baseline.nix`) is the
flake fetch and substitution above, at fixed times: 03:00, 04:00 and 05:00.
Anyone watching GitHub's or the caches' logs can tell an automated fleet from
the pattern, which says nothing they could use. **needed**.

**Alerts** (`modules/alerts.nix`). A failed upgrade or backup posts to an
ntfy.sh topic, and each success pings healthchecks.io. What leaves is the
host's name, the unit's name and the word "failed": no log lines. The ntfy
topic is random and secret, which is ntfy.sh's only access control, and
healthchecks.io sees each job's timing. If DNS is down, the request is retried
over DoH to Cloudflare or Quad9 by address, which tells them the two service
names. **needed**: both are outside the house on purpose, so they can report
the house being down.

## core5

**All of its DNS.** `networking.nameservers = net.publicResolvers`, so every
name core5 resolves, for Home Assistant's integrations, image pulls, upgrades
and backups, goes in plaintext to Cloudflare or Quad9, unfiltered. The reason
(`hosts/core5/default.nix`) is that the monitoring collector should not
depend on the resolvers it monitors. **narrow** (F5): core5 already depends on
gate for every packet it sends, so resolving through gate's Unbound would add
no dependency and send nothing to a third party. That needs
`modules/unbound.nix` to bind an address on gate, which has no `ip` in
`lib/net.nix`.

**Off-box backups** (`modules/offbox-push.nix`). The newest UniFi and Home
Assistant backups, age-encrypted to a key core5 does not hold, pushed over SSH
to a private GitHub repo. GitHub holds ciphertext, its size and a dated commit
a day at most per job, authored as `core5`. **needed**: the point is a copy
outside the house.

**Container image pulls** (`modules/unifi.nix`). `mongo` from Docker Hub and
`unifi-network-application` from lscr.io, pinned by digest, so pulled only
when a pin moves or the local copy is gone. **needed**. The weekly check for
newer images (`image-updates.yml`) runs on GitHub's runners, not here.

**UniFi** (`modules/unifi.nix`, docs/unifi.md). The controller runs with a
local admin, and docs/unifi.md has Remote Management and Analytics turned off
in its settings, which live in its database rather than this repo. The
controller still checks Ubiquiti for device firmware, and the switch and AP,
on `servers`, can reach the internet like any host there; what their firmware
sends is not visible from here. **narrow** (F10): confirm the two settings are
still off, and decide whether gate should deny the switch and AP the
internet, which turns on how they get firmware.

**Home Assistant** (`modules/home-assistant.nix`, docs/home-assistant.md).
Onboarding was local, with analytics declined, and the Govee lights are driven
over their LAN API with no cloud in the path. What remains:

- `met`, in `extraComponents`, is the weather integration onboarding sets up
  for the home location. Every hour it asks api.met.no for a forecast at the
  home's coordinates, unrounded. **narrow** (F8): the integration can take a
  location of its own instead of tracking home, and one rounded to a few
  kilometres gives the same weather.
- `default_config` brings in integrations that reach Home Assistant's own
  servers: `homeassistant_alerts` fetches its alert feed, and `cloud` is
  loaded but inert without a sign-in. The Companion app's notifications, if
  any are sent, go through Home Assistant's push relay. **off** (F9), low
  value: listing `default_config`'s parts explicitly would drop the first
  two.

## forge

forge is a desktop and carries the most flows, most of them from software the
repo installs but does not configure.

**Firefox** (`programs.firefox.enable` in `hosts/forge/desktop.nix`). The only
policy set is NixOS's own `DisableAppUpdate`. The nixpkgs build is an official
one (`MOZILLA_OFFICIAL=1`) with the crash reporter built in, so telemetry and
studies are on, and crash reports are offered, unless turned off. Firefox
may also enable DNS-over-HTTPS to its default provider, which takes its
lookups away from AdGuard altogether. **off** (F1): enterprise policies
(`DisableTelemetry`, `DisableFirefoxStudies`, crash reports, and an explicit
`DNSOverHTTPS` decision) make all of that declarative.

**Brave** (`unstable.brave`, same file). No policy is set, so Brave's defaults
apply, including its daily usage ping and its P3A product analytics, which
Brave describes as private but which leave the house all the same. **off**
(F2): Brave reads managed policies from `/etc/brave/policies/managed`, which
NixOS can write.

**VS Code** (`unstable.vscode`, `hosts/forge/dev.nix`). Microsoft's build, with
settings and extensions from Settings Sync, so nothing about telemetry is
visible in the repo. Its default is full telemetry. Settings Sync itself sends
the settings to the account it signs in to, and extensions come from the
marketplace. **off** (F4) for telemetry; the rest is needed.

**Claude Code** (`home/claude.nix`, `hosts/forge/claude.nix`), on forge, WSL
and the Mac. Prompts and the files it reads go to Anthropic, which is the
tool. Beyond that it sends usage telemetry and error reports by default, and
the repo sets neither `DISABLE_TELEMETRY` nor `DISABLE_ERROR_REPORTING`. It is
installed by its own installer and updates itself, which should stay on.
The sandbox's `allowedDomains` limits what commands reach, not what Claude
Code itself sends. **off** (F3), for the telemetry and error reports.

**The night shift** (`hosts/forge/night-shift.nix`, `night-shift.sh`). Linear
receives issue state and comments, which is its job. GitHub's API is asked,
without a token, whether each branch's PR has merged. ntfy.sh, on the fleet's
topic, receives each issue's title and Linear URL when it is ready or needs
Nick. **narrow** (F14): a title can describe the house; the identifier and
URL alone are enough to find the issue.

**Firmware metadata.** `services.fwupd` is on (`hosts/forge/default.nix`), and
NixOS enables its refresh timer, which downloads LVFS's metadata. Reports are
uploaded only when asked. Discover is installed alongside, because fwupd is,
and shows the same updates. **needed**.

**Location lookups.** Plasma turns on geoclue, which NixOS points at beacondb
(`api.beacondb.net`) with submission off. When an application asks for the
location, such as Firefox for a site that requests it, geoclue sends the Wi-Fi
networks in range and gets coordinates back. **off** (F13), if nothing on
forge needs it; the issue should first check what in Plasma asks.

**DNS away from home.** With neither tunnel profile up, forge uses whatever
resolver the local network hands out, in plaintext: every lookup, the tunnel
endpoint's hostname among them, which ties the laptop to the house's address
for anyone logging that network's DNS. **narrow** (F11): an encrypted
resolver when forge is not at home, or the split tunnel up by default.

**Steam and Plasma.** Steam talks to Valve, which is what it is for; its
hardware survey asks first. Plasma's user feedback is off unless enabled in
System Settings, which is KDE's default, and DrKonqi sends crash reports only
when asked to. **needed**.

**Dev tools** (`home/dev-tools.nix`, `home/common-tools.nix`), on every dev
machine: npm, pnpm and cargo reach their registries when used, npm and pnpm
also check them for their own updates, `tldr` downloads its pages from
GitHub, and `vulnix` downloads the NVD feed. All on use, none on a timer.
**needed**.

## GitHub Actions

`.github/workflows/` runs on GitHub's runners, so none of it leaves the house:
it is listed because the repo causes it. `check.yml` and `cache.yml` fetch
inputs and substitute from the same caches as the hosts, and `cache.yml`
pushes the Pis' closures to the public Cachix cache, built from this public
repo with secrets kept in sops. `update-flake.yml` opens lock bumps,
`image-updates.yml` reads registry manifests, and Dependabot watches the
pinned actions. The DeterminateSystems actions would export OpenTelemetry
traces and an installer diagnostic report to their vendor by default; every
workflow sets `OTEL_SDK_DISABLED` and `diagnostic-endpoint: ""`, with the
reasoning at the top of `check.yml`. **needed**, and already narrowed.

## The device side

The repo shows what the fleet sends. What the phones, TVs, plugs and
laptops send is in the resolvers' query logs, which no file here can show.
`nix run .#dns-top-domains` summarises them:

```bash
nix run .#dns-top-domains -- --top 25
```

It asks each resolver's AdGuard API for its query log, read-only, as the admin
user named after the host, and prompts for each password without echo. It
needs a machine that can reach the AdGuard UI: forge at home, or through the
tunnel. The output is Markdown, one table per segment of the domains looked up
most, with counts and how many were blocked. It never prints a client address
or device name, reverse lookups and local names are counted under a fixed
label, and the work segment, which `lib/net.nix` marks `logQueries = false`,
is left out entirely, not even counted. `scripts/dns-top-domains.sh` has the
details and the other options.

Run it in your own terminal rather than through an agent: the domains are a
summary of the house's browsing. Read the output before pasting any of it
here, and pass `--exclude <domain>` for anything that should not be named,
the house's own domain first.

### Results

Run on 2026-10-10 over about 200,000 queries per resolver: four days on
core4 and six weeks on lifeline, which answers far less of the house's
traffic.

- **iot.** Devices reaching their vendors' clouds, some of which need that
  to work, and app analytics the blocklists already refuse. A personal
  device was on this segment for a few days, and its lookups are in these
  counts. Follow-up: NNO-27 decides which devices need the internet at all.
- **servers.** The switch and AP contact their vendor. Apart from that,
  the segment reaches only time servers. This confirms F10.
- **vpn.** The tunnel peers, filtered as at home. Nothing new.
- **The resolvers themselves.** Time, GitHub, the binary caches and the
  two alert services, as the inventory above lists, plus one-off manual
  tests.
- **No segment.** Lookups from before the 2026-09-05 cutover, when every
  client was on the flat network. lifeline still holds them under
  AdGuard's default retention. Follow-up: NNO-26, for the retention and to
  clear that history once.
- **trusted.** Not summarised here, since it is the household's own
  browsing. Its most-blocked entries are app and OS analytics and push
  services, which is the blocklists working. Devices also ask for a few
  thousand names that exist only inside the house; whether those reach
  the root servers is for NNO-26 to check.
- **guest** is absent, as it should be: it resolves through public
  resolvers.
- **work** is absent by design.

## Suggested follow-ups

Each is one issue, titled the way a PR for it would be.

| | Issue | Verdict |
|---|---|---|
| F1 | `forge: firefox policies for telemetry, studies, crash reports and DoH` | off |
| F2 | `forge: brave policies for its usage ping, P3A and web discovery` | off |
| F3 | `home: turn off claude code's telemetry and error reports` | off |
| F4 | `docs/laptop.md: vs code telemetry off, and how settings sync carries it` | off |
| F5 | `core5: resolve through gate's unbound rather than public resolvers` | narrow |
| F6 | `adguardhome: send the fallback over DNS-over-TLS` | narrow |
| F7 | `adguardhome: fewer blocklist operators for the same coverage` | narrow |
| F8 | `docs/home-assistant.md: give met.no a coarse location` | narrow |
| F9 | `home-assistant: list default_config's integrations, without cloud and alerts` | off |
| F10 | `gate: keep the switch and AP off the internet` | narrow |
| F11 | `forge: encrypted DNS away from home` | narrow |
| F12 | `gate: stop sending its hostname in DHCP requests on wan` | narrow |
| F13 | `forge: turn geoclue off` | off |
| F14 | `forge: night-shift pushes carry the identifier, not the title` | narrow |

F10 changes gate's firewall, so it goes behind deploy-guard. F5 changes gate
and core5 together, and F6 the resolvers, which take it that night. The rest
are forge, docs, or one service on core5.
