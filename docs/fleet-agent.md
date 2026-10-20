# The fleet agent

A decision record. Nothing in it is built. It settles how an agent answers
an alert with a diagnosis, read-only by construction, so that the milestone
issues at the end build it rather than re-argue it.

## The question

An alert reaches the phone as a name, a host and a one-line summary
([observability.md](observability.md), "Alerts"). Finding the cause takes a
terminal: `fleet-ssh <host> host-status`, a few queries against core5's
VictoriaMetrics, the journal of a unit or two. The night shift
([night-shift.md](night-shift.md)) already runs Claude Code agents
unattended, but on forge alone, and only while it is awake, logged in and on
AC.

The store's own history shows what that work is. In the 14 days to
2026-10-17 two alerts fired, beside the always-firing `Watchdog` (read from
the `ALERTS` series vmalert writes to the store): `DiskFilling` on gate and on
lifeline. Both were false predictions. A 6-hour fit had drawn one write, a
kernel upgrade's, as a steady slope, and #205 fixed the rule. Everything that
diagnosis needed was in the metrics around the alert and the upgrade's
timing, and none of it needed a shell or a write. That is the work this agent
is for: read the alert, read what surrounds it, say what it most likely is
and what Nick should look at.

## In short

| | Decision |
|---|---|
| Trigger | Poll Alertmanager's alert groups on core5 every 2 minutes, over the same read-only login as every other tool. No webhook and no new listener |
| Which alerts | `critical` and `warning`, active, neither inhibited nor silenced. Not `info`, not `Watchdog` |
| Limits | One run at a time. One run per alert and host per 6 hours, 8 runs a day, 10 minutes and 25 tool calls a run |
| Output | A follow-up ntfy push on the same topic at low priority, rendered from a structured answer and masked. The full report in a local file. No Linear drafts |
| Where | forge first, by hand, then on a timer while awake. Then a Raspberry Pi of its own, always on ([nas.md](nas.md)). Never core5, gate or the NAS |
| Tools | host-status, unit state, boots and journals on every host; metrics and alerts on core5. Through a forced command, `triage-agent`, on a login of its own, `triage`, with a key of its own |
| VictoriaMetrics | Through that forced command on core5. It stays on loopback |
| Untrusted text | Kept from the model at the source: journals that carry text a device chose arrive as counts, never lines. Everything is masked on the host, and again before the push |
| Harness | Claude Code headless, restricted to no built-in tools and the fleet's own MCP tools, which the wrapper checks before the run goes on |
| Credentials | On forge, Nick's existing Claude login and a new SSH key. On its Pi, an API key in a workspace of its own with a spend limit, in sops |
| Phone | Later: a page on its Pi, reached through the tunnel, behind a new port and a new grant |

## A run, end to end

```
core5:   vmalert ──► Alertmanager ─── push, as today ─────────────► phone
                         ▲
                         │ triage@core5 alerts, every 2 minutes
                         │
forge or its Pi:       poller ──► claude -p ──► triage-tools ──► triage@<host>
                         │        no built-in   MCP, stdio       masked there
                         │        tools
                         └──► mask, render ──► push, low priority ───► phone
                                    └────────► report, kept locally
```

1. The poller asks core5 for Alertmanager's active alert groups and finds one
   it has not triaged.
2. It starts `claude -p` with the alert as its only input, and the fleet's
   tools as its only tools.
3. The model calls those tools. Each becomes `ssh triage@<host> <verb>`, and
   the host runs the verb, masks its output and returns it.
4. The model answers in a fixed JSON shape. The poller checks it, masks it
   again, renders the push from it and writes the report.

## Trigger

### Poll, not a webhook

**The poller reads Alertmanager's `/api/v2/alerts/groups` through the forced
command on core5.** A webhook receiver beside the ntfy ones was the other
option, and loses on four counts:

- **It needs a listener.** A webhook needs a port on the agent's host, in
  `lib/net.nix`, opened to core5 in that host's firewall, and anything else
  that reaches the port can post an alert of its own choosing, starting runs
  and pushes, unless the receiver authenticates it. A poll reads alerts from
  Alertmanager itself, so every alert it sees is real.
- **It points the wrong way.** core5 would dial the agent's host, which on
  forge is a laptop that sleeps and travels. Alertmanager would retry into
  the void, and an alert that fired while forge slept would be lost rather
  than seen on waking. A poll sees whatever is still firing when it asks.
- **It is one more path.** Every other tool already reaches core5 through the
  `triage` login, so the poll adds no credential, port or rule.
- **Latency does not matter.** The alert's own push is the alarm, and it goes
  out as it does today. The diagnosis follows it, and a few minutes later is
  as good.

Alertmanager's groups are its routing: one group per alert name, the same
grouping the ntfy push uses (`group_by = [ "alertname" ]` in
`modules/alerting.nix`), with each group's receiver named. So a run per group
matches a push per incident without the poller rebuilding the grouping.

Every 2 minutes, inside a group's 5-minute flush. That is about 720 short
logins a day on core5, a few journal lines each, well inside journald's
200 MB cap (`modules/baseline.nix`).

### Which alerts

Groups whose receiver is `critical` or `warning`, and in them the alerts
whose state is `active`. `info` is `WireGuardPeerSilent`, a reminder with
nothing to diagnose, and `Watchdog` always fires. An alert another holds back
is `suppressed`, not active, and is skipped: `HostDown` inhibits every other
alert about its host, so a host that is down gets one run, for `HostDown`,
which covers the rest.

An alert first seen more than 6 hours after it started is skipped too. Its
push went out long before, forge was asleep or away, and Nick can run
`triage` on it by hand.

### Grouping and limits

An alert is identified by Alertmanager's fingerprint, a hash of its labels,
and its `startsAt`, so a firing that resolves and fires again is a new one.
The poller keeps the identities it has triaged, and the time of each run, in
a state file, for 31 days, past Alertmanager's 30-day repeat.

- **One run per group, once it has settled.** The poller waits until the
  newest alert in a group is a minute old, past Alertmanager's 30-second
  `group_wait`, so that a fault on several hosts at once is one run that sees
  all of them.
- **One run per alert name and host per 6 hours.** A flapping alert gets a
  new `startsAt` each time it fires, so identity alone would start a run per
  flap. A host joining a group within its 6 hours is noted in the next run
  rather than starting one.
- **One run at a time**, by a lock. The next group waits for it.
- **8 runs a day.** Past that, one push says triage is paused until midnight,
  and nothing more is sent. Two firings in two weeks is the history so far,
  so the cap is for a bad night, not for a normal one.

### When core5 itself goes quiet

core5 is the host whose failure matters most, and the one that cannot alert
about itself: the `Watchdog`'s silence arrives from healthchecks.io with no
reason attached. When the poll fails for 10 minutes while gate or lifeline
still answer `status`, the poller runs one triage for core5 itself, once per
outage, with what still works. The tool reports how core5 failed, which
already says a lot:

| core5's answer | Reads as |
|---|---|
| No route, or the connection times out | Off, or off the network |
| Connection refused | Up, with sshd not running |
| Login refused | Up on a generation without the `triage` login, as its SD-card fallback would be ([recovery.md](recovery.md#the-silent-wrong-boot)), or its key revoked |
| Logged in, but `alerts` fails | The stack is down; `status` and the units say which part |

If nothing answers, forge is away with its tunnel down, or the house is
offline, and the poller does nothing.

### Time

10 minutes a run, from start to push, enforced by the poller, which kills the
run and pushes one line saying there is no diagnosis. 30 seconds and 16 KB
of output a tool call, and 25 tool calls a run, enforced by the tool server,
which refuses the 26th. The first milestone measures how long runs take, and
these move with what it finds.

## Output

### The push

**A follow-up on the same ntfy topic, at priority 2 (low), so it arrives
silently under the alert that woke Nick.** Rendered by the poller from the
model's structured answer, never written by the model as a message:

```json
{
  "cause": "one or two sentences, at most 280 characters",
  "confidence": "low | medium | high",
  "seen": ["at most 3 lines of evidence, 120 characters each"],
  "check": [
    {
      "host": "lifeline",
      "what": "status | unit | journal | dashboard",
      "unit": "...",
      "dashboard": "Fleet | DNS"
    }
  ]
}
```

Claude Code holds the answer to the schema (`--json-schema`). The poller then
checks each field: `host` is a name in `lib/net.nix`; a `unit` has a unit's
shape and was named by one of this run's own tool results; at most 3 checks.
Each check renders from a fixed template, so the push can name no command
but these:

| `what` | Renders as |
|---|---|
| `status` | `fleet-ssh <host> host-status` |
| `unit` | `fleet-ssh <host> systemctl status <unit>` |
| `journal` | `fleet-ssh <host> journalctl -u <unit> -b -n 50` |
| `dashboard` | `Grafana: <Fleet or DNS>` |

An illustration, from the `DiskFilling` firing on lifeline that #205 fixed:

```
Triage: DiskFilling on lifeline
Likely: a false prediction. / is under a fifth full, and the 6-hour fit drew
the nightly upgrade's one write as a steady slope. (high)
Seen: / +2.8 GB during the upgrade, flat since. 48 GB free.
Check: fleet-ssh lifeline host-status
```

A diagnosis is advice. The alert is the fact, and the push says "Likely" for
that reason.

### The report

Each run writes `~/.local/state/fleet-agent/<startsAt>-<alertname>.md` on the
host that ran it, outside every repository: the alert, every tool call and
its masked result, the answer, the push as sent, and the run's tokens, cost
and time. It is where Nick checks why a diagnosis said what it did. Kept for
30 days. Claude Code's own session is not kept (`--no-session-persistence`),
since the report holds everything it would.

### Not a Linear draft

A draft in `.git/linear-handoff/` would be a write into a repository, and the
night shift's task queue begins there: Nick files drafts as himself, and the
night shift later works filed issues as his tasks. A draft written by a
model that read the journals is a path from text on the network into that
queue, and Nick's reading of each draft should not be all that stands
between the two. Most diagnoses are also transient, a host that rebooted or
a false prediction, and a draft for each would fill the backlog. When a
diagnosis says the repo needs a change, the report says so, and Nick asks an
interactive session for the draft.

## Where it runs

**What it needs** is small. A Claude Code process, which milestone 1 measures
rather than this record guessing; outbound HTTPS to Anthropic's API and to
ntfy.sh; SSH to each fleet host; a few megabytes of state. No builds, no
checkout, no listener.

| Host | |
|---|---|
| **forge** | **First.** Has Claude Code, Nick's login, and SSH to every host at home (trusted reaches servers) and away (its `ssh` grant in `hosts/gate/wireguard.nix`). It sleeps, travels, and is down whenever its lid is shut, so it can only ever be the first home |
| **Its own Pi** | **The long-term home**: a Raspberry Pi 5 (8 GB), built like core5, always on, on servers, where it reaches every host's SSH directly, and holding no personal data ([nas.md](nas.md), "The fleet agent's Pi") |
| The NAS | No. It holds every irreplaceable file the house has, so it runs nothing model-driven ([nas.md](nas.md), "Roles") |
| core5 | No. It runs the alerting, so when it fails the agent fails with it, and it is the host whose failure most needs explaining |
| gate | No. The router deploys by hand, has no fallback, and should not hold an API key or run a model's tool calls |
| core4, lifeline | No. They are always on and could run it, but they are the house's DNS, on SD cards, and deploy unattended every night |

A first version on forge needs nothing new on forge but the command, and
nothing on any host but the login. Milestones 1 and 2 are that.

**Alone on its Pi.** The night shift stays on forge, and later moves to an
agents box rather than here ([nas.md](nas.md)), so no preflight shares the
Pi's 8 GB. The agent's unit still gets a `MemoryMax`, so a run that
misbehaves cannot take the host.

**DNS.** A run calls Anthropic's API and ntfy.sh by name, and
`ResolverFailing` on both resolvers is an incident it should explain. On its
Pi the agent's unit resolves through `net.publicResolvers`, as core5 does
for the same reason (network.md, on pimon), with a `resolv.conf` of its own
bound into the unit if the Pi itself uses the fleet's resolvers. On forge,
both resolvers failing at home leaves the run unable to start, which is a
limit of milestone 2.

## Tools

### The triage login

**A login of its own on every fleet host, `triage`, whose key runs one forced
command, `triage-agent`, and nothing else.** The same construction as the
Pis' deploy login (`modules/deploy-agent.nix`), and for the same reason: an
instruction in a prompt is not enforcement, and a forced command is.

- `modules/triage-agent.nix`, imported from `hosts/common/default.nix`, so
  core4, lifeline, core5 and gate all get it. forge is not a fleet host and
  needs none.
- `users.users.triage`: a system user, not in `wheel`, so no sudo, and in
  `systemd-journal`, to read journals. Its shell is bash, since sshd runs a
  forced command through the login shell, as deploy-agent's comment says.
- Its keys, in a new `lib/triage-keys.nix`, one per machine that runs the
  agent, each generated on its machine: `~/.ssh/id_ed25519_triage` on forge,
  later its Pi's. `flake.nix` passes them as `triagePubKeys`, beside
  `deployPubKeys`. Each is written
  `restrict,command="/run/current-system/sw/bin/triage-agent" <key>`:
  no pty, no forwarding of any kind, no agent, no `~/.ssh/rc`. `restrict`
  matters most for port forwarding, which would otherwise hand the key
  VictoriaMetrics' whole API on core5's loopback.
- `services.openssh.settings.AllowUsers` gains `triage`, merging with the
  host's own user and `deploy` as deploy-agent's entry does.
- A separate key, because sshd tells logins apart by key: `id_ed25519_pis`
  opens Nick's shell on every host, and the triage key opens only this.

`triage-agent` reads `SSH_ORIGINAL_COMMAND` as words, never through a shell,
checks every word against a pattern, and exits 64 on anything else. PromQL
arrives on stdin, at most 4 KB, so no quoting ever reaches a shell. Its
verbs:

| Verb | Hosts | Returns |
|---|---|---|
| `status` | every host | host-status's lines |
| `unit <unit>` | every host | `ActiveState`, `SubState`, `Result`, `NRestarts`, `ExecMainStatus` and the last entry to and exit from active, from `systemctl show` |
| `boots` | every host | The last 10 boots' first and last entry times, from `journalctl --list-boots` |
| `journal <unit or kernel> <since> <until> [<boot>]` | every host | Lines or counts, below. A window of at most 24 hours inside the last 31 days (journald keeps a month), at most 200 lines |
| `query <time>` | core5 | VictoriaMetrics' `/api/v1/query`, PromQL on stdin |
| `range <start> <end> <step>` | core5 | `/api/v1/query_range`: at most 7 days a window, anywhere in the store's 12 months, 500 points a series and 50 series |
| `alerts` | core5 | Alertmanager's `/api/v2/alerts/groups`, active alerts only |

Every verb's output passes through the mask (below) before it leaves the
host. Every one is a read: `systemctl show` and `journalctl` need no
privilege beyond the group, and the core5 verbs build their URLs themselves
and use only GET, so the caller chooses a query, never a path.

### Journals: lines or counts

**A unit's lines reach the model only if the unit's messages are written by
the fleet's own software about itself. Every other unit's journal arrives as
counts.** The list is in Nix, beside the module, per host:

- **Lines**, masked: `nixos-upgrade`, the exporters
  (`prometheus-*-exporter`), `victoriametrics`, `vmalert`, `alertmanager`,
  the fleet's textfile writers (`fleet-*`), the off-box pushes,
  `deploy-agent-*` and `deploy-guard`.
- **Counts**, for everything else, the kernel included: the number of lines
  at each priority in the window, and the number matching each of a fixed
  set of patterns kept beside the unit in Nix. Kea's allocation failures,
  Unbound's `SERVFAIL` and validation failures, sshd's failed and accepted
  logins, gate's WAN DHCP client's leases, refusals and failed renewals, the
  kernel's out-of-memory kills, under-voltage, throttling, I/O errors, NVMe
  resets and link changes. Counts say what kind of thing happened and how
  often, and carry no text.

gate's WAN DHCP client is software of the fleet's own, but it logs what the
ISP's server sends, such as the message that comes with a refusal. That
server is outside the house, so its journal is counted, like any other whose
text someone else chose.

### Metrics and alerts through core5's forced command

VictoriaMetrics, vmalert and Alertmanager listen on core5's loopback
(`vmAddress` in `modules/metrics.nix`), and they stay there.

- **A new listener, with a firewall rule to the agent's host**, was the
  alternative. Single-node VictoriaMetrics has no authentication, and its
  HTTP API also takes writes (`/api/v1/import`, the remote-write and Influx
  endpoints) and deletions (`/api/v1/admin/tsdb/delete_series`), so opening
  the port opens those to whatever reaches it. vmauth could front it with a
  read-only path list, but that is another service, a port in `lib/net.nix`,
  a rule on core5's interface and a token in two sops files, and it covers
  neither Alertmanager nor the journals.
- **Grafana's datasource proxy**, with a viewer token, was the other. It
  reaches the store from the network today, but the token reads every
  dashboard, is one more credential to keep, and covers metrics alone.
- **The forced command** covers all of it with the login every other tool
  already needs, adds no port or rule, and keeps the allowlist in one script.
  Chosen.

### The client side

On the host that runs the agent, the model's tools are an MCP server,
`triage-tools`, registered as `triage` and started by Claude Code over
stdio. The MCP Python SDK is in nixpkgs (1.26.0 at this lock). Its tools are
the verbs above, each with the host as an argument chosen from
`lib/net.nix`'s names. Each call becomes

```
ssh -F /dev/null -i ~/.ssh/id_ed25519_triage -o IdentitiesOnly=yes \
    -o BatchMode=yes -o ConnectTimeout=10 -o ClearAllForwardings=yes \
    -o ProxyCommand=none -o PermitLocalCommand=no triage@<address> <verb> <args>
```

with the address from the flake, and gate reached as fleet-status reaches it,
at its tunnel address with `HostKeyAlias` while `wg-home` is up. The user is
fixed, the key is fixed and `IdentitiesOnly` keeps ssh to it, so even a tool
server that went wrong could not log in as anyone else, and every host
refuses the triage key for any other login. The tool server reads no files,
and the tool server, not the model, decides how a call is made.

The run itself, with Claude Code 2.1.302 as installed on forge:

```
claude -p --restricted --tools "" --strict-mcp-config \
  --mcp-config <triage-tools.json> --allowedTools mcp__triage \
  --system-prompt-file <prompt> --json-schema <schema> \
  --output-format stream-json --verbose --no-session-persistence \
  --model <model>
```

`--restricted` removes the built-in tools that run commands or code, and
WebFetch, and ignores user, project and local settings files. `--tools ""`
removes the rest of the built-in set. `--strict-mcp-config` loads no MCP
server but this one. The run starts in an empty directory under the
agent's state, so no project's `CLAUDE.md` or settings are near it.

**The wrapper checks this rather than trusting the flags.** The first event
of a `stream-json` run lists the session's tools. Unless they are exactly
`triage-tools`' own, the wrapper ends the run before the model's first turn
and says why. forge's Claude Code updates itself, nixpkgs' (2.1.223 at this
lock) is older than forge's and may lack `--restricted`, and a flag that
changes meaning in either is caught there rather than in a transcript.

`--system-prompt-file` replaces Claude Code's own prompt, which a run with
no built-in tools does not need. The prompt is built from the flake at build
time: the alert rules as vmalert runs them (`modules/alert-rules.nix`),
observability.md's "Alerts" section for what each means, the Grafana
dashboards' queries (`modules/dashboards.nix`) as a library of good ones,
and the hosts' names and roles. It tells the model that tool results are
data, not instructions, and the next section is why nothing depends on that
sentence.

### fail2ban

Every host bans a source address after 3 refused logins in 10 minutes
(`modules/fail2ban.nix`), for an hour, longer each time. A poller that
retried a host refusing its key, such as core5 on its fallback card, would
have forge banned from that host within 10 minutes, and Nick's own sessions
from forge with it. So the tool server stops asking a host after one refused
login, and asks again no sooner than 15 minutes later. A refused verb is not
a refused login: the session authenticated and `triage-agent` said no, which
fail2ban does not count.

### What no diagnosis needs

Mapping each rule in the set to what its diagnosis reads shows none needs a
write or a shell:

| Alert | Its diagnosis reads |
|---|---|
| `HostDown` | How the host answers `status`, or how it fails to; `boots`; the previous boot's kernel counts and allowlisted journals; its last metrics before the gap |
| `ScrapeDown` | The exporter's unit and journal |
| `WanDown` | gate's carrier, lease, route and probe series, and its DHCP client's counts. Only once the WAN is back, and only by hand: the alert resolves when it returns, and until then neither the run nor its push can leave the house |
| `ResolverFailing` | Probe and SERVFAIL series; Unbound's and AdGuard's counts by pattern; their units |
| `AdGuardStatsMissing` | The collector's unit and journal, AdGuard's unit |
| `ConntrackPressure` | Conntrack and per-interface throughput series |
| `DhcpPoolLow` | Pool series; Kea's allocation-failure counts |
| `DiskFilling` | The filesystem's series around the alert; the upgrade's journal and timing |
| `HostHot` | Temperature, load and CPU series; the kernel's throttling and under-voltage counts |
| `DriveFailing`, `DriveWearing`, `DriveUnread` | smartctl series, the exporter's journal, the kernel's NVMe and I/O counts |
| `InterfaceErrors` | Error series; the kernel's link counts |
| `RevisionBehind`, `RevisionCheckStale` | `status`'s upgrade line, `boots`, the upgrade's and `fleet-main-revision`'s journals |

Some questions need root to answer, such as what under `/var/lib` grew. The
diagnosis says that is the question, and Nick answers it from his own shell.
A verb that ran as root over a path the caller chose would make the triage
key a way to read the host as root, which is the opposite of this design.

## Untrusted input

### Where text a device chose lives

Anything on the network can choose some of the text the fleet records: a
DHCP hostname, a DNS query name, an HTTP user agent or path, an SSH user
name, a Home Assistant device or entity name, an SSID. Any of it can read as
instructions. The design keeps it from the model, rather than asking the
model to ignore it:

| Text | Where it is recorded | What reaches the model |
|---|---|---|
| DNS query names | AdGuard's query log file; Unbound's and AdGuard's journals | Nothing from the file, which no verb reads. Counts from the journals |
| DHCP hostnames, MACs | Kea's lease file and journal | Nothing from the file. Counts from the journal. Kea's exporter labels carry pools, never leases |
| HTTP user agents and paths | Grafana's, Home Assistant's and the UniFi containers' journals | Counts |
| SSH user names, source addresses | sshd's journal | Counts |
| Home Assistant names | Its journal and database | Counts from the journal. It is not scraped |
| SSIDs | The UniFi controller | Counts from its containers' journals |
| What the ISP's DHCP server sends | gate's WAN DHCP client's journal | Counts |
| Alert labels and annotations | `modules/alert-rules.nix` | Held by the rules to names and fixed text already, since they go out in today's push |

What remains is masked lines from the fleet's own software, metrics whose
labels the scrape already holds to names (observability.md, "What leaves
the house"), and host-status's fixed fields.

### The mask

**One program, `fleet-mask`, generated from `lib/net.nix`, run three times:
on the host before a verb's output leaves it, in the tool server before a
result reaches the model, and in the poller before the push leaves the
house.** CLAUDE.md's rules for transcripts apply to all three: everything
the model sees is sent to Anthropic's API, as in any Claude session, and the
push goes to ntfy.sh.

- **IPv4.** A fleet host's address becomes its name, gate's gateways become
  `gate`, and any other address in a segment becomes the segment's name in
  brackets (`<iot>`). The public addresses the repo already names
  (`publicResolvers`, `encryptedResolvers`, `rootZoneSources`) stay. Every
  other address becomes `<addr>`, which is where the WAN address goes.
- **IPv6.** Every address becomes `<v6>`, and a link-local one, or any with
  `ff:fe` in its interface identifier, `<v6-link-local>`, since EUI-64 embeds
  the MAC.
- **MACs**, in colon, dash, dot and bare 12-hex forms: `<mac>`. node_exporter's
  `broadcast` label has this shape too.
- **URLs**, whole: `<url>`. **Domain names**, labels joined by dots and ending
  in a letter: `<name>`, which covers the DDNS hostname and every query name,
  with a short list of the fleet's own services (the caches, github.com,
  ntfy.sh) kept.
- **Tokens.** Runs of 20 or more characters of base64 or hex that mix letters
  and digits become `<token>`, which covers the ntfy topic, ping keys and
  WireGuard keys if a log line ever carries one. A store path keeps its name
  and loses its hash; host-status's revision, a 40-character commit, stays.
- **Email addresses**: `<email>`.

A fixture of lines with every shape is checked in milestone 1's tests, so a
rule that stops matching fails CI rather than leaking.

### What a push may carry

Names from `lib/net.nix`, alert names, unit names a tool result named,
mountpoints and segments, numbers, times, and short prose. Never a log line
quoted, a command beyond the four templates, a URL, a code span, or anything
the mask replaced. The poller removes code spans and URLs, masks, and
truncates each field to its length before rendering, so a model that tried
to put a command on Nick's phone would produce a shorter sentence instead.

### What injection can still do

With tools that only read, and text from devices kept out, the worst left is
a misleading diagnosis or a wasted run:

- **Mislead.** A line in an allowlisted unit's journal is written by the
  fleet's software, but can quote something from outside, such as an error
  from a server. The model could repeat it as a cause. It reaches the phone
  as at most 280 masked characters beside an alert that states the fact,
  and the report shows which tool result it came from.
- **Spend.** It could make the model call tools until the limits stop it:
  25 calls, 10 minutes, the day's 8 runs and the API key's spend limit.
- **Leak.** A tool's arguments go to the fleet's own forced commands, the
  model has no tool that reaches anywhere else, and every result is masked
  before the model sees it. What could leave is what the mask let through,
  which is the mask's test fixture's job.

## Credentials

### The harness: Claude Code headless

**Claude Code's `-p` mode, with the flags above, on both hosts.** The same
invocation runs under Nick's subscription on forge and under an API key on
its Pi, so milestone 1's diagnoses are the Pi's diagnoses.

- **The Claude Agent SDK** is the same harness as a library, with the same
  built-in tools to switch off. It would buy control flow this does not need,
  one prompt and one answer, at the cost of a Python or TypeScript program
  to package.
- **The Messages API with the SDK's tool runner** has the smallest surface:
  no built-in tools exist to switch off, and no settings scopes, plugins or
  auto-updater come with it. It takes an API key alone, so milestone 1 would
  need one from its first run. It is what this moves to if the wrapper's
  tool check ever fails on a Claude Code update.

### forge: Nick's subscription

Milestones 1 and 2 run under the login Claude Code already has on forge.
Nothing new is stored. A run costs no money and counts against the plan's usage limits,
shared with Nick's own sessions and the night shift. At about 120,000 tokens
processed, most of them cache reads, a run is small beside a night-shift
task.

The triage key on forge gets a passphrase and is loaded with the others
after a boot (`ssh-add ~/.ssh/id_ed25519_pis ~/.ssh/id_ed25519_deploy
~/.ssh/id_ed25519_triage`), so the file alone opens nothing. The timer of
milestone 2 then runs only once Nick has loaded it, as after every boot.

### Its Pi: an API key

A server should not hold Nick's personal login, which acts as him across the
whole plan. The Pi gets an API key instead:

- **In a workspace of its own**, in the Anthropic Console, with a monthly
  spend limit, so the key can spend that much and reach nothing else: the
  workspace holds no files and no batches.
- **In sops**, as `anthropic-api-key` in the Pi's secrets file, beside
  `ntfy-url`, owned by the agent's system user and handed to the unit as a
  systemd credential.
- **Read through `apiKeyHelper`** in the run's `--settings`, a command that
  prints the credential file, rather than `ANTHROPIC_API_KEY` in the
  environment, which the MCP server and the ssh it runs would inherit.
- `--max-budget-usd 1` on each run, as a backstop under the workspace's
  limit.
- The Pi's own triage key has no passphrase, since the service runs
  unattended. It lives in the unit's state directory, mode 0600, and never
  leaves the Pi.

### What a run costs

Estimated, for milestone 1 to replace with what Claude Code reports per run
(`total_cost_usd` and `usage` in its final event). The assumed run: a system
prompt of 8,000 tokens, 6 requests in the loop, tool results adding 15,000
tokens across them, and 5,000 tokens out. With caching, each request reads
what the last wrote: about 90,000 tokens read from cache, 25,000 written
at the 5-minute rate (1.25 times input), 5,000 out. Prices as of 2026-10-06:

| Model | Input, output, cache read per million | Reads | Writes | Out | A run |
|---|---|---|---|---|---|
| Opus 5.5 | $4, $20, $0.20 | $0.02 | $0.13 | $0.10 | about $0.25 |
| Sonnet 5.5 | $2, $10, $0.20 | $0.02 | $0.06 | $0.05 | about $0.13 |
| Haiku 5.5 | $0.10, $0.50 | under $0.01 | under $0.01 | under $0.01 | about $0.01 |

At 8 runs every day of a month, the most the limits allow, that is $60 on
Opus. At the two firings of the first two weeks, it is cents. Milestone 1
runs Opus 5.5, to learn whether the best diagnoses are worth having, and
replays its incidents on Sonnet 5.5 to learn whether a cheaper one holds.
The Pi's model follows from that.

### What a stolen copy allows

| Credential | Where | A stolen copy allows | Revoked by |
|---|---|---|---|
| forge's triage key | `~/.ssh/id_ed25519_triage`, with a passphrase | Masked, read-only diagnostics on every host, from wherever SSH reaches them | Deleting its line in `lib/triage-keys.nix`: the Pis drop it that night, gate at its next deploy |
| The Pi's triage key | The unit's state directory | The same | The same |
| Nick's Claude login | forge, already there | Claude Code as Nick against his plan, as today; triage adds nothing to it | Signing that session out |
| The API key | The Pi's sops file | Spending up to the workspace's limit, and nothing else | Deleting it in the Console |
| The ntfy URL | forge's sops file already, the Pi's | Posting to and reading the fleet's topic, as on every Pi today | Rotating the topic (README, "Alerts") |

## Later: questions from the phone

Not the first milestone, and sketched here so the threat model is known
before it is wanted.

**A small page on the agent's Pi, reached through the tunnel.** A question box, the
same harness and tools, the same mask, answers shown on the page. What it
adds:

- `ports.fleetAgent` in `lib/net.nix`, a number not already in `ports`.
- A rule in the Pi's host configuration opening that port on its LAN
  interface from the phone's tunnel address alone
  (`net.segments.vpn.peers.phone`). gate forwards the tunnel without
  masquerading, and WireGuard binds a source address to its key, so the
  source is the phone.
- An `agent` grant in `hosts/gate/wireguard.nix`: one entry in
  `forwardRules`, matching the Pi's address and `ports.fleetAgent`, held by
  `phone`. It changes gate's firewall, so it deploys behind `deploy-guard`.

What it adds to the threat model:

- **The phone stops being DNS-only.** It has nothing more today because it
  is the device most likely to be lost. With this, a lost phone can ask
  questions, read masked diagnostics and spend the budget until its key is
  revoked, which is deleting its key line and deploying gate.
- **A person's free text becomes input.** The tools are unchanged, so a
  question can ask more but never do more.
- **A listener.** The page is the Pi's first port for the agent, open to one
  address. Its own budget: a cap on questions a day apart from the alerts'.
- **Answers leave by the tunnel**, not through ntfy.sh, but a lost phone
  shows its screen, so the mask stays as it is.

A second ntfy topic for questions would need no port or grant, but the
topic is a bearer secret anyone holding it can use, and every question and
answer would pass through ntfy.sh. If `docs/services.md` exists by then, the
page takes its name and TLS from it.

## Ports, grants and logins, by milestone

| Milestone | Adds | Where |
|---|---|---|
| 1 | The `triage` login and its forced command on core4, lifeline, core5 and gate; `triage` in `AllowUsers` | `modules/triage-agent.nix`, imported in `hosts/common/default.nix` |
| 1 | forge's triage key | `lib/triage-keys.nix`, passed as `triagePubKeys` in `flake.nix` |
| 1 | No port and no grant. SSH is open on each host's `sshInterfaces`, which forge reaches from trusted at home and through its `ssh` grant away | `lib/net.nix` and `hosts/gate/wireguard.nix` unchanged |
| 2 | Nothing on any host. A user timer on forge, reusing `ntfy-url` | `secrets/forge.yaml` already holds it |
| 3 | The Pi's triage key | `lib/triage-keys.nix` |
| 3 | `anthropic-api-key` and `ntfy-url` | The Pi's sops file |
| 3 | No inbound port. Outbound HTTPS from servers, which the Pis already use, and SSH within servers and to gate's servers gateway, where sshd already listens | The Pi's firewall unchanged. gate's rules gain the Pi with its address in `lib/net.nix` ([nas.md](nas.md)) |
| 4 | `ports.fleetAgent` | `lib/net.nix` |
| 4 | The port, from the phone's tunnel address alone | The agent Pi's host configuration ([nas.md](nas.md), "The fleet agent's Pi") |
| 4 | The `agent` grant, held by `phone` | Its rule in `forwardRules` in `hosts/gate/wireguard.nix`, and the grant in `segments.vpn.grantNames` and `segments.vpn.grants` in `lib/net.nix`, behind `deploy-guard` |

## Milestones

As issues, smallest first, each after the one before.

1. **fleet: a read-only triage login on every host, and `triage` on forge,
   by hand.** Two PRs, host side first, since forge's needs the login.
   - Host side: `modules/triage-agent.nix` (the login, the verbs, the line
     and count lists), `fleet-mask`, `lib/triage-keys.nix` with forge's key,
     `triagePubKeys` in `flake.nix`, and a VM test,
     `tests/triage-agent.nix`, in `checks.x86_64-linux`: every verb, a
     refused verb, a unit outside the lines list returning counts, a window
     past its bounds, port forwarding refused, and the mask's fixture.
     Preflight's verdict is expected to be `review`, for a new login on
     every host. The Pis take it that night; gate at Nick's next deploy,
     with no firewall change.
   - forge side: `pkgs/triage/` (the `triage` command, `triage-tools`, the
     prompt built from the flake and the answer's schema, with the host
     side's `fleet-mask`), on forge's PATH. `triage` lists the active
     alerts and those that fired in the last 7 days (from `ALERTS`), and
     `triage <n>` diagnoses one, as of the time it fired, prints the push it
     would send, and writes the report. Each report records the run's
     tokens, cost, time and peak memory.
   - Done when Nick has run it on the past firings and a few live ones and
     judged each diagnosis right, partly right or wrong, and the Sonnet
     replays beside them. Whether milestone 2 is worth building is decided
     there.
2. **forge: triage firing alerts on its own while awake.** A user timer
   every 2 minutes, the state file and its limits, the push, the core5
   trigger, and the back-off for refused logins. No host changes.
   docs/privacy.md gains a row for what leaves on each run: the masked tool
   results to Anthropic's API, and the push to ntfy.sh.
3. **The agent's Pi: triage, always on.** Once its Pi exists
   ([nas.md](nas.md), "The fleet agent's Pi"), which waits for nothing else
   in the NAS project. A system service with its own user,
   `lib/hardening.nix`, a `MemoryMax`, public resolvers for the unit, the API
   key, and the Pi's triage key. forge's timer is switched off in the same
   change, since two pollers would push twice; `triage` by hand stays on
   forge.
4. **fleet: questions from the phone, through the tunnel.** After Nick's
   answer below. The page on the agent's Pi and its rule first, then gate's
   grant, as its own PR behind `deploy-guard`.

## For Nick

1. **An API key for the agent's Pi.** It needs an Anthropic Console account
   with billing, a workspace for the agent and a monthly limit. $20 is about
   80 runs on Opus 5.5 or 150 on Sonnet 5.5, against two firings in the first
   two weeks, and stops a bad month there. The alternative is Nick's
   subscription login on the Pi, which this record advises against: a stolen
   copy would act as Nick across his whole plan.
2. **The phone's grant.** Milestone 4 reverses the phone being DNS-only.
   Whether questions from it are worth that is Nick's to weigh; forge could
   take the grant first, as it does for SSH.
3. **A stopgap host.** Settled by [nas.md](nas.md): the agent gets a Pi of
   its own, which does not wait for the NAS, so lifeline is not needed as a
   stopgap.

## What would reopen this

- A diagnosis that needs a write, root, or text from a device to be any
  good.
- The wrapper's tool check failing on a Claude Code update, which moves the
  harness to the Messages API's tool runner.
- Alerts firing often enough that the limits suppress ones worth seeing.
- The collector moving off core5, which moves the core5 verbs with it.

This file changes no host. The milestones' modules will carry the details.
