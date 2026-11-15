# The exit tunnel: gate as a WireGuard client of a VPN provider, so a segment
# in `exitSegments` (lib/net.nix) reaches the internet through it rather than
# `wan`, and through nothing when it is down. docs/router.md, "Exit tunnel",
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

  tunneled = builtins.attrNames (lib.filterAttrs (_: s: builtins.elem s net.exitSegments) segmentOn);
  tunneledSet = "{ ${lib.concatMapStringsSep ", " (i: "\"${i}\"") tunneled} }";
  houseSet = "{ ${lib.concatStringsSep ", " (lib.mapAttrsToList (_: s: s.subnet) net.segments)} }";

  # IPv4 and TCP headers. The route out a LAN interface says 1500, so the
  # clamp on what comes in from the provider names the tunnel's figure.
  exitMss = toString (net.exitMtu - 40);

  conf = config.sops.templates."exit-tunnel.conf";
  ph = config.sops.placeholder;
in
{
  sops.secrets = {
    exit-private-key = { };
    exit-primary-public-key = { };
    exit-primary-endpoint = { };
    exit-address.restartUnits = [ "exit-tunnel.service" ];
  };

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
      PersistentKeepalive = 25
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
          comment "tunneled segments routed out wan, dropped"
        }

        chain exit-mss {
          type filter hook forward priority mangle; policy accept;
          oifname "${exit}" tcp flags & (syn | rst) == syn tcp option maxseg size set rt mtu comment "exit tunnel: clamp to its MTU"
          iifname "${exit}" tcp flags & (syn | rst) == syn tcp option maxseg size set ${exitMss} comment "exit tunnel: clamp to its MTU"
        }
      '';
    };
  };
}
