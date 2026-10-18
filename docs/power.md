# Power

A plan, from NNO-75, for putting the rack on a UPS. Nothing in it is bought or
built. It says what the UPS must carry and for how long, the class of UPS
that does it, which host talks to it, the order the hosts shut down in, what
alerts, and [the PRs in order](#the-prs-in-order). It belongs to the NAS
project, since the NAS's array is what most needs a clean shutdown, but every
step before the NAS's own protects today's fleet.

## Why

Nothing in the repo handles power loss. A cut takes the modem, gate, the
switch and, through the switch's PoE, all three Pis down in the same instant,
and brings them back together when power returns. Much of that is survivable
by design: gate is rebuilt from this repo, the switch, the AP and the modem
keep their settings in flash, and `modules/baseline.nix` already plans for
"the rack lost power" in its `persistent = false` comment. What is not:

- **core4 and lifeline run from SD cards**, which corrupt on a hard power loss
  more readily than SSDs. A card's controller rewrites whole erase blocks
  behind the filesystem's back, so a cut can damage data written long before.
- **core5 holds databases**: the UniFi controller's MongoDB, Home Assistant's
  database and the metrics store. Each is built to survive a hard stop, and a
  clean one costs nothing.
- **The NAS will add an array of SMR drives**, which handle a hard power loss
  badly. A UPS that shuts the NAS down first takes most of that question away
  from the NAS project's choice of filesystem.

## In short

| | Decision |
|---|---|
| Load | About 55 W for today's fleet, 90 to 115 W with the NAS. Peaks near 125 W and 325 W |
| UPS | Line-interactive, pure sine wave output, about 1500 VA / 900 W, two 12 V 9 Ah lead-acid blocks or more, USB HID that `usbhid-ups` drives |
| On it | The modem, gate, the switch, and the NAS. The Pis and the AP through the switch's PoE |
| Runtime | 5 minutes with everything up, then about an hour for the rest, on a battery aged to 80% |
| Talks to it | core5, over USB, serving the other hosts on `ports.nut` |
| Order | The NAS at 5 minutes on battery. core4, lifeline and gate at 30% charge or 10 minutes' runtime. core5 after them. The switch, the AP and the modem when the UPS cuts its outlets |
| Back on | The UPS cycles its outlets after every shutdown, so every host boots on its own. The NAS, when it alone was shed, by Wake-on-LAN |
| Alerts | core5's `upsmon` pushes to the ntfy topic: on battery, back on mains, shutting down. Metrics and rules for the battery's health and the plan's assumptions |

## What it carries

Everything the house needs for a network, and the NAS. Estimates are marked;
the UPS measures its own load once it is in (step 4 below), and the measured
figures replace these.

| Device | Powered from | Typical | Peak | Basis |
|---|---|---|---|---|
| Modem | Its adapter, an outlet | 10 W | 15 W | Estimate. Modems of its kind draw 6 to 12 W |
| gate | Its 12 V adapter, an outlet | 10 W | 35 W | Estimate, from its CPU's limits as gate's firmware sets them, read on gate: 20 W sustained and 25 W in bursts (PL1 and PL2). Plus four NICs, memory, the NVMe drive and the adapter's loss |
| Flex switch, itself | An outlet | 8 W | 12 W | Estimate. The model's own figure, from its label or datasheet, belongs here |
| U7 Pro | The switch, PoE+, port 8 | 11 W | 21 W | Peak is the AP's rated maximum. Typical is an estimate |
| core4 | The switch, PoE | 4 W | 9 W | Estimate. A Pi 4 draws about 3 W idle and 6 to 7 W at full load, plus the PoE HAT's conversion and fan |
| lifeline | The switch, PoE | 4 W | 9 W | As core4 |
| core5 | The switch, PoE | 6 W | 17 W | Estimate. A Pi 5 draws about 3 W idle and 8 to 9 W at full load, its NVMe drive 1 to 2 W idle and up to 5 W writing, plus the HAT |
| PoE loss in the switch | | 3 W | 7 W | Estimate, about a tenth of what it delivers |
| **Today's fleet** | | **about 55 W** | **about 125 W** | |
| NAS, not chosen | An outlet | 35 to 60 W | 150 to 200 W | Estimate for a desktop board and four 3.5" drives. Each drive 4 to 7 W spinning and about 25 W spinning up; the board 15 to 30 W idle and 60 to 90 W loaded, through its supply |
| **With the NAS** | | **90 to 115 W** | **275 to 325 W** | |

**Typical is idle.** Over the week to 2026-10-17 every host averaged 1 to 2%
CPU busy, and its busiest five minutes were under 40%, the nightly upgrade
(core5's metrics store, `node_cpu_seconds_total`). So the typical column is
each device at rest, and the peak column is a burst. Peaks do not coincide,
except when power returns and everything boots at once, and by then the UPS is
on mains again.

**The Pis and the AP have no plugs of their own.** The switch powers all three
Pis by PoE ([unifi.md](unifi.md), "Device firmware"). The U7 Pro takes power
by PoE+ alone and sits on switch port 8 ([network.md](network.md)); the repo
does not record an injector between the two, and the controller's port list
would show one. So four outlets carry everything: the modem, gate, the switch
and the NAS. The switch's row is only its own draw, since what it delivers is
counted in the rows of the devices it powers, and its PoE conversion loss has
a row of its own.

Not on it: forge, phones and laptops, which have batteries, and the machine on
`lan1`, which is not part of the fleet.

## Size and runtime

### Two targets

1. **Ride through short cuts with everything up.** Most cuts last seconds or
   minutes. Everything, the NAS included, stays up for the first 5 minutes on
   battery.
2. **On a long cut, keep the house's network up for about an hour, then shut
   down with charge to spare.** The NAS sheds at 5 minutes, and the rest of the
   fleet, about 55 W, runs on until the battery reaches the final threshold,
   30%, which leaves far more than the shutdown needs.

Both on a battery aged to 80% of its new capacity. Lead-acid loses capacity
steadily, and the plan should hold in year three, not only in week one.

### The battery that takes

Assumptions, all estimates. At these light loads the UPS draws about the load
divided by 0.75 from its battery, for the inverter's losses and its own
overhead. A lead-acid battery delivers about 70% of its rated energy at this
rate. The final stage fires with 30% left. The NAS stage is 5 minutes at about
110 W, 12 Wh from the battery.

| Battery | Rated | Usable, new and aged | Cut to final stage, new | Aged |
|---|---|---|---|---|
| Two 12 V 7 Ah blocks | 170 Wh | 120 and 95 Wh | about 60 minutes | about 50 minutes |
| Two 12 V 9 Ah blocks | 215 Wh | 150 and 120 Wh | about 80 minutes | about 60 minutes |

**Two 12 V 9 Ah blocks or more**, about 215 Wh, the usual battery of a
1500 VA tower. Before buying, the model's own runtime chart replaces this
arithmetic, and after the drill (step 8 below) the measured curve replaces
both.

Shedding the NAS is what buys the hour. With it running throughout, the same
battery reaches the final stage in about 45 minutes new.

The 30% left at the final stage is about half an hour at the fleet's draw,
against a shutdown that takes under 5 minutes. That margin is for wrong
estimates: a UPS estimates charge from voltage, an aged lead-acid battery's
voltage falls away steeply near the end, and deep discharges shorten its life.
Once the drill has measured the curve, 20% is a reasonable setting.

### The rating

The watt rating has to cover the largest load that can arrive on battery, with
room: today's fleet at its peak, about 125 W, and the NAS under load, up to
200 W, about 325 W together. So at least 600 W. Every UPS that carries the
battery above is rated higher, about 900 W at 1500 VA, so the battery sets the
size, not the rating. VA is the bigger number on the box and says little here;
read the watts.

The UPS's own draw on mains, a few watts for its charger and electronics, is
its running cost.

### The waveform

**Pure sine wave output, because of the NAS.** On battery, cheaper UPSes make a
stepped approximation of a sine wave. Small supplies such as gate's and the
modem's adapters do not mind, since they rectify whatever arrives. A desktop
power supply, which the NAS will have, almost certainly has active power
factor correction, and some of those shut off or refuse the transfer on a
stepped wave, at the moment of transfer and under load, which is the one
moment the NAS must not lose power. Without the NAS a stepped wave would do.
Buy for the NAS.

**Line-interactive, not online.** A line-interactive UPS transfers to battery
in a few milliseconds, well inside a desktop supply's hold-up time and the
adapters' own capacitors, and its voltage regulation (AVR) rides out sags
without touching the battery. An online UPS converts all the time, so it turns
5 to 10% of the load into heat and runs fans, for a protection this load does
not need.

### The chemistry

| | Sealed lead-acid (AGM) | Lithium iron phosphate (LiFePO4) |
|---|---|---|
| Life | 3 to 5 years at 25 °C, halved for every 8 to 10 °C warmer | 8 to 10 years, and more tolerant of heat |
| Recharge | Slow: most quote 6 to 8 hours to 90% | Faster, where the charger allows |
| Price | The usual battery in this class. Replacements are standard parts | About twice as much, in fewer models |
| NUT | The common case | Supported on some models. Check the exact one |

**Lead-acid**, for the first UPS. The class with pure sine output and
`usbhid-ups` support is widest there, and a replacement is a standard part.
Budget for one in year three or four: the UPS's self-test raises `RB`,
replace battery, and an alert below reports it. Lithium is worth its price if
the UPS will sit somewhere warm. gate is fanless and runs warm
([router.md](router.md), "Thermals"), and the NAS will add heat to the same
space, so measure where the UPS will sit before choosing.

### What to buy

**A line-interactive UPS with pure sine wave output, about 1500 VA / 900 W,
with two 12 V 9 Ah lead-acid blocks or bigger.** A tower, or a 2U unit if the
rack is 19-inch and deep enough; the electrical class is the same. Before
choosing a model, check that:

- **NUT drives it with `usbhid-ups`.** NUT's hardware compatibility list names
  the model under that driver, and the pinned nixpkgs carries NUT 2.8.4. The
  UPS presents itself over USB as a HID power device; one that needs a
  vendor's own protocol or a serial cable does not qualify.
- **It can turn its outlets off and on again when told.** NUT calls it
  `shutdown.return`, and it is what brings every host back after a shutdown
  ([below](#when-power-returns)). The driver's manual says many CyberPower
  models count its delays in whole minutes, and that some cannot set a restart
  delay at all, so whatever the make, it gets tested on arrival.
- **It reports `battery.charge` and `battery.runtime`**, which the thresholds
  read, and ideally its load in watts (`ups.realpower`).
- **It has at least four battery-backed outlets**, spaced for adapters: the
  modem, gate, the switch and the NAS. Six leave room. Many UPSes also have
  outlets with surge protection alone, which do not count.

Worth having: a minimum charge before the outlets come back on
(`battery.charge.restart`), so hosts do not boot into a battery that could not
carry another clean shutdown; a beeper NUT can turn off, since it will sound at
night; a battery replaceable without tools.

## Which host talks to it

One host holds the USB cable and runs NUT's server: the driver,
`usbhid-ups`; `upsd`, which serves the UPS's state to the network; and
`upsmon` as the primary. Every other host runs `upsmon` as a secondary, a
network client of that server. In NUT's model the primary is the last host up.
On low battery it tells the secondaries to shut down, waits for them, shuts
itself down, and as its last act tells the UPS to cut its outlets. So the
server has to be the host that stays up longest.

Read from the `power.ups` module at the nixpkgs pinned on 2026-10-17: it runs
`upsd` and the driver as root (`-u root`, with a TODO to change that);
`openFirewall` opens the port on every interface; `upsd` listens on loopback
alone until `upsd.listen` names an address; and its `ups-killpower` unit, late
in the primary's shutdown, is what tells the UPS to cycle its outlets, once
`upsmon` has flagged a shutdown for power.

| | gate | core5 | NAS |
|---|---|---|---|
| Up longest | Yes: nothing works without it | Yes, as the primary | No: it sheds first |
| Deploys | By hand. Its firewall changes go behind deploy-guard | With the nightly upgrade | Not built yet |
| A root daemon listening on the network | On the router | On a Pi that already serves several | |
| Pushes | Needs the ntfy secret and a sender of its own | Holds both, for fleetAlerts and Alertmanager | |
| Metrics | A new exporter port on gate, opened to core5 | An exporter on loopback, as smartctl's | |

**core5.** It holds the alerting already, so the exporter stays on loopback
and the pushes use secrets it has. Every tuning of thresholds and timers,
which the first months will need, deploys with the nightly upgrade instead of
by hand on the router, and nothing about the UPS needs deploy-guard. And a
daemon that runs as root and answers the network belongs on a Pi more than on
the router.

What it costs:

- **gate depends on a Pi for one decision.**
  [observability.md](observability.md) chose pull so that gate never dials
  into the LAN, and here gate's `upsmon` dials core5. What it decides is only
  when gate halts. With core5 unreachable on mains, gate logs it and carries
  on. On battery, it halts after `DEADTIME`, which an unwatched battery calls
  for anyway.
- **core5 reboots itself** for kernel changes in the upgrade window, and goes
  dark with the rest of the switch's PoE during a switch firmware update. A UPS
  whose server is down is unwatched. The secondaries' `DEADTIME` is 5 minutes,
  longer than core5 takes to reboot, so a reboot during a cut is not read as a
  dead server. core5 down for longer is already the Watchdog's alert, from
  outside ([observability.md](observability.md), "Alerts").
- **core5 cannot shed early**, since it is the primary. It draws about 6 W, so
  that costs little.

The NAS is not a candidate. It sheds first, and the server goes last. It does
not exist yet either, and the plan should protect the fleet before it does.

### Port and firewall

`upsd` listens on 3493, NUT's registered port, as `ports.nut` in
`lib/net.nix`, on core5's address and loopback alone. Its rule opens 3493 on
core5's `end0` from each client's address, the way node_exporter's opens to
the collector (`modules/node-exporter.nix`), and not to the whole segment,
which also holds the switch, the AP and anything on an untagged switch port.
Never `power.ups.openFirewall`. gate connects from its servers gateway, the
address its `metricsSegment` names, so no connection crosses gate's forward
chain.

`lib/net.nix` names the roles, as it does for metrics:

```nix
upsServer = "core5";
upsClients = [ "core4" "lifeline" "gate" ];
```

and `modules/net-assertions.nix` holds them: the server has an `ip`, each
client has an `ip` or a `metricsSegment` on the server's segment, and the
server is not one of its own clients.

### Logins

Each secondary logs in to `upsd` with a user of its own (`upsmon secondary`),
so one can be revoked alone. Its password is random, in its own sops file and
in core5's, set from one `openssl rand -hex 32` the way the AdGuard metrics
pair is ([observability.md](observability.md), "The metrics login"). NUT sends
it in the clear on the servers segment. A secondary's login can only follow
the UPS's state, which `upsd` serves to any client it accepts without a login
at all, so the firewall's source addresses are the access control that
matters. The one login that can order a shutdown, `upsmon primary`, is
core5's own, and never leaves its loopback.

## Shutdown order

| Stage | Hosts | Trigger | Why there |
|---|---|---|---|
| 1 | NAS | 5 minutes on battery: a `upssched` timer on the NAS, cancelled when mains returns | The largest load and the most fragile, and nothing else depends on it |
| 2 | core4, lifeline, gate, and the NAS if it is up | Battery under 30%, or under 10 minutes' runtime, whichever comes first | Together, since the resolvers are what makes gate useful to the house |
| 3 | core5 | Once stage 2's hosts have logged off, or after `HOSTSYNC` | The primary goes last, and tells the UPS to cycle its outlets |
| 4 | The switch, the AP and the modem | The UPS cuts its outlets, `offdelay` after core5's command | No software shutdown: they are made for a hard stop |

Or not at all past stage 1: if mains returns before stage 2, nothing else
shuts down. 5 minutes for the NAS is this plan's default; the NAS project may
shorten it once it knows how its array takes a cut.

**The resolvers do not go before gate.** Shedding core4 and lifeline first
would leave gate routing for a house whose DHCP points it at resolvers that are
off, and gate redirects stray port 53 to them too, so clients would keep a
link and lose DNS. The two draw about 8 W. So they halt with gate, and the
order within the stage is the one NUT gives: the secondaries, then the
primary, then the network.

**The trigger is set here, not by the UPS.** A UPS raises low battery (`LB`)
at its own threshold, often 2 minutes or 10% left, which an aged battery
cannot honour. The driver's `ignorelb` makes it decide `LB` itself, from
`override.battery.charge.low = 30` and `override.battery.runtime.low = 600`,
whichever is crossed first. Two other things halt the secondaries: core5
unreachable for `DEADTIME` while last seen on battery, which halts each one on
its own, and `upsmon -c fsd` on core5, which starts stage 2 by hand and is how
the drill tests it.

**The time it takes.** Each secondary logs off as its own shutdown begins, and
core5 starts its own seconds later. Its last act asks the UPS to turn the
outlets off after `offdelay`, and on again after `ondelay` once mains is
there. The driver's defaults are 20 and 30 seconds. Here they are 120 and 180,
so a slow halt anywhere still finishes before the cut, and on a model that
counts both from the command, as most do, the outlets stay off a full minute,
long enough for every device to lose power completely. If the NAS is up at
stage 2, it logs off only once its array is down (`SHUTDOWNEXIT` off, with its
`upsmon` stopped after the array), and core5's `HOSTSYNC` is set to the NAS's
measured halt time. All of it fits in about 5 minutes, against the half hour
that 30% leaves.

### When power returns

**Every host that halts for power is brought back by the UPS cycling its
outlets, never by a person.** A host that halts on an outlet that stays live
stays off: gate and the NAS sit in soft-off, and a Pi stays halted until its
power is cut and restored. That is why core5's last act is `shutdown.return`
and not only halting, and why the NAS's early shed needs a way back of its own.

| Power returns | What happens |
|---|---|
| Within the first minute | Nothing at all, not even a push. core5's journal has the transfer |
| Before 5 minutes | Two pushes, on battery and back on mains. Nothing has shut down |
| After the NAS shed, before stage 2 | The NAS is off on a live outlet that nothing will cycle. core5 sends it a Wake-on-LAN packet once mains has held for 10 minutes, so a flickering grid does not boot it into the next drop |
| During stages 2 and 3 | NUT does not abandon a shutdown once begun. core5 still sends `shutdown.return`, and with mains present the UPS turns the outlets off and then on again, so every host reboots |
| After the outlets are off | The UPS turns them on `ondelay` after mains returns, and only above `battery.charge.restart` where the model has it. Everything boots |
| If nothing watched the battery | Every watcher failed, so stage 2 never came. The UPS cuts its outlets when the battery is flat, and most turn them on when mains returns; the drill checks this model does |

Each host has to boot when power is applied, with nobody there:

| Host | How it comes back | What it needs |
|---|---|---|
| gate | Firmware power-on after AC loss | Its firmware's "State After G3" or "Restore on AC Power Loss" set to power on. The repo does not record it; the installation below tests it |
| core4, lifeline | A Pi 4 boots when powered | Nothing. Power returns with the switch's PoE |
| core5 | A Pi 5 boots when powered | Nothing, at the EEPROM's defaults |
| NAS | Firmware power-on after AC loss, and Wake-on-LAN from soft-off | Both in its firmware, with ErP or EuP off, which would otherwise cut the NIC's standby power. `wakeOnLan` on its interface |
| Switch, AP, modem | Boot when powered | Nothing |

The switch boots, then powers its PoE ports, and the Pis boot after that, so
DNS is back a few minutes after the outlets; the drill times it.

The Wake-on-LAN packet needs the NAS's MAC address, which stays out of this
repo: it goes in core5's sops file as `mac-nas`, named as
[device-identity.md](device-identity.md) names gate's. The packet is a
broadcast on the NAS's segment, so this assumes the NAS lives on servers, with
core5. If the NAS project puts it elsewhere, the packet comes from gate
instead.

## Alerts

**Power events push from core5's `upsmon`, not through fleetAlerts or
Alertmanager.** fleetAlerts reports units that fail or stop succeeding, and a
cut is neither. Alertmanager here never sends a resolution, by design
([observability.md](observability.md), "Alerts"), and "back on mains" is one.
It also waits on a scrape, an evaluation and a group wait, in the minutes when
a push matters most. So `upsmon` hands its events to `upssched`, whose script
posts to the same ntfy topic through the same sender `modules/alerts.nix`
uses: the URL from a credential rather than an argument, and DNS-over-HTTPS
when the name does not resolve. That sender moves to `lib/` so both share it.

| Event | Push | Priority |
|---|---|---|
| On battery for 60 seconds | On battery: the NAS shuts down at 5 minutes, the rest at 30% | High |
| Back on mains, after that push | Back on mains, after how long. The cancel command of the `upssched` timer above, so a blip under a minute sends neither | Default |
| Stage 2 begins | Battery low: the fleet is shutting down, and comes back when mains does | High |

`upsmon`'s other events go to the journal alone. The slow ones are the
metrics' to report, once: `upsmon` repeats a replace-battery warning every 12
hours.

**The modem goes on the UPS.** Pushes need the internet. Without the modem,
the first push of a cut would fail with nothing to retry it, and the phones and
laptops in the house would lose the internet with it. It adds about 10 W, a
sixth of the long-cut load. A cut that also takes down the ISP's own equipment
still stops the pushes. Then the Watchdog speaks: core5's pings to
healthchecks.io stop, and it alerts from outside within 20 minutes of the
fleet going down.

**Metrics and rules, for what is slow.** NUT's exporter
(`services.prometheus.exporters.nut`) runs on core5's loopback at
`ports.nutExporter`, its default 9199, and is scraped at `/ups_metrics`, not
`/metrics`. Its `device_info` series stays off (`--nut.disable_device_info`),
since its labels carry the UPS's serial number, which no label may
(`modules/alert-rules.nix`). The Fleet dashboard gains a row: status, charge,
runtime, load and input voltage. Rules:

- **`UpsBatteryReplace`**, warning: the `RB` flag, or a failed self-test.
- **`UpsLoadHigh`**, warning, for an hour: load past what this plan sized for,
  about 80 W before the NAS and 130 W with it. Something new on a battery
  outlet, and the runtimes here no longer hold.
- **`UpsClientMissing`**, warning, for 15 minutes: fewer secondaries logged in
  to `upsd` than `upsClients` names. A host whose `upsmon` has died is cut hard
  at the next long cut, and this says so first. The count comes from
  `upsc -c` through node_exporter's textfile directory, as main's head does in
  `modules/alerting.nix`.
- **`UpsOnBattery`**, sent nowhere, while on battery and for 30 minutes after:
  it holds `HostDown` back for the hosts the plan sheds, so the NAS going off at
  5 minutes is not a second push.

A UPS that stops answering is `ScrapeDown` on the exporter's job, as for any
source. fleetAlerts covers the units: `upsdrv`, `upsd` and `upsmon` on core5,
and `upsmon` on core4 and lifeline. gate has no `ntfy-url`, so no fleetAlerts;
its `upsmon` failing shows as `UpsClientMissing`.

## Installing it

Hands-on, when the UPS arrives. Moving the plugs is itself a power cut, so it
is a planned one: in daylight, and not between 02:30 and 06:00, when the Pis
upgrade.

1. Charge the UPS on its own for as long as its manual asks.
2. Halt core4, lifeline and core5 with `sudo poweroff`, then gate.
3. Move the modem, gate and the switch to battery outlets, and connect the
   UPS's USB cable to core5.
4. gate should power on by itself as its plug goes in. That is the first test
   of its firmware's power-on after AC loss: if it stays off, set it at the
   keyboard, and note it in [router.md](router.md)'s hardware notes. The
   switch's power returning boots the Pis.
5. `fleet-ssh <host> host-status` on each host.

## The PRs, in order

Each depends on the one before. None needs deploy-guard: gate's one PR changes
no firewall rule, interface or boot path on gate. Where core5's firewall
changes, preflight's verdict is `be there`, since core5 applies it that night
unattended, and the PR quotes the brief.

1. **`docs/power: plan a ups for the rack, and clean shutdowns on power loss`.**
   This file, and its row in the README. Verdict: routine; no host changes.
2. **Hands-on: buy the UPS and install it**, as above.
3. **`core5: watch the ups over usb, and push its power events`.** `power.ups`
   on core5 in standalone mode: the driver with `ignorelb`, the two overrides,
   `offdelay` and `ondelay`; `upsd` on loopback; `upsmon` as primary; `upssched`
   with the timers and pushes above; `alerts.nix`'s sender moved to `lib/`; the
   units in fleetAlerts; `ports.nut`. One secret, the primary's password, in
   core5's sops file. Until steps 6 and 7, stage 2 halts core5 alone and the
   outlet cycle cuts the rest hard, as any cut does today, but an hour later and
   with a way back. Expected verdict: routine, since only services are added.
   After the merge: `upsc ups@localhost` reads charge, runtime and load, and
   `upscmd -l ups` lists `shutdown.return`.
4. **`core5: ups metrics, a dashboard row and its alert rules`.** The exporter,
   its scrape and `ports.nutExporter`, the row, `UpsBatteryReplace` and
   `UpsLoadHigh`. Expected verdict: routine.
5. **`docs/power: the load as measured`.** After a week of the load graph, the
   measured load and the UPS's own runtime estimate replace the estimates here,
   and the thresholds are checked against them. Verdict: routine; no host
   changes.
6. **`pis: shut down cleanly when the ups runs low`.** `upsServer` and
   `upsClients` in `lib/net.nix`, with core4 and lifeline, and their
   assertions. On core5, `netserver` mode, with `upsd` also on its address,
   and the firewall rule and a user for each client. On core4 and lifeline,
   `upsmon` as a secondary with a 5-minute `DEADTIME`, in fleetAlerts.
   `UpsClientMissing`. One password per client, in its sops file and in
   core5's. Expected verdict: **be there**, for core5's firewall. After the
   merge: `upsc -c ups@localhost` on core5 lists both.
7. **`gate: shut down cleanly when the ups runs low`.** gate in `upsClients`,
   core5's rule and user for gate's servers gateway, and `upsmon` on gate.
   Expected verdict: **be there**, for core5's firewall again. gate itself
   deploys with `nrs` and no deploy-guard: it only dials core5.
8. **Hands-on: the drill.** In daylight, outside 02:30 to 06:00, with someone
   at home, and with each host's `host-status` showing it runs its boot
   default, since a power cycle boots that. First pull the UPS's plug for 2
   minutes: an on-battery push at 1 minute, a back-on-mains push, and nothing
   halts. Then `sudo upsmon -c fsd` on core5, with mains present, which the
   driver's manual names as the test: core4, lifeline and gate halt, then core5,
   the UPS turns its outlets off and on again, and every host comes back by
   itself. Time each halt, and how long until the house resolves names again.
   Optionally, a runtime test down to stage 2, or the model's own calibration
   (`calibrate.start`) where it has one, so its runtime estimate is honest.
   Then **`docs/power: the drill's results`**, with dates, and the final
   threshold lowered to 20% if the curve allows.
9. **In the NAS project: `nas: shed at 5 minutes on battery, and wake when
   mains returns`.** The NAS as a secondary, with its `upssched` timer;
   `SHUTDOWNEXIT` off, with `upsmon` stopped after the array; core5's
   `HOSTSYNC` set to its measured halt time; core5's rule and user for its
   address; `mac-nas` in core5's sops file, and the Wake-on-LAN timer;
   `UpsOnBattery` holding `HostDown` back for it. Its firmware settings come
   first. Expected verdict: **be there**, for core5's firewall. Then the
   drill's plug pull again, held past 5 minutes.

## Not planned

- **Switched outlet groups**, which some larger UPSes have, would let the UPS
  cut and restore the NAS's outlet itself, instead of Wake-on-LAN. They narrow
  the class and raise the price, for one host.
- **NUT over TLS.** The only secrets on the wire are the secondaries'
  passwords, and their logins read what any client allowed to connect can read.
- **Holding the nightly upgrade on battery.** An upgrade during a cut spends a
  little charge, and core5 rebooting is inside the secondaries' `DEADTIME`.
  Worth revisiting if a cut and an upgrade ever meet.
- **Hosts with two supplies, or a second UPS.** No host in the fleet has two
  power inputs.
