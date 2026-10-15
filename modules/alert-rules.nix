# The alert rules vmalert evaluates on the collector (modules/alerting.nix), as
# vmalert's rule file. A function rather than a module, so that
# tests/alert-rules.nix can check the same rules against series of its own
# without evaluating a host. docs/observability.md, "Alerts", has the table
# and the reasons for each threshold.
#
# Labels are the alert's name, `instance` (a host's name, which
# modules/metrics.nix sets at scrape and ntfy's template shows), `severity`,
# and where one is needed, a name from lib/net.nix: a segment, a WireGuard
# peer, a mountpoint. Never an address and never a value, since every label
# and annotation leaves the house in the push.
{
  lib,
  net,
  hostname,
}:
let
  # The router, which is judged apart from the Pis wherever it differs: it
  # holds the WAN and the DHCP pools, and it upgrades by hand.
  router = "gate";

  # Kea labels its statistics with the subnet in CIDR form and with Kea's
  # subnet id, which hosts/gate/routing.nix sets to the segment's VLAN id. The
  # alert names the segment instead, so no address leaves the house.
  pooled = lib.attrNames (lib.filterAttrs (_: s: s ? pool) net.segments);
  bySegment =
    expr:
    lib.foldl' (
      e: name:
      ''label_replace(${e}, "segment", "${name}", "subnet_id", "${toString net.segments.${name}.id}")''
    ) expr pooled;
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
          alert = "ConntrackPressure";
          expr = ''
            max by (instance) (node_nf_conntrack_entries{instance="${router}"} / node_nf_conntrack_entries_limit{instance="${router}"}) > 0.8
          '';
          for = "10m";
          labels.severity = "warning";
          annotations.summary = "{{ $labels.instance }}'s conntrack table is over 80% of its limit.";
        }
        {
          # Kea reports each pool and each subnet. The pools' series alone,
          # so a pool is counted once, and since every segment has one pool,
          # summed by segment. A pool's count leaves out reservations below it,
          # which the subnet's count includes and the pool can never run out of.
          alert = "DhcpPoolLow";
          expr = ''
            sum by (instance, segment) (${bySegment ''kea_dhcp4_addresses_assigned_total{pool!=""}''})
              / sum by (instance, segment) (${bySegment ''kea_dhcp4_addresses_total{pool!=""}''})
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
          # last 6 hours', so the nightly upgrade's burst of writes is a
          # fraction of it, and either has to hold for an hour.
          alert = "DiskFilling";
          expr = ''
            max by (instance, mountpoint) (
              1 - node_filesystem_avail_bytes{mountpoint!="/nix/store"} / node_filesystem_size_bytes{mountpoint!="/nix/store"} > 0.85
              or predict_linear(node_filesystem_avail_bytes{mountpoint!="/nix/store", fstype!="tmpfs"}[6h], 3 * 86400) < 0
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
              # judged only while that head is known: read in the last 6 hours.
              # A head that has gone stale would flag every host that upgraded
              # past it. The revision is dropped, so a host that upgrades but
              # is still behind keeps its clock running.
              alert = "RevisionBehind";
              expr = ''
                max by (instance) (fleet_revision_info{${hosts}} unless on (revision) fleet_main_revision_info)
                  and on () (time() - max(fleet_main_revision_checked_timestamp_seconds) < 6 * 3600)
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
