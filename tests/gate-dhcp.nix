# gate's DHCP, end to end in VMs: Kea's own test passes on the config sops
# renders, every device in lib/net.nix has a reservation, a device takes its
# reserved address by its MAC, and a client that is not one takes a pool
# address.
#
# `nix build .#checks.x86_64-linux.gate-dhcp`. It needs KVM, which forge's
# daemon has; CI's vm-tests job runs it on pull requests.
#
# The topology is ./lib/gate-topology.nix's, whose sops stand-in renders Kea's
# config with test MACs. gate takes its WAN lease from the internet, as in
# ./gate-metrics.nix.
{ net }:
let
  topology = import ./lib/gate-topology.nix { inherit net; };
  inherit (topology) isp;
  seg = net.segments;

  deviceName = builtins.head (builtins.attrNames net.devices);
  reserved = net.devices.${deviceName};
  pool = seg.${reserved.segment}.pool;
in
{
  name = "gate-dhcp";

  node.specialArgs = { inherit net; };

  nodes = {
    gate = topology.router { dhcp = true; };

    internet = {
      imports = [ topology.internet ];
      services.dnsmasq = {
        enable = true;
        resolveLocalQueries = false;
        settings = {
          port = 0;
          interface = "wan";
          dhcp-range = "${isp.leases.first},${isp.leases.last},255.255.255.0,10m";
          dhcp-option = [ "option:router,${isp.upstream}" ];
        };
      };
    };

    # The device, with its test MAC set by udev as the VLAN appears, before
    # dhcpcd asks.
    device = {
      imports = [ (topology.onSegment reserved.segment null) ];
      systemd.network.links."10-${reserved.segment}" = {
        matchConfig.OriginalName = reserved.segment;
        linkConfig.MACAddress = topology.testMac.${deviceName};
      };
    };

    stranger = topology.onSegment reserved.segment null;
  };

  testScript = ''
    import ipaddress
    import json

    start_all()
    gate.wait_for_unit("kea-dhcp4-server.service")

    def address(machine):
        out = machine.wait_until_succeeds(
            "ip -4 -o addr show dev ${reserved.segment} scope global | grep inet", timeout=120
        )
        return ipaddress.ip_address(out.split()[3].split("/")[0])

    with subtest("Kea's own test passes on the rendered config"):
        gate.succeed("kea-dhcp4 -t /etc/kea/dhcp4-server.conf")

    with subtest("every device in lib/net.nix is reserved"):
        conf = json.loads(gate.succeed("cat /etc/kea/dhcp4-server.conf"))
        got = sorted(r["ip-address"] for s in conf["Dhcp4"]["subnet4"] for r in s["reservations"])
        want = sorted(${builtins.toJSON (map (d: d.ip) (builtins.attrValues net.devices))})
        assert got == want, f"{got} != {want}"

    with subtest("a device takes its reserved address"):
        device.succeed("ip link show ${reserved.segment} | grep -q ${topology.testMac.${deviceName}}")
        got = address(device)
        assert str(got) == "${reserved.ip}", got

    with subtest("a client that is no device takes a pool address"):
        got = address(stranger)
        first = ipaddress.ip_address("${pool.first}")
        last = ipaddress.ip_address("${pool.last}")
        assert first <= got <= last, got
  '';
}
