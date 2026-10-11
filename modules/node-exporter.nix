# node_exporter on every host in net.metricsTargets, scraped by the collector
# (modules/metrics.nix). Imported by hosts/common and inert elsewhere, so the
# list in lib/net.nix is the one switch. docs/observability.md has the design.
{
  config,
  lib,
  pkgs,
  hostname,
  net,
  ...
}:
let
  host = net.hosts.${hostname} or { };
  collector = net.hosts.${net.metricsCollector};
  port = net.ports.nodeExporter;

  # host-status's two facts (modules/host-status.nix), as metrics, so the store
  # can see a host running the wrong system. Read when the timer fires rather
  # than written at build time: nixos-version is built with its generation's
  # revision inside it, so this calls the one in /run/current-system, which
  # after a switch or a fallback boot is whatever is actually running. One
  # series each, with the fact as a label and the value 1.
  textfileDir = "/run/fleet-metrics";
  facts = pkgs.writeShellApplication {
    name = "fleet-metrics-facts";
    runtimeInputs = with pkgs; [
      coreutils
      util-linux
    ];
    text = ''
      # Label values are quoted in the exposition format, so neither may carry
      # a quote or a backslash. Neither should; this keeps a surprise from
      # breaking the whole file.
      clean() { tr -d '"\\\n'; }

      revision=$(/run/current-system/sw/bin/nixos-version --configuration-revision 2>/dev/null || echo unknown)
      root=$(findmnt -no SOURCE /)

      tmp=$(mktemp -p ${textfileDir})
      {
        echo '# HELP fleet_revision_info The flake revision the running system was built from.'
        echo '# TYPE fleet_revision_info gauge'
        printf 'fleet_revision_info{revision="%s"} 1\n' "$(printf %s "$revision" | clean)"
        echo '# HELP fleet_root_device_info The device the root filesystem is mounted from.'
        echo '# TYPE fleet_root_device_info gauge'
        printf 'fleet_root_device_info{device="%s"} 1\n' "$(printf %s "$root" | clean)"
      } >"$tmp"
      chmod 0644 "$tmp"
      # A rename, so the collector never reads a half-written file.
      mv "$tmp" ${textfileDir}/fleet.prom
    '';
  };
in
lib.mkIf (lib.elem hostname net.metricsTargets) {
  services.prometheus.exporters.node = {
    enable = true;
    inherit port;
    # The host's own address, never every address: the same reasoning as
    # sshd's bind in modules/ssh.nix, whose ip_nonlocal_bind also covers the
    # boot race here.
    listenAddress = host.ip;
    extraFlags = [
      "--collector.textfile.directory=${textfileDir}"
      # Docker names a new veth for every container start, and each new name
      # is a new set of series that never ends. Only core5 runs Docker; the
      # flags cost nothing elsewhere.
      "--collector.netdev.device-exclude=^veth"
      "--collector.netclass.ignored-devices=^veth"
    ];
    # Not `openFirewall`: it writes its rule with ip46tables, and an IPv4
    # source in that rule fails the IPv6 half, which fails the firewall's start.
  };

  # The host's LAN interface, from the collector's address alone. Not the
  # whole segment: servers also holds the switch, the AP and anything on an
  # untagged switch port. The collector scrapes itself over loopback, which
  # the base ruleset accepts, so it opens nothing.
  networking.firewall.extraCommands = lib.mkIf (hostname != net.metricsCollector) ''
    iptables -A nixos-fw -i ${host.iface} -p tcp --dport ${toString port} -s ${collector.ip} -j nixos-fw-accept
  '';

  # At boot and every five minutes. The revision changes under a running host
  # at each nightly switch, so once at boot would not do, and a new timer fires
  # at once when a switch starts it.
  systemd.services.fleet-metrics-facts = {
    description = "Write host-status's facts for node_exporter";
    serviceConfig = import ../lib/hardening.nix // {
      Type = "oneshot";
      ExecStart = lib.getExe facts;
      # node_exporter's own user, the one reader. Not DynamicUser: systemd
      # then puts the directory under /run/private, which is 0700, and
      # node_exporter cannot open it.
      User = config.services.prometheus.exporters.node.user;
      RuntimeDirectory = baseNameOf textfileDir;
      RuntimeDirectoryMode = "0755";
      # Kept between runs, or the file would vanish each time this exits.
      RuntimeDirectoryPreserve = true;
    };
  };
  systemd.timers.fleet-metrics-facts = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = 0;
      OnUnitActiveSec = "5min";
    };
  };
}
