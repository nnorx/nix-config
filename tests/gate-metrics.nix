# gate's metrics, end to end in VMs: core5 can scrape node_exporter and Kea's
# exporter at gate's servers gateway, nothing else on servers can, and what
# they serve answers docs/router.md's questions without the WAN address.
#
# `nix build .#checks.x86_64-linux.gate-metrics`. It needs KVM, which forge's
# daemon has; CI's vm-tests job runs it on pull requests.
#
# The topology is ./lib/gate-topology.nix's, with ./metrics.nix,
# ./trusted-clients.nix and modules/node-exporter.nix added to gate. Its WAN
# lease comes from a DHCP server on the internet, as the ISP's does, so the
# lease metrics read a real dhcpcd lease, and it serves leases with Kea.
# WireGuard is a stand-in for hosts/gate/wireguard.nix, whose keys are in sops:
# the same interface and peers' public keys, so the handshake metric is read
# from a real interface, though no peer can complete one.
{ net }:
let
  topology = import ./lib/gate-topology.nix { inherit net; };
  inherit (topology) isp;
  seg = net.segments;
  keys = import ../lib/wireguard-keys.nix;
  gateAddress = seg.${net.hosts.gate.metricsSegment}.gateway;
  node = "http://${gateAddress}:${toString net.ports.nodeExporter}/metrics";
  kea = "http://${gateAddress}:${toString net.ports.keaExporter}/metrics";
  ispPrefix = isp.prefix;
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
          (topology.router { dhcp = true; })
          ../hosts/gate/metrics.nix
          ../hosts/gate/trusted-clients.nix
          ../modules/node-exporter.nix
        ];

        networking.wireguard.interfaces.${net.hosts.gate.vpnIface} = {
          ips = [ "${seg.vpn.gateway}/${toString seg.vpn.prefixLength}" ];
          generatePrivateKeyFile = true;
          privateKeyFile = "/var/lib/wireguard/key";
          peers = lib.mapAttrsToList (name: key: {
            publicKey = key;
            allowedIPs = [ "${seg.vpn.peers.${name}}/32" ];
          }) keys.peers;
        };

        # gate's sshd binds by address, with modules/ssh.nix's sysctl; the
        # exporters rely on the same one at boot.
        boot.kernel.sysctl."net.ipv4.ip_nonlocal_bind" = 1;
      };

    # The ISP: a DHCP server on the far side of `wan`.
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

    core5 = topology.onServers [ net.hosts.${net.metricsCollector}.ip ];

    # Another host on servers, as the switch or the AP is: refused.
    other = topology.onServers [ net.hosts.core4.ip ];

    # A DHCP client on iot, so one pool has a lease in it.
    iot = topology.onSegment "iot" null;

    # Two on trusted: one there before ./trusted-clients.nix first runs, and
    # one that joins after.
    laptop = topology.onSegment "trusted" null;
    newcomer = topology.onSegment "trusted" null;
  };

  testScript = ''
    import re
    import time

    for m in machines:
        if m is not newcomer:
            m.start()

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
        for device in ("wan", "${net.hosts.gate.trunkIface}", "${net.hosts.gate.trunkIface}.${toString seg.iot.id}", "br-trusted", "${net.hosts.gate.vpnIface}"):
            for name in ("receive_bytes", "transmit_bytes", "receive_errs", "transmit_errs"):
                one(text, f"node_network_{name}_total", device=device)

    with subtest("each WireGuard peer's last handshake, by name"):
        for peer in ${builtins.toJSON (builtins.attrNames keys.peers)}:
            assert one(text, "fleet_wireguard_last_handshake_timestamp_seconds", peer=peer) == 0

    with subtest("no exit tunnel: no handshake, primary, every bypass closed"):
        assert one(text, "fleet_exit_last_handshake_timestamp_seconds") == 0
        assert one(text, "fleet_exit_transmit_bytes_total") == 0
        assert one(text, "fleet_exit_server", role="primary") == 1
        bypasses = sorted((labels["segment"], v) for labels, v in series(text, "fleet_exit_bypass_open"))
        assert bypasses == sorted((s, 0) for s in (${
          builtins.concatStringsSep ", " (map (s: "\"${s}\"") (net.exitSegments ++ [ "resolvers" ]))
        },)), bypasses

    with subtest("Kea pool usage per segment"):
        print("\n".join(l for l in keaText.splitlines() if "addresses" in l))
        iotSubnet = "${seg.iot.subnet}"
        assert one(keaText, "kea_dhcp4_addresses_assigned_total", subnet=iotSubnet, pool="") == 1
        assert one(keaText, "kea_dhcp4_addresses_total", subnet=iotSubnet, pool="") == 141
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

    def leaseLines():
        return int(gate.succeed("cat /var/lib/kea/dhcp4.leases* | wc -l"))

    # Kea's lease caching answers an early renewal without writing it, so the
    # client releases and leases again, which Kea writes.
    def renew(client, iface):
        before = leaseLines()
        leased = f"ip -4 -o addr show dev {iface} scope global | grep -q inet"
        client.succeed(f"dhcpcd -k {iface}")
        client.wait_until_fails(leased, timeout=30)
        client.succeed(f"dhcpcd -n {iface}")
        client.wait_until_succeeds(leased, timeout=60)
        gate.wait_until_succeeds(f"[ $(cat /var/lib/kea/dhcp4.leases* | wc -l) -ge {before + 2} ]", timeout=60)

    def newClients():
        gate.succeed("systemctl start gate-trusted-clients.service")
        return int(gate.succeed("cat /run/gate-trusted-clients/count"))

    with subtest("new trusted devices: none at the first run, then each once"):
        laptop.wait_until_succeeds("ip -4 -o addr show dev trusted scope global | grep -q inet", timeout=120)
        # As if just deployed, with laptop already leased.
        gate.succeed("systemctl stop gate-trusted-clients.timer")
        gate.succeed("rm -rf /var/lib/gate-trusted-clients /run/gate-trusted-clients")
        assert newClients() == 0
        assert gate.succeed("stat -c '%U %a' /var/lib/gate-trusted-clients").strip() == "root 700"
        assert gate.succeed("wc -l </var/lib/gate-trusted-clients/seen").strip() == "1"

        renew(laptop, "trusted")
        renew(iot, "iot")
        assert newClients() == 0

        gate.succeed("systemctl start gate-trusted-clients.timer")
        newcomer.start()
        newcomer.wait_until_succeeds("ip -4 -o addr show dev trusted scope global | grep -q inet", timeout=120)
        # The timer, then gate-metrics-facts, then the scrape.
        gate.wait_until_succeeds("grep -qx 1 /run/gate-trusted-clients/count", timeout=90)
        gate.wait_until_succeeds("grep -qx 'fleet_kea_new_trusted_clients_total 1' /run/fleet-metrics/gate.prom", timeout=60)
        core5.wait_until_succeeds("curl -sf --max-time 5 ${node} | grep -x 'fleet_kea_new_trusted_clients_total 1'", timeout=60)

        renew(newcomer, "trusted")
        assert newClients() == 1
        text = scrape("${node}")
        assert one(text, "fleet_kea_new_trusted_clients_total") == 1

    with subtest("no WAN address, and MAC addresses only where core5 drops them"):
        for t in (text, keaText):
            assert "${ispPrefix}" not in t, [l for l in t.splitlines() if "${ispPrefix}" in l]
        for t in (text, keaText):
            for line in t.splitlines():
                if re.search(r"([0-9a-f]{2}:){5}[0-9a-f]{2}", line) and not line.startswith("#"):
                    assert line.startswith("node_network_info{"), line
  '';
}
