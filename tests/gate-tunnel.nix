# gate's tunnel rules, end to end in VMs: each peer in `segments.vpn.peers`
# reaches DNS and what its `grants` name, and nothing else. The expectations
# are built from lib/net.nix, so a change to a peer's grants changes them.
#
# `nix build .#checks.x86_64-linux.gate-tunnel`. It needs KVM, which forge's
# daemon has; CI's vm-tests job runs it on pull requests.
#
# The rules match on the interface name and the source address, so gate's
# tunnel here is a plain NIC named as the tunnel, with the peers' addresses
# behind it. WireGuard's own source check is not exercised: this covers the
# firewall's half, which is the half the grants control.
{ net }:
let
  topology = import ./lib/gate-topology.nix { inherit net; };
  seg = net.segments;
  vpn = seg.vpn;
  tunnel = net.hosts.gate.vpnIface;
  publicResolver = builtins.head net.publicResolvers;
  resolverIps = map (h: net.hosts.${h}.ip) net.resolvers;
  iotDevice = seg.iot.pool.first;
  peerNames = builtins.attrNames vpn.peers;

  row = what: host: port: reached: {
    inherit
      what
      host
      port
      reached
      ;
  };
  rowsFor =
    peer:
    let
      has = grant: builtins.elem grant vpn.grants.${peer};
    in
    map (ip: row "dns" ip 53 true) resolverIps
    ++ map (ip: row "adguard" ip net.ports.adguardWeb (has "adguard")) resolverIps
    ++ map (ip: row "ssh" ip 22 (has "ssh")) (resolverIps ++ [ vpn.gateway ])
    # Not 53, which is redirected to the fleet resolvers on the tunnel.
    ++ [ (row "internet" publicResolver 443 (has "internet")) ]
    ++ [ (row "not granted" iotDevice 22 false) ];
  expected = builtins.listToAttrs (
    map (peer: {
      name = peer;
      value = rowsFor peer;
    }) peerNames
  );

  # The grant names the rows test, deduplicated and sorted by attrNames.
  covered = builtins.attrNames (
    removeAttrs
      (builtins.listToAttrs (
        map (r: {
          name = r.what;
          value = null;
        }) (rowsFor (builtins.head peerNames))
      ))
      [
        "dns"
        "not granted"
      ]
  );

  sopsStub =
    { lib, ... }:
    {
      options.sops.secrets = lib.mkOption {
        type = lib.types.attrsOf lib.types.attrs;
        default = { };
      };
    };

  peerNode =
    address:
    { pkgs, ... }:
    {
      virtualisation.interfaces.tunnel.vlan = topology.wire.tunnel;
      networking = {
        useDHCP = false;
        firewall.enable = false;
        interfaces.tunnel.ipv4.addresses = [
          {
            inherit address;
            inherit (vpn) prefixLength;
          }
        ];
        defaultGateway = {
          address = vpn.gateway;
          interface = "tunnel";
        };
      };
      environment.systemPackages = [ (topology.probe pkgs) ];
    };
in
# A new grant fails evaluation here until the rows above test it.
assert covered == builtins.sort builtins.lessThan vpn.grantNames;
{
  name = "gate-tunnel";

  node.specialArgs = { inherit net; };

  nodes = {
    gate =
      { lib, ... }:
      {
        imports = [
          (topology.router { })
          ../hosts/gate/wireguard.nix
          sopsStub
        ];
        virtualisation.interfaces.${tunnel}.vlan = topology.wire.tunnel;
        networking.wireguard.interfaces = lib.mkForce { };
        networking.interfaces.${tunnel}.ipv4.addresses = [
          {
            address = vpn.gateway;
            inherit (vpn) prefixLength;
          }
        ];
      };

    internet =
      { pkgs, ... }:
      {
        imports = [ topology.internet ];
        systemd.services.listen-443 = {
          wantedBy = [ "multi-user.target" ];
          script = "${pkgs.socat}/bin/socat TCP-LISTEN:443,fork,reuseaddr EXEC:${pkgs.coreutils}/bin/true";
        };
      };

    fleet = topology.fleet;

    # Firewall off, so a packet gate lets through is refused rather than
    # dropped here.
    iot = {
      imports = [ (topology.onSegment "iot" iotDevice) ];
      networking.firewall.enable = false;
    };
  }
  // builtins.listToAttrs (
    map (peer: {
      name = "peer_${peer}";
      value = peerNode vpn.peers.${peer};
    }) peerNames
  );

  testScript = ''
    import json

    expected = json.loads('${builtins.toJSON expected}')
    peers = {${builtins.concatStringsSep ", " (map (p: ''"${p}": peer_${p}'') peerNames)}}

    start_all()

    internet.wait_for_open_port(443)
    gate.wait_for_unit("nftables.service")
    for m in [gate, internet, fleet, iot, *peers.values()]:
        m.wait_for_unit("network.target")
    for m in peers.values():
        m.wait_until_succeeds("ping -c1 -W1 ${vpn.gateway}", timeout=60)

    print(gate.succeed("nft list ruleset"))

    for name, rows in expected.items():
        for r in rows:
            with subtest(f"{name}: {r['what']} at {r['host']}:{r['port']}"):
                result = peers[name].succeed(f"probe {r['host']} {r['port']}").strip()
                if r["reached"]:
                    assert result != "timeout", f"{name} did not reach {r['what']}: {result}"
                else:
                    assert result == "timeout", f"{name} reached {r['what']}: {result}"
  '';
}
