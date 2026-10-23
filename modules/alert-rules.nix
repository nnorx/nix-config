# The alert rules vmalert evaluates on the collector (modules/alerting.nix), as
# vmalert's rule file. A function rather than a module, so that
# tests/alert-rules.nix can check the same rules against series of its own
# without evaluating a host. docs/observability.md, "Alerts", has the table
# and the reasons for each threshold.
#
# Labels are the alert's name, `instance` (a host's name, which
# modules/metrics.nix sets at scrape and ntfy's template shows), `severity`,
# and where one is needed, a name: a segment or a WireGuard peer from
# lib/net.nix, a mountpoint, a drive's kernel name. Never an address, a serial
# number or a value, since every label and annotation leaves the house in the
# push.
{
  lib,
  net,
  hostname,
}:
let
  # The router, which is judged apart from the Pis wherever it differs: it
  # holds the WAN and the DHCP pools, and it upgrades by hand.
  router = "gate";

  # How old main's head may be, in hours, and still be judged by: past it,
  # RevisionBehind stops and RevisionCheckStale says so. modules/alerting.nix
  # reads the head every 30 minutes, so this is a dozen reads failing in a row.
  headFresh = 6;

  # Kea's statistics by segment rather than subnet, so no address leaves the
  # house. Shared with the DHCP dashboard.
  kea = import ../lib/kea-segments.nix { inherit lib net; };
in
{
  groups = [
    {
      name = "fleet";
      rules = [
        {
          # Always firing, and routed to healthchecks.io alone, which alerts
          # when its pings stop. vmalert, Alertmanager and the way out of the
          # house all have to work for one to arrive.
          alert = "Watchdog";
          expr = "vector(1)";
          labels.severity = "none";
          annotations.summary = "The alerting pipeline on ${hostname} is working.";
        }
        {
          # A missing exporter reads as down too: a generation older than
          # node_exporter, such as a fallback boot, is silent here.
          alert = "HostDown";
          expr = ''max by (instance) (up{job="node"}) == 0'';
          for = "5m";
          labels.severity = "critical";
          annotations.summary = "{{ $labels.instance }} has not answered a scrape for 5 minutes.";
        }
        {
          # Every other source, whose silence would leave the rules that read
          # it nothing to read, quiet rather than firing. unbound and kea keep
          # `instance`, the host they run on, so HostDown holds them back when
          # the whole host is down. A probe job's targets are all asked of the
          # blackbox exporter here, and probe-ping's `instance` is a public
          # resolver's address, so a probe job is down when all its targets
          # are, and is named for this host. A probe that fails still answers
          # its scrape, with probe_success 0.
          #
          # Not the store, vmalert or Alertmanager, which scrape themselves:
          # with one of them down this rule is not evaluated or its alert not
          # delivered, and the Watchdog's silence says so from outside. 10
          # minutes is past a restart: in the store's first 4 days, to
          # 2026-10-15, unbound and kea missed two minutes' scrapes at most.
          alert = "ScrapeDown";
          expr = ''
            max by (job, instance) (up{job!~"node|probe-.*|victoriametrics|vmalert|alertmanager"}) == 0
              or label_replace(max by (job) (up{job=~"probe-.*"}) == 0, "instance", "${hostname}", "", "")
          '';
          for = "10m";
          labels.severity = "warning";
          annotations.summary = "{{ $labels.job }} on {{ $labels.instance }} has not answered a scrape for 10 minutes.";
        }
        {
          # gate's own view of its uplink, and the house's view through it:
          # the link, the lease, the default route, and both public resolvers
          # going unanswered at once, which is traffic not leaving. One alert
          # for all four, so a link that drops and takes the lease with it is
          # one push. Every term carries gate's name, which the last adds.
          alert = "WanDown";
          expr = ''
            (max by (instance) (node_network_carrier{job="node", instance="${router}", device="${net.hosts.${router}.wanIface}"}) == 0)
            or (max by (instance) (fleet_wan_addresses{instance="${router}"}) == 0)
            or (max by (instance) (fleet_wan_default_routes{instance="${router}"}) == 0)
            or label_replace(max(probe_success{job="probe-ping"}) == 0, "instance", "${router}", "", "")
          '';
          for = "2m";
          labels.severity = "critical";
          annotations.summary = "${router}'s WAN is down: no link, no lease or no default route, or neither public resolver answers a ping.";
        }
        {
          # Either the resolver does not answer core5's probe, a name Unbound
          # answers itself, or it answers but recursion is failing. The ratio
          # leaves out Unbound's `nodata`, which counts NOERROR answers with
          # nothing in them a second time.
          #
          # The ratio needs at least 100 answers in the window. In the quiet
          # hours a resolver answers 30 to 80 every 15 minutes, 30 of them
          # core5's own probes (measured 2026-10-13), and 5% of that is two or
          # three SERVFAILs, which one device retrying a broken name makes on
          # its own. 100 is above every quiet hour, and below core4's busy
          # ones; lifeline, the second resolver, rarely reaches it, so for
          # lifeline this is mostly the probe.
          alert = "ResolverFailing";
          expr = ''
            (max by (instance) (probe_success{job="probe-resolver"}) == 0)
            or (
              sum by (instance) (rate(unbound_answer_rcodes_total{rcode="SERVFAIL"}[15m]))
                / sum by (instance) (rate(unbound_answer_rcodes_total{rcode!="nodata"}[15m]))
                > 0.05
              and sum by (instance) (increase(unbound_answer_rcodes_total{rcode!="nodata"}[15m])) >= 100
            )
          '';
          for = "5m";
          labels.severity = "critical";
          annotations.summary = "{{ $labels.instance }} is failing DNS: it does not answer core5's probe, or over 5% of its answers are SERVFAIL.";
        }
        {
          # AdGuard's counts going missing, and only that: AdGuard not serving
          # is the DNS probe's, above. The read reaches the store through
          # node_exporter rather than a scrape of its own, and writes
          # fleet_adguard_up 0 when AdGuard does not answer it. 30 minutes,
          # since the counts feed only the dashboards.
          alert = "AdGuardStatsMissing";
          expr = "max by (instance) (fleet_adguard_up) == 0";
          for = "30m";
          labels.severity = "warning";
          annotations.summary = "AdGuard's statistics on {{ $labels.instance }} have not been read for 30 minutes.";
        }
        {
          alert = "ConntrackPressure";
          expr = ''
            max by (instance) (node_nf_conntrack_entries{instance="${router}"} / node_nf_conntrack_entries_limit{instance="${router}"}) > 0.8
          '';
          for = "10m";
          labels.severity = "warning";
          annotations.summary = "{{ $labels.instance }}'s conntrack table is over 80% of its limit.";
        }
        {
          # Each pool's share leased, by segment: lib/kea-segments.nix says
          # which of Kea's series that reads, and why. The DHCP dashboard draws
          # the same ratio, with this threshold marked.
          alert = "DhcpPoolLow";
          expr = ''
            ${kea.poolUsed}
              > 0.9
          '';
          for = "15m";
          labels.severity = "warning";
          annotations.summary = "The {{ $labels.segment }} segment's DHCP pool on {{ $labels.instance }} is over 90% leased.";
        }
        {
          # /nix/store is a second mount of the root, and ramfs reports no size
          # and drops out. tmpfs counts for fullness but not for the trend: a
          # few megabytes written to /run read as a steep rate, and on core5
          # predicted it full once in the 3 days before this. The rate is the
          # last 6 hours', and either has to hold for an hour. A single write
          # still reads as a slope while it stays in the window: an upgrade
          # that adds a kernel, 57 MB to gate's 1 GB /boot or 2.8 GB to
          # lifeline's 59 GB root, predicted each full in under 3 days. So the
          # trend counts only on a filesystem already over half full, as in
          # node_exporter's own mixin.
          alert = "DiskFilling";
          expr = ''
            max by (instance, mountpoint) (
              1 - node_filesystem_avail_bytes{mountpoint!="/nix/store"} / node_filesystem_size_bytes{mountpoint!="/nix/store"} > 0.85
              or (
                predict_linear(node_filesystem_avail_bytes{mountpoint!="/nix/store", fstype!="tmpfs"}[6h], 3 * 86400) < 0
                and 1 - node_filesystem_avail_bytes / node_filesystem_size_bytes > 0.5
              )
            )
          '';
          for = "1h";
          labels.severity = "warning";
          annotations.summary = "{{ $labels.mountpoint }} on {{ $labels.instance }} is over 85% full, or at its rate will be full within 3 days.";
        }
        {
          # node_exporter has no trip points, so one figure: 75°C, under the
          # Pis' 80°C throttle. The same for gate, though its CPU throttles at
          # 105°C: its case is fanless and shares the heat with an NVMe drive
          # whose own limit is 80°C, and its package peaked at 47°C in the
          # week before this. Its other zone, acpitz, reads a constant 27.8°C.
          alert = "HostHot";
          expr = "max by (instance) (node_thermal_zone_temp) > 75";
          for = "15m";
          labels.severity = "warning";
          annotations.summary = "{{ $labels.instance }} has been above 75°C for 15 minutes.";
        }
        {
          # The drive's own verdict, from its health log (modules/smartctl.nix).
          # Each term is a field the NVMe specification defines as a fault,
          # judged against the drive's own figures rather than ours. The
          # critical-warning field is a bit set: spare under its threshold,
          # temperature past the drive's limit, reliability degraded by media
          # or internal errors, the media read-only, or its volatile backup
          # failed. smartctl's verdict fails on the same bits. The spare's
          # threshold is the drive's, from the same log. Media errors are
          # unrecovered integrity errors, and any new one is data lost; the
          # count a drive arrives with is history, so the term is the count
          # risen above its lowest in the last hour, which holds for an hour
          # and is one push. Not increase(): VictoriaMetrics counts a new
          # series' first value, if small, as an increase from 0, so a drive
          # with old errors would push at its first scrape. 5 minutes, so that
          # the temperature bit, which a burst of writes can set and clear,
          # has to persist.
          alert = "DriveFailing";
          expr = ''
            max by (instance, device) (
              smartctl_device_critical_warning > 0
              or smartctl_device_smart_status == 0
              or smartctl_device_available_spare < smartctl_device_available_spare_threshold
              or smartctl_device_media_errors > min_over_time(smartctl_device_media_errors[1h])
            )
          '';
          for = "5m";
          labels.severity = "critical";
          annotations.summary = "{{ $labels.device }} on {{ $labels.instance }} says it is failing: a critical warning, a failed SMART verdict, spare under its threshold, or new media errors.";
        }
        {
          # The drive's estimate of its rated endurance used, which may pass
          # 100 and goes on working there. 80 leaves a fifth of the rating: at
          # the rate that used the first four fifths, a quarter as long again,
          # which is years on any drive that took years to get there, and time
          # to buy one rather than react to DriveFailing. It only rises, so it
          # stays firing, and Alertmanager repeats it every 30 days.
          alert = "DriveWearing";
          expr = "max by (instance, device) (smartctl_device_percentage_used) > 80";
          for = "1h";
          labels.severity = "warning";
          annotations.summary = "{{ $labels.device }} on {{ $labels.instance }} has used over 80% of its rated endurance.";
        }
        {
          # A drive the exporter was given but has never read publishes no
          # series at all, while the scrape still answers, so the two rules
          # above and ScrapeDown are all quiet: a sandbox that refuses the
          # device reads as a healthy drive. smartctl_devices counts the
          # drives it was given, and every drive it has read has an exit
          # status, whether or not its log carries a verdict. By host, since
          # an unread drive has no series to carry its name. 15 minutes for a
          # restart, which empties the exporter's cache until its first read.
          alert = "DriveUnread";
          expr = ''
            max by (instance) (smartctl_devices)
              > (
                count by (instance) (smartctl_device_smartctl_exit_status)
                or max by (instance) (smartctl_devices) * 0
              )
          '';
          for = "15m";
          labels.severity = "warning";
          annotations.summary = "smartctl_exporter on {{ $labels.instance }} has not read every drive it watches, so their health is unknown.";
        }
        {
          # Frames that arrived damaged or could not be sent, which a healthy
          # link does not count. Not drops, which count ordinary things such
          # as frames for a protocol nothing here speaks. Every interface on
          # every host counted none over the store's first 4 days, to
          # 2026-10-15, so any error is a fault once it persists: some in
          # every 10 minutes for 30, as a failing cable, port or driver keeps
          # up, and a link reseated or renegotiating, a burst of seconds,
          # does not.
          alert = "InterfaceErrors";
          expr = ''
            sum by (instance, device) (increase({__name__=~"node_network_(receive|transmit)_errs_total"}[10m])) > 0
          '';
          for = "30m";
          labels.severity = "warning";
          annotations.summary = "{{ $labels.device }} on {{ $labels.instance }} has counted receive or transmit errors for 30 minutes.";
        }
        {
          # main's head unread for `headFresh` hours, which turns
          # RevisionBehind off. One failed read is a GitHub hiccup, which is
          # why fleet-main-revision is not in fleetAlerts; a dozen in a row is
          # not. A failed read leaves the last one in place, so the first term
          # sees it age. The second is the file missing altogether: it is in
          # /run, so after core5 boots it is gone until a read succeeds, and a
          # read that never does is the same fault, held to the same hours from
          # the last sample the store has. Named for this host, which reads the
          # head, so HostDown holds it back when the series stops with the rest
          # of core5's. 10 minutes for a new store, empty until the first read,
          # 2 minutes after boot.
          alert = "RevisionCheckStale";
          expr = ''
            label_replace(
              time() - max(fleet_main_revision_checked_timestamp_seconds) > ${toString headFresh} * 3600
                or absent_over_time(fleet_main_revision_checked_timestamp_seconds[${toString headFresh}h]),
              "instance", "${hostname}", "", ""
            )
          '';
          for = "10m";
          labels.severity = "warning";
          annotations.summary = "{{ $labels.instance }} has not read main's head for ${toString headFresh} hours, so RevisionBehind is judging no host.";
        }
      ]
      ++
        map
          (
            {
              hosts,
              for,
              why,
            }:
            {
              # How long a host has run something other than main's head,
              # judged only while that head is known: read in the last
              # `headFresh` hours. A head that has gone stale would flag every
              # host that upgraded past it. The revision is dropped, so a host
              # that upgrades but is still behind keeps its clock running.
              alert = "RevisionBehind";
              expr = ''
                max by (instance) (fleet_revision_info{${hosts}} unless on (revision) fleet_main_revision_info)
                  and on () (time() - max(fleet_main_revision_checked_timestamp_seconds) < ${toString headFresh} * 3600)
              '';
              inherit for;
              labels.severity = "warning";
              annotations.summary = "{{ $labels.instance }} has not run main's head for ${why}.";
            }
          )
          [
            # A day and a half has missed a night's upgrade: from a merge to
            # the next upgrade is a day at most, or a little more when the
            # first night outruns cache.yml.
            {
              hosts = ''instance!="${router}"'';
              for = "36h";
              why = "36 hours, so it missed a night's upgrade";
            }
            # gate is behind after every merge until it is deployed by hand,
            # so this is a reminder rather than a fault.
            {
              hosts = ''instance="${router}"'';
              for = "7d";
              why = "7 days";
            }
          ];
    }
    {
      # Hourly, since it reads 90 days of samples.
      name = "reminders";
      interval = "1h";
      rules = [
        {
          # A peer's last handshake reads 0 until it connects after gate
          # boots, so its current value cannot say how long it has been
          # silent. The largest value over the window can: 0 does not raise
          # it, and any handshake in the window does. Only once the store has
          # held the peer for the whole window, or a new store would read every
          # peer as silent.
          alert = "WireGuardPeerSilent";
          expr = ''
            max by (instance, peer) (max_over_time(fleet_wireguard_last_handshake_timestamp_seconds[90d])) < time() - 90 * 86400
              and on (instance, peer) max by (instance, peer) (present_over_time(fleet_wireguard_last_handshake_timestamp_seconds[1d] offset 89d))
          '';
          labels.severity = "info";
          annotations.summary = "WireGuard peer {{ $labels.peer }} has not connected in 90 days. Review it, or revoke it (lib/wireguard-keys.nix).";
        }
      ];
    }
  ];
}
