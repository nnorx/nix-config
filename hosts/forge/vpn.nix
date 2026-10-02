# WireGuard home to gate, as two NetworkManager profiles that never connect on
# their own: switch one on from Plasma's network applet or with
# `nmcli connection up "home (split)"`. gate's side, and what this peer may
# reach through it, is hosts/gate/wireguard.nix; the design is "Inbound remote
# access" in docs/router.md.
#
#   home (split)  The default. Only the fleet's addresses and DNS go through
#                 the tunnel, so SSH, the AdGuard UI and filtered DNS work from
#                 anywhere and everything else takes the local network.
#   home (full)   Everything, for untrusted networks. It moves what the local
#                 network can see to the home ISP rather than hiding it, and is
#                 bounded by the home upload.
#
# Neither works from inside the house: gate opens the port on `wan`, and a
# packet from the LAN to its public address arrives on a LAN interface. At home
# forge is on trusted anyway, and a profile left up there sends DNS into a
# tunnel that never comes up.
{
  config,
  pkgs,
  lib,
  net,
  ...
}:
let
  keys = import ../../lib/wireguard-keys.nix;
  vpn = net.segments.vpn;
  hostIp = h: net.hosts.${h}.ip;

  # Single addresses, not the segments they sit in. A hotel network is often a
  # 192.168.x.0/24 of its own, and a /24 here would collide with it, while a
  # /32 always wins. gate is reached at its tunnel address, not 192.168.10.1,
  # which is the gateway of a great many networks that are not this one; see
  # `gate-vpn` in home/ssh.nix.
  fleet = map hostIp (builtins.attrNames (lib.filterAttrs (_: h: h ? ip) net.hosts)) ++ [
    vpn.gateway
  ];
  resolvers = map hostIp net.resolvers;

  nmList = xs: lib.concatMapStrings (x: "${x};") xs;

  # The secrets are filled in by NetworkManager-ensure-profiles from the files
  # in `environmentFiles` below, with envsubst, so none of them reaches the Nix
  # store. WG_PRIVATE_KEY is forge's own, generated here and never anywhere
  # else; WG_PSK and WG_ENDPOINT come from secrets/forge.yaml.
  profile =
    {
      id,
      iface,
      allowedIPs,
      ipv6,
    }:
    {
      connection = {
        inherit id;
        type = "wireguard";
        interface-name = iface;
        autoconnect = false;
      };
      wireguard = {
        private-key = "$WG_PRIVATE_KEY";
        private-key-flags = 0; # stored in the profile, not asked of an agent

        # See `net.vpnMtu` in lib/net.nix: the default 1420 handshakes and
        # then drops everything larger than a ping on a phone's hotspot.
        mtu = net.vpnMtu;
      };
      "wireguard-peer.${keys.gate}" = {
        endpoint = "\${WG_ENDPOINT}:${toString net.ports.wireguard}";
        preshared-key = "$WG_PSK";
        preshared-key-flags = 0;
        allowed-ips = nmList allowedIPs;

        # Hotel NAT forgets idle mappings within minutes. An idle SSH session
        # would survive that from forge's side, but not anything gate or a
        # server sends first, until forge next speaks.
        persistent-keepalive = 25;
      };
      ipv4 = {
        method = "manual";
        address1 = "${vpn.peers.forge}/32";
        dns = nmList resolvers;

        # Every lookup to the fleet while the tunnel is up, which is the point:
        # filtered DNS away from home. Negative means exclusive, so the local
        # network's resolver is not consulted alongside.
        dns-search = "~;";
        dns-priority = -50;
      };
      inherit ipv6;
    };
in
{
  sops.secrets = {
    wireguard-psk = { };
    wireguard-endpoint-host = { };
  };

  sops.templates."wireguard-home.env" = {
    content = ''
      WG_PSK=${config.sops.placeholder.wireguard-psk}
      WG_ENDPOINT=${config.sops.placeholder.wireguard-endpoint-host}
    '';
    # The profiles are rendered once, at activation, so a rotated key or a new
    # hostname would otherwise wait for the next boot.
    restartUnits = [ "NetworkManager-ensure-profiles.service" ];
  };

  networking.networkmanager.ensureProfiles = {
    # The private key is a file on this machine, root-only, made by hand (see
    # docs/laptop.md). Missing, the unit fails and both profiles are absent,
    # which is the right failure: there is nothing to connect with.
    environmentFiles = [
      config.sops.templates."wireguard-home.env".path
      "/var/lib/wireguard/forge.env"
    ];

    profiles = {
      home-split = profile {
        id = "home (split)";
        iface = "wg-split";
        allowedIPs = map (ip: "${ip}/32") fleet;
        ipv6.method = "disabled";
      };

      # IPv6 is routed into the tunnel too, where it dies: gate has no IPv6
      # and accepts nothing from this peer but its IPv4 address. Without
      # this, a network that offers IPv6 would carry that half of the traffic
      # outside the tunnel. The address is a unique-local placeholder that
      # exists only so NetworkManager will install the IPv6 route; glibc then
      # prefers IPv4 for global destinations, so most connections never try it.
      home-full = profile {
        id = "home (full)";
        iface = "wg-full";
        allowedIPs = [
          "0.0.0.0/0"
          "::/0"
        ];
        ipv6 = {
          method = "manual";
          address1 = "fd60::10/128";
        };
      };
    };
  };

  # `wg show` for when a tunnel will not come up: NetworkManager logs nothing
  # about WireGuard at its default level, and this is where the endpoint,
  # handshake and transfer counters are.
  environment.systemPackages = [ pkgs.wireguard-tools ];

  # NetworkManager routes a full tunnel through its own policy table, and gate's
  # encrypted replies arrive on Wi-Fi from an address that table now routes into
  # the tunnel. The strict reverse-path check would drop every one of them, so
  # the full profile could never complete a handshake. Loose keeps the check
  # that a route back exists at all. On a laptop that routes for nothing else,
  # strict was protecting little.
  networking.firewall.checkReversePath = "loose";
}
