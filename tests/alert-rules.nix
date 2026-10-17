# The alert rules in modules/alert-rules.nix, against series written here:
# each fires on the fault it is for, and stays quiet on the cases
# docs/observability.md argues it past. vmalert-tool runs them against a store
# of its own, in the build, with no VM.
#
# `nix build .#checks.x86_64-linux.alert-rules`. Seconds, not minutes; CI's
# vm-tests job builds it with the rest of `checks`.
#
# Series carry the labels the store gives them at scrape (modules/metrics.nix,
# hosts/gate/metrics.nix): `instance` is a host's name. Kea's subnets and pools
# are read from lib/net.nix, as Kea's own are.
{ pkgs, net }:
let
  inherit (pkgs) lib;
  seg = net.segments;

  rules = pkgs.writeText "alert-rules.json" (
    builtins.toJSON (
      import ../modules/alert-rules.nix {
        inherit lib net;
        hostname = net.metricsCollector;
      }
    )
  );

  # A series as vmalert-tool reads it: a selector and its values, one per
  # interval, in promtool's notation (`a+bxn` is n steps from a by b).
  series =
    name: labels: values:
    let
      pairs = lib.mapAttrsToList (k: v: ''${k}="${v}"'') labels;
    in
    {
      series = "${name}{${lib.concatStringsSep "," pairs}}";
      inherit values;
    };

  # The alerts expected at a time, or none when `alerts` is empty. Each is its
  # labels and its summary, which is checked whole: it is what reaches the
  # phone, and it names things rather than quoting values.
  expect = eval_time: alertname: groupname: alerts: {
    inherit eval_time alertname groupname;
    exp_alerts = map (a: {
      exp_labels = removeAttrs a [ "summary" ];
      exp_annotations.summary = a.summary;
    }) alerts;
  };

  node = instance: {
    job = "node";
    inherit instance;
  };

  # Kea's series for one segment's subnet and its one pool, as the exporter
  # writes both.
  kea =
    name: assigned:
    let
      s = seg.${name};
      subnet = {
        instance = "gate";
        job = "kea";
        operation = "dhcp4";
        subnet = s.subnet;
        subnet_id = toString s.id;
      };
      pool = subnet // {
        pool = "${s.pool.first}-${s.pool.last}";
      };
    in
    [
      (series "kea_dhcp4_addresses_assigned_total" (subnet // { pool = ""; }) "${toString assigned}x20")
      (series "kea_dhcp4_addresses_total" (subnet // { pool = ""; }) "141x20")
      (series "kea_dhcp4_addresses_assigned_total" pool "${toString assigned}x20")
      (series "kea_dhcp4_addresses_total" pool "141x20")
    ];

  # Unbound's answers by code, as counters rising by so many a minute.
  answers =
    instance: perMinute:
    lib.mapAttrsToList (
      rcode: n:
      series "unbound_answer_rcodes_total" {
        job = "unbound";
        inherit instance rcode;
      } "0+${toString n}x40"
    ) perMinute;
  resolverUp =
    instance:
    series "probe_success" {
      job = "probe-resolver";
      inherit instance;
    } "1x40";

  # Minutes, evaluated every minute.
  short = [
    {
      interval = "1m";
      input_series = [
        (series "up" (node "core4") "1 1 0x10")
        (series "up" (node "lifeline") "1x12")
      ];
      alert_rule_test = [
        (expect "6m" "HostDown" "fleet" [ ])
        (expect "9m" "HostDown" "fleet" [
          {
            instance = "core4";
            severity = "critical";
            summary = "core4 has not answered a scrape for 5 minutes.";
          }
        ])
      ];
    }

    # ScrapeDown. core4's Unbound exporter stops, and the blackbox exporter's
    # DNS probes do, which is the exporter. gate's Kea exporter misses one
    # scrape, a restart. One public resolver's probe misses its scrapes and
    # the other's does not, so the exporter answers. vmalert's and
    # node_exporter's are not this rule's.
    {
      interval = "1m";
      input_series = [
        (series "up" {
          job = "unbound";
          instance = "core4";
        } "1x2 0x20")
        (series "up" {
          job = "kea";
          instance = "gate";
        } "1x5 0 1x15")
        (series "up" {
          job = "probe-ping";
          instance = lib.head net.publicResolvers;
        } "0x22")
        (series "up" {
          job = "probe-ping";
          instance = lib.last net.publicResolvers;
        } "1x22")
        (series "up" {
          job = "probe-resolver";
          instance = "core4";
        } "1x2 0x20")
        (series "up" {
          job = "probe-resolver";
          instance = "lifeline";
        } "1x2 0x20")
        (series "up" {
          job = "vmalert";
          instance = "core5";
        } "0x22")
        (series "up" (node "lifeline") "0x22")
      ];
      alert_rule_test = [
        (expect "8m" "ScrapeDown" "fleet" [ ])
        (expect "14m" "ScrapeDown" "fleet" [
          {
            instance = "core4";
            job = "unbound";
            severity = "warning";
            summary = "unbound on core4 has not answered a scrape for 10 minutes.";
          }
          {
            instance = "core5";
            job = "probe-resolver";
            severity = "warning";
            summary = "probe-resolver on core5 has not answered a scrape for 10 minutes.";
          }
        ])
      ];
    }

    # WanDown: the link goes, and with it the lease.
    {
      interval = "1m";
      input_series = [
        (series "node_network_carrier" (node "gate" // { device = "wan"; }) "1x4 0x10")
        (series "fleet_wan_addresses" (node "gate") "1x6 0x8")
        (series "fleet_wan_default_routes" (node "gate") "1x6 0x8")
      ];
      alert_rule_test = [
        (expect "10m" "WanDown" "fleet" [
          {
            instance = "gate";
            severity = "critical";
            summary = "gate's WAN is down: no link, no lease or no default route, or neither public resolver answers a ping.";
          }
        ])
      ];
    }
    # One public resolver not answering is that resolver; both is the house.
    {
      interval = "1m";
      input_series = map (
        ip:
        series "probe_success" {
          job = "probe-ping";
          instance = ip;
        } (if ip == lib.head net.publicResolvers then "0x20" else "1x5 0x15")
      ) net.publicResolvers;
      alert_rule_test = [
        (expect "6m" "WanDown" "fleet" [ ])
        (expect "10m" "WanDown" "fleet" [
          {
            instance = "gate";
            severity = "critical";
            summary = "gate's WAN is down: no link, no lease or no default route, or neither public resolver answers a ping.";
          }
        ])
      ];
    }

    # ResolverFailing. lifeline stops answering its probe. core4 answers 5 a
    # minute, 3 of them SERVFAIL, but 75 in 15 minutes is under the floor of
    # 100. Its 5 a minute of `nodata` would lift it over, and do not count:
    # NOERROR already includes them.
    {
      interval = "1m";
      input_series = [
        (series "probe_success" {
          job = "probe-resolver";
          instance = "lifeline";
        } "1x5 0x30")
        (resolverUp "core4")
      ]
      ++ answers "core4" {
        NOERROR = 2;
        SERVFAIL = 3;
        nodata = 5;
      };
      alert_rule_test = [
        (expect "30m" "ResolverFailing" "fleet" [
          {
            instance = "lifeline";
            severity = "critical";
            summary = "lifeline is failing DNS: it does not answer core5's probe, or over 5% of its answers are SERVFAIL.";
          }
        ])
      ];
    }
    # Above the floor: 8 a minute, 120 in 15 minutes, one in 8 a SERVFAIL.
    {
      interval = "1m";
      input_series = [
        (resolverUp "core4")
      ]
      ++ answers "core4" {
        NOERROR = 7;
        SERVFAIL = 1;
      };
      alert_rule_test = [
        (expect "30m" "ResolverFailing" "fleet" [
          {
            instance = "core4";
            severity = "critical";
            summary = "core4 is failing DNS: it does not answer core5's probe, or over 5% of its answers are SERVFAIL.";
          }
        ])
      ];
    }
    # Busy and healthy: 1 in 50.
    {
      interval = "1m";
      input_series = [
        (resolverUp "core4")
      ]
      ++ answers "core4" {
        NOERROR = 49;
        SERVFAIL = 1;
      };
      alert_rule_test = [ (expect "30m" "ResolverFailing" "fleet" [ ]) ];
    }

    # AdGuard's statistics stop being read on core4, and on lifeline for 20
    # minutes, which is not long enough.
    {
      interval = "1m";
      input_series = [
        (series "fleet_adguard_up" (node "core4") "1x5 0x40")
        (series "fleet_adguard_up" (node "lifeline") "1x10 0x20 1x15")
      ];
      alert_rule_test = [
        (expect "25m" "AdGuardStatsMissing" "fleet" [ ])
        (expect "40m" "AdGuardStatsMissing" "fleet" [
          {
            instance = "core4";
            severity = "warning";
            summary = "AdGuard's statistics on core4 have not been read for 30 minutes.";
          }
        ])
      ];
    }

    {
      interval = "1m";
      input_series = [
        (series "node_nf_conntrack_entries" (node "gate") "100000x5 230000x15")
        (series "node_nf_conntrack_entries_limit" (node "gate") "262144x20")
      ];
      alert_rule_test = [
        (expect "10m" "ConntrackPressure" "fleet" [ ])
        (expect "18m" "ConntrackPressure" "fleet" [
          {
            instance = "gate";
            severity = "warning";
            summary = "gate's conntrack table is over 80% of its limit.";
          }
        ])
      ];
    }

    # iot's pool is 130 of 141 leased; trusted's 10. One alert, though Kea
    # reports iot twice, naming the segment and not the subnet or the pool.
    {
      interval = "1m";
      input_series = kea "iot" 130 ++ kea "trusted" 10;
      alert_rule_test = [
        (expect "17m" "DhcpPoolLow" "fleet" [
          {
            instance = "gate";
            segment = "iot";
            severity = "warning";
            summary = "The iot segment's DHCP pool on gate is over 90% leased.";
          }
        ])
      ];
    }

    {
      interval = "1m";
      input_series = [
        (series "node_thermal_zone_temp" (
          node "lifeline"
          // {
            type = "cpu-thermal";
            zone = "0";
          }
        ) "60x2 76x20")
        (series "node_thermal_zone_temp" (
          node "gate"
          // {
            type = "x86_pkg_temp";
            zone = "1";
          }
        ) "70x22")
      ];
      alert_rule_test = [
        (expect "20m" "HostHot" "fleet" [
          {
            instance = "lifeline";
            severity = "warning";
            summary = "lifeline has been above 75°C for 15 minutes.";
          }
        ])
      ];
    }

    # gate's WAN port fails to send 3 frames a minute, throughout. core4's
    # port counts 200 damaged frames at once, a link renegotiating, and none
    # after.
    {
      interval = "1m";
      input_series = [
        (series "node_network_transmit_errs_total" (node "gate" // { device = "wan"; }) "0+3x50")
        (series "node_network_receive_errs_total" (node "gate" // { device = "wan"; }) "0x50")
        (series "node_network_transmit_errs_total" (node "core4" // { device = "end0"; }) "0x50")
        (series "node_network_receive_errs_total" (node "core4" // { device = "end0"; }) "0x5 200x45")
      ];
      alert_rule_test = [
        (expect "25m" "InterfaceErrors" "fleet" [ ])
        (expect "45m" "InterfaceErrors" "fleet" [
          {
            instance = "gate";
            device = "wan";
            severity = "warning";
            summary = "wan on gate has counted receive or transmit errors for 30 minutes.";
          }
        ])
      ];
    }
  ];

  # DiskFilling, over hours: a root 90% full, seen again through /nix/store,
  # is one alert; a root half full and filling at 100 MB a minute is another;
  # /run gaining a megabyte a minute is not, though at that rate it would be
  # full in under a day. Nor is gate's /boot taking a new kernel and initrd
  # at once, 57 MB of its 1 GB, which the 6 hours' fit draws as a slope that
  # fills it in a day.
  disk =
    let
      fs =
        instance: mountpoint: fstype: size: avail:
        let
          labels = node instance // {
            inherit mountpoint fstype;
            device = "/dev/root";
          };
        in
        [
          (series "node_filesystem_size_bytes" labels "${toString size}x180")
          (series "node_filesystem_avail_bytes" labels avail)
        ];
    in
    [
      {
        interval = "1m";
        input_series =
          fs "lifeline" "/" "ext4" 100000000000 "10000000000x180"
          ++ fs "lifeline" "/nix/store" "ext4" 100000000000 "10000000000x180"
          ++ fs "core4" "/" "ext4" 100000000000 "50000000000-100000000x180"
          ++ fs "core5" "/run" "tmpfs" 1000000000 "1000000000-1000000x180"
          ++ fs "gate" "/boot" "vfat" 1000000000 "941000000x59 884000000x120";
        alert_rule_test = [
          (expect "30m" "DiskFilling" "fleet" [ ])
          (expect "90m" "DiskFilling" "fleet" [
            {
              instance = "core4";
              mountpoint = "/";
              severity = "warning";
              summary = "/ on core4 is over 85% full, or at its rate will be full within 3 days.";
            }
            {
              instance = "lifeline";
              mountpoint = "/";
              severity = "warning";
              summary = "/ on lifeline is over 85% full, or at its rate will be full within 3 days.";
            }
          ])
          (expect "170m" "DiskFilling" "fleet" [
            {
              instance = "core4";
              mountpoint = "/";
              severity = "warning";
              summary = "/ on core4 is over 85% full, or at its rate will be full within 3 days.";
            }
            {
              instance = "lifeline";
              mountpoint = "/";
              severity = "warning";
              summary = "/ on lifeline is over 85% full, or at its rate will be full within 3 days.";
            }
          ])
        ];
      }
    ];

  # RevisionBehind and WireGuardPeerSilent, over days, evaluated hourly.
  # Series that hold a time count from vmalert-tool's clock, which starts at
  # 2000-01-01, so `at h` is a timestamp h hours in.
  start = 946684800;
  at = h: toString (start + h * 3600);
  long = [
    # core4 runs an old revision throughout, core5 main's head, and gate the
    # same old one, which it may do for a week.
    {
      interval = "1h";
      input_series = [
        (series "fleet_revision_info" (node "core4" // { revision = "old"; }) "1x48")
        (series "fleet_revision_info" (node "core5" // { revision = "head"; }) "1x48")
        (series "fleet_revision_info" (node "gate" // { revision = "old"; }) "1x48")
        (series "fleet_main_revision_info" (node "core5" // { revision = "head"; }) "1x48")
        (series "fleet_main_revision_checked_timestamp_seconds" (node "core5") "${at 0}+3600x48")
      ];
      alert_rule_test = [
        (expect "34h" "RevisionBehind" "fleet" [ ])
        (expect "38h" "RevisionCheckStale" "fleet" [ ])
        (expect "38h" "RevisionBehind" "fleet" [
          {
            instance = "core4";
            severity = "warning";
            summary = "core4 has not run main's head for 36 hours, so it missed a night's upgrade.";
          }
        ])
      ];
    }
    # main's head last read 5 hours in: by 38 hours it is too old to judge by,
    # and from 11 hours that is an alert of its own.
    {
      interval = "1h";
      input_series = [
        (series "fleet_revision_info" (node "core4" // { revision = "old"; }) "1x48")
        (series "fleet_main_revision_info" (node "core5" // { revision = "head"; }) "1x48")
        (series "fleet_main_revision_checked_timestamp_seconds" (node "core5") "${at 0}+3600x5 ${at 5}x43")
      ];
      alert_rule_test = [
        (expect "38h" "RevisionBehind" "fleet" [ ])
        (expect "11h" "RevisionCheckStale" "fleet" [ ])
        (expect "13h" "RevisionCheckStale" "fleet" [
          {
            instance = "core5";
            severity = "warning";
            summary = "core5 has not read main's head for 6 hours, so RevisionBehind is judging no host.";
          }
        ])
      ];
    }
    # The file gone 2 hours in, as after a boot whose reads all fail: absent
    # for 6 hours is the same fault.
    {
      interval = "1h";
      input_series = [
        (series "fleet_main_revision_checked_timestamp_seconds" (node "core5") "${at 0}+3600x2 _x20")
      ];
      alert_rule_test = [
        (expect "7h" "RevisionCheckStale" "fleet" [ ])
        (expect "10h" "RevisionCheckStale" "fleet" [
          {
            instance = "core5";
            severity = "warning";
            summary = "core5 has not read main's head for 6 hours, so RevisionBehind is judging no host.";
          }
        ])
      ];
    }

    # 100 days of gate's view of three peers. phone connected in the first
    # hour and never again, and has read 0 since gate rebooted on day 50. forge connected every hour until gate rebooted 6
    # days ago, and has not since, so it reads 0. new appears 10 days ago and
    # has never connected: the store has not seen it long enough to say.
    {
      interval = "1h";
      input_series = [
        (series "fleet_wireguard_last_handshake_timestamp_seconds" {
          job = "node";
          instance = "gate";
          peer = "phone";
        } "${at 1}x1200 0x1200")
        (series "fleet_wireguard_last_handshake_timestamp_seconds" {
          job = "node";
          instance = "gate";
          peer = "forge";
        } "${at 0}+3600x2256 0x144")
        (series "fleet_wireguard_last_handshake_timestamp_seconds" {
          job = "node";
          instance = "gate";
          peer = "new";
        } "_x2160 0x240")
      ];
      alert_rule_test = [
        (expect "2399h" "WireGuardPeerSilent" "reminders" [
          {
            instance = "gate";
            peer = "phone";
            severity = "info";
            summary = "WireGuard peer phone has not connected in 90 days. Review it, or revoke it (lib/wireguard-keys.nix).";
          }
        ])
      ];
    }
  ];

  file =
    name: evaluation_interval: tests:
    pkgs.writeText "${name}.json" (
      builtins.toJSON {
        rule_files = [ rules ];
        inherit evaluation_interval tests;
      }
    );
in
pkgs.runCommand "alert-rules" { nativeBuildInputs = [ pkgs.victoriametrics ]; } ''
  # A dry run first, so a rule vmalert cannot load fails here by name.
  vmalert -dryRun -rule=${rules}
  vmalert-tool unittest \
    --files ${file "short" "1m" short} \
    --files ${file "disk" "1m" disk} \
    --files ${file "long" "1h" long}
  touch $out
''
