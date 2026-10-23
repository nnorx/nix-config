# Observability

A decision record: the design the follow-up issues built, one piece each, so
that none of them re-argued it. The store, the dashboards, the metrics from
every host and the alerts over them are built (steps 1 to 4 under "Order of
the follow-up issues"). pimon still runs beside them, for liveness, until it
is retired, and [`modules/alerts.nix`](../modules/alerts.nix), for failed and
missed jobs (README, "Alerts"), stays.

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
core5's address. VictoriaMetrics' delete, snapshot and force-merge APIs take a
key made on core5 at boot and read by root alone, since nothing deletes series
or makes snapshots in the normal run of things; `modules/metrics.nix` has the
command for when something must. The `diag` login queries VictoriaMetrics but
reaches neither vmalert, Alertmanager nor the blackbox exporter
(`modules/diag-login.nix`). core5 keeps the public resolvers it already uses
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
| Unbound exporters on core4 and lifeline | about 500 |
| Kea exporter, five subnets | about 150 |
| Blackbox probes, WAN and DNS | about 150 |
| VictoriaMetrics, vmalert and Alertmanager scraping themselves | about 1,300 |
| **Total** | **about 6,100** |

At 30 seconds, 6,100 series are 17.6 million samples a day, 6.4 billion a year,
and at 0.65 bytes each **about 4.2 GB for 12 months**. The budget is 10 GB: room
for the series to double, or for the interval to drop to 15 seconds (8.3 GB),
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
| 9167 | `unboundExporter` | core4, lifeline |
| 9547 | `keaExporter` | gate's servers gateway |
| 9115 | `blackboxExporter` | core5 loopback |
| 9633 | `smartctlExporter` | core5 loopback |
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
  `sum by (instance) (rate(unbound_answer_rcodes_total{rcode="SERVFAIL"}[5m])) / sum by (instance) (rate(unbound_answer_rcodes_total{rcode!="nodata"}[5m]))`.
  `nodata` is left out of the whole: it counts NOERROR answers with nothing
  in them, which NOERROR has already counted.
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

**Still unseen.** gate's own Unbound, deliberately (step 3 below).

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

Built in NNO-24: [`modules/alerting.nix`](../modules/alerting.nix) runs the
two services, and [`modules/alert-rules.nix`](../modules/alert-rules.nix)
holds the rules, each with its reasons beside it.

- **Delivery.** Alertmanager's webhook posts to the ntfy topic with
  `?template=alertmanager`, which ntfy.sh formats itself (its built-in
  Alertmanager template), so no bridge runs on core5. The URL is assembled by a
  sops template from the `ntfy-url` secret core5 already holds and read through
  the webhook's `url_file`, so it never reaches the store. One receiver per
  severity: `critical` adds `&priority=high` and `warning` uses the default,
  the same split alerts.nix makes between a failed backup and a failed
  upgrade, and `info` adds `&priority=low`, for reminders.
- **One push per incident.** Alertmanager groups by alert name, so one fault
  on several hosts at once is one push, and waits 30 seconds for the rest of a
  group to arrive. A host joining a group already pushed is a new push, at the
  group's next 5-minute flush. Nothing else is sent: no resolution, and no
  repeat until the same alerts have fired for 30 days, with the log of what
  was sent kept for 31 days so that it outlasts the repeat. vmalert writes its
  alerts' state to the store and reads it back at start, and Alertmanager
  keeps its log on disk, so a restart of either sends nothing again.
  `tests/alerting.nix` checks this, restarts included.
- **What leaves the house.** alerts.nix sends only a host's and a unit's names.
  The ntfy template sends every alert's labels, so the labels are kept to the
  same standard: scrape relabelling sets `instance` to the host's name rather
  than its address, rules carry `alertname`, `instance` (the template's
  "Instance") and `severity`, a name from `lib/net.nix` where one is needed (a
  segment, a peer, a mountpoint), and summaries that name things rather than
  quote values. The `address` label (a MAC address) is dropped from
  `node_network_info` at scrape, so it is never stored either. Kea labels its
  pools by address range and its subnets in CIDR form; `DhcpPoolLow` names the
  segment instead. The links in the body, back to vmalert and Alertmanager,
  are loopback addresses, set so that they do not default to the host's name.
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
  connection. While `WanDown` fires it holds back `ResolverFailing`, since
  every recursion fails with it, and `HostDown` holds back every other alert
  about the same host.
- **fleetAlerts** keeps unit failures and missed jobs: upgrades, backups, and
  now `victoriametrics`, `vmalert`, `alertmanager` and `grafana` in core5's
  `fleetAlerts.failure`, so the stack failing to start says so through the
  path that does not depend on it.

The rule set. Every threshold below was checked against core5's store on
2026-10-13, and the four added in NNO-68 (`ScrapeDown`, `AdGuardStatsMissing`,
`InterfaceErrors`, `RevisionCheckStale`) against all it held on 2026-10-15,
4 days; none fired. The two drive rules, added in NNO-69, were not: the store
had no drive health until they merged, and they are judged by the NVMe
fields' meanings and the drive's own threshold ("Drive health" below).
`tests/alert-rules.nix` checks each rule against series of its own, firing
and not.

| Alert | Fires when | Severity |
|---|---|---|
| `HostDown` | A host's node_exporter scrape (`up`) is 0 for 5 minutes | critical |
| `ScrapeDown` | Any other scrape but the alerting stack's own is 0 for 10 minutes: Unbound's or Kea's exporter, or every target of a probe job | warning |
| `WanDown` | gate's `wan` has no carrier, no lease or no default route, or both public resolvers fail ICMP probes from core5, for 2 minutes | critical |
| `ResolverFailing` | A resolver fails its DNS probe, or more than 5% of its answers over 15 minutes are SERVFAIL, of at least 100, for 5 minutes | critical |
| `AdGuardStatsMissing` | A resolver's read of AdGuard's statistics (`fleet_adguard_up`) fails for 30 minutes | warning |
| `ConntrackPressure` | gate's conntrack table is over 80% of its limit for 10 minutes | warning |
| `DhcpPoolLow` | A segment's pool is over 90% leased for 15 minutes | warning |
| `DiskFilling` | A filesystem is over 85% full, or over half full and predicted full within 3 days at its last 6 hours' rate, for an hour | warning |
| `HostHot` | A thermal zone stays above 75°C for 15 minutes | warning |
| `DriveFailing` | A drive's health log reports a critical warning, a failed SMART verdict, spare under the drive's own threshold, or a media error newer than an hour, for 5 minutes | critical |
| `DriveWearing` | A drive reports over 80% of its rated endurance used, for an hour | warning |
| `DriveUnread` | A host's smartctl_exporter has read fewer drives than it was given, for 15 minutes | warning |
| `InterfaceErrors` | An interface counts receive or transmit errors in every 10 minutes for 30 | warning |
| `RevisionBehind` | See "The wrong boot" below | warning |
| `RevisionCheckStale` | main's head was last read more than 6 hours ago, or not at all in 6 hours | warning |
| `WireGuardPeerSilent` | A WireGuard peer has not completed a handshake in 90 days | info |
| `Watchdog` | Always | none: routed to healthchecks.io only |

Where the table needed a decision:

- **`ResolverFailing`'s floor.** In the quiet hours a resolver answers 30 to
  80 queries every 15 minutes, 30 of them core5's own probes, and lifeline,
  the second resolver, little beyond the probes all day. 5% of that is two or
  three SERVFAILs, which one device retrying a broken name makes on its own.
  100 answers is above every quiet hour and below core4's busy ones, so for
  lifeline this alert is mostly its probe. Both halves leave out Unbound's
  `nodata`, which NOERROR already counts.
- **`DhcpPoolLow`** reads Kea's per-pool series, not the per-subnet ones, so a
  pool is counted once. Each segment has one pool, and a pool's count leaves
  out the reservations below it, which the subnet's includes.
- **`DiskFilling`** predicts every filesystem but tmpfs, whose few megabytes
  written to `/run` read as a steep rate; it still counts for fullness.
  `/nix/store` is the root mounted again, and is left out. The prediction
  counts only once a filesystem is over half full. A 6 hours' fit draws one
  write as a slope for as long as it stays in the window, up to 18 times
  the write over 3 days, so the upgrade to a new kernel predicted gate's
  1 GB `/boot` full from 57 MB, and lifeline's root from 2.8 GB with 48 GB
  free. Both were under a fifth full.
- **`HostHot`** has one figure, since node_exporter exports no trip points:
  75°C, under the Pis' 80°C throttle. gate's CPU throttles at 105°C, but the
  same figure stands there: its case is fanless and shares the heat with an
  NVMe drive whose own limit is 80°C, and its package peaked at 47°C in the
  week to 2026-10-13. Its other zone, `acpitz`, reads a constant 27.8°C.
- **`WireGuardPeerSilent`**, which the issue asked for beside this table. A
  peer's handshake reads 0 until it connects after gate boots, so the rule
  reads the largest value over 90 days rather than the current one: a 0
  never raises it, and any handshake in the window does. It waits until the
  store has held the peer for the whole window. Hourly, as a reminder to review
  or revoke the peer.
- **No root-device alert.** core4 and lifeline have one SD card and nothing
  to fall back to, and core5 booted wrong runs none of this. The
  running-generation half is `RevisionBehind`. It compares each host with
  main's head, read from GitHub every 30 minutes, and judges only while that
  read is under 6 hours old: a stale head would flag every host that upgraded
  past it.
- **`ScrapeDown`** is what keeps a rule from going quiet when its source
  does: with Unbound's exporter down, `ResolverFailing`'s ratio has nothing to
  read, and with Kea's, `DhcpPoolLow`. Unbound's and Kea's jobs keep
  `instance`, the host's name, so `HostDown` holds them back when the whole
  host is down. The probe jobs are judged by job alone, down when every
  target is, since every target is asked of core5's one blackbox exporter and
  probe-ping's `instance` is a public resolver's address; the alert names
  core5. A probe that fails still answers its scrape. node_exporter is
  `HostDown`'s, and the store, vmalert and Alertmanager are left out: with one
  of them down the alert is not evaluated or not delivered, and the
  watchdog's silence says so from outside. 10 minutes is past a restart; in
  the store's first 4 days, Unbound's and Kea's exporters missed two minutes'
  scrapes at most.
- **`AdGuardStatsMissing`** is its own rule rather than part of `ScrapeDown`,
  since the read reaches the store through node_exporter rather than as a
  scrape of its own, and its 30 minutes are longer: the counts feed only the
  dashboards. AdGuard not serving is the DNS probe's, in `ResolverFailing`.
- **`InterfaceErrors`** reads receive and transmit errors, frames that
  arrived damaged or could not be sent, by host and interface, and not drops,
  which count ordinary things such as frames for a protocol nothing here
  speaks. Every interface counted no errors over everything core5's store
  held on 2026-10-15, so the threshold is any error, held for 30 minutes of
  10-minute windows: a failing cable, port or driver keeps that up, and a
  link reseated or renegotiating, a burst of seconds, does not.
- **`RevisionCheckStale`** is the read of main's head failing: the 6 hours
  `RevisionBehind` judges within, one value in the rule file for both. One
  failed read is a GitHub hiccup, which is why the reading unit is not in
  `fleetAlerts.failure`; a dozen in a row are not. A failed read leaves the
  last one's file in place, which then ages. The file is in `/run`, so after
  core5 boots it is missing until a read succeeds, and missing for 6 hours
  counts the same.
- **`DriveFailing`**, **`DriveWearing`** and **`DriveUnread`** are under
  "Drive health" below.

**What none of this watches.** With core5 down, nothing here runs, and the
watchdog's silence is the one signal, from healthchecks.io, without a reason.
fleetAlerts still covers the other Pis' upgrades. Away from core5:

- **gate's own Unbound** has no exporter, and gets none. It binds loopback
  and serves gate alone, for DDNS, its rebuilds and time sync, so its failure
  is better caught by what depends on it, such as a DDNS freshness fact on
  gate, if that is ever wanted.
- **A textfile fact whose writer stops.** node_exporter serves the last file
  for as long as it is in place, so the revision, gate's WAN and WireGuard
  facts, and AdGuard's counts freeze rather than go missing. Only main's head
  carries its own read time.
- **Throughput and drops**, which the dashboards show and no rule reads.
- **The Pis' SD cards.** SD cards report no SMART or health log, so core4's
  and lifeline's roots, and core5's fallback card, have no drive health at
  all. `DiskFilling` and the wrong-boot checks are what watches them.
- **gate's NVMe drive**, until its own issue: the exporter there opens a port
  on gate, which waits for a `deploy-guard` sitting.
- **A drive that stops answering.** smartctl_exporter keeps the last good
  reading and serves it, so a drive that has dropped off its bus reads as it
  last did. On core5 that drive is the root, so `HostDown` and the watchdog
  say so instead.

## Drive health

**core5's NVMe drive reports its own health log, and two rules read it.**

On 2026-09-04 core5's NVMe drive dropped off its bus and the firmware booted
the SD card ([recovery.md](recovery.md#the-silent-wrong-boot)). That was a
loose ribbon, which no health log predicts. What the log does say is the
drive's own view of itself, which node_exporter does not read: its
temperature reaches the store through hwmon, and nothing else does.

[`modules/smartctl.nix`](../modules/smartctl.nix) runs nixpkgs'
smartctl_exporter, named the devices to read rather than scanning: on core5,
`/dev/nvme0n1`. The namespace, not the controller (`/dev/nvme0`): nixpkgs'
sandbox for the exporter is kept as it is, a dynamic user in `disk` with the
two capabilities smartctl's passthrough commands need, and its udev rule
grants the controller only when the device is added, so after the nightly
switch it would stay unreadable until a reboot. `disk` reads the namespace
already. The exporter listens on loopback, as the blackbox exporter does, and
core5 scrapes it as the `smartctl` job, with `instance` its name. A
`ScrapeDown` covers it like any other source.

**Labels.** smartctl_exporter 0.14.0 labels `smartctl_device` with the
drive's serial number, which identifies the physical drive, and labels
nothing else with an identifier: no WWN, EUI-64 or NGUID. The scrape drops any
label whose name contains `serial`, `wwn`, `eui`, `nguid` or `uuid`, which
today is `serial_number` alone, so that a later version adding one stores
nothing. Model, firmware and the kernel name (`device="nvme0n1"`) stay. The
exporter builds `device` from the path it reads, and a `/dev/disk/by-id` path
holds the serial, so the module asserts kernel names.

**The rules**, judged by the NVMe specification's meaning for each field and
by the drive's own threshold, since reading the log takes root and nothing
here has it on core5:

- **`DriveFailing`**, critical, for 5 minutes. The critical-warning field is
  a bit set, and any bit is the drive saying it is in trouble: spare under its
  threshold, temperature past its own limit, reliability degraded by media or
  internal errors, the media read-only, or its volatile backup failed.
  smartctl's SMART verdict fails on the same bits; the rule reads both, and
  spare under the threshold the drive itself reports. Media errors are
  unrecovered integrity errors, data lost, and the count a drive arrives with
  is history, so the term is the count risen above its lowest in the last
  hour, which is one push. Not `increase()`: VictoriaMetrics counts a new
  series' small first value as an increase from 0, so a drive with old errors
  would have pushed at its first scrape, which the test checks. The 5 minutes
  are for the temperature bit, which a burst of writes can set and clear.
- **`DriveWearing`**, warning, for an hour: percentage used over 80. It is the
  drive's estimate of its rated endurance used, and may pass 100 and go on
  working. 80 leaves a fifth of the rating, a quarter as long again at the
  rate that used the rest, which is years on a drive that took years to get
  there, and time to buy a replacement rather than react to `DriveFailing`.
  It only rises, so it stays firing and repeats every 30 days.
- **`DriveUnread`**, warning, for 15 minutes. The exporter publishes nothing
  for a drive it has never read, while its scrape still answers, so a sandbox
  that refuses the device would leave the two rules above and `ScrapeDown`
  quiet, and the drive would read as healthy. It does count the drives it was
  given (`smartctl_devices`), and every drive it has read has an exit status,
  so the rule compares the two by host. The 15 minutes cover a restart, which
  empties the exporter's cache until its first read.

The Fleet dashboard has the three in a row: spare beside its threshold,
endurance used, and media errors.

gate's drive is its own issue, since the exporter there opens a port on gate.
The NAS will import the same module for its disks, which first needs the
exporter on an address core5 can scrape, the way node_exporter binds, and the
assertion that holds it to the collector relaxed. Its disks are not its root,
so one that drops off its bus goes on reading as it last did, with no
`HostDown` to say otherwise; the NAS will need its own check for that.

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
`forwardRules`, matching core5's address and `ports.grafana`, and its name in
`segments.vpn.grantNames`, held by forge. The phone does not get it: it is
DNS-only as the device most likely to be lost, and the alert itself already
reaches it through ntfy. Adding it later is one word in `segments.vpn.grants`.

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
   says instead ("DNS failure ratios" above). gate's own Unbound gets no
   exporter after all: it binds loopback and serves gate alone (DDNS,
   rebuilds, time sync), so its failure is better caught by what depends on
   it, such as a DDNS freshness fact on gate, if that is ever wanted.
4. **Alert rules.** vmalert and Alertmanager on core5, the ntfy receivers, the
   watchdog check in healthchecks.io, the rule set above, the GitHub timer for
   `RevisionBehind`, and the stack's units in `fleetAlerts.failure`.
   Landed as one PR (NNO-24), with `WireGuardPeerSilent` added to the rule
   set, an `info` receiver for it, and no root-device alert ("Alerts" above
   has why). The watchdog's check appears in healthchecks.io at its first
   ping, and its period is set by hand.
5. **Retire pimon**, two weeks after 4.

Later, if wanted: **Grafana over the tunnel**, the `grafana` grant for forge
described under Access. gate alone, behind `deploy-guard`, since it changes
gate's firewall.

This file changes no host itself. The modules it links carry the details.
