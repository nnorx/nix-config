# gate's half of the fleet's metrics: what docs/router.md watches the router for,
# for core5 to scrape (modules/metrics.nix). docs/observability.md is the
# runbook; this file has what gate needed beyond node_exporter, which
# modules/node-exporter.nix runs here as on every target.
#
# What answers each question:
#
#   WAN link and lease    node_exporter's netclass for carrier, and the
#                         textfile below for the lease and the default route
#   conntrack             node_exporter's conntrack collector, count and limit
#   interfaces            node_exporter's netdev, bytes, errors and drops
#   Kea pools             Kea's own statistics, through the exporter below
#   WireGuard             the textfile below, each peer's last handshake
#   Exit tunnel           the textfile below: handshake, bytes, server role,
#                         leak drops and bypasses
#   New trusted devices   the textfile below, from ./trusted-clients.nix
#
# Both exporters bind gate's gateway address on its metricsSegment and nothing
# else, and their ports open on the interface carrying that segment, from the
# collector's address alone. Never `wan`.
{
  config,
  lib,
  pkgs,
  net,
  ...
}:
let
  gate = net.hosts.gate;
  collector = net.hosts.${net.metricsCollector};
  address = net.segments.${gate.metricsSegment}.gateway;
  keys = import ../../lib/wireguard-keys.nix;

  # The interface holding that address, found in the addressing ./routing.nix
  # generates rather than named here, for the reason it gives for sshd's binds:
  # `lan0` once meant trusted and now means servers, and a second list of
  # names would not have followed it.
  holdsAddress =
    i: lib.any (a: a.address == address) config.networking.interfaces.${i}.ipv4.addresses;
  scrapeIfaces = lib.filter holdsAddress (builtins.attrNames config.networking.interfaces);
  scrapeIface = builtins.head scrapeIfaces;

  # Kea's control socket, which it has only for this. In /run/kea, where Kea 3
  # expects its control sockets, and which the exporter's unit shares.
  keaSocket = "/run/kea/kea-dhcp4.socket";

  # The directory modules/node-exporter.nix points node_exporter's textfile
  # collector at, where host-status's facts already go.
  textfileDir = "/run/fleet-metrics";

  # Peers by public key, so a handshake is reported under the peer's name.
  # Endpoints are not read at all: a peer's address on the internet says
  # where its owner is.
  peerCases = lib.concatStringsSep "\n" (
    lib.mapAttrsToList (name: key: "'${key}') peer=${name} ;;") keys.peers
  );

  # The exit tunnel's state that its failover watchdog and exit-bypass keep:
  # the role of the server in use, and one file per bypassed segment. Roles
  # are the sops entries' names; the resolvers' recursion bypasses as one.
  exit = gate.exitIface;
  exitServerFile = "/run/exit-tunnel/server";
  bypassDir = "/run/exit-bypass";
  exitRoles = [
    "primary"
    "failover1"
    "failover2"
  ];
  bypassable = net.exitSegments ++ [ "resolvers" ];

  # ./trusted-clients.nix's count, which it publishes for this alone.
  newClientsFile = "/run/gate-trusted-clients/count";

  # The lease, the WireGuard handshakes and the exit tunnel, as metrics. None
  # has a collector in node_exporter. Nothing here prints the WAN address: jq
  # reads it, and emits only counts and lifetimes.
  facts = pkgs.writeShellApplication {
    name = "gate-metrics-facts";
    runtimeInputs = with pkgs; [
      coreutils
      gawk
      iproute2
      jq
      nftables
      wireguard-tools
    ];
    text = ''
      # `ip -j` can print nothing at all for an empty answer, and prints
      # nothing when `wan` does not exist; slurping reads either as none.
      addrs=$(ip -j -4 addr show dev ${gate.wanIface} scope global 2>/dev/null || true)
      addresses=$(printf %s "$addrs" | jq -s '[add // [] | .[].addr_info[]] | length')
      # dhcpcd gives the address the lease's lifetime, and the kernel counts it
      # down until a renewal resets it. 0 when there is no address at all.
      remaining=$(printf %s "$addrs" | jq -s '[add // [] | .[].addr_info[].valid_life_time] | min // 0')
      routes=$(ip -j -4 route show default dev ${gate.wanIface} 2>/dev/null || true)
      routes=$(printf %s "$routes" | jq -s 'add // [] | length')

      # The exit tunnel by what it does, never by whom it reaches: awk drops
      # the provider's key, and the server is named by role. A tunnel that is
      # gone reads as no handshake and nothing carried, not as missing.
      read -r handshake < <(wg show ${exit} latest-handshakes 2>/dev/null | awk '$2 > m { m = $2 } END { printf "%d\n", m }')
      read -r rx tx < <(wg show ${exit} transfer 2>/dev/null | awk '{ rx += $2; tx += $3 } END { printf "%d %d\n", rx, tx }')
      # No file is primary. One that cannot be read names no role, so it shows.
      server=primary
      if [ -e ${exitServerFile} ]; then
        server=$(tr -d '[:space:]' 2>/dev/null <${exitServerFile}) || server=""
      fi
      leak=$(nft -j list counter inet nixos-fw exit-leak-dropped 2>/dev/null |
        jq -r '.nftables[].counter // empty | "\(.packets) \(.bytes)"') || leak=""
      newClients=""
      if [ -e ${newClientsFile} ]; then
        newClients=$(tr -dc 0-9 2>/dev/null <${newClientsFile}) || newClients=""
      fi

      tmp=$(mktemp -p ${textfileDir})
      {
        echo '# HELP fleet_wan_addresses Global IPv4 addresses on wan. 0 is no DHCP lease.'
        echo '# TYPE fleet_wan_addresses gauge'
        echo "fleet_wan_addresses $addresses"
        echo '# HELP fleet_wan_lease_remaining_seconds Lifetime left on the wan address, which a renewal resets.'
        echo '# TYPE fleet_wan_lease_remaining_seconds gauge'
        echo "fleet_wan_lease_remaining_seconds $remaining"
        echo '# HELP fleet_wan_default_routes IPv4 default routes out wan.'
        echo '# TYPE fleet_wan_default_routes gauge'
        echo "fleet_wan_default_routes $routes"

        echo '# HELP fleet_wireguard_last_handshake_timestamp_seconds When each peer last completed a handshake. 0 is not since wg0 came up.'
        echo '# TYPE fleet_wireguard_last_handshake_timestamp_seconds gauge'
        # A peer missing from the output, as when wg0 is down, is missing
        # here too, rather than reported as never having handshaked.
        wg show ${gate.vpnIface} latest-handshakes 2>/dev/null | while read -r key stamp; do
          case "$key" in
            ${peerCases}
            *) continue ;;
          esac
          printf 'fleet_wireguard_last_handshake_timestamp_seconds{peer="%s"} %s\n' "$peer" "$stamp"
        done || true

        echo '# HELP fleet_exit_last_handshake_timestamp_seconds When ${exit} last completed a handshake. 0 is not since it came up, or no ${exit}.'
        echo '# TYPE fleet_exit_last_handshake_timestamp_seconds gauge'
        echo "fleet_exit_last_handshake_timestamp_seconds $handshake"
        echo '# HELP fleet_exit_receive_bytes_total Bytes received from the exit server.'
        echo '# TYPE fleet_exit_receive_bytes_total counter'
        echo "fleet_exit_receive_bytes_total $rx"
        echo '# HELP fleet_exit_transmit_bytes_total Bytes sent to the exit server.'
        echo '# TYPE fleet_exit_transmit_bytes_total counter'
        echo "fleet_exit_transmit_bytes_total $tx"
        echo '# HELP fleet_exit_server 1 for the role of the exit server in use, from ${exitServerFile}; primary without it.'
        echo '# TYPE fleet_exit_server gauge'
        for role in ${toString exitRoles}; do
          printf 'fleet_exit_server{role="%s"} %d\n' "$role" "$([ "$server" = "$role" ] && echo 1 || echo 0)"
        done
        echo '# HELP fleet_exit_bypass_open 1 while exit-bypass is open for a segment, as ${bypassDir}/<segment> exists.'
        echo '# TYPE fleet_exit_bypass_open gauge'
        ${lib.concatMapStrings (segment: ''
          printf 'fleet_exit_bypass_open{segment="${segment}"} %d\n' "$([ -e ${bypassDir}/${segment} ] && echo 1 || echo 0)"
        '') bypassable}
        # Left out only if the ruleset has no such counter.
        if [ -n "$leak" ]; then
          read -r packets bytes <<<"$leak"
          echo '# HELP fleet_exit_leak_dropped_packets_total Packets from tunneled segments routed out wan and dropped. A ruleset reload zeroes it.'
          echo '# TYPE fleet_exit_leak_dropped_packets_total counter'
          echo "fleet_exit_leak_dropped_packets_total $packets"
          echo '# HELP fleet_exit_leak_dropped_bytes_total Bytes from tunneled segments routed out wan and dropped. A ruleset reload zeroes it.'
          echo '# TYPE fleet_exit_leak_dropped_bytes_total counter'
          echo "fleet_exit_leak_dropped_bytes_total $bytes"
        fi
        # Left out until ./trusted-clients.nix has first run.
        if [ -n "$newClients" ]; then
          echo '# HELP fleet_kea_new_trusted_clients_total Devices Kea leased to on trusted for the first time.'
          echo '# TYPE fleet_kea_new_trusted_clients_total counter'
          echo "fleet_kea_new_trusted_clients_total $newClients"
        fi
      } >"$tmp"
      chmod 0644 "$tmp"
      mv "$tmp" ${textfileDir}/gate.prom
    '';
  };
in
{
  assertions = [
    {
      assertion = builtins.length scrapeIfaces == 1;
      message = ''
        gate's metricsSegment is "${gate.metricsSegment}", whose gateway
        ${address} should be on exactly one of gate's interfaces, and is on
        ${toString (builtins.length scrapeIfaces)}: ${toString scrapeIfaces}.
        hosts/gate/metrics.nix opens the exporters' ports on that interface.
      '';
    }
  ];

  services.kea.dhcp4.settings.control-socket = {
    socket-type = "unix";
    socket-name = keaSocket;
  };

  # The control socket answers any command, not only statistics, so the
  # exporter is held to Kea's own user, which nixpkgs runs it as: nothing gains
  # a power over Kea that Kea's own process does not already have.
  services.prometheus.exporters.kea = {
    enable = true;
    listenAddress = address;
    port = net.ports.keaExporter;
    targets = [ keaSocket ];
  };
  systemd.services.prometheus-kea-exporter.serviceConfig = {
    # It exits at start if the socket is not there yet: at boot, since it is
    # ordered after Kea but Kea does not signal readiness, and while Kea loops
    # on an interface without carrier (./routing.nix). At systemd's default of
    # 100 ms between restarts it would spend the start limit, 5 in 10 seconds,
    # and stay failed. At 5 seconds it keeps trying until the socket is there.
    RestartSec = "5s";
    # Both units set up /run/kea, and each start applies its own mode. Kea's
    # is 0750; without this the exporter would widen it to 0755.
    RuntimeDirectoryMode = "0750";
  };

  # Rendered only once the interface is known, so a wrong metricsSegment is
  # reported by the assertion above rather than by `head` of an empty list.
  networking.firewall.extraInputRules = lib.optionalString (builtins.length scrapeIfaces == 1) ''
    iifname "${scrapeIface}" ip saddr ${collector.ip} tcp dport { ${toString net.ports.nodeExporter}, ${toString net.ports.keaExporter} } accept comment "metrics, to ${net.metricsCollector} alone"
  '';

  # Every 30 seconds, the scrape interval. All of it changes under a running
  # system, so this is read rather than written at build time.
  systemd.services.gate-metrics-facts = {
    description = "Write gate's WAN lease, WireGuard handshakes and exit tunnel and new trusted devices for node_exporter";
    serviceConfig = import ../../lib/hardening.nix // {
      Type = "oneshot";
      ExecStart = lib.getExe facts;
      # node_exporter's user, as for host-status's facts. `wg show` and `nft`
      # need CAP_NET_ADMIN to read, and that is all this holds.
      User = config.services.prometheus.exporters.node.user;
      AmbientCapabilities = [ "CAP_NET_ADMIN" ];
      CapabilityBoundingSet = [ "CAP_NET_ADMIN" ];
      RuntimeDirectory = baseNameOf textfileDir;
      RuntimeDirectoryMode = "0755";
      RuntimeDirectoryPreserve = true;
      # Every 30 seconds, systemd's own "Starting" and "Finished" lines would
      # be thousands a day in gate's journal. Notice and above still come
      # through, so a failed run is logged as before.
      LogLevelMax = "notice";
    };
  };
  systemd.timers.gate-metrics-facts = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = 0;
      OnUnitActiveSec = "30s";
      # The default would let a 30-second timer drift by up to a minute.
      AccuracySec = "1s";
    };
  };
}
