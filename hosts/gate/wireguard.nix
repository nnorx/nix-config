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
# DNS plus `segments.vpn.grants` in lib/net.nix is the whole of what a peer
# may reach.
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

  # What each peer may reach beyond DNS is `segments.vpn.grants` in
  # lib/net.nix, which says what each grant is and why DNS is not one. It
  # lives there so that each proxy can read it too.
  inherit (vpn) grants;

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

  # Filtered for the same reason as `usablePeers`. ./routing.nix asserts that
  # every resolver has an address, and that message names the cause; without
  # the filter this map would throw first.
  resolverIps = map hostIp (lib.filter (h: net.hosts ? ${h} && net.hosts.${h} ? ip) net.resolvers);

  # Every host with an address, which is the servers. gate has none in
  # lib/net.nix, so SSH to gate is an input rule rather than a forward one.
  serverIps = map hostIp (builtins.attrNames (lib.filterAttrs (_: h: h ? ip) net.hosts));

  # Rules for the peers in `who`, rendering nothing when there are none, since
  # `ip saddr { }` is an nftables syntax error whose message says nothing about
  # why the set is empty.
  rulesFor =
    who: match: comment:
    lib.optionalString (who != [ ]) ''
      iifname "${tunnel}" ip saddr ${nftSet (map addr who)} ${match} comment "${comment}"
    '';

  # The forward rule behind each grant. `internet` has none of its own: the nat
  # module's accept covers it, and peers without it are dropped ahead of that,
  # below. The names a peer may be granted are `grantNames` in lib/net.nix,
  # where modules/net-assertions.nix reads them on every host, and an assertion
  # below holds these rules to that list.
  forwardRules = {
    adguard = {
      match = "ip daddr ${nftSet resolverIps} tcp dport ${toString net.ports.adguardWeb} accept";
      comment = "tunnel: adguard ui";
    };
    ssh = {
      match = "ip daddr ${nftSet serverIps} tcp dport 22 accept";
      comment = "tunnel: ssh to the servers";
    };
  };
  ruledGrants = builtins.attrNames forwardRules ++ [ "internet" ];

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
    # The keys are gate's, so this check is too. The rest of what `grants` must
    # hold is modules/net-assertions.nix's.
    ++ map (p: {
      assertion = grants ? ${p};
      message = ''
        lib/wireguard-keys.nix has a key for "${p}", but net.segments.vpn.grants
        has no entry for it. Give it one, even [ ] for DNS only, or remove the
        key.
      '';
    }) peers
    ++ [
      {
        # A name in `grantNames` without a rule here would let a peer hold a
        # grant that renders nothing, failing silently closed. A rule without a
        # name could never be granted.
        assertion = lib.sort lib.lessThan ruledGrants == lib.sort lib.lessThan vpn.grantNames;
        message = ''
          net.segments.vpn.grantNames is ${toString vpn.grantNames}, but
          hosts/gate/wireguard.nix has rules for ${toString ruledGrants}. Each
          grant name needs its rule in that file's `forwardRules`, and each
          rule a grant name.
        '';
      }
      {
        # lib/net.nix says so in prose; this says it at eval. Listed there, the
        # tunnel would also be bound twice, once by ./routing.nix from
        # `sshInterfaces` and once below.
        assertion = !(builtins.elem tunnel net.hosts.gate.sshInterfaces);
        message = ''
          lib/net.nix lists ${tunnel} in gate's `sshInterfaces`, which would open
          SSH to every peer on the tunnel, the phone included. SSH over the
          tunnel is granted per peer, in net.segments.vpn.grants. Take ${tunnel}
          out of that list.
        '';
      }
    ];

  # Restart what holds each key when it changes. The units read these files at
  # start, and their definitions do not change when only a secret does, so a
  # rotation would otherwise not take effect until the next reboot. The peer
  # units require the interface unit, so restarting it restarts them too.
  sops.secrets = {
    wireguard-private-key.restartUnits = [ "wireguard-${tunnel}.service" ];
  }
  // lib.listToAttrs (
    map (p: {
      name = "wireguard-psk-${p}";
      value.restartUnits = [ "wireguard-${tunnel}-peer-${p}.service" ];
    }) usablePeers
  );

  networking.wireguard.interfaces.${tunnel} = {
    ips = [ "${vpn.gateway}/${toString vpn.prefixLength}" ];
    listenPort = net.ports.wireguard;
    privateKeyFile = config.sops.secrets.wireguard-private-key.path;

    # gate's side of the same limit: replies are as large as gate's MTU
    # allows, and they cross the same mobile path. See `vpnMtu` in lib/net.nix.
    mtu = net.vpnMtu;

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

  # sshd on gate's tunnel address, which is `gate-vpn` in home/ssh.nix. Bound
  # whoever holds the grant: the per-peer input rule below decides who may
  # reach it, as `sshInterfaces` does on the LAN. The sysctl in modules/ssh.nix
  # lets sshd bind it whether or not wg0 is up yet.
  services.openssh.listenAddresses = [ { addr = vpn.gateway; } ];

  networking.firewall = {
    # WireGuard answers nothing without a valid key, so the WAN port scan in
    # docs/router.md still finds nothing listening.
    interfaces.${wan}.allowedUDPPorts = [ net.ports.wireguard ];

    # SSH to gate itself, per peer. Not `sshInterfaces`, which would open it to
    # every peer on the tunnel.
    extraInputRules = rulesFor (holding "ssh") "tcp dport 22 accept" "tunnel: ssh to gate";

    extraForwardRules = lib.mkMerge [
      # Ahead of the nat module's blanket `iifname { segments } oifname wan
      # accept`, which would otherwise let any peer use the house as an exit by
      # editing its own config. A lost phone is the case in mind.
      (lib.mkBefore (
        rulesFor withoutInternet ''oifname "${wan}" counter drop'' "tunnel: no exit for this peer"
      ))

      # Queries addressed to a resolver directly. Those addressed anywhere else
      # are redirected, and pass as described at `grants` in lib/net.nix.
      (rulesFor usablePeers "ip daddr ${nftSet resolverIps} meta l4proto { tcp, udp } th dport 53 accept"
        "tunnel: dns to the fleet resolvers"
      )

      (lib.concatStrings (
        lib.mapAttrsToList (grant: r: rulesFor (holding grant) r.match r.comment) forwardRules
      ))

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
