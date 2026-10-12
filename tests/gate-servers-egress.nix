# gate's servers egress chain, end to end in VMs: a host on servers that
# lib/net.nix does not name is dropped out `wan` and counted, while it still
# keeps time over NTP; one of the fleet's hosts there reaches the internet
# uncounted; flushing the chain lets the stranger out, and reloading the
# ruleset puts it back. docs/privacy.md, "UniFi" under core5, has the design,
# and docs/unifi.md the flush that a firmware upgrade needs.
#
# `nix build .#checks.x86_64-linux.gate-servers-egress`. It needs KVM, which
# forge's daemon has; CI evaluates it without building.
#
# The topology is ./gate-iot-egress.nix's, with servers in place of iot: gate
# is hosts/gate/routing.nix itself, and "the internet" is one VM holding the
# public resolvers' addresses, listening on 443 as a vendor's cloud would and
# serving NTP as a public pool does.
{ net }:
let
  seg = net.segments;
  publicResolver = builtins.head net.publicResolvers;

  # RFC 5737 documentation addresses, as in ./gate-dns.nix.
  isp = {
    gate = "203.0.113.2";
    upstream = "203.0.113.1";
  };

  wire = {
    wan = 1;
    trunk = 2;
  };

  # A Pi, by the address lib/net.nix gives it, and a stranger, as the switch
  # or the AP is: an address on servers that lib/net.nix does not name. The
  # first one it leaves alone (.241 and up), since servers has no pool to take
  # one from.
  addressOf = {
    fleet = net.hosts.${builtins.head net.resolvers}.ip;
    stranger =
      let
        octets = builtins.filter builtins.isString (builtins.split "\\." seg.servers.gateway);
      in
      builtins.concatStringsSep "." (builtins.genList (builtins.elemAt octets) 3 ++ [ "241" ]);
  };

  # Untagged on the trunk, as everything on servers is.
  onServers =
    address:
    { pkgs, ... }:
    {
      virtualisation.interfaces.trunk.vlan = wire.trunk;
      networking = {
        useDHCP = false;
        firewall.enable = false;
        interfaces.trunk.ipv4.addresses = [
          {
            inherit address;
            inherit (seg.servers) prefixLength;
          }
        ];
        defaultGateway = {
          address = seg.servers.gateway;
          interface = "trunk";
        };
      };
      environment.systemPackages = [
        pkgs.chrony
        (probe pkgs)
      ];
    };

  # Connects over TCP and says how it went: "open", "refused", or "timeout",
  # which is what a drop looks like.
  probe =
    pkgs:
    pkgs.writers.writePython3Bin "probe" { } ''
      import socket
      import sys

      host, port = sys.argv[1], int(sys.argv[2])
      s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
      s.settimeout(5)
      try:
          s.connect((host, port))
          result = "open"
      except ConnectionRefusedError:
          result = "refused"
      except socket.timeout:
          result = "timeout"
      print(result)
    '';
in
assert !(builtins.any (h: (h.ip or null) == addressOf.stranger) (builtins.attrValues net.hosts));
{
  name = "gate-servers-egress";

  node.specialArgs = { inherit net; };

  nodes = {
    gate =
      { lib, ... }:
      {
        imports = [ ../hosts/gate/routing.nix ];

        virtualisation.interfaces = {
          wan.vlan = wire.wan;
          lan0.vlan = wire.trunk;
        };

        # Kea requires carrier on every interface it serves, and leases are
        # not what is under test. The hosts here are static, as servers' are.
        services.kea.dhcp4.enable = lib.mkForce false;

        networking = {
          useDHCP = false;
          interfaces.wan.ipv4.addresses = [
            {
              address = isp.gate;
              prefixLength = 24;
            }
          ];
          defaultGateway = {
            address = isp.upstream;
            interface = "wan";
          };
        };
      };

    internet =
      { pkgs, ... }:
      {
        virtualisation.interfaces.wan.vlan = wire.wan;
        networking = {
          useDHCP = false;
          firewall.enable = false;
          interfaces.wan.ipv4.addresses = [
            {
              address = isp.upstream;
              prefixLength = 24;
            }
          ]
          ++ map (address: {
            inherit address;
            prefixLength = 32;
          }) net.publicResolvers;
        };
        systemd.services.listen-443 = {
          wantedBy = [ "multi-user.target" ];
          script = "${pkgs.socat}/bin/socat TCP-LISTEN:443,fork,reuseaddr EXEC:${pkgs.coreutils}/bin/true";
        };
        # A time server with no source of its own, serving its clock as a
        # pool member would.
        services.chrony = {
          enable = true;
          servers = [ ];
          extraConfig = ''
            local stratum 8
            allow all
          '';
        };
      };

    fleet = onServers addressOf.fleet;
    stranger = onServers addressOf.stranger;
  };

  testScript = ''
    import json

    start_all()

    internet.wait_for_unit("chronyd.service")
    internet.wait_for_open_port(443)
    gate.wait_for_unit("nftables.service")
    gate.wait_for_unit("network.target")
    for h in (fleet, stranger):
        h.wait_for_unit("network.target")
        # Within servers, without crossing gate, as the switch and the AP
        # reach the controller.
        h.wait_until_succeeds("ping -c1 -W1 ${seg.servers.gateway}", timeout=60)
    fleet.wait_until_succeeds("ping -c1 -W1 ${publicResolver}", timeout=60)
    stranger.succeed("ping -c1 -W1 ${addressOf.fleet}")

    def dropped():
        out = json.loads(gate.succeed("nft -j list counter inet nixos-fw servers-wan-dropped"))
        return next(o["counter"]["packets"] for o in out["nftables"] if "counter" in o)

    def reaches_cloud(host):
        return host.succeed("probe ${publicResolver} 443").strip()

    def keeps_time(host):
        # Query only: asks the server and reports the offset, without setting
        # the clock. Fails, saying "No suitable source", if nothing answers.
        out = host.succeed("chronyd -Q -t 20 -u root 'server ${publicResolver} iburst maxsamples 1' 2>&1")
        assert "System clock wrong by" in out, f"no time from the internet:\n{out}"

    print(gate.succeed("nft list chain inet nixos-fw servers-egress"))

    with subtest("a fleet host reaches the internet, uncounted"):
        before = dropped()
        assert reaches_cloud(fleet) == "open"
        fleet.succeed("ping -c1 -W2 ${publicResolver}")
        keeps_time(fleet)
        assert dropped() == before, "a fleet host's traffic was counted as dropped"

    with subtest("a stranger on servers is dropped out wan, and counted"):
        before = dropped()
        assert reaches_cloud(stranger) == "timeout", "the stranger reached the internet"
        stranger.fail("ping -c1 -W2 ${publicResolver}")
        assert dropped() > before, "the drops were not counted"

    with subtest("the stranger still keeps time"):
        before = dropped()
        keeps_time(stranger)
        assert dropped() == before, "NTP was counted as dropped"

    with subtest("flushing the chain lets the stranger out, as a firmware upgrade needs"):
        gate.succeed("nft flush chain inet nixos-fw servers-egress")
        assert reaches_cloud(stranger) == "open"
        assert reaches_cloud(fleet) == "open"

    with subtest("reloading the ruleset restores the chain"):
        gate.succeed("systemctl reload nftables")
        assert dropped() == 0, "servers-wan-dropped survived the reload"
        assert reaches_cloud(stranger) == "timeout", "the reloaded chain let the stranger out"
        assert dropped() > 0, "the reloaded chain did not count the drop"
        assert reaches_cloud(fleet) == "open"
        keeps_time(stranger)
  '';
}
