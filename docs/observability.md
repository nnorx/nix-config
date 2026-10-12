# Observability

A decision record. Nothing here is deployed yet: this is the design the
follow-up issues build, one piece each, so that none of them re-argues it.
What runs today is pimon, for liveness, and
[`modules/alerts.nix`](../modules/alerts.nix), for failed and missed jobs (README,
"Alerts"). The second stays; the first is retired by the end of this.

## The questions

[`modules/pimon.nix`](../modules/pimon.nix) answers one question, whether a host
is up, and keeps only the latest snapshot in memory. Phase 8 in
[router.md](router.md) lists what nothing answers yet:

- **WAN state.** Is the link up, and does traffic leave the house?
- **Conntrack pressure.** How close gate's connection table is to its limit.
- **Per-interface throughput**, on gate's segments and the Pis' links.
- **DHCP pool exhaustion**, per Kea subnet.
- **DNS failure ratios**, per resolver.
- **A host that is up and running the wrong system**, as core5 was on its SD
  card on 2026-09-04 ([recovery.md](recovery.md#the-silent-wrong-boot)).

And alerting for all of it, since a router fault learned about by noticing the
internet is broken is one monitoring did not catch.

## In short

| | Decision |
|---|---|
| Store | VictoriaMetrics, single node, on core5 |
| UI | Grafana on core5, provisioned from the repo. VictoriaMetrics' own vmui for ad hoc queries |
| Collection | Pull. core5 scrapes exporters on each host, every 30 seconds |
| Retention | 12 months, about 4 GB, budgeted at 10 GB |
| gate's address | gate gets no `ip`. A new `metricsSegment` names where it is scraped |
| Alerts | vmalert and Alertmanager on core5, to the existing ntfy topic. A watchdog pings healthchecks.io, so the stack's own silence alerts from outside |
| fleetAlerts | Unchanged, and still the path for unit failures and missed jobs |
| pimon | Retired once node metrics and the host-down alert have run for two weeks |
| Wrong boot | The hosted root-device check stays primary. Metrics add how long each host has been behind main, and treat a missing exporter as down |
| Access | Grafana from trusted. Over the tunnel later, if wanted, for forge alone |

## Store and UI

**VictoriaMetrics, single node, on core5. Grafana beside it.**

core5 has the room. Measured on 2026-10-10 with `fleet-ssh`, after 13 days up:
16 GB of RAM with 4.9 GB used and 11.3 GB available, a load average of 0.02,
and 11 GB used of a 937 GB NVMe root. Home Assistant, the UniFi controller and
its database, Docker and pimon all fit in that 4.9 GB. The NVMe was the
blocker in router.md, since a time-series database writes continuously and an
SD card is the wrong medium for it; core5 has been on NVMe since 2026-08-31.
The disk is already written at about 6.5 GB a day (85 GB in 13.2 days, from
`/proc/diskstats`), mostly the nightly upgrade, against which the store's
writes below are small.

VictoriaMetrics over Prometheus, on three counts. It stores the same data in
less disk, which the sample below measures for this fleet rather than quoting.
Its scrape configuration is Prometheus's own format (`-promscrape.config`), and
it answers PromQL, so the exporters, the scrape config, the alert rules and
every Grafana dashboard written for Prometheus carry across unchanged; the
choice is reversible. And retention is one flag, with no separate compaction
or WAL to size. nixpkgs has modules for all of it: `services.victoriametrics`,
`services.vmalert`, `services.prometheus.alertmanager` and `services.grafana`.
Prometheus would also fit in core5's memory; this is not a choice forced by
resources.

Grafana for dashboards, because the community dashboards for node_exporter,
Kea and Unbound are written for it, and vmui, built into VictoriaMetrics, is a
query box rather than a dashboard. Its datasource and dashboards are
provisioned from files in the repo, so Grafana's own state holds nothing worth
keeping: no dashboard is edited in the UI and kept there. Neither Grafana nor
the metrics history joins the off-box backups (`modules/offbox-push.nix`):
losing them to a dead drive costs graphs, not configuration.

VictoriaMetrics, vmalert and Alertmanager listen on loopback only, since
everything that talks to them is on core5. Grafana is the one listener on
core5's address. core5 keeps the public resolvers it already uses
(`networking.nameservers`), for the reason network.md gives for pimon:
monitoring that resolves through the resolvers it watches goes blind exactly
when they fail.

## Retention and disk

**12 months. About 4 GB at the fleet's expected size, budgeted at 10 GB.**

Measured rather than guessed, against a sample: node_exporter 1.11.1, default
collectors, scraped every 15 seconds into VictoriaMetrics 1.152.0 for two hours
on forge, 1,794 series at 120 samples a second, 887,000 samples in all. After
a forced flush and merge the store held 572 KB, **0.65 bytes per sample**
including the index; the growth between the first and last readings, which
leaves the index's fixed cost out, was 0.56. Two hours is short for a store
that compresses better as its parts merge into larger ones, so 0.65 is the
figure to plan with and likely an overestimate. The on-disk caches
VictoriaMetrics writes at shutdown added 1.8 MB, which is rebuildable and does
not grow with retention.

The fleet's series, per host from that scrape, adjusted for each host's CPUs,
mounts and interfaces (read with `fleet-ssh`): node_exporter's default
collectors cost about 27 series per CPU, 8 per filesystem and 35 per network
interface, and about 500 more that do not scale with hardware. On core5,
node_exporter should exclude `veth*` interfaces: Docker names a new one each
time a container restarts, and each name is a new set of series.

| Source | Series |
|---|---|
| core4, lifeline: 4 CPUs, about 10 filesystems, 3 interfaces each | about 900 each |
| core5: the same, and Docker's bridges and veths, 7 interfaces | about 1,050 |
| gate: 4 CPUs, about 10 filesystems, 11 interfaces | about 1,150 |
| Unbound exporters on core4, lifeline and gate | about 750 |
| Kea exporter, five subnets | about 150 |
| Blackbox probes, WAN and DNS | about 150 |
| VictoriaMetrics, vmalert and Alertmanager scraping themselves | about 1,300 |
| **Total** | **about 6,350** |

At 30 seconds, 6,350 series are 18.3 million samples a day, 6.7 billion a year,
and at 0.65 bytes each **about 4.3 GB for 12 months**. The budget is 10 GB: room
for the series to double, or for the interval to drop to 15 seconds (8.7 GB),
and about a hundredth of the free disk either way. Compressed, that is
about 12 MB a day of new data. Merges rewrite it several times over, a write
amplification the sample did not measure, but even tenfold it is a few
percent of the 6.5 GB a day core5 already writes.

12 months, because the slowest things worth seeing are seasonal: gate is
fanless, and its temperature in August is the comparison that matters in
August. Longer buys little for a fleet that changes this often. VictoriaMetrics
sets it with `-retentionPeriod=12`, and `-storage.minFreeDiskSpaceBytes` makes
it stop accepting writes, rather than fill the root, if the estimate is wrong by
two orders of magnitude.

30 seconds rather than the default 15, since the questions are pressure, trends
and failures rather than sub-minute bursts. It halves the samples, and the
alert rules below hold for minutes anyway.

## Pull, and which ports open

**Pull. core5 scrapes; the other hosts only listen.**

- Liveness comes free. Every scrape records `up` for its target, from the
  collector's side, which is the question pimon answers today and the one an
  agent that pushes cannot answer about itself.
- The list of what is watched lives in one place, core5's scrape
  configuration, generated from `lib/net.nix`.
- Every scrape stays on the servers segment. core4, lifeline and core5 share it,
  and gate is scraped at its own address there, so nothing crosses gate's
  forward chain and no forward rule is needed. The one cross-segment flow is
  someone loading Grafana.
- gate never has to dial into the LAN. Under push, the router would initiate
  connections to a Pi, which is a dependency in the wrong direction.

What it costs is a listening port on each watched host, where push would open
one port on core5 alone. Each exporter's port opens on the host's LAN interface
and only from core5's address, the reverse of what core5 does for pimon's
agents today. The source address matters even on servers, which also holds the
switch, the AP and anything on an untagged switch port
([home-assistant.md](home-assistant.md) has the same caveat for Home Assistant).

On gate, the exporters bind the servers gateway address alone, the way sshd
binds named addresses rather than all of them (`modules/ssh.nix`), and the port
opens on `lan0`, whose untagged VLAN is servers, from core5's address. No other
segment, and never `wan`.

Ports to add to `lib/net.nix` under `ports`, each in the issue that first uses
it. The loopback ones go there too, since the invariant is every port, as
pimon's loopback agent on core5 already does:

| Port | Name | Listens on |
|---|---|---|
| 9100 | `nodeExporter` | Every host's LAN address; gate's servers gateway |
| 9167 | `unboundExporter` | core4, lifeline; gate's servers gateway |
| 9547 | `keaExporter` | gate's servers gateway |
| 9115 | `blackboxExporter` | core5 loopback |
| 8428 | `victoriaMetrics` | core5 loopback |
| 8881 | `vmalert` | core5 loopback |
| 9093 | `alertmanager` | core5 loopback |
| 3030 | `grafana` | core5's address |

Each is the upstream default except where one collides. vmalert's own default is 8880, which is
the UniFi controller's guest-portal port; nothing publishes it today, but one
number meaning two things on one host invites the wrong firewall rule. Grafana's
default, 3000, is `adguardWeb` already: a different host, but the same number
under two names in one file, and gate's tunnel grants match on the number.

## gate's address

**gate gets no `ip`. It gets `metricsSegment = "servers"`, and is scraped at that
segment's gateway.**

`net.hosts.<host>.ip` means more than "an address this host has". hosts/common
binds it on `iface` with the segment's gateway as the default route;
`modules/ssh.nix` binds sshd to it; `home/ssh.nix` makes it the host's SSH
address; `hosts/forge/vpn.nix` routes it into the tunnel; `serverIps` in
`hosts/gate/wireguard.nix` grants SSH forwarding to it; and the comment on
`gate` in `lib/net.nix` already warns that an `ip` there would put a LAN
address and default route on the wrong interface. Each of those is wrong for a
router that holds `.1` in every segment. Giving gate an `ip` so that one
consumer can find it would change the meaning for the six that already read it.

What the scraper needs is narrower: the address at which gate is reached from
the collector's segment. That is already in `lib/net.nix`, as
`segments.servers.gateway`, so the new attribute names a segment rather than
carrying an address:

```nix
gate = {
  # The segment gate's exporters bind and are scraped on: its gateway address
  # there, and that address alone.
  metricsSegment = "servers";
  ...
};
```

Two lists, beside `pimonAgents` and named rather than derived for the same
reason (being in `hosts` is not the same fact as being scraped):

```nix
metricsCollector = "core5";
metricsTargets = [ "core4" "lifeline" "core5" "gate" ];
```

`modules/net-assertions.nix` gains the checks: every target has an `ip` or a
`metricsSegment`; a `metricsSegment` names a declared segment; and it is the
collector's own segment, so scraping never depends on gate forwarding. When
pimon is retired, `pimonAgents` and its assertion go with it.

## DNS failure ratios

**Per resolver, from Unbound's exporter, AdGuard's own statistics and core5's
probes. Totals only: no metric names a client or a domain.**

On core4 and lifeline, `modules/unbound.nix` turns on Unbound's
`extended-statistics` and runs nixpkgs' `unbound_exporter` over the local
control socket the cache dump already uses, on `ports.unboundExporter` at the
host's address, open to core5 alone. Unbound's statistics are counters of
answers by response code, cache hits, a histogram of recursion times, DNSSEC
results and dropped queries. Its one client is AdGuard on loopback, and it has
no field for a name.

AdGuard Home has no metrics endpoint and nixpkgs has no exporter for it, but
its statistics API answers for the current hour alone
(`/control/stats?recent=3600000`). `modules/adguardhome.nix` reads it every 30
seconds, as a login of its own called `metrics`, and writes the totals where
node_exporter's textfile collector picks them up, as `fleet_adguard_*`. The
hour's totals start again from zero on the hour, and `rate()` takes that as a
counter reset, so a rate over any window is right except for the queries
between the hour's last read and its end. The response also lists the busiest
clients and domains; the collector drops them, keeping only totals, and
reports the upstreams by role (`primary`, `fallback`) rather than address.
When AdGuard does not answer, only `fleet_adguard_up 0` is written.

The questions, as queries. The DNS dashboard on core5 draws each of them, with
`$__rate_interval` for the window:

- **Queries.** From clients, work aside:
  `sum by (instance) (rate(fleet_adguard_queries_total[5m]))`. Reaching
  Unbound, which is everything AdGuard did not block:
  `sum by (instance) (rate(unbound_queries_total[5m]))`.
- **SERVFAIL ratio**, of Unbound's answers. A recursion that timed out
  upstream and an answer that failed validation both end here:
  `sum by (instance) (rate(unbound_answer_rcodes_total{rcode="SERVFAIL"}[5m])) / sum by (instance) (rate(unbound_answer_rcodes_total[5m]))`.
- **Timeout ratio**, in two places. AdGuard asks its fallback only when Unbound
  errs or takes longer than `upstream_timeout`, so the fallback's share of
  AdGuard's upstream answers is Unbound timing out as AdGuard sees it:
  `sum by (instance) (rate(fleet_adguard_upstream_responses_total{upstream!="primary"}[5m])) / sum by (instance) (rate(fleet_adguard_upstream_responses_total[5m]))`.
  And the queries Unbound discarded unanswered, too long in its queue or with
  its request list full:
  `sum by (instance) (rate({__name__=~"unbound_(queries_discard_timeout|queries_wait_limit|request_list_exceeded_total)"}[5m])) / sum by (instance) (rate(unbound_queries_total[5m]))`.
- **Blocked ratio**, over an hour since blocking is bursty:
  `sum by (instance) (rate(fleet_adguard_blocked_total[1h])) / sum by (instance) (rate(fleet_adguard_queries_total[1h]))`.
- **Cache hit rate**, Unbound's, the only cache, since AdGuard's is off:
  `sum by (instance) (rate(unbound_cache_hits_total[5m])) / sum by (instance) (rate(unbound_queries_total[5m]))`.
- **Upstream latency.** Unbound's recursion, cache misses alone:
  `histogram_quantile(0.9, sum by (instance, le) (rate(unbound_response_time_seconds_bucket[5m])))`.
  AdGuard waiting on Unbound, cache hits included:
  `sum by (instance) (rate(fleet_adguard_upstream_seconds_total{upstream="primary"}[5m])) / sum by (instance) (rate(fleet_adguard_upstream_responses_total{upstream="primary"}[5m]))`.
- **DNSSEC failures**, answers that failed validation:
  `sum by (instance) (rate(unbound_answers_bogus[5m]))`, and the records found
  bogus on the way, `unbound_rrset_bogus_total`.

**The work segment stays out by construction.** AdGuard's persistent client
for the segment sets `ignore_statistics`, so its queries are never counted,
and the API has nothing of them to return. Unbound counts them, since they
reach it from AdGuard on loopback like everyone else's, but only within totals
that have no client in them: they say how busy the house was, work's lookups
included, never whose. `tests/dns-metrics.nix` checks both, with queries from
a work address that leave AdGuard's counts where they were and raise
Unbound's.

### Probes from core5

**What no exporter on a host can say about itself: whether the resolver
answers a client, and whether traffic leaves the house.** The blackbox
exporter runs on core5's loopback (`modules/blackbox.nix`), on
`ports.blackboxExporter`, and VictoriaMetrics scrapes its `/probe` for each
target every 30 seconds, with the target's name as `instance`.

- **`probe-resolver`**: each resolver at its address on port 53, over UDP, as
  a client on servers would ask. The question is `net.resolverProbe`, a name in
  `lan`, which Unbound answers NXDOMAIN from its own static local zone, so the
  probe passes through AdGuard and Unbound and needs neither the WAN nor the
  cache. A resolver that answers it is up; whether recursion works is the
  SERVFAIL ratio's question, so a WAN outage reads as `WanDown` and not also
  as both resolvers failing. `modules/unbound.nix` asserts the zone is there.
  AdGuard leaves the name out of its query log and statistics by rule
  (`ignored`), so the probes neither fill the log nor count as client
  queries. When Unbound is down, AdGuard's fallback answers the probe
  NXDOMAIN too, and the probe passes, as clients are answered; `unbound_up`
  and the fallback's share say which path answered.
- **`probe-ping`**: an ICMP echo to each address in `net.publicResolvers`,
  from core5 through gate and out of `wan`. What leaves the house is two pings
  every 30 seconds to resolvers it already uses. It needs no capability: the
  exporter opens an unprivileged ICMP socket, which NixOS's default
  `net.ipv4.ping_group_range` allows.

The queries, which the DNS and fleet dashboards draw:

- **Resolver answering**, the share of probes answered over the window:
  `avg_over_time(probe_success{job="probe-resolver"}[5m])`. Its complement is
  the end-to-end failure ratio.
- **Resolver answer time**, the query's round trip from core5:
  `probe_dns_duration_seconds{job="probe-resolver", phase="request"}`.
- **Public resolvers reachable**:
  `avg_over_time(probe_success{job="probe-ping"}[5m])`, which falls to 0
  for both when the house's traffic stops leaving it.
- **Round trip to them**:
  `probe_icmp_duration_seconds{job="probe-ping", phase="rtt"}`.

**Still unseen.** gate's own Unbound has no exporter yet.

### The metrics login

**`metrics` is a full admin login.** AdGuard has no read-only role, so the
login can do anything Nick's can, from wherever AdGuard's UI is reachable:
each resolver's LAN interface, which trusted and servers reach, and over the
tunnel for peers granted `adguard` in `hosts/gate/wireguard.nix`. It is a login
of its own so that Nick's password reaches no service. The timer uses it over
loopback alone, and `mutableSettings` puts back anything changed through it at
AdGuard's next start, which is the extent of the protection. Its password and
its bcrypt hash are a pair in each resolver's sops file,
`adguard-metrics-password` and `adguard-metrics-hash`, and evaluation fails
until both are there. The password reaches the collector as a systemd
credential, from a root-only netrc that sops renders: node_exporter, which
shares the collector's user, cannot read it there. To make both, from the
repo, in your own terminal (zsh), inside
`nix shell nixpkgs#sops nixpkgs#jq nixpkgs#openssl nixpkgs#apacheHttpd`:

```bash
for h in core4 lifeline; do
  pw=$(openssl rand -hex 32)
  printf '"%s"' "$pw" | sops set --value-stdin secrets/$h.yaml '["adguard-metrics-password"]'
  printf %s "$pw" | htpasswd -niBC 10 metrics | cut -d: -f2- | tr -d '\n' | jq -R . | sops set --value-stdin secrets/$h.yaml '["adguard-metrics-hash"]'
done; unset pw h
```

And to check each pair without printing either half. The hash must be 60 bytes
exactly: sops splices it into AdGuard's configuration, and a stray newline or
quote there would stop AdGuard from starting.

```bash
for h in core4 lifeline; do
  hash=$(sops decrypt --extract '["adguard-metrics-hash"]' secrets/$h.yaml)
  n=$(sops decrypt --extract '["adguard-metrics-hash"]' secrets/$h.yaml | wc -c)
  [[ $n -eq 60 && $hash =~ '^\$2y\$10\$[./A-Za-z0-9]{53}$' ]] && echo "$h: hash shape ok" || echo "$h: hash shape BAD"
  sops decrypt --extract '["adguard-metrics-password"]' secrets/$h.yaml | htpasswd -vi =(printf 'metrics:%s\n' "$hash") metrics >/dev/null 2>&1 && echo "$h: pair matches" || echo "$h: pair MISMATCH"
done; unset hash n h
```

## Alerts

**Rules evaluated on core5 by vmalert, delivered by Alertmanager to the ntfy
topic the phone already follows. fleetAlerts stays as it is.**

```
exporters ──scrape──► VictoriaMetrics ◄──query── vmalert ──► Alertmanager
                                                                  │
            ntfy.sh topic ◄── webhook, ?template=alertmanager ────┤
            hc-ping.com   ◄── Watchdog, every 5 minutes ──────────┘
```

- **Delivery.** Alertmanager's webhook posts to the ntfy topic with
  `?template=alertmanager`, which ntfy.sh formats itself (its built-in
  Alertmanager template), so no bridge runs on core5. The URL is assembled by a
  sops template from the `ntfy-url` secret core5 already holds and read through
  the webhook's `url_file`, so it never reaches the store. Two receivers by
  severity: `critical` adds `&priority=high`, `warning` uses the default, the
  same split alerts.nix makes between a failed backup and a failed upgrade.
- **What leaves the house.** alerts.nix sends only a host's and a unit's names.
  The ntfy template sends every alert's labels, so the labels are kept to the
  same standard: scrape relabelling sets `instance` to the host's name rather
  than its address, rules carry `alertname`, `host` and `severity` and
  summaries that name things rather than quote values, and the `address`
  label (a MAC address) is dropped from `node_network_info` at scrape, so it
  is never stored either.
- **The stack's own silence.** An always-firing `Watchdog` alert routes to
  healthchecks.io every 5 minutes, as a check named `core5-metrics-watchdog`.
  If core5 is off, booted from its SD card, out of disk, or the pipeline is
  broken anywhere between scrape and delivery, the pings stop and
  healthchecks.io alerts through the same topic from outside the house. It
  needs its period set to 15 minutes by hand, as the other checks need their
  grace set (README, "Alerts").
- **WAN down** is the case the hosted half exists for. An alert that gate's
  uplink is down cannot leave the house until it is back, and arrives as
  history. The watchdog's missed pings arrive on time, over the phone's own
  connection.
- **fleetAlerts** keeps unit failures and missed jobs: upgrades, backups, and
  now `victoriametrics`, `vmalert`, `alertmanager` and `grafana` in core5's
  `fleetAlerts.failure`, so the stack failing to start says so through the
  path that does not depend on it.

The first rule set, in the alert-rules issue, with thresholds to tune against
what the graphs show by then:

| Alert | Fires when | Severity |
|---|---|---|
| `HostDown` | A target's `up` is 0 for 5 minutes | critical |
| `WanDown` | gate's `wan` has no carrier, or both public resolvers fail ICMP probes from core5, for 2 minutes | critical |
| `ResolverFailing` | A resolver fails its DNS probe for 5 minutes, or more than 5% of its answers are SERVFAIL over 15 | critical |
| `ConntrackPressure` | gate's conntrack table is over 80% of its limit for 10 minutes | warning |
| `DhcpPoolLow` | A Kea subnet has under 10% of its pool free | warning |
| `DiskFilling` | A filesystem is over 85% full, or predicted full within 3 days | warning |
| `HostHot` | A thermal zone stays above its threshold for 15 minutes | warning |
| `RevisionBehind` | See below | warning |
| `Watchdog` | Always | none: routed to healthchecks.io only |

## pimon

**Retired, once node metrics and `HostDown` have run for two weeks without a
gap.**

Everything pimon collects (CPU, memory, disk, temperature, load and uptime) is
in node_exporter's defaults, with history pimon never kept, and `up` answers
its liveness question from the collector's side. Keeping both would mean two
answers to "is core4 up", from two collectors that can disagree. The two weeks
are for confidence that the new path sees what the old one did.

Retiring it is its own PR, after the alert rules: drop the module and the
`pimon` input, `pimonAgents` and its assertion, the collector rule in
`hosts/core5/default.nix`, and `ports.pimon`. network.md's diagram and its
reasoning for core5's public resolvers then name the metrics stack instead.

## The wrong boot

**The hosted daily root-device check, filed separately through fleetAlerts,
stays the primary detection. The metrics side adds two signals, and claims
neither of the things only the hosted check can see.**

What metrics add:

- **Revision age against main.** Each host exports its running revision as a
  label (`fleet_revision_info{revision=...}`), read at runtime from
  `nixos-version --configuration-revision` by node_exporter's textfile
  collector, so nothing new is baked into the toplevel. A timer on core5 asks
  the public GitHub API, with no token, for main's head alone, and
  `RevisionBehind` fires when a host's revision has differed from it
  continuously for 36 hours. Comparing against the head is enough: the
  duration, not how far behind, is what separates a missed night from a merge
  waiting for tonight's upgrade. A healthy Pi is behind for at
  most a day, from a merge until its next upgrade; one behind for a day and a
  half has missed a night, whether or not its upgrade reported success, which
  is the signature recovery.md describes. gate has no upgrade
  timer and is behind after every merge until deployed by hand, so its
  threshold is 7 days, as a reminder rather than a fault.
- **A missing exporter is a down host.** A fallback boots a generation that
  predates any check added since. Once node_exporter is everywhere, a
  generation without it is one that predates the metrics stack, and `HostDown`
  fires for it like any other silence.

What metrics cannot do:

- **See core5's own wrong boot.** The store, the rules and the delivery all run
  on core5's NVMe. Booted from its SD card, core5 runs none of them, and says
  nothing. The watchdog going quiet is the signal, and it does not say why;
  the hosted root-device check does.
- **See anything with the house down.** Which is why the root-device check is
  hosted, and stays so.
- **Check the root device.** The expected device lives in each host's own
  configuration, and on a fallback that is the wrong generation's
  configuration, which agrees with itself. Expectation has to come from
  outside, which is the hosted check's design.

## Access

**Grafana from trusted. Over the tunnel later, if wanted, for forge alone, as a
new `grafana` grant in `hosts/gate/wireguard.nix`.**

From trusted it needs nothing new at gate: trusted reaches servers in full.
core5 opens `ports.grafana` on its wired interface, as it does for Home
Assistant, so the servers segment reaches it directly too, and iot, work and
guest cannot. Grafana's own login guards it, with anonymous access off and the
admin password in sops, set by Nick.

Over the tunnel, it waits until it is missed. Alerts reach the phone away from
home without it, and the grant is a change to gate's firewall, behind
`deploy-guard`, for the convenience of reading graphs from a hotel. When it is
wanted, forge gets it, because forge is what is open when an alert arrives
away from home and the question is why. The grant is one entry in
`forwardRules`, matching core5's address and `ports.grafana`, held by forge.
The phone does not get it: it is DNS-only as the device most likely to be lost,
and the alert itself already reaches it through ntfy. Adding it later is one
word in `grants`.

## Order of the follow-up issues

In this order, each depending on the one before. Where an issue touches gate
and the Pis, it is two PRs, gate's first, since it adds what core5's half reads
from `lib/net.nix`. gate deploys by hand and the Pis deploy themselves, so the
two can land days apart; in either order the gap is only scrapes failing until
both are in.

1. **Node metrics.** VictoriaMetrics and Grafana on core5, node_exporter on
   core4, lifeline and core5, scraped by core5. Ports, `metricsCollector` and
   `metricsTargets` (without gate yet) in `lib/net.nix`, the firewall rule per
   host, the label relabelling, a node dashboard, and the revision textfile.
   One PR across the Pis, since the collector and its targets change together.
2. **gate metrics.** First gate: `metricsSegment` and its assertions,
   node_exporter and the Kea exporter bound to the servers gateway, and Kea's
   control socket, which it does not have today, for the exporter to read.
   Then core5: gate in `metricsTargets`, and the blackbox exporter with ICMP
   probes to the public resolvers. Answers WAN state, conntrack,
   per-interface throughput and pool exhaustion.
   Landed as one PR, with each WireGuard peer's last handshake added, and
   without the blackbox exporter, which moved to step 3 and landed there, in
   NNO-23. So gate reports WAN state as the link, the lease and the default
   route as it sees them, and whether traffic leaves the house is core5's
   ICMP probes to the public resolvers ("Probes from core5" above).
3. **DNS metrics.** First gate, then the Pis: the Unbound exporter on gate,
   core4 and lifeline, over each Unbound's control socket, and blackbox DNS
   probes from core5 to each resolver through AdGuard on port 53, which is the
   end-to-end failure ratio. AdGuard Home has no Prometheus endpoint and
   nixpkgs no exporter for it, so its own counters stay in its UI. The same
   blackbox exporter carries step 2's ICMP probes to the public resolvers,
   which `WanDown` needs.
   Landed for the Pis first, as one PR (NNO-23): the Unbound exporter on core4
   and lifeline; AdGuard's own counts after all, read from its statistics API;
   and on core5 the blackbox exporter, with the DNS probes to each resolver
   and step 2's ICMP probes, which `ResolverFailing` and `WanDown` need. The
   DNS probe asks a name Unbound answers itself, so it says whether the
   resolver answers, not whether recursion works, which the SERVFAIL ratio
   says instead ("DNS failure ratios" above). Still to come: gate's Unbound
   exporter, a gate PR of its own.
4. **Alert rules.** vmalert and Alertmanager on core5, the ntfy receivers, the
   watchdog check in healthchecks.io, the rule set above, the GitHub timer for
   `RevisionBehind`, and the stack's units in `fleetAlerts.failure`.
5. **Retire pimon**, two weeks after 4.

Later, if wanted: **Grafana over the tunnel**, the `grafana` grant for forge
described under Access. gate alone, behind `deploy-guard`, since it changes
gate's firewall.

Nothing in this file changes a host. The first that does is issue 1.
