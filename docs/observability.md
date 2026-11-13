# Observability

What watches the fleet, on core5, and how to operate it. The reasoning behind
it, from the choice of store to the sizing and each threshold's measurements,
is in [the design record as it last
stood](https://github.com/nnorx/nix-config/blob/cf3fa4a/docs/observability.md).

Failed and missed jobs are a separate, hosted path, `modules/alerts.nix`
(README, "Alerts"), and do not depend on anything here.

## What runs

| Service | Listens on | Port in `lib/net.nix` | Module |
|---|---|---|---|
| VictoriaMetrics, the store | core5 loopback | `victoriaMetricsStore` | `modules/metrics.nix` |
| vmauth, reads alone, in front of the store | core5 loopback | `victoriaMetrics` | `modules/metrics.nix` |
| Grafana | core5's address | `grafana` | `modules/metrics.nix`, `modules/dashboards.nix` |
| vmalert | core5 loopback | `vmalert` | `modules/alerting.nix` |
| Alertmanager | core5 loopback | `alertmanager` | `modules/alerting.nix` |
| blackbox exporter | core5 loopback | `blackboxExporter` | `modules/blackbox.nix` |
| smartctl_exporter | core5 loopback | `smartctlExporter` | `modules/smartctl.nix` |
| node_exporter | Each target's address; gate's servers gateway | `nodeExporter` | `modules/node-exporter.nix` |
| Unbound exporter | core4's and lifeline's addresses | `unboundExporter` | `modules/unbound.nix` |
| Kea exporter | gate's servers gateway | `keaExporter` | `hosts/gate/metrics.nix` |

Exporters on other hosts accept connections from core5's address alone.

The store keeps 12 months, and stops accepting samples when free space falls
under 50 GiB. Its data and Grafana's database are under `/var/lib` and are not
backed up: the dashboards and datasource are provisioned from this repo, so
losing either costs history, not configuration.

Grafana comes from `unstable`, and its migrations are one-way. Before rolling
core5 back past a Grafana upgrade, delete `/var/lib/grafana/data/grafana.db`.
Provisioning and sops recreate what it holds.

## Scrape targets

Every 30 seconds. `instance` is the host's name, or for `probe-ping` the public
resolver's address. To watch another host, add it to `metricsTargets` in
`lib/net.nix`.

| Job | Targets | Module |
|---|---|---|
| `node` | `metricsTargets`: core4, lifeline, core5, gate | `modules/node-exporter.nix` |
| `unbound` | `resolvers`: core4, lifeline | `modules/unbound.nix` |
| `kea` | gate | `hosts/gate/metrics.nix` |
| `smartctl` | core5's `/dev/nvme0n1` | `modules/smartctl.nix` |
| `probe-resolver` | Each resolver on port 53, through AdGuard, for `net.resolverProbe` | `modules/blackbox.nix` |
| `probe-ping` | `publicResolvers`, ICMP, out through gate | `modules/blackbox.nix` |
| `victoriametrics`, `vmalert`, `alertmanager` | Themselves | `modules/metrics.nix`, `modules/alerting.nix` |

Facts no exporter has reach the store through node_exporter's textfile
collector, from `/run/fleet-metrics`:

| Metrics | Host | Written by | Every |
|---|---|---|---|
| `fleet_revision_info`, `fleet_root_device_info` | Every target | `fleet-metrics-facts` | 5 minutes |
| `fleet_wan_addresses`, `fleet_wan_lease_remaining_seconds`, `fleet_wan_default_routes`, `fleet_wireguard_last_handshake_timestamp_seconds` | gate | `gate-metrics-facts` | 30 seconds |
| `fleet_adguard_*`, from AdGuard's statistics and query log | core4, lifeline | `adguard-metrics` | 30 seconds |
| `fleet_main_revision_info`, `fleet_main_revision_checked_timestamp_seconds` | core5 | `fleet-main-revision`, `git ls-remote` against main | 30 minutes |

Metrics carry totals and names, never a client, a domain, a MAC address or a
drive's serial number. The scrape drops the last two, and AdGuard's leave out
the work segment (`tests/dns-metrics.nix`).

## Dashboards

Provisioned from `modules/dashboards.nix`, never edited in the UI.
`tests/grafana.nix` runs every panel's queries against the store.

| Dashboard | Answers |
|---|---|
| Fleet | Each host up and what it runs, CPU, memory, disk, temperature, network, public resolvers, drive health |
| DNS | Queries, blocked, SERVFAIL, timeouts, cache hits, latency, DNSSEC failures, sources up, resolvers answering core5 |
| DHCP | Pool used per segment, leases, messages, trouble, reclaimed leases, the exporter |
| Alerting | Firing and pending alerts, and the stack from rule evaluation to delivery, store ingest and scrapes |

`Watchdog` is left off Alerting's tables, since it always fires. A silenced
alert still shows as firing there: silences are Alertmanager's.

## Access

- **Grafana**, at core5's address on `ports.grafana`, from trusted and servers.
- **vmui**, for ad hoc queries: `ssh -L <port>:127.0.0.1:<port> core5` with
  `ports.victoriaMetrics`, then `http://localhost:<port>/vmui`. vmauth passes
  queries, series, labels, the status pages and vmui, and refuses the rest.
- **The `diag` login** queries the store through vmauth from `fleet-ssh core5`.
  It cannot reach the store's own port, vmalert, Alertmanager or the blackbox
  exporter (`modules/diag-login.nix`).
- **Admin paths** (deleting series, snapshots) take the key core5 makes at boot,
  at the store's own port, as root. `modules/metrics.nix` has the delete command.

Queries for Grafana's Explore view:

```
up{job="node"}                                              # 1 per host scraped
fleet_revision_info                                         # each host's revision
fleet_root_device_info                                      # each host's root device
node_network_carrier{instance="gate",device="wan"}          # 1 while the link is up
fleet_wan_addresses                                         # 1 while wan holds a lease
time() - fleet_wireguard_last_handshake_timestamp_seconds   # seconds since each handshake
```

A handshake timestamp of 0 means none since `wg0` came up, so its age reads as
decades.

## Alerts

```
exporters ──scrape──► VictoriaMetrics ◄──query── vmalert ──► Alertmanager
                                                                  │
            ntfy.sh topic ◄── webhook, ?template=alertmanager ────┤
            hc-ping.com   ◄── Watchdog, every 5 minutes ──────────┘
```

Rules are in `modules/alert-rules.nix`, each with its reasons in the comment
beside it, and `tests/alert-rules.nix` checks each against series of its own.
Every label and annotation leaves the house in the push, so a rule names things
and never quotes an address, a serial number or a value.

- **Priority.** `critical` is high in ntfy, `warning` the default, `info` low.
- **One push per incident.** Alertmanager groups by alert name and waits 30
  seconds, so one fault on several hosts is one push. A host joining later is a
  new push, at the next 5-minute flush. There is no resolved message, and no
  repeat until the same alerts have fired for 30 days. Restarting vmalert or
  Alertmanager sends nothing again (`tests/alerting.nix`).
- **Held back.** `HostDown` holds every other alert about the same host, and
  `WanDown` holds `ResolverFailing`.
- **The stack failing to start** (`victoriametrics`, `vmauth`, `vmalert`,
  `alertmanager`, `grafana`) pushes through `fleetAlerts.failure`, which does not
  depend on any of it.

### When one fires

For anything on a host, `fleet-ssh <host> host-status` is the first question: its
revision, root device, last upgrade and failed units.

| Alert | Fires when | Severity | First look |
|---|---|---|---|
| `HostDown` | A host's node_exporter scrape is 0 for 5 minutes | critical | `host-status`. No answer: power and link, then [recovery.md](recovery.md). Answering with no exporter: a generation older than node_exporter, so check its root device |
| `ScrapeDown` | Any other scrape but the stack's own is 0 for 10 minutes, or every target of a probe job | warning | `systemctl status prometheus-<job>-exporter` on that host; the blackbox exporter for a probe job, on core5 |
| `WanDown` | gate's `wan` has no carrier, no lease or no default route, or both public resolvers fail pings, for 2 minutes | critical | The queries above show which. It arrives once the WAN is back, so it is often history, and the Watchdog's silence is what reaches the phone on time |
| `ResolverFailing` | A resolver fails its probe, or over 5% of at least 100 answers in 15 minutes are SERVFAIL, for 5 minutes | critical | DNS dashboard: answering, then SERVFAIL. `systemctl status adguardhome unbound` on the host |
| `AdGuardStatsMissing` | `fleet_adguard_up` is 0 for 30 minutes | warning | `journalctl -u adguard-metrics` on the host. DNS works; `SecurityListBlocked` is blind |
| `SecurityListBlocked` | A security list blocked a lookup within 15 minutes | warning | Its query log |
| `ConntrackPressure` | gate's table is over 80% of its limit for 10 minutes | warning | Fleet dashboard, Network: what is suddenly busy |
| `DhcpPoolLow` | A segment's pool is over 90% leased for 15 minutes | warning | DHCP dashboard. Widen the pool in `lib/net.nix`, or find what is taking leases |
| `DiskFilling` | A filesystem is over 85% full, or over half full and predicted full in 3 days, for an hour | warning | `df -h` on the host |
| `HostHot` | A thermal zone is above 75°C for 15 minutes | warning | Fleet dashboard. Airflow and load |
| `DriveFailing` | A critical warning, a failed SMART verdict, spare under the drive's threshold, or a new media error, for 5 minutes | critical | Fleet dashboard, drive panels. Treat it as failing: check the off-box backups, then replace it |
| `DriveWearing` | Over 80% of rated endurance used, for an hour | warning | Buy a replacement. It stays firing, and repeats every 30 days |
| `DriveUnread` | smartctl_exporter has read fewer drives than it was given, for 15 minutes | warning | `journalctl -u prometheus-smartctl-exporter` on core5 |
| `InterfaceErrors` | Receive or transmit errors in every 10 minutes for 30 | warning | Fleet dashboard, Network. Cable, port, driver |
| `RevisionBehind` | A Pi differs from main's head for 36 hours, gate for 7 days | warning | `host-status`, for the last upgrade. On a Pi, `journalctl -u nixos-upgrade`. On gate, deploy it |
| `RevisionCheckStale` | main's head unread for 6 hours | warning | `journalctl -u fleet-main-revision` on core5. `RevisionBehind` judges no host until it clears |
| `WireGuardPeerSilent` | A peer has not connected in 90 days | info | Review it, or revoke it in `lib/wireguard-keys.nix` |
| `Watchdog` | Always | none | Routed to healthchecks.io alone, below |

`Watchdog` pings healthchecks.io every 5 minutes as `core5-metrics-watchdog`. When
the pings stop, healthchecks.io pushes through the same topic from outside the
house, without a reason: core5 is off or out of disk, or the path from scrape to
delivery is broken somewhere. With core5 down this is the one signal. Start with
`fleet-ssh core5 host-status`, then the Alerting dashboard. The check appears at
its first ping with the one-day default; set its period to 15 minutes and its
grace to 5, which a ping cannot do.

## CVE scan

Every Tuesday forge scans main (`hosts/forge/cve-scan.nix`), keeps the report
in `~/.local/state/cve-scan/`, and pushes the configs whose count of visible
findings changed, or "scan failed" after two tries.

## Secrets

**Grafana's `admin` password** is in sops on core5, and evaluation fails without
it. Grafana reads it once, when it creates the account on first start, so later
changes go through Grafana's own profile page and then the secret to match. From
the repo, in your own terminal, with the password at the prompt:

```bash
read -rs pw
printf '%s' "$pw" | jq -R . | sops set --value-stdin secrets/core5.yaml '["grafana-admin-password"]'
unset pw
```

**The `metrics` login** is how `adguard-metrics` reads AdGuard. Its password
and bcrypt hash are a pair in each resolver's sops file,
`adguard-metrics-password` and `adguard-metrics-hash`, and evaluation fails until
both are there. To make both, inside
`nix shell nixpkgs#sops nixpkgs#jq nixpkgs#openssl nixpkgs#apacheHttpd`:

```bash
for h in core4 lifeline; do
  pw=$(openssl rand -hex 32)
  printf '"%s"' "$pw" | sops set --value-stdin secrets/$h.yaml '["adguard-metrics-password"]'
  printf %s "$pw" | htpasswd -niBC 10 metrics | cut -d: -f2- | tr -d '\n' | jq -R . | sops set --value-stdin secrets/$h.yaml '["adguard-metrics-hash"]'
done; unset pw h
```

To check each pair without printing either half. The hash must be 60 bytes
exactly: sops splices it into AdGuard's configuration, and a stray newline or
quote would stop AdGuard from starting.

```bash
for h in core4 lifeline; do
  hash=$(sops decrypt --extract '["adguard-metrics-hash"]' secrets/$h.yaml)
  n=$(sops decrypt --extract '["adguard-metrics-hash"]' secrets/$h.yaml | wc -c)
  [[ $n -eq 60 && $hash =~ '^\$2y\$10\$[./A-Za-z0-9]{53}$' ]] && echo "$h: hash shape ok" || echo "$h: hash shape BAD"
  sops decrypt --extract '["adguard-metrics-password"]' secrets/$h.yaml | htpasswd -vi =(printf 'metrics:%s\n' "$hash") metrics >/dev/null 2>&1 && echo "$h: pair matches" || echo "$h: pair MISMATCH"
done; unset hash n h
```
