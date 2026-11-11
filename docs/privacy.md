# What leaves the house

Every outbound flow this repo causes, per host and service: where it goes,
what it carries, and what keeps it narrow. What the devices in the house send
on their own is in the resolvers' query logs, under
[the device side](#the-device-side). Plans to narrow more are in Linear's
Privacy project.

## Summary

| Host | Flow | Destination | Narrowed by |
|---|---|---|---|
| every NixOS host | Binary substitution | cache.nixos.org, two Cachix caches | |
| every NixOS host | Flake fetches | GitHub | |
| every NixOS host | Time | NixOS's NTP pool | |
| gate | Recursive DNS | Root, TLD and authoritative servers | QNAME minimisation, a local root zone |
| gate | DDNS | Cloudflare's API | A token for one zone, writes only on change |
| gate | DHCP on `wan` | The ISP | No hostname, no vendor class |
| core4, lifeline | Recursive DNS | Root, TLD and authoritative servers | As gate's, and local names answered locally |
| core4, lifeline | AdGuard fallback DNS | Cloudflare and Quad9, plaintext | Used only on a transport error |
| core4, lifeline | Blocklist downloads | Eight list operators | |
| Pis | Nightly upgrade | GitHub and the caches | |
| Pis | Alerts and heartbeats | ntfy.sh, healthchecks.io | No log lines, a secret topic |
| core5 | All of its DNS | Cloudflare and Quad9, plaintext | |
| core5 | Off-box backups | A private GitHub repo | age-encrypted |
| core5 | Container image pulls | Docker Hub, lscr.io | Pinned by digest |
| core5 | UniFi controller | Ubiquiti | Remote management and analytics off |
| servers | Switch and AP | Ubiquiti | Dropped at gate, NTP aside |
| core5 | Home Assistant weather | api.met.no | |
| core5 | Home Assistant's `default_config` | Home Assistant's servers | |
| guest segment | All of its DNS | Cloudflare and Quad9 | |
| forge | Firefox, Brave | Mozilla, Brave | Telemetry and crash reports off by policy |
| forge | VS Code | Microsoft, the extension marketplace | Telemetry off |
| forge, WSL, Mac | Claude Code | Anthropic | Telemetry and error reports off |
| forge | Night shift | Linear, ntfy.sh, GitHub's API | Pushes carry the identifier, not the title |
| forge | Firmware metadata | LVFS | |
| forge | DNS away from home | Quad9, over TLS | Never plaintext |
| forge | Steam, Plasma | Valve, KDE | |
| GitHub Actions | CI, cache, lock bumps | GitHub, Cachix, registries | Vendor telemetry off |

## Every NixOS host

gate, the three Pis and forge all import `modules/baseline.nix`.

- **Binary substitution.** `nnorx-nix-config.cachix.org`, then
  cache.nixos.org. Each build asks them
  for the store paths it needs, from the house's WAN address. A Pi that
  cannot substitute compiles its kernel for half a day.
- **Flake fetches.** `nrs`, `nrb` and the Pis' upgrade fetch
  `github:nnorx/nix-config` with `--refresh`, so GitHub sees each deploy;
  `flake.lock`'s inputs come from GitHub too.
- **Time.** `services.timesyncd` with NixOS's default pool. Each pool server
  sees the house's address and nothing else.

## gate

**Recursive DNS.** gate resolves only through its own Unbound
(`modules/unbound.nix`), from the root servers with no forwarder. Each cache
miss goes in plaintext to the zone's authoritative servers, with
`qname-minimisation` limiting each to the labels it needs. Recursion means
each zone's operator sees its own names, rather than one resolver seeing all
of them; the ISP can read names on the wire either way.
[network.md](network.md) has why the fleet recurses.

**DDNS.** `hosts/gate/ddns.nix` runs `cloudflare-ddns` every five minutes,
with a token scoped to DNS edit on one zone. It reads the WAN address locally
and writes the A record only when it changes. WireGuard peers dial that name.

**DHCP on `wan`.** dhcpcd sends `hostname ""` and a bare `vendorclassid`
(`hosts/gate/default.nix`), so a request carries neither gate's name nor
dhcpcd's default vendor class, which names the kernel release and so dates
each upgrade. What is left is the MAC, which every request needs, and a
parameter request list, which fingerprints dhcpcd but not the house. No
client ID is sent, so the lease is keyed on the MAC alone.

**The guest segment** gets Cloudflare and Quad9 from DHCP, not the fleet's
resolvers (`publicResolverSegments` in `hosts/gate/routing.nix`). That is
what keeps it isolated.

## core4 and lifeline

Both run AdGuard Home in front of their own Unbound
(`hosts/common/resolver.nix`, `modules/adguardhome.nix`), which recurses as
gate's does.

**AdGuard's fallback.** `fallback_dns` is `net.publicResolvers`, Cloudflare
and Quad9, asked only on a transport error from the local Unbound: a timeout
or a refused connection. A SERVFAIL is an answer and goes back to the client,
and private reverse zones never fall back. A fallback query goes to both
operators at once, in plaintext, with no client subnet.

**Blocklists.** 24 lists from eight operators, each fetched once a day by
each resolver: raw.githubusercontent.com, v.firebog.net, pgl.yoyo.org,
hostfiles.frogeye.fr, phishing.army, urlhaus.abuse.ch, lists.cyberhost.uk and
gitlab.com. AdGuard's own update check is off (`--no-check-update`).

## What the resolvers keep

The resolvers hold the most detailed record in the house: every name each
device looks up. Each setting below is explicit in `modules/adguardhome.nix`
or `modules/unbound.nix`, whose comments give the reasoning, so a change to
one shows up in review.

| What | Kept | Why |
|---|---|---|
| AdGuard's query log | 84-hour rotation: 3.5 days to a week | Debugging a device needs the last few days |
| AdGuard's statistics | One day | The dashboard's counts; the log answers anything older |
| Client addresses | Kept, not anonymised | Anonymising zeroes the segment octet, so the log could not say which device asked, and the work rule would stop matching |
| Unbound's query logging | Off | |
| Unbound's cache dump | Deleted once loaded at start | It holds every name resolved, without clients |
| Safe browsing, parental control | Off | Each sends a hash prefix of every name to AdGuard |

**The work segment is recorded nowhere.** `logQueries = false` in
`lib/net.nix` becomes a persistent AdGuard client on both resolvers, covering
the segment's subnet, with `ignore_querylog` and `ignore_statistics`.
Everything else that sees those queries:

- AdGuard's verbose log is off. The error line it writes when an exchange with
  Unbound fails names the lookup, so the unit drops those lines with
  `LogFilterPatterns=`; the fallback's share of upstream answers counts the
  same failures without names.
- Unbound sees work's queries from 127.0.0.1, and logs nothing about them.
- The metrics store on core5 keeps totals only: Unbound's have neither names
  nor clients, and AdGuard's come from its statistics API, which never counts
  excluded queries. core5's probe is in AdGuard's `ignored` list.
  `tests/dns-metrics.nix` checks it.

### What goes upstream

- **No client subnet**, from Unbound or AdGuard.
- **Names that exist only inside the house are answered locally.** Unbound
  answers `lan`, `local`, `localdomain`, `internal`, `home` and `corp` with
  NXDOMAIN, on core4, lifeline and gate, beside the suffixes it answers by
  default. `scripts/dns-top-domains.jq` counts the same list as local.
- **So are single-label names, from a copy of the root zone** (RFC 8806, an
  `auth-zone` for `.`). A name under no real TLD is answered from the copy.
  The root servers see a SOA query every half hour and a transfer when the
  zone changes, from `rootZoneSources` in `lib/net.nix`. Each load is checked
  against the zone's ZONEMD digest, and a missing digest is refused; with no
  valid copy, Unbound asks the root servers as before.
  `tests/unbound-root-zone.nix` runs it against a stand-in root.

### Telemetry coverage

Two of HaGeZi's native tracker lists cover what operating systems send on
their own vendors' domains: `native.winoffice`, for Windows and Microsoft's
apps, and `native.apple`, for the iPhones and the Mac. Both apply on the work
segment too, which reaches `events.data.microsoft.com`. AdGuard cannot apply a
list to some clients only; a rule in `user_rules`, such as
`@@||events.data.microsoft.com^$client='work'`, unblocks a name for one
segment. HaGeZi's per-vendor TV and Android lists are one line each if a
device needs one. When something breaks, the query log names the list that
blocked it.

## The Pis

**The nightly upgrade** (`hosts/common/pi.nix`) is the flake fetch and
substitution above, on a timer.

**Alerts** (`modules/alerts.nix`). A failed upgrade or backup posts to an
ntfy.sh topic, and each success pings healthchecks.io. What leaves is the
host's name, the unit's name and the word "failed", never log lines. The
topic is random and secret, which is ntfy.sh's only access control. When DNS
is down, the request retries over DoH to Cloudflare or Quad9 by address.

## core5

**All of its DNS** goes to `net.publicResolvers`, plaintext and unfiltered,
so the monitoring collector does not depend on the resolvers it monitors
(`hosts/core5/default.nix`).

**Pings to the public resolvers** (`modules/blackbox.nix`), every 30 seconds,
for `WanDown`.

**Off-box backups** (`modules/offbox-push.nix`). The newest UniFi and Home
Assistant backups, age-encrypted to a key core5 does not hold, pushed to a
private GitHub repo, at most a commit a day per job.

**Container image pulls** (`modules/unifi.nix`). `mongo` from Docker Hub and
`unifi-network-application` from lscr.io, pinned by digest, so pulled only
when a pin moves. The weekly check for newer images runs on GitHub's runners.

**UniFi.** The controller runs with a local admin, and Remote Management and
Analytics are off in its settings ([unifi.md](unifi.md)). It checks Ubiquiti
for device firmware itself.

The switch and the AP do not reach the internet. gate's `servers-egress`
chain (`hosts/gate/routing.nix`) lets out only the hosts `lib/net.nix` gives
an address on `servers`, which are the Pis, and the controller's containers
behind core5's address. Anything else there is dropped out `wan` and counted
in `servers-wan-dropped`, except NTP: the devices take time from a public
pool and need a correct clock to verify firmware downloads. They reach the
controller on `servers` itself, without crossing gate. A firmware upgrade
downloads from Ubiquiti's CDN on the device, so it needs the chain flushed
while it runs ([unifi.md](unifi.md), "Device firmware"). On gate:

```
sudo nft list counter inet nixos-fw servers-wan-dropped   # what is being refused
sudo nft flush chain inet nixos-fw servers-egress         # everything on servers out, until a reload
sudo systemctl reload nftables                            # and back
```

The counter zeroes on every reload. Connections already open when the chain
loads last until they close. IPv4 only; the drop fails closed if the house
gets IPv6. `tests/gate-servers-egress.nix` checks it.

**Home Assistant** (`modules/home-assistant.nix`). Onboarding was local, with
analytics declined, and the Govee lights are driven over their LAN API. `met`
asks api.met.no hourly for the forecast at the home location.
`default_config` loads `homeassistant_alerts`, which fetches Home Assistant's
alert feed, and `cloud`, inert without a sign-in. Companion app
notifications go through Home Assistant's push relay.

## forge

**Firefox** (`hosts/forge/desktop.nix`). Enterprise policies set
`DisableTelemetry`, `DisableFirefoxStudies`, and `DNSOverHTTPS` locked off.
Firefox's automatic DoH would respect AdGuard's canary domain, but it never
checks while any policy is set, so the choice is off or DoH everywhere. Crash
reports have no policy; three locked prefs stop backlogged reports being
sent or offered and untick the crashed-tab page's box
(`browser.crashReports.unsubmittedCheck.autoSubmit2`,
`browser.crashReports.unsubmittedCheck.enabled`,
`browser.tabs.crashReporting.sendReport`). A whole-browser crash still opens
Mozilla's reporter, whose send box it remembers itself.

**Brave** (same file). Managed policy turns off the daily usage ping
(`BraveStatsPingEnabled`), P3A (`BraveP3AEnabled`) and Web Discovery
(`BraveWebDiscoveryEnabled`), and Chromium's `MetricsReportingEnabled`, which
Brave reads as its crash-report switch. Each also locks its setting;
`brave://policy` lists them.

**VS Code** (`hosts/forge/dev.nix`). Microsoft's build, with settings and
extensions from Settings Sync. Telemetry is off in the synced settings,
not the repo: [laptop.md](laptop.md#vs-code-telemetry).

**Claude Code** (`home/claude.nix`), on forge, WSL and the Mac. Prompts and
the files it reads go to Anthropic, which is the tool. `DISABLE_TELEMETRY`
and `DISABLE_ERROR_REPORTING` are set in the user settings, which the night
shift's agents read too. The updater stays on, which is why the switch is not
`CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC`. Telemetry off also stops feature
flags, which turns off: dropping an MCP tool with an invalid schema (every
request then fails with a 400 instead), artifact comments, skills and plugins
synced from the claude.ai account, the advisor tool, `/skill-doctor`,
`claude import`, and messaging sessions on other machines. Auto mode and
Remote Control keep working; if either goes missing after an upgrade, undo
this first. The sandbox's `allowedDomains` limits what commands reach, not
what Claude Code itself sends.

**The night shift** (`hosts/forge/night-shift.nix`). Linear gets issue state
and comments; GitHub's API is asked, without a token, whether each PR has
merged; ntfy.sh gets an issue's identifier, its Linear URL and a few words
("NNO-12: Handoff ready"), never its title, since a title can describe the
house.

**Firmware metadata.** `services.fwupd` refreshes LVFS's metadata on a timer.
Reports upload only when asked.

**Location lookups.** geoclue is off (`hosts/forge/desktop.nix`): Night
Light is in Constant mode and nothing else on forge needs it. Firefox falls
back to its own provider, beacondb, for a site Nick allows at its prompt.

**DNS away from home** (`hosts/forge/dns.nix`). With no tunnel up and away
from home, every lookup goes over strict DNS-over-TLS to Quad9
(`encryptedResolvers` in `lib/net.nix`); where port 853 is refused, lookups
fail rather than fall back. forge knows it is home when DHCP hands it exactly
the fleet's resolvers, and then uses AdGuard. A captive portal needs
`portal-dns` ([laptop.md](laptop.md#dns-away-from-home)). Docker containers
use resolved's upstream list, which away from home is Quad9 on port 53.

Passed over: the split tunnel by default (NetworkManager cannot raise it only
away from home, and at home it sends DNS into a tunnel that never comes up);
opportunistic TLS (silently plaintext on exactly the networks that block
853); DoH (resolved does not speak it, and it gains only those networks); and
recursing on forge (plaintext to authoritative servers).

**Steam and Plasma.** Steam's hardware survey asks first. Plasma's user
feedback is off by default, and DrKonqi sends crash reports only when asked.

**Dev tools** (`home/dev-tools.nix`, `home/common-tools.nix`). npm, pnpm and
cargo reach their registries, `tldr` fetches pages from GitHub, `vulnix` and
`nix run .#cve-scan` fetch NVD's feeds. All on use, none on a timer.

## GitHub Actions

`.github/workflows/` runs on GitHub's runners, so none of it leaves the house.
`check.yml` and `cache.yml` substitute from the hosts' caches, and `cache.yml`
and `cache-vm-tests.yml` push to the public Cachix cache, built from this
public repo with secrets in sops and test stand-ins. Every workflow sets
`OTEL_SDK_DISABLED` and `diagnostic-endpoint: ""` for the DeterminateSystems
actions (top of `check.yml`).

## The device side

What the phones, plugs and laptops send is in the resolvers' query logs.
`nix run .#dns-top-domains` summarises them:

```bash
nix run .#dns-top-domains -- --top 25
```

It reads each resolver's AdGuard query log, read-only, as the admin user
named after the host, prompting for each password. It needs to reach the
AdGuard UI: forge at home or through the tunnel. The output is one Markdown
table per segment. It never prints a client address or device name, counts
reverse lookups and local names under a fixed label, and leaves out the work
segment entirely. `scripts/dns-top-domains.sh` has the options.

Run it in your own terminal, not through an agent: it summarises the house's
browsing. Read it before pasting any of it, and `--exclude` the house's own
domain.

### Results

By segment, at the category level:

- **iot**: devices reaching their vendors' clouds, some of which need that
  to work, and app analytics the blocklists refuse.
- **servers**: the switch and AP contacting their vendor, which gate
  drops, and time servers.
- **vpn**: the tunnel peers, filtered as at home.
- **The resolvers themselves**: time, GitHub, the caches and the alert
  services, as above.
- **trusted** is the household's own browsing and not summarised. Its most
  blocked entries are app and OS analytics and push services.
- **guest** is absent, since it resolves publicly, and **work** by design.

## Internet for iot

iot's way out `wan` passes gate's `iot-egress` chain
(`hosts/gate/routing.nix`), which counts iot's attempts in `iot-wan` and
drops those from addresses in the `iot-trial` set, counted in
`iot-trial-dropped`. The set is declared empty and
filled by hand, so nothing about a device reaches the repo. Per-device
classes are planned in Linear's Privacy project.

### The trial set, by hand

On gate, with a device's current iot address:

```
sudo nft add element inet nixos-fw iot-trial '{ <address> }'      # on trial
sudo conntrack -D -s <address>                                    # and end what it already has open
sudo nft delete element inet nixos-fw iot-trial '{ <address> }'   # off trial
sudo nft list set inet nixos-fw iot-trial                         # who is on it
sudo nft list counters table inet nixos-fw                        # both counters
sudo nft flush chain inet nixos-fw iot-egress                     # all of iot back out, at once
```

- **`conntrack -D` matters.** Established connections are accepted before
  the jump to `iot-egress`, so the set stops only new ones. A device that
  keeps its open cloud connection stays online in its app and barely moves
  the counter. It reports how many entries it deleted; 0 is fine.
- **The counters count attempts**, not flows: each retry of a dropped
  connection, and each packet of a one-way UDP exchange.
- **A member keeps resolving.** Redirected DNS is accepted before the jump.
- **Nothing survives a reload.** A deploy that changes gate's ruleset, `sudo
  systemctl reload nftables`, or a reboot empties the set, zeroes the
  counters and restores a flushed chain. Re-add the address after any gate
  deploy during a trial.

`sudo nft list chain inet nixos-fw forward-allow` shows the jump after the
two `dport 853` rules and before nat's `oifname "wan" accept`.
`tests/gate-iot-egress.nix` runs these commands in VMs.
