# gate's metrics, end to end in VMs: core5 can scrape node_exporter and Kea's
# exporter at gate's servers gateway, nothing else on servers can, and what
# they serve answers docs/router.md's questions without the WAN address.
#
# `nix build .#checks.x86_64-linux.gate-metrics`. It needs KVM, which forge's
# daemon has; CI's vm-tests job runs it on pull requests.
#
# gate is hosts/gate/routing.nix and ./metrics.nix themselves, with
# modules/node-exporter.nix, on VM NICs given gate's interface names. Its WAN
# lease comes from a DHCP server on the far side, as the ISP's does, so the
# lease metrics read a real dhcpcd lease. WireGuard is a stand-in for
# hosts/gate/wireguard.nix, whose keys are in sops: the same interface and
# peers' public keys, so the handshake metric is read from a real interface,
# though no peer can complete one.
{ net }:
let
  seg = net.segments;
  keys = import ../lib/wireguard-keys.nix;
  gateAddress = seg.${net.hosts.gate.metricsSegment}.gateway;
  node = "http://${gateAddress}:${toString net.ports.nodeExporter}/metrics";
  kea = "http://${gateAddress}:${toString net.ports.keaExporter}/metrics";

  # The ISP side, RFC 5737 documentation addresses as in ./gate-dns.nix.
  isp = {
    upstream = "203.0.113.1";
    first = "203.0.113.10";
    last = "203.0.113.20";
  };
  ispPrefix = "203.0.113.";

  wire = {
    wan = 1;
    trunk = 2;
    wired = 3;
  };

  # A host untagged on the trunk, as the Pis are on the switch.
  onServers = ip: {
    virtualisation.interfaces.trunk.vlan = wire.trunk;
    networking = {
      useDHCP = false;
      firewall.enable = false;
      interfaces.trunk.ipv4.addresses = [
        {
          address = ip;
          inherit (seg.servers) prefixLength;
        }
      ];
    };
  };
in
{
  name = "gate-metrics";

  node.specialArgs = {
    inherit net;
    hostname = "gate";
  };

  nodes = {
    gate =
      { lib, ... }:
      {
        imports = [
          ../hosts/gate/routing.nix
          ../hosts/gate/metrics.nix
          ../modules/node-exporter.nix
        ];

        virtualisation.interfaces = {
          wan.vlan = wire.wan;
          lan0.vlan = wire.trunk;
          lan1.vlan = wire.wired;
        };

        networking = {
          useDHCP = false;
          interfaces.wan.useDHCP = true;
          wireguard.interfaces.${net.hosts.gate.vpnIface} = {
            ips = [ "${seg.vpn.gateway}/${toString seg.vpn.prefixLength}" ];
            generatePrivateKeyFile = true;
            privateKeyFile = "/var/lib/wireguard/key";
            peers = lib.mapAttrsToList (name: key: {
              publicKey = key;
              allowedIPs = [ "${seg.vpn.peers.${name}}/32" ];
            }) keys.peers;
          };
        };

        # gate's sshd binds by address, with modules/ssh.nix's sysctl; the
        # exporters rely on the same one at boot.
        boot.kernel.sysctl."net.ipv4.ip_nonlocal_bind" = 1;
      };

    # The ISP: a DHCP server on the far side of `wan`.
    internet = {
      virtualisation.interfaces.wan.vlan = wire.wan;
      networking = {
        useDHCP = false;
        firewall.enable = false;
        interfaces.wan.ipv4.addresses = [
          {
            address = isp.upstream;
            prefixLength = 24;
          }
        ];
      };
      services.dnsmasq = {
        enable = true;
        resolveLocalQueries = false;
        settings = {
          port = 0;
          interface = "wan";
          dhcp-range = "${isp.first},${isp.last},255.255.255.0,10m";
          dhcp-option = [ "option:router,${isp.upstream}" ];
        };
      };
    };

    core5 = onServers net.hosts.${net.metricsCollector}.ip;

    # Another host on servers, as the switch or the AP is: refused.
    other = onServers net.hosts.core4.ip;

    # A DHCP client on iot, so one pool has a lease in it.
    iot = {
      virtualisation.interfaces.trunk.vlan = wire.trunk;
      networking = {
        useDHCP = false;
        vlans.iot = {
          id = seg.iot.id;
          interface = "trunk";
        };
        interfaces.iot.useDHCP = true;
      };
    };
  };

  testScript = ''
    import re
    import time

    start_all()

    internet.wait_for_unit("dnsmasq.service")
    gate.wait_for_unit("kea-dhcp4-server.service")
    gate.wait_for_unit("prometheus-node-exporter.service")
    core5.wait_for_unit("network.target")
    other.wait_for_unit("network.target")
    gate.wait_until_succeeds("ip -4 -o addr show dev wan scope global | grep -q inet", timeout=120)
    iot.wait_until_succeeds("ip -4 -o addr show dev iot scope global | grep -q inet", timeout=120)
    gate.wait_for_unit("prometheus-kea-exporter.service")
    # Written at boot and every 30 seconds after, so the lease may only be in
    # a later write than the first.
    gate.wait_until_succeeds("grep -q '^fleet_wan_addresses 1$' /run/fleet-metrics/gate.prom", timeout=90)

    def scrape(url):
        return core5.wait_until_succeeds(f"curl -sf --max-time 5 {url}", timeout=60)

    def series(text, name):
        out = []
        for line in text.splitlines():
            m = re.match(r"^([a-zA-Z_:][a-zA-Z0-9_:]*)(?:\{(.*)\})? (\S+)$", line)
            if m and m.group(1) == name:
                labels = dict(re.findall(r'(\w+)="([^"]*)"', m.group(2) or ""))
                out.append((labels, float(m.group(3))))
        return out

    def one(text, name, **want):
        hits = [v for labels, v in series(text, name) if all(labels.get(k) == w for k, w in want.items())]
        assert len(hits) == 1, f"{name} {want}: {hits}"
        return hits[0]

    with subtest("both exporters bind the servers gateway alone"):
        listening = gate.succeed("ss -ltnH")
        print(listening)
        for port in ("${toString net.ports.nodeExporter}", "${toString net.ports.keaExporter}"):
            assert f"${gateAddress}:{port} " in listening, f"nothing on ${gateAddress}:{port}"
            for wildcard in ("0.0.0.0", "*", "[::]"):
                assert f"{wildcard}:{port} " not in listening, f"{port} listens on {wildcard}"

    with subtest("another host on servers is refused"):
        other.fail("curl -sf --max-time 5 ${node}")
        other.fail("curl -sf --max-time 5 ${kea}")

    text = scrape("${node}")
    keaText = scrape("${kea}")

    with subtest("WAN link, lease and default route"):
        assert one(text, "node_network_carrier", device="wan") == 1
        assert one(text, "fleet_wan_addresses") == 1
        remaining = one(text, "fleet_wan_lease_remaining_seconds")
        assert 0 < remaining <= 600, f"lease remaining {remaining}, from a 10-minute lease"
        assert one(text, "fleet_wan_default_routes") == 1

    with subtest("conntrack against its limit"):
        assert one(text, "node_nf_conntrack_entries") > 0
        assert one(text, "node_nf_conntrack_entries_limit") == 262144

    with subtest("per-interface throughput and errors"):
        for device in ("wan", "lan0", "lan0.${toString seg.iot.id}", "br-trusted", "${net.hosts.gate.vpnIface}"):
            for name in ("receive_bytes", "transmit_bytes", "receive_errs", "transmit_errs"):
                one(text, f"node_network_{name}_total", device=device)

    with subtest("each WireGuard peer's last handshake, by name"):
        for peer in (${
          builtins.concatStringsSep ", " (map (p: "\"${p}\"") (builtins.attrNames keys.peers))
        }):
            assert one(text, "fleet_wireguard_last_handshake_timestamp_seconds", peer=peer) == 0

    with subtest("Kea pool usage per segment"):
        print("\n".join(l for l in keaText.splitlines() if "addresses" in l))
        iot = "${seg.iot.subnet}"
        assert one(keaText, "kea_dhcp4_addresses_assigned_total", subnet=iot, pool="") == 1
        assert one(keaText, "kea_dhcp4_addresses_total", subnet=iot, pool="") == 141
        assert one(keaText, "kea_dhcp4_addresses_assigned_total", subnet="${seg.guest.subnet}", pool="") == 0

    with subtest("Kea's exporter outlasts Kea being away at its start"):
        # As at boot, or while Kea loops on an interface without carrier: the
        # exporter exits for want of the socket, and retries rather than
        # spending systemd's start limit and staying failed.
        gate.succeed("systemctl stop kea-dhcp4-server.service")
        gate.succeed("rm -f /run/kea/kea-dhcp4.socket")
        gate.succeed("systemctl restart prometheus-kea-exporter.service")
        time.sleep(15)
        gate.succeed("systemctl start kea-dhcp4-server.service")
        core5.wait_until_succeeds("curl -sf --max-time 5 ${kea}", timeout=60)

    with subtest("no WAN address, and MAC addresses only where core5 drops them"):
        for t in (text, keaText):
            assert "${ispPrefix}" not in t, [l for l in t.splitlines() if "${ispPrefix}" in l]
        for t in (text, keaText):
            for line in t.splitlines():
                if re.search(r"([0-9a-f]{2}:){5}[0-9a-f]{2}", line) and not line.startswith("#"):
                    assert line.startswith("node_network_info{"), line
  '';
}
