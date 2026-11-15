# The exit tunnel: gate as a WireGuard client of a VPN provider, so a segment
# in `exitSegments` (lib/net.nix), and with `exitResolvers` the resolvers'
# port 53, reaches the internet through it rather than `wan`, and through
# nothing when it is down. docs/router.md, "Exit tunnel",
# has the design and the runbook.
#
# Not `networking.wireguard`, which takes the peer as Nix strings: the
# provider's key, its endpoint and gate's inner address identify the provider
# and the account, so they stay in sops and reach only /run.
{
  config,
  lib,
  pkgs,
  net,
  segmentOn,
  ...
}:
let
  exit = net.hosts.gate.exitIface;
  wan = net.hosts.gate.wanIface;
  table = toString net.exitTable.id;

  # Rule priorities, ahead of `main` at 32766.
  suppressPriority = "1000";
  ifacePriority = "1100";
  markPriority = "1200";

  nftSet = xs: "{ ${lib.concatStringsSep ", " xs} }";
  quoted = map (x: "\"${x}\"");

  tunneled = builtins.attrNames (lib.filterAttrs (_: s: builtins.elem s net.exitSegments) segmentOn);
  tunneledSet = nftSet (quoted tunneled);

  # The resolvers' port 53 from where they sit, so no other host and no
  # spoofed source is marked. gate's own DNS is output, never prerouting.
  mark = toString net.exitMark;
  resolverIps = map (h: net.hosts.${h}.ip) net.resolvers;
  resolverSegments = map (h: net.hosts.${h}.segment) net.resolvers;
  resolverIfaces = builtins.attrNames (
    lib.filterAttrs (_: s: builtins.elem s resolverSegments) segmentOn
  );
  houseSet = nftSet (lib.mapAttrsToList (_: s: s.subnet) net.segments);

  # The rules wanted at the mark's priority, as `ip -j rule` prints them.
  markRules = builtins.toJSON (
    lib.optional net.exitResolvers {
      src = "all";
      fwmark = "0x${lib.toLower (lib.toHexString net.exitMark)}";
      table = net.exitTable.name;
    }
  );

  # IPv4 and TCP headers. The route out a LAN interface says 1500, so the
  # clamp on what comes in from the provider names the tunnel's figure.
  exitMss = toString (net.exitMtu - 40);

  conf = config.sops.templates."exit-tunnel.conf";
  ph = config.sops.placeholder;

  # Servers in one city, in the order the watchdog tries them. The key and
  # inner address are the account's, so each takes the same interface.
  roles = [
    "primary"
    "failover1"
    "failover2"
  ];
  privateKey = lib.escapeShellArg config.sops.secrets.exit-private-key.path;
  secretPaths =
    what: toString (map (r: lib.escapeShellArg config.sops.secrets."exit-${r}-${what}".path) roles);
  # gate-metrics-facts (./metrics.nix) reads the role in use from here.
  stateDir = "/run/exit-tunnel";
  keepalive = toString 25;
  deadAfter = toString 180;

  watchdog = pkgs.writeShellApplication {
    name = "exit-watchdog";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.gawk
      pkgs.wireguard-tools
    ];
    text = ''
      roles=(${toString roles})
      keys=(${secretPaths "public-key"})
      endpoints=(${secretPaths "endpoint"})

      record() {
        local tmp
        tmp=$(mktemp -p ${stateDir})
        printf '%s\n' "$1" >"$tmp"
        chmod 0644 "$tmp"
        mv "$tmp" ${stateDir}/server
      }

      # The tunnel's own config with that role's server, made by printf, a
      # builtin, so no key or endpoint is in any process's arguments; syncconf
      # drops the old peer. wg would print a value it refused, so its errors
      # are replaced.
      use_role() {
        local key endpoint
        key=$(cat "''${keys[$1]}") || key=""
        endpoint=$(cat "''${endpoints[$1]}") || endpoint=""
        if wg syncconf ${exit} <(printf '[Interface]\nPrivateKey = %s\n\n[Peer]\nPublicKey = %s\nEndpoint = %s\nAllowedIPs = 0.0.0.0/0\nPersistentKeepalive = %s\n' \
          "$(cat ${privateKey})" "$key" "$endpoint" ${keepalive}) 2>/dev/null; then
          record "''${roles[$1]}"
        else
          echo "wg refused ''${roles[$1]}: check its exit-* entries in secrets/gate.yaml" >&2
          return 1
        fi
      }

      # By hand, with the unit stopped: `exit-watchdog <role>` switches once.
      if [ $# -gt 0 ]; then
        for i in "''${!roles[@]}"; do
          if [ "$1" = "''${roles[i]}" ]; then
            use_role "$i" && echo "switched to $1"
            exit
          fi
        done
        echo "usage: exit-watchdog [''${roles[*]}]" >&2
        exit 2
      fi

      # The role is found by the peer's key, so restarting this unit alone
      # keeps the server in use. A key that is none of them names no role.
      peer=$(wg show ${exit} peers | head -n 1)
      current=-1
      role="no role"
      for i in "''${!roles[@]}"; do
        if [ "$peer" = "$(cat "''${keys[i]}")" ]; then
          current=$i
          role=''${roles[i]}
          break
        fi
      done
      if [ "$current" -ge 0 ]; then
        echo "on $role"
        record "$role"
      else
        echo "${exit}'s peer is no role's, so the next switch is to ''${roles[0]}"
        record ""
      fi

      # Judged from the later of its last handshake and the last switch (or
      # this start), so a server just switched to has the full time to answer.
      since=$(date +%s)
      while sleep 10; do
        now=$(date +%s)
        handshake=$(wg show ${exit} latest-handshakes | awk '$2 > m { m = $2 } END { print m + 0 }')
        [ "$handshake" -gt "$since" ] || handshake=$since
        [ $((now - handshake)) -gt ${deadAfter} ] || continue

        next=$(((current + 1) % ''${#roles[@]}))
        if use_role "$next"; then
          echo "no handshake from $role in ${deadAfter} s, switched to ''${roles[next]}"
          role=''${roles[next]}
        fi
        current=$next
        since=$now
      done
    '';
  };
in
{
  sops.secrets = {
    exit-private-key = { };
    exit-address.restartUnits = [ "exit-tunnel.service" ];
  }
  # Read at each switch, so a new failover needs no restart.
  // lib.genAttrs (lib.concatMap (r: [
    "exit-${r}-public-key"
    "exit-${r}-endpoint"
  ]) roles) (_: { });

  # Read only at start, so a new key or server restarts the tunnel.
  sops.templates."exit-tunnel.conf" = {
    restartUnits = [ "exit-tunnel.service" ];
    content = ''
      [Interface]
      PrivateKey = ${ph.exit-private-key}

      [Peer]
      PublicKey = ${ph.exit-primary-public-key}
      Endpoint = ${ph.exit-primary-endpoint}
      AllowedIPs = 0.0.0.0/0
      PersistentKeepalive = ${keepalive}
    '';
  };

  networking.iproute2 = {
    enable = true;
    rttablesExtraConfig = "${table} ${net.exitTable.name}";
  };

  # Fail closed, before any interface is configured. The exit table falls back
  # to `unreachable`, so a tunnel that is gone never falls through to `main`;
  # `main` minus its default route still wins, so the house's own subnets
  # stay local. gate's own traffic matches no `iif` rule and keeps `main`.
  #
  # Every start reconciles the `iif` rules with `exitSegments`, removing those
  # for segments no longer listed. A change to the list changes this script,
  # so a switch restarts the unit. The tunnel only wants it, so stays up.
  systemd.services.exit-routing = {
    description = "Exit tunnel routing rules, failing closed";
    wantedBy = [ "multi-user.target" ];
    wants = [ "network-pre.target" ];
    before = [
      "network-pre.target"
      "network.target"
      "exit-tunnel.service"
    ];
    unitConfig.DefaultDependencies = false;
    path = [
      pkgs.iproute2
      pkgs.jq
    ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      ip route replace unreachable default metric 100 table ${table}

      rules=$(ip -j rule show)
      if ! jq -e 'any(.[]; .priority == ${suppressPriority} and .table == "main" and .suppress_prefixlen == 0)' <<<"$rules" >/dev/null; then
        ip rule add priority ${suppressPriority} lookup main suppress_prefixlength 0
      fi

      # One rule per listed segment into the exit table; any other here goes.
      wanted=" ${toString tunneled} "
      have=" "
      while read -r tbl iface; do
        if [ -n "$iface" ] && [ "$tbl" = ${net.exitTable.name} ] && [[ $wanted == *" $iface "* && $have != *" $iface "* ]]; then
          have+="$iface "
          continue
        fi
        sel=(priority ${ifacePriority} table "$tbl")
        [ -z "$iface" ] || sel+=(iif "$iface")
        ip rule del "''${sel[@]}"
      done < <(jq -r '.[] | select(.priority == ${ifacePriority}) | "\(.table) \(.iif // "")"' <<<"$rules")
      for iface in $wanted; do
        [[ $have == *" $iface "* ]] || ip rule add priority ${ifacePriority} iif "$iface" table ${table}
      done

      # The resolvers' mark into the exit table while `exitResolvers` is on,
      # and nothing else at its priority. Anything but exactly that is
      # rewritten whole: a near miss, such as `not fwmark`, would send gate's
      # own traffic into the tunnel.
      if ! jq -e --argjson want '${markRules}' '[.[] | select(.priority == ${markPriority}) | del(.priority)] == $want' <<<"$rules" >/dev/null; then
        echo "rewriting the rules at ${markPriority}"
        while ip rule del priority ${markPriority} 2>/dev/null; do :; done
        ${lib.optionalString net.exitResolvers "ip rule add priority ${markPriority} fwmark ${mark} table ${table}"}
      fi
    '';
  };

  # Errors are replaced rather than shown, since `wg` and `ip` would print the
  # value they refused into the journal.
  systemd.services.exit-tunnel = {
    description = "Exit tunnel to the VPN provider";
    wantedBy = [ "multi-user.target" ];
    wants = [ "exit-routing.service" ];
    # After the firewall too, which holds the leak drop.
    after = [
      "exit-routing.service"
      "nftables.service"
      "network-pre.target"
    ];
    restartTriggers = [ conf.file ];
    path = [
      pkgs.iproute2
      pkgs.wireguard-tools
    ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      ip link show dev ${exit} >/dev/null 2>&1 || ip link add dev ${exit} type wireguard
      # Loose, as a reply's source routes by `main`, out `wan`.
      echo 2 > /proc/sys/net/ipv4/conf/${exit}/rp_filter
      if ! wg setconf ${exit} ${conf.path} 2>/dev/null; then
        echo "wg refused ${conf.path}: check the exit-* entries in secrets/gate.yaml" >&2
        exit 1
      fi
      if ! ip address replace "$(cat ${config.sops.secrets.exit-address.path})" dev ${exit} 2>/dev/null; then
        echo "ip refused exit-address from secrets/gate.yaml" >&2
        exit 1
      fi
      ip link set dev ${exit} mtu ${toString net.exitMtu} up
      ip route replace default dev ${exit} table ${table}
    '';
    postStop = ''
      ip link del dev ${exit} 2>/dev/null || true
    '';
  };

  # For the runbook's hand check: `exit-watchdog <role>`.
  environment.systemPackages = [ watchdog ];

  # A loop rather than a timer, as the time since a switch is state, and the
  # tunnel's restart is what returns it to the primary. It never returns on
  # its own: the exit address, which banks watch, moves with the server.
  systemd.services.exit-watchdog = {
    description = "Exit tunnel failover between servers";
    wantedBy = [
      "multi-user.target"
      "exit-tunnel.service"
    ];
    bindsTo = [ "exit-tunnel.service" ];
    partOf = [ "exit-tunnel.service" ];
    after = [ "exit-tunnel.service" ];
    serviceConfig = import ../../lib/hardening.nix // {
      ExecStart = lib.getExe watchdog;
      Restart = "always";
      RestartSec = "10s";
      # Root for the sops entries, which are root's alone.
      CapabilityBoundingSet = [ "CAP_NET_ADMIN" ];
      RuntimeDirectory = baseNameOf stateDir;
      RuntimeDirectoryMode = "0755";
      # So the metrics still name the last server while it is stopped.
      RuntimeDirectoryPreserve = true;
    };
  };

  networking.firewall = {
    # The tunnel is exempt from the strict filter for the same reason as its
    # kernel setting above, but never for a house address, which only a LAN
    # interface carries.
    extraReversePathFilterRules = ''
      iifname "${exit}" ip saddr != ${houseSet} accept comment "exit tunnel: replies route back by main"
    '';

    # After every segment's deny (`mkBefore`), and ahead of nat's accept out
    # `wan`. Left out while no segment is tunneled, since `iifname { }` does
    # not parse.
    extraForwardRules = lib.mkOrder 600 (
      lib.optionalString (tunneled != [ ]) ''
        iifname ${tunneledSet} oifname "${wan}" counter name "exit-leak-dropped" drop comment "a tunneled segment never leaves by wan"
        iifname ${tunneledSet} oifname "${exit}" accept comment "tunneled segments, out the exit tunnel"
      ''
      + lib.optionalString net.exitResolvers ''
        meta mark ${mark} oifname "${wan}" counter name "exit-leak-dropped" drop comment "the resolvers' recursion never leaves by wan"
        meta mark ${mark} iifname ${nftSet (quoted resolverIfaces)} oifname "${exit}" accept comment "the resolvers' recursion, out the exit tunnel"
      ''
    );
  };

  # `family` for the reason given at nixos-nat in ./routing.nix.
  networking.nftables.tables = {
    "nixos-nat" = {
      family = "ip";
      content = ''
        chain exit-masquerade {
          type nat hook postrouting priority srcnat;
          oifname "${exit}" masquerade comment "the provider sees one device"
        }
      '';
    };
    "nixos-fw" = {
      family = "inet";
      content = ''
        counter exit-leak-dropped {
          comment "tunneled segments${lib.optionalString net.exitResolvers " and the resolvers' mark"} routed out wan, dropped"
        }

        chain exit-mss {
          type filter hook forward priority mangle; policy accept;
          oifname "${exit}" tcp flags & (syn | rst) == syn tcp option maxseg size set rt mtu comment "exit tunnel: clamp to its MTU"
          iifname "${exit}" tcp flags & (syn | rst) == syn tcp option maxseg size set ${exitMss} comment "exit tunnel: clamp to its MTU"
        }
      ''
      # Before routing, which is what reads the mark. A house destination
      # still routes by `main`, through the suppress rule ahead of the mark's.
      + lib.optionalString net.exitResolvers ''
        chain exit-mark {
          type filter hook prerouting priority mangle; policy accept;
          iifname ${nftSet (quoted resolverIfaces)} ip saddr ${nftSet resolverIps} meta l4proto { tcp, udp } th dport 53 meta mark set ${mark} comment "the resolvers' recursion, into the exit table"
        }
      '';
    };
  };
}
