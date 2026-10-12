# DNS away from home: over TLS to `encryptedResolvers` in lib/net.nix, never in
# plaintext to whatever network forge has joined. At home every lookup still
# goes to the fleet's AdGuard. F11 in docs/privacy.md has the options this was
# chosen over; tests/forge-dns.nix runs each case below in VMs.
#
# NetworkManager hands each connection's resolvers to systemd-resolved, which
# sends a lookup to every link whose routing domains match it. When none
# matches, it goes to every link marked as a default route and to resolved's
# global servers, the encrypted ones here, together. A link with `~.` matches
# everything, so it takes lookups away from the global servers altogether.
#
# Every Wi-Fi and Ethernet connection comes up asking its own resolvers over
# strict TLS (`connection-joined` below). A hotel's resolver does not speak it,
# so until the dispatcher script below has run, lookups fail there and succeed
# only at the global servers: nothing leaks in the moments before the script
# runs. NetworkManager hands the resolvers over before pre-up, so the script
# alone could not close that gap. It then decides by the resolvers DHCP handed
# out:
#
#   the fleet's   home. Plaintext to them, with `~.`, so they alone answer.
#   any other     away. The network's resolvers are dropped from the link, and
#                 the global servers answer alone. The guest segment is away.
#
# Recognising home by SSID or gateway would put identifying data in this repo,
# and marking the home profiles by hand would leave every new profile, and a
# wired one used both at home and elsewhere, to get it wrong. A foreign network
# that hands out one of the fleet's private addresses as its resolver would
# pass for home and get plaintext to it, which is what forge did before.
#
# The tunnel profiles (./vpn.nix) are untouched: they are WireGuard, which
# `connection-joined` does not match, and their `~.` at a negative priority
# leaves the global servers idle while one is up. Bringing one up looks gate's
# hostname up over TLS, since the tunnel is not there yet.
{
  lib,
  pkgs,
  net,
  ...
}:
let
  fleet = map (h: net.hosts.${h}.ip) net.resolvers;

  # The network's own resolvers, in plaintext, alone. Only the applied
  # connection is changed, never the saved profile, so a profile is judged
  # afresh each time it comes up. The negative priority is what makes
  # NetworkManager give the link `~.`; without it the global servers are asked
  # alongside, and at home gate refuses them.
  useNetworkDns = ''
    use_network_dns() {
      nmcli device modify "$1" connection.dns-over-tls no \
        ipv4.ignore-auto-dns no ipv6.ignore-auto-dns no \
        ipv4.dns-priority -10 ipv6.dns-priority -10 >/dev/null
    }
  '';

  # pre-up runs once per activation, before NetworkManager reports the
  # connection up, including when it restarts. It fires once either address
  # family is configured, so the DHCPv4 lease may not be there yet;
  # dhcp4-change, which follows when it arrives and at every renewal, can then
  # still find home. It never takes a network's resolvers away again, so
  # portal-dns lasts until a reconnect.
  networkDns = pkgs.writeShellApplication {
    name = "network-dns";
    runtimeInputs = [
      pkgs.networkmanager
      pkgs.gnused
      pkgs.gnugrep
      pkgs.systemd
    ];
    text = ''
      ${useNetworkDns}
      iface=$1 action=$2
      case $action in
        pre-up | dhcp4-change) ;;
        *) exit 0 ;;
      esac

      # The networks forge joins, by DHCP: not a hotspot it shares, nor
      # anything addressed by hand.
      type=$(nmcli -g connection.type connection show "$CONNECTION_UUID")
      method=$(nmcli -g ipv4.method connection show "$CONNECTION_UUID")
      case $type in
        802-11-wireless | 802-3-ethernet) ;;
        *) exit 0 ;;
      esac
      [[ $method == auto ]] || exit 0

      handed=$(nmcli -t -f DHCP4 device show "$iface" |
        sed -n 's/^DHCP4\.OPTION\[[0-9]*\]:domain_name_servers = //p')
      fleet=" ${toString fleet} "
      home=''${handed:+1}
      for server in $handed; do
        [[ $fleet == *" $server "* ]] || home=
      done

      if [[ -n $home ]]; then
        # Already done, as at a renewal.
        if resolvectl dnsovertls "$iface" | grep -q ': no$'; then
          exit 0
        fi
        echo "$iface: $action: home, the fleet's resolvers" >&2
        use_network_dns "$iface"
      elif [[ $action == pre-up ]]; then
        echo "$iface: $action: away, the encrypted resolvers" >&2
        nmcli device modify "$iface" ipv4.ignore-auto-dns yes ipv6.ignore-auto-dns yes >/dev/null
      fi
    '';
  };

  # A captive portal refuses port 853 until its login is done, so nothing
  # resolves and its page cannot be found. This hands the network its resolver
  # back, in plaintext, until the connection next comes up. docs/laptop.md.
  portalDns = pkgs.writeShellApplication {
    name = "portal-dns";
    runtimeInputs = [
      pkgs.networkmanager
      pkgs.iproute2
      pkgs.gawk
    ];
    text = ''
      ${useNetworkDns}
      iface=''${1:-$(ip -4 route show default | awk '{ for (i = 1; i < NF; i++) if ($i == "dev") { print $(i + 1); exit } }')}
      if [[ -z $iface ]]; then
        echo "portal-dns: no default route; name the interface" >&2
        exit 1
      fi
      use_network_dns "$iface"
      echo "$iface: the network's own resolver, in plaintext, until it reconnects"
    '';
  };
in
{
  services.resolved.enable = true;
  services.resolved.settings.Resolve = {
    DNS = map (r: "${r.ip}#${r.name}") net.encryptedResolvers;

    # Strict: never plaintext to these addresses instead. Where port 853 is
    # refused, lookups fail rather than go out readable.
    DNSOverTLS = true;

    # systemd's built-in fallback list is plaintext, and Google is on it. With
    # servers set above it is never used; empty says so.
    FallbackDNS = [ ];

    # Neither was on before resolved, and both would multicast the names forge
    # looks up onto whatever network it is on.
    LLMNR = false;
    MulticastDNS = false;
  };

  networking.networkmanager.settings = {
    # Every connection's resolvers in plaintext unless a section below says
    # otherwise: the tunnel's, through the tunnel. Unset, a link would inherit
    # DNSOverTLS above and ask AdGuard for TLS, which it does not serve.
    connection = {
      "connection.dns-over-tls" = 0;
      "connection.llmnr" = 0;
      "connection.mdns" = 0;
    };

    # The networks forge joins, which start out on TLS until network-dns has
    # decided. NetworkManager reads `[connection]` last, whatever the order.
    connection-joined = {
      match-device = "type:ethernet,type:wifi";
      "connection.dns-over-tls" = 2;
    };
  };

  networking.networkmanager.dispatcherScripts = [
    {
      type = "pre-up";
      source = lib.getExe networkDns;
    }
    {
      type = "basic";
      source = lib.getExe networkDns;
    }
  ];

  environment.systemPackages = [ portalDns ];
}
