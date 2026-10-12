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
`upstreamTimeout`. dnsproxy, AdGuard's resolver library, takes the fallback
path only on a transport error: a timeout or a refused connection. A SERVFAIL
from Unbound is an answer and goes back to the client, and lookups for
private reverse zones never fall back. When it does fall back it asks both
operators at once, so each sees the query. Those queries are plaintext, carry
the client's query name, and go from the house's address, with no client
subnet: AdGuard adds none (`edns_client_subnet` is off in the module), and
only a client that put one in its own query would pass one through.
`bootstrap_dns` names the same two, but only resolves DoH or DoT upstream
names, and there are none. **narrow** (F6): the fallback could use
DNS-over-TLS to the same two operators, addressed by IP, which needs no
bootstrap and hides the names from the path.

**Blocklist downloads.** 24 lists, refreshed by each resolver at AdGuard's
default interval of 24 hours, from eight operators:
raw.githubusercontent.com, v.firebog.net, pgl.yoyo.org,
hostfiles.frogeye.fr, phishing.army, urlhaus.abuse.ch, lists.cyberhost.uk and
gitlab.com. Each sees two fetches a day from the house's address and
AdGuard's user agent. AdGuard's own update check is off: the NixOS module
passes `--no-check-update`. Parental control and safe browsing, AdGuard's
two lookup services, are both off in the module.
**narrow** (F7): nine lists come from v.firebog.net and nine from GitHub,
and the other six each bring an operator of their own for a single list.
Whether those six add coverage the rest lack is the question.

## What the resolvers keep

The resolvers hold the most detailed record in the house: every name each
device looks up. What they keep, and what they still tell the outside, was
reviewed in NNO-26 against AdGuard Home 0.107.79 and Unbound 1.26.0, the
versions pinned on 2026-10-11. Each default below was read from that
version's source, not its documentation, and each setting is now explicit in
`modules/adguardhome.nix` or `modules/unbound.nix`, with comments, so a
change to any of them shows up in review.

**The query log keeps between three and a half days and a week.** AdGuard's
default is 90 days, and the module set nothing. The log is for debugging a
device: what it asked for and what was refused when it misbehaved. That needs
the last few days, not the last season. AdGuard's `interval` is a rotation
period, not an age limit: once the oldest entry in the log passes it, the
file is renamed aside and the previous one deleted, so entries live between
one and two intervals. The default therefore kept up to 180 days. The module
sets 84 hours: at least three and a half days, which covers a fault noticed
after a weekend, and never more than a week. `nix run .#dns-top-domains`
then summarises a week at most, which is still a representative sample.

**Statistics keep one day**, AdGuard's default, now written down. They are
the per-client and per-domain counts behind the dashboard, kept in hourly
buckets and dropped at a true age limit. A day shows which device is busy;
the log answers anything older.

**Client addresses are kept, not anonymised.** AdGuard can anonymise client
addresses (`anonymize_client_ip`), and the module keeps that off. Turned on,
it zeroes the last two octets of each IPv4 client. The third octet is the
segment here, so every device in the house would be logged under one
address, and the log could no longer say which device asked, or even which
segment. That is the whole of what per-device debugging needs, and what
checking gate's `dns-redirect` relies on: a device with a hardcoded resolver
is caught by seeing its own address in the log. Worse, AdGuard anonymises
before it matches the client against its rules, so the work segment's rule,
which matches that segment's subnet, would stop matching and work's queries
would be logged. What anonymising would leave is the domains, which are the
sensitive half. Short retention is the privacy control instead: it limits
what the log can say about anyone, and keeps it useful while it does.

**The work segment is recorded nowhere.** `logQueries = false` in
`lib/net.nix` becomes a persistent AdGuard client on both resolvers that
covers the segment's subnet with `ignore_querylog` and `ignore_statistics`.
AdGuard matches a client address against a subnet for both checks (its client
index, `findByIP`), so the rule covers the log and the statistics, on core4
and lifeline alike, since both import the module. Everything else that sees
those queries was checked too:

- AdGuard's debug logging, which writes per-query lines with client
  addresses to the journal, is off (`log.verbose`).
- Unbound sees work's queries, attributed to 127.0.0.1 because they come
  from AdGuard. Its query logging is off (`log-queries`, `log-replies`,
  `log-local-actions`), so it keeps nothing about them beyond its cache.
- Unbound's cache is dumped to disk on stop so a restart does not start cold.
  The dump holds names without clients or timestamps, work's among them,
  from up to four days of cache. It used to stay on disk until the next stop,
  which on a host that rarely restarts could be months. It is now deleted as
  soon as it has been loaded.
- gate's `dns-redirect` rule has a counter, which counts packets and records
  no addresses. pimon reports host health only.
- No metrics are deployed yet. The design in
  [observability.md](observability.md) scrapes Unbound's counters, which are
  totals with neither names nor clients, and probes each resolver from core5.
  AdGuard has no metrics endpoint, and an exporter built on its statistics
  API would inherit the rule, since excluded queries are never counted.

**Lookup services stay off.** Safe browsing and parental control each send a
hash prefix of every name to AdGuard's servers. Both are off by default, and
the module now says so for safe browsing as it already did for parental
control. WHOIS lookups of clients, on by default, apply only to public
addresses, and every client here has a private one, so they never run.

### What goes upstream

**No client subnet.** Unbound sends EDNS Client Subnet only with its
subnetcache module loaded and `send-client-subnet` set, and neither is.
AdGuard's own option is off. The fallback is above.

**Names that exist only inside the house are answered locally.** Devices ask
for names under suffixes that exist only on a home network: a few thousand
such lookups on trusted in the run below. Unbound already answers
`home.arpa`, `onion`, `test`, `invalid`, `localhost` and the private reverse
zones itself, by default. It sent the rest to the root servers, which saw the
device names in them. It now answers `lan`, `local`, `localdomain`,
`internal`, `home` and `corp` with NXDOMAIN, on core4, lifeline and gate: the
same list `scripts/dns-top-domains.jq` counts as local names.

Single-label names, such as a bare `printer`, still reach the root. A
local-zone is a suffix, and every TLD is a single label too, so Unbound has
no way to list them. `aggressive-nsec` answers most repeats from the root's
signed NSEC records once it has them, so the root sees such a name now and
then rather than on every lookup, but not never. What would close it is a
local copy of the root zone (RFC 8806, Unbound's `auth-zone` for `.`), from
which every nonexistent TLD is answered locally and the root sees zone
transfers rather than queries. That changes how all three resolvers start and
recurse, and adds the root servers' transfer addresses to `lib/net.nix`, so
it is a follow-up (F15) rather than part of this review.

### Telemetry coverage

EasyPrivacy and Frogeye's first-party trackers are written for browsers and
apps. What an operating system sends on its own runs on its vendor's domains,
and two lists cover that for the devices in the house, both from HaGeZi's
Native Tracker set and both updated in the week NNO-34 added them, in
October 2026. Each has a comment in `modules/adguardhome.nix` saying why it
is there.

- **Windows and Office: `native.winoffice`**, for the PC WSL runs on and
  Microsoft's apps on any machine. It replaced WindowsSpyBlocker's `spy.txt`,
  which last changed in May 2022. The two overlap less than their
  descriptions suggest: `spy.txt` was 347 exact hostnames, `native.winoffice`
  is about 380 adblock rules, each of which also blocks its subdomains, and
  only 62 of the old names fall under one. What it adds is mostly Office's
  per-application telemetry hosts, along with Bing and MSN advertising, App
  Center, Application Insights and Clarity. Of the 285 names it drops, 215
  are individual servers under `wns.windows.com`, which delivers Windows'
  push notifications, and `llnw.net`, a CDN that has carried Windows Update
  downloads. Neither is telemetry, so dropping them takes away breakage
  rather than coverage.
- **Apple: `native.apple`**, for the iPhones on trusted and the work Mac.
  Its rules are OS, app and advertising analytics.

No list is added for the Android phones on trusted. HaGeZi's Android lists
are per handset vendor, and none covers Google's own services. A vendor's
list is a one-line addition if the phones turn out to need one.

No TV is on the network: the TVs in the house are displays for other
machines. HaGeZi's per-vendor TV lists (`native.lgwebos`, `native.roku`,
`native.amazon` and others) are there for when one joins iot, which is where
lib/net.nix puts TVs.

HaGeZi says its standalone native lists are the thorough end of its range and
can occasionally limit a feature. When something stops working, the query log
names the list that blocked each name, so that is where to look first.

**The work segment** is filtered, so both lists apply to the work laptop.
The rule with the most reach there is `events.data.microsoft.com`, whose
subdomains carry diagnostic data for Windows, Office and Teams, and which
Microsoft's management and security agents can report through. `spy.txt`
blocked only the crash-report hosts under it. The work laptop is a Mac and
does not use Office, so nothing on it is expected to need those names, and
neither list is exempted there.

AdGuard Home cannot apply a list to some clients and not others: a
persistent client uses every enabled list, or turns filtering off entirely.
Should the work laptop need a name back, a custom rule set from the module
(`user_rules`), such as `@@||events.data.microsoft.com^$client='work'`,
unblocks it for that segment alone. It matches the persistent client the module names after
the segment, so no address is written out.

Both lists come from raw.githubusercontent.com, which the resolvers already
fetch from, so neither adds an operator (F7).

### Clearing the history from before the cutover

lifeline's log reached back to 2026-08-29 in the run below, so it held
lookups from before the 2026-09-05 cutover, when every client was on the
flat network and nothing was excluded. core4's log
rotated at 90 days and may hold up to 180, so the same is likely there. The
new interval ages both out within a week of the upgrade, but clearing them
once makes it immediate. Statistics need no reset: a day's worth holds
nothing from then.

Clearing needs the admin login on each resolver and no root. From forge at
home, or through the tunnel, in the repo:

```bash
for h in lifeline core4; do
  curl -fsS -u "$h" -X POST \
    "http://$(nix eval --raw --file lib/net.nix hosts.$h.ip):$(nix eval --file lib/net.nix ports.adguardWeb)/control/querylog_clear" \
    && echo "$h: query log cleared"
done
```

curl prompts for each password without echo. The UI does the same, under
Settings, General settings, "Clear query log". Once is enough: the
retention above keeps the history from building up again.

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

**Firefox** (`programs.firefox` in `hosts/forge/desktop.nix`). The nixpkgs
build is an official one (`MOZILLA_OFFICIAL=1`) with the crash reporter built
in, so telemetry and studies are on, and crash reports are offered, unless
turned off. **off** (F1), by enterprise policy: `DisableTelemetry` and
`DisableFirefoxStudies`, and `DNSOverHTTPS` locked off. Firefox's automatic
DoH would respect AdGuard, which answers its canary domain,
`use-application-dns.net`, with NXDOMAIN, but that check never runs while any
policy is set, so the only alternative to off is DoH everywhere, home
included. Crash reports have no policy; three prefs, locked through the
`Preferences` policy, stop backlogged reports being sent without asking
(`browser.crashReports.unsubmittedCheck.autoSubmit2`), stop the bar offering
them (`browser.crashReports.unsubmittedCheck.enabled`), and untick the
crashed-tab page's box (`browser.tabs.crashReporting.sendReport`). A crash
still writes a report locally, listed in `about:crashes`. If the whole browser
crashes, Mozilla's crash reporter dialog still opens, with a send checkbox it
remembers itself, so a report goes only if that box is ticked when it closes.

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
tool. Beyond that it sends usage telemetry and error reports by default.
`home/claude.nix` sets `DISABLE_TELEMETRY` and `DISABLE_ERROR_REPORTING` under
`env` in the user settings on all three machines, which turns both off, and
the night shift's agents read the same settings. It is installed by its own
installer and updates itself, which stays on: that is why the switch is not
`CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC`, which stops the updater too.

Telemetry off also stops Claude Code fetching its feature flags, and no
setting separates the two, so the features behind a flag go with it. Chosen
knowingly, on 2026-10-11. What is lost, per Claude Code's documentation:

- **An MCP tool with an invalid input schema is sent anyway**, and every
  request then fails with a 400 naming the tool by position, instead of the
  tool being left out.
- **Artifact comments**, skills and plugins synced from the claude.ai account,
  the advisor tool, `/skill-doctor`, `claude import`, and messaging sessions
  on other machines. The fleet's own plugins come from nix and are unaffected.

What stays: auto mode, which a session without flags asks the server for
(the night shift passes `--permission-mode auto`), and Remote Control, from
v2.1.283. If either goes missing after an upgrade, this is the first thing to
undo.
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
  counts. [Internet for iot](#internet-for-iot) is the design for giving
  the internet only to the devices that need it.
- **servers.** The switch and AP contact their vendor. Apart from that,
  the segment reaches only time servers. This confirms F10.
- **vpn.** The tunnel peers, filtered as at home. Nothing new.
- **The resolvers themselves.** Time, GitHub, the binary caches and the
  two alert services, as the inventory above lists, plus one-off manual
  tests.
- **No segment.** Lookups from before the 2026-09-05 cutover, when every
  client was on the flat network. lifeline still held them under
  AdGuard's default retention. NNO-26 set the retention and gives the
  command to clear that history once
  ([above](#clearing-the-history-from-before-the-cutover)).
- **trusted.** Not summarised here, since it is the household's own
  browsing. Its most-blocked entries are app and OS analytics and push
  services, which is the blocklists working. Devices also ask for a few
  thousand names that exist only inside the house. Those under a local
  suffix are now answered by Unbound; single-label ones still reach the
  root ([What goes upstream](#what-goes-upstream)).
- **guest** is absent, as it should be: it resolves through public
  resolvers.
- **work** is absent by design.

## Internet for iot

A design, from NNO-27. Nothing in this section is deployed: it is what the
PRs [at its end](#the-prs-in-order) build, one at a time.

**Today every iot device reaches the whole internet.** `networking.nat`
appends `iifname { every segment } oifname "wan" accept` to gate's
`forward-allow` chain, and nothing on iot's side narrows it except the two
rules in `hosts/gate/routing.nix` that run first: private space upstream is
dropped, and port 853 is refused. Plaintext DNS is redirected to the
resolvers, so every name an iot device looks up is in AdGuard's log, but what
it connects to afterwards is not checked against anything. The device side
above says some iot devices need their vendor's cloud to work and some only
use it to report on themselves.

The house has no global IPv6 ([router.md](router.md)), so this is IPv4 only.
If IPv6 arrives, every rule below needs its `ip6` twin before iot gets an
address.

### Per device or per segment

**Per class, where a class is a list of named devices.** gate can only tell
devices apart by their source address or, since iot is one hop away, their
MAC address. [device-identity.md](device-identity.md) settles how a rule
names one without this repo saying which hardware it is: a role name and a
reserved address, public in `lib/net.nix`, and the MAC that Kea reserves the
address for, in gate's sops file. The ways a class can be expressed:

- **One policy for the whole segment.** Simple, and useless here: the
  segment holds devices that need a cloud and devices that need nothing, so
  one rule is either too open for the second or breaks the first.
- **A list of devices on iot.** A class is a list of names from `devices`,
  as `goveeLights` is, and its chain matches their reserved addresses. No new
  segment, no device moves network, and Home Assistant's rules are
  untouched. Two limits. An address on a shared segment is not
  authentication: a device that takes a pool address for itself is out of
  its class. That is enough against firmware reporting home, not against a
  compromised device set on getting out. And every name in the list is
  public, so this is for devices the repo already names, or whose existence
  is harmless to say; "What would reopen this" in device-identity.md says
  what happens if the list grows into an inventory. This is the
  recommendation, with one class to start: local-only, for devices that need
  no internet at all, holding the Govee lamps.
- **One segment per policy.** A device's class is the network it joins,
  chosen in the UniFi controller and on the device, so the repo names
  classes, never devices, and the AP rather than an address keeps a device
  in its class. It costs a VLAN, a gate reboot and moving each device onto
  the new network. It is the answer for a device that should not be named in
  public, and is [designed below](#a-local-only-segment-later) but not
  scheduled.
- **A runtime set, for trials.** An nftables set on gate, declared empty,
  that Nick fills by hand with a device's current address. Nothing about the
  device reaches the repo. It is not policy: the set empties whenever a
  deploy reloads the ruleset, and for a device without a reservation the
  entry goes stale if its lease moves. It is how a device is tried without
  the internet for a week before it joins a class for good.

### Allowing by name

A device that needs its cloud needs it by name, and the addresses behind
those names change. Four places the name could be checked, by what each costs
on an N100 that is the house's only router:

- **The resolvers, with gate unchanged.** AdGuard can refuse every name for
  one segment's clients and allow a few (`$client` rules, written like the
  work segment's example above). It costs gate nothing and needs no
  new software, and the query log names each refusal, the rule and the client.
  It does not stop a device that connects to a hardcoded address, or that
  resolves over DoH, which nothing on gate can see.
- **nftables sets filled from DNS answers, on gate.** iot's DNS replies come
  from the Pis and cross gate's forward chain, redirected ones included, so
  gate can read them without answering them, and AdGuard keeps seeing each
  device's own address. A small program would take each reply from an NFQUEUE,
  add the addresses for allowed names, CNAME targets followed, to a set with
  a timeout no shorter than an hour, and release it, so the device cannot
  connect before its address is in the set. With the queue's `bypass` flag a
  dead program releases replies untouched, so DNS keeps working and only new
  destinations are refused. The CPU and memory are negligible at iot's query
  rate. The cost is a program written or adopted for this, with no NixOS
  module behind it, running in the DNS path of the house's only router.
  The two cheaper ways to fill such a set are both worse: AdGuard's `ipset`
  option fills sets in the Pis' kernels, not gate's, and pushing them into
  gate would have a Pi reconfigure the router; and a forwarder on gate with
  `nftset=` would make gate every iot device's resolver, so AdGuard would see
  gate's address for all of them and the log could no longer say which device
  was refused.
- **A forward proxy on gate**, reading the server name from each TLS
  handshake without decrypting it. It covers TLS over TCP only, so QUIC,
  plaintext MQTT and every vendor protocol on its own port would need rules
  of their own anyway, and every allowed connection would terminate in a
  userspace process on the router, whose fault takes all of them down. The
  most machinery for the least coverage, so not this.
- **No names at all: allow by default for one class, deny for another.**
  Static rules, nothing at runtime, nothing that can crash. It cannot narrow
  a cloud device's destinations, only give it all of the internet or none.

The names in any allowlist are a list of the vendors whose devices are in the
house, which is the inventory device-identity.md keeps out of the public
half. Writing one down is what its "What would reopen this" names, so that
decision comes first; they never go in this repo in the clear.

**Decision.** Start with the last: a local-only class with no internet, for
the devices that need none, which is the whole gain for them and costs gate
nothing at runtime. Leave the cloud class open until the local class has run
for a while. Then, if it is still wanted, allow by name at the resolvers
first, since that changes gate not at all, and add sets filled from DNS on
gate only if a device keeps working while the resolvers refuse its names,
which means it reaches its cloud without asking them. The proxy is not
pursued.

### Which devices need the cloud

By category; which category each device in the house is in is Nick's to
record, from AdGuard's per-client log, and stays out of the repo.

| Category | Needs the internet | Without it |
|---|---|---|
| Lights driven by Home Assistant over a LAN API: the Govee lamps | No | See below |
| Plugs and switches with a local Home Assistant integration | No | The vendor's app loses remote control |
| Plugs and switches only the vendor's app controls | Their vendor's cloud | They stop being controllable |
| Cameras recording locally | No | Remote viewing through the vendor's app stops |
| Cameras recording to the vendor's cloud | Their vendor's cloud | Recording stops |
| TVs and streaming devices (none today) | Broad: every service they stream | Not a candidate; they stay open |

**The Govee lamps** are controlled from Home Assistant through
`govee_light_local` and need nothing outside the house for it
([home-assistant.md](home-assistant.md#govee-lights)). Cut off, what changes:

- **The vendor's app** can no longer reach them through its cloud, so
  control from the app away from home, and voice assistants linked through
  it, stop. Home Assistant's control does not.
- **What the app does through the cloud** stops with it, some scenes and
  effects among them. What Home Assistant does over the LAN API, which is
  all it does with the lamps today, is unaffected.
- **Firmware updates** stop. They are installed from the app, with the lamp
  online, and the vendor has also pushed security fixes to some lamps
  automatically. Cut off, a lamp keeps the firmware it has, and an update
  becomes a deliberate act: flush the class's chain (below), or take the
  lamp out of the trial set during the trial, update from the app, then
  restore it. A vulnerable lamp that can reach only iot and Home
  Assistant's three ports is the smaller exposure than one that reaches the
  internet.
- **Setting one up** needs the cloud: the app adds the lamp and turns on LAN
  Control through it. A new lamp is set up as "Adding a lamp" says, on a
  pool address with the internet, and cut off when it joins `devices` and
  the class, which Home Assistant needs of it anyway once its rules name the
  lamps (device-identity.md).

That is acceptable, and the lamps go first, since they are the devices this
repo already knows need nothing. What the trial has to show is that a lamp
does not misbehave when its cloud is unreachable: some firmware reboots or
stops answering locally when it cannot reach home. If a lamp does, it stays
out of the class, and that finding goes here.

### Failing, and noticing

**How a cut-off device fails.** Its DNS keeps working: the redirect's
`ct status dnat accept` passes port 53 ahead of every rule here, so it is
answered as before and its lookups keep reaching the log. Its connections out
`wan` are dropped, not refused. A refusal tells it at once, and firmware that
retries on failure then retries at once, in a loop; a drop makes it wait out
its own timeout between attempts. A trial can switch to `reject` if a device
hangs waiting. Connections it already had keep going until they close,
since established traffic is accepted before `forward-allow` is consulted.
To the vendor's app the device looks offline; to Home Assistant, a local
device looks unchanged.

**How Nick notices**, in the order the pieces arrive:

- **Home Assistant**, for the case that matters: a device it controls
  locally going unavailable is the one breakage that is not expected. Its
  history shows when.
- **AdGuard's log.** A cut-off device keeps asking for its cloud's names,
  usually more often than before, since it is retrying. That is expected for
  a local-only device and is how to see what it would have contacted.
- **A named counter per class on gate**, counting the drops:
  `nft list counters table inet nixos-fw`. For the local class it rises all
  the time, since that is the devices trying, so it is evidence rather than
  an alarm. Like the redirect's, it resets whenever a deploy reloads the
  ruleset.
- **A metric**, once gate's metrics exist (NNO-32,
  [observability.md](observability.md)): node_exporter's textfile collector
  reading `nft -j list counters` every minute, so drops per class are a
  graph. An alert on drops makes sense only for a class with an allowlist,
  where a drop means the list is missing something, so it waits for one.

### Rolling out, and rolling back

Every class's policy is its own chain in `inet nixos-fw`, appended the way
`dns-redirect` is appended to `nixos-nat`, and jumped to from a `mkBefore`
rule in `forward-allow` after the private-space drop and the 853 refusals and
before nat's accept. A chain drops what it refuses and returns everything
else, rather than accepting, so nat's rule stays the one accept out `wan`.
That gives three ways back, none of which reboots gate:

- **For one device**: take its address out of the trial set, with no change
  to gate's config. Once it is in a class, its name comes out of the class's
  list in `lib/net.nix`, which is an ordinary gate deploy.
- **For a class, at once**: `sudo nft flush chain inet nixos-fw <chain>`. An
  empty chain returns everything, so the class falls through to nat's accept,
  as today. It lasts until the ruleset is next loaded, by a deploy or by
  `sudo systemctl reload nftables`.
- **For good**: switch gate to the previous generation, which reloads the
  old ruleset and is a firewall reload, not a reboot.

None of the steps below reboots gate, and the lamps stay on iot, so Home
Assistant's Govee rules on gate and core5 are untouched by this.
device-identity.md narrows those to the lamps' addresses on its own
schedule.

### A local-only segment, later

For a device that needs no internet and should not be named in public. Not
scheduled: it waits for such a device.

- **It reboots gate.** A new VLAN interface's address unit is not started by
  `switch`, and Kea, which requires every interface it serves, would loop
  until it was. The reboot happens before any device depends on the segment,
  behind `deploy-guard`, so it risks only what any gate reboot does.
- **The pull request** adds the segment to `lib/net.nix`, with its VLAN,
  subnet and pool; gate carries it in `hosts/gate/routing.nix`, with an
  egress chain dropping everything out `wan`, counted; and the VLAN is
  tagged on the AP and gate ports and its network made in the controller, by
  hand. Every host reads `lib/net.nix`, so the PR quotes preflight's brief on
  whether the Pis change with it.
- **Moving a device** means giving it the new network's Wi-Fi credentials. A
  private pre-shared key on the iot SSID, mapped to the new VLAN, would spare
  a second SSID's beacons on 2.4 GHz, if the controller offers it there;
  otherwise a second SSID. Either way its name stays in the controller.
- **A device Home Assistant controls** would need its rules on the new
  segment too, on gate and on core5, during the move and after it.

### The PRs, in order

Each depends on the one before. The gate PRs change its firewall, so each
deploys behind `deploy-guard` ([recovery.md](recovery.md)).

1. **`gate: count iot's traffic to the internet, and an empty trial set`.**
   The `iot-egress` chain, which returns everything, a named counter for new
   iot flows out `wan`, and the `iot-trial` set, empty, whose members are
   dropped and counted. No device changes until Nick adds an address. A VM
   test beside `tests/gate-dns.nix` checks that a member is dropped, that a
   non-member still reaches the internet and the Pis, and that flushing the
   chain restores both. Firewall only: `nrs` behind `deploy-guard`, no
   reboot. It can land now.
2. **Hands-on, no PR: trial one lamp.** Its address in the trial set for a
   week, then all three. Each time: Home Assistant still controls it, the
   app shows it offline, the counter rises, and the log shows it retrying.
   The finding goes in this section, and if a lamp misbehaves, the plan
   stops here.
3. **device-identity.md's steps 1 to 3**: `devices` and `goveeLights` in
   `lib/net.nix`, the MACs in gate's sops file, and Kea's reservations, so
   each lamp holds a stable address. Its own PRs, on its own schedule; the
   next step needs them.
4. **`gate: keep the govee lamps off the internet`.** A `localOnly` list of
   device names in `lib/net.nix`, holding the lamps, which net-assertions
   checks like `goveeLights`; `iot-egress` drops their addresses out `wan`
   into a counter named for the class, and the VM test covers it. Firewall
   only: `nrs` behind `deploy-guard`, no reboot. `lib/net.nix` changes, so
   the PR quotes preflight's brief on whether the Pis change with it.
5. **`gate: egress counters as metrics`**, after NNO-32: the textfile
   collector above, and a panel per class.

Later, and only if wanted after the local class has run for a while: an
allowlist for the cloud class, at the resolvers first, once the names in it
have somewhere to live (above). And the local-only segment, when a device
needs it.

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
| F15 | `unbound: serve the root zone locally, so single-label names stay home` | narrow |
| F16 | `adguardhome: maintained telemetry lists for windows and the house's tvs` | narrow, done in NNO-34 |

F10 changes gate's firewall, so it goes behind deploy-guard. F5 changes gate
and core5 together, and F6 the resolvers, which take it that night. F15
changes Unbound on gate and the Pis together, and F16 the resolvers. The rest
are forge, docs, or one service on core5.
