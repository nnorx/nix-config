# WireGuard for remote peers: SSH into the fleet and filtered DNS from away.
#
# The design, and why this is plain WireGuard rather than Tailscale or
# Headscale, is "Inbound remote access" in docs/router.md. In short: gate has a
# routable address, so there is nothing for a coordination server to solve, and
# either one adds a party that can enroll devices.
#
# Peers land on the `vpn` segment. ./routing.nix carries it like any other, so
# it already has masquerade out `wan`, the upstream-management deny and the DNS
# redirect. What it does not have is any forward accept, which is this file:
# `grants` below is the whole of what a peer may reach.
{
  config,
  lib,
  net,
  ...
}:
let
  keys = import ../../lib/wireguard-keys.nix;
  vpn = net.segments.vpn;
  tunnel = net.hosts.gate.vpnIface;
  wan = net.hosts.gate.wanIface;

  # What each peer may reach through the tunnel:
  #
  #   dns       the fleet resolvers, port 53
  #   adguard   the AdGuard UI on those resolvers
  #   ssh       SSH to every server, and to gate itself
  #   internet  out `wan`, for a full-tunnel profile
  #
  # Nothing grants the UniFi UI, which administers the network itself. The
  # phone gets DNS only, since it is the device most likely to be lost.
  #
  # This applies through the tunnel only. At home forge is on trusted, as
  # before, and the tunnel does not work from inside the house anyway: the WAN
  # port is opened on `wan`, and a packet from the LAN to gate's public address
  # arrives on a LAN interface.
  grants = {
    forge = [
      "dns"
      "adguard"
      "ssh"
      "internet"
    ];
    phone = [ "dns" ];
  };
  knownGrants = [
    "dns"
    "adguard"
    "ssh"
    "internet"
  ];

  # Peers with a key. An address in lib/net.nix without a key is reserved and
  # configures nothing.
  peers = builtins.attrNames keys.peers;
  addr = name: vpn.peers.${name};

  # Filtered before dereferencing, so a peer missing from lib/net.nix or from
  # `grants` is reported by the assertions below rather than by an "attribute
  # missing" trace from inside a map.
  usablePeers = lib.filter (p: vpn.peers ? ${p} && grants ? ${p}) peers;
  holding = grant: lib.filter (p: builtins.elem grant grants.${p}) usablePeers;

  nftSet = xs: "{ ${lib.concatStringsSep ", " xs} }";
  hostIp = h: net.hosts.${h}.ip;
  resolverIps = map hostIp net.resolvers;

  # Every host with an address, which is the servers. gate has none in
  # lib/net.nix, so SSH to gate is an input rule rather than a forward one.
  serverIps = map hostIp (builtins.attrNames (lib.filterAttrs (_: h: h ? ip) net.hosts));

  # One rule per grant, matching the peers that hold it. A grant nobody holds
  # renders nothing, since `ip saddr { }` is an nftables syntax error whose
  # message says nothing about why the set is empty.
  rule =
    grant: match: comment:
    lib.optionalString (holding grant != [ ]) ''
      iifname "${tunnel}" ip saddr ${nftSet (map addr (holding grant))} ${match} comment "${comment}"
    '';

  withoutInternet = lib.filter (p: !(builtins.elem p (holding "internet"))) usablePeers;
in
{
  assertions =
    map (p: {
      assertion = vpn.peers ? ${p};
      message = ''
        lib/wireguard-keys.nix has a key for "${p}", but net.segments.vpn.peers
        gives it no address. The address is what gate's firewall identifies the
        peer by, so the peer cannot be configured without one.
      '';
    }) peers
    ++ map (p: {
      assertion = grants ? ${p};
      message = ''
        lib/wireguard-keys.nix has a key for "${p}", but hosts/gate/wireguard.nix
        has no `grants` entry for it. Grant it something, even [ "dns" ], or
        remove the key.
      '';
    }) peers
    ++ lib.mapAttrsToList (p: gs: {
      assertion = lib.all (g: builtins.elem g knownGrants) gs;
      message = ''
        hosts/gate/wireguard.nix grants "${p}" ${toString gs}, but only
        ${toString knownGrants} mean anything. An unknown grant would otherwise
        render no rule and fail silently closed.
      '';
    }) grants;

  sops.secrets = {
    wireguard-private-key = { };
  }
  // lib.genAttrs (map (p: "wireguard-psk-${p}") usablePeers) (_: { });

  networking.wireguard.interfaces.${tunnel} = {
    ips = [ "${vpn.gateway}/${toString vpn.prefixLength}" ];
    listenPort = net.ports.wireguard;
    privateKeyFile = config.sops.secrets.wireguard-private-key.path;

    # One /32 each. WireGuard drops any packet from a peer whose source is not
    # in that peer's allowedIPs, which is what makes `ip saddr` in the rules
    # below an authenticated identity rather than a claim.
    #
    # The pre-shared key adds a symmetric layer, so recorded traffic stays
    # sealed even against a future break of the Curve25519 exchange.
    peers = map (name: {
      inherit name;
      publicKey = keys.peers.${name};
      presharedKeyFile = config.sops.secrets."wireguard-psk-${name}".path;
      allowedIPs = [ "${addr name}/32" ];
    }) usablePeers;
  };

  networking.firewall = {
    # WireGuard answers nothing without a valid key, so the WAN port scan in
    # docs/router.md still finds nothing listening.
    interfaces.${wan}.allowedUDPPorts = [ net.ports.wireguard ];

    # SSH to gate itself, per peer. Not `sshInterfaces`, which would open it to
    # every peer on the tunnel.
    extraInputRules = rule "ssh" "tcp dport 22 accept" "tunnel: ssh to gate";

    extraForwardRules = lib.mkMerge [
      # Ahead of the nat module's blanket `iifname { segments } oifname wan
      # accept`, which would otherwise let any peer use the house as an exit by
      # editing its own config. A lost phone is the case in mind.
      (lib.mkBefore (
        lib.optionalString (withoutInternet != [ ]) ''
          iifname "${tunnel}" oifname "${wan}" ip saddr ${nftSet (map addr withoutInternet)} counter drop comment "tunnel: no exit for this peer"
        ''
      ))

      (lib.concatStrings [
        (rule "dns" "ip daddr ${nftSet resolverIps} meta l4proto { tcp, udp } th dport 53 accept"
          "tunnel: dns to the fleet resolvers"
        )
        (rule "adguard" "ip daddr ${nftSet resolverIps} tcp dport ${toString net.ports.adguardWeb} accept"
          "tunnel: adguard ui"
        )
        (rule "ssh" "ip daddr ${nftSet serverIps} tcp dport 22 accept" "tunnel: ssh to the servers")
      ])

      # Everything else from the tunnel would fall to the chain's default drop
      # anyway. This only counts it first, after the nat module's accept so
      # that full-tunnel traffic gets there, so `nft list chain inet nixos-fw
      # forward-allow` shows whether a peer is being refused.
      (lib.mkAfter ''
        iifname "${tunnel}" counter drop comment "tunnel: not granted"
      '')
    ];
  };
}
