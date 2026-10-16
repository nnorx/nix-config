# gate's DNS rules, end to end in VMs: plaintext port 53 to an outside
# resolver lands on the fleet, and port 853 to one is refused fast enough that
# a client falls back rather than waits.
#
# `nix build .#checks.x86_64-linux.gate-dns`. It needs KVM, which forge's
# daemon has; CI's vm-tests job runs it on pull requests.
#
# The router is hosts/gate/routing.nix itself, on VM NICs given gate's
# interface names, so the ruleset under test is the one gate renders. What it
# leaves out is everything that needs gate's hardware or secrets: WireGuard,
# DDNS, deploy-guard and Kea, none of which these rules depend on. The fleet's
# resolvers are one VM holding both their addresses and answering a filtered
# name the way AdGuard blocks it, and "the internet" is one VM holding the
# public resolvers' addresses and answering the same name differently, so an
# answer says which side it came from.
{ net }:
let
  seg = net.segments;
  publicResolver = builtins.head net.publicResolvers;
  filteredName = "filtered.example";

  # The link between gate and its upstream, standing in for the ISP's DHCP.
  # RFC 5737 documentation addresses: nothing in the fleet, so they belong
  # here rather than in lib/net.nix.
  isp = {
    gate = "203.0.113.2";
    upstream = "203.0.113.1";
  };

  # Test VLANs, which are QEMU's virtual wires, not 802.1Q tags.
  wire = {
    wan = 1;
    trunk = 2;
    wired = 3;
  };

  # A client on a tagged segment, as a device behind the AP is.
  client =
    name:
    { pkgs, ... }:
    {
      virtualisation.interfaces.trunk.vlan = wire.trunk;
      networking = {
        useDHCP = false;
        vlans.${name} = {
          id = seg.${name}.id;
          interface = "trunk";
        };
        interfaces.${name}.ipv4.addresses = [
          {
            address = seg.${name}.pool.first;
            inherit (seg.${name}) prefixLength;
          }
        ];
        defaultGateway = {
          address = seg.${name}.gateway;
          interface = name;
        };
      };
      environment.systemPackages = [
        pkgs.dnsutils
        pkgs.knot-dns
        (probe pkgs)
      ];
    };

  # Connects to a port and says how it went and how long that took: "refused"
  # is a TCP reset or an ICMP port-unreachable, which is what gate is meant to
  # send. For UDP, which has no handshake, "timeout" means nothing came back.
  probe =
    pkgs:
    pkgs.writers.writePython3Bin "probe" { } ''
      import socket
      import sys
      import time

      proto, host, port = sys.argv[1], sys.argv[2], int(sys.argv[3])
      kind = socket.SOCK_STREAM if proto == "tcp" else socket.SOCK_DGRAM
      s = socket.socket(socket.AF_INET, kind)
      s.settimeout(5)
      start = time.monotonic()
      try:
          s.connect((host, port))
          if proto == "udp":
              s.send(b"probe")
              s.recv(1)
          result = "open"
      except ConnectionRefusedError:
          result = "refused"
      except socket.timeout:
          result = "timeout"
      print(result, int((time.monotonic() - start) * 1000))
    '';

  # Answers `filteredName` with `answer`, on every address it holds.
  dns = answer: {
    enable = true;
    resolveLocalQueries = false;
    settings = {
      no-resolv = true;
      address = "/${filteredName}/${answer}";
    };
  };
in
{
  name = "gate-dns";

  node.specialArgs = { inherit net; };

  nodes = {
    gate =
      { lib, ... }:
      {
        imports = [ ../hosts/gate/routing.nix ];

        virtualisation.interfaces = {
          wan.vlan = wire.wan;
          ${net.hosts.gate.trunkIface}.vlan = wire.trunk;
          ${net.hosts.gate.wiredIface}.vlan = wire.wired;
        };

        # Kea requires carrier on every interface it serves, and serving
        # leases is not what is under test. Clients here are static.
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

    # core4 and lifeline, untagged on the trunk as they are on the switch.
    fleet = {
      virtualisation.interfaces.trunk.vlan = wire.trunk;
      networking = {
        useDHCP = false;
        firewall.enable = false;
        interfaces.trunk.ipv4.addresses = map (h: {
          address = net.hosts.${h}.ip;
          inherit (seg.servers) prefixLength;
        }) net.resolvers;
        defaultGateway = {
          address = seg.servers.gateway;
          interface = "trunk";
        };
      };
      # What AdGuard answers for a blocked name.
      services.dnsmasq = dns "0.0.0.0";
    };

    # The far side of `wan`: every public resolver, plus a DoT and DoQ
    # listener that records whatever reaches it, so a refusal can be shown to
    # be gate's rather than the far end's.
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
        services.dnsmasq = dns isp.upstream;
        systemd.services = {
          listen-853-tcp = {
            wantedBy = [ "multi-user.target" ];
            script = "${pkgs.socat}/bin/socat -u TCP-LISTEN:853,fork,reuseaddr OPEN:/tmp/853-tcp,creat,append";
          };
          listen-853-udp = {
            wantedBy = [ "multi-user.target" ];
            script = "${pkgs.socat}/bin/socat -u UDP-RECVFROM:853,fork OPEN:/tmp/853-udp,creat,append";
          };
        };
      };

    # Redirected, so 853 is refused.
    trusted = client "trusted";

    # Not redirected, since it is on public resolvers, so 853 passes. Shows
    # the refusal follows the redirect rather than covering everything.
    guest = client "guest";
  };

  testScript = ''
    import time

    start_all()

    fleet.wait_for_unit("dnsmasq.service")
    internet.wait_for_unit("dnsmasq.service")
    internet.wait_for_unit("listen-853-tcp.service")
    internet.wait_for_unit("listen-853-udp.service")
    internet.wait_for_open_port(853)
    gate.wait_for_unit("nftables.service")
    gate.wait_for_unit("network.target")
    for c in (trusted, guest):
        c.wait_for_unit("network.target")
        c.wait_until_succeeds("ping -c1 -W1 ${publicResolver}", timeout=60)

    def probe(machine, proto):
        result, ms = machine.succeed(f"probe {proto} ${publicResolver} 853").split()
        return result, int(ms)

    with subtest("trusted: plaintext DNS to an outside resolver is answered by the fleet"):
        answer = trusted.succeed("dig +short +tries=1 +time=3 @${publicResolver} ${filteredName}").strip()
        assert answer == "0.0.0.0", f"expected the fleet's answer, got {answer!r}"
        answer = trusted.succeed("dig +short +tcp +tries=1 +time=3 @${publicResolver} ${filteredName}").strip()
        assert answer == "0.0.0.0", f"expected the fleet's answer over TCP, got {answer!r}"

    with subtest("trusted: DoT is reset, at once"):
        result, ms = probe(trusted, "tcp")
        assert result == "refused" and ms < 1000, f"tcp 853: {result} after {ms} ms"

    with subtest("trusted: DoQ gets port-unreachable, at once"):
        result, ms = probe(trusted, "udp")
        assert result == "refused" and ms < 1000, f"udp 853: {result} after {ms} ms"

    with subtest("trusted: kdig +tls fails fast, as docs/router.md has it checked on gate"):
        start = time.monotonic()
        trusted.fail("kdig +tls +retry=0 +timeout=5 @${publicResolver} ${filteredName}")
        elapsed = time.monotonic() - start
        assert elapsed < 2, f"kdig +tls took {elapsed:.1f} s to fail"

    with subtest("nothing from trusted reached the far end on 853"):
        internet.succeed("[ ! -s /tmp/853-tcp ] && [ ! -s /tmp/853-udp ]")

    with subtest("gate's counters show the refusals"):
        rules = gate.succeed("nft list chain inet nixos-fw forward-allow")
        print(rules)
        for line in rules.splitlines():
            if "dport 853" in line:
                assert "packets 0 " not in line, f"rule never matched: {line}"

    with subtest("guest: not redirected, and 853 passes"):
        answer = guest.succeed("dig +short +tries=1 +time=3 @${publicResolver} ${filteredName}").strip()
        assert answer == "${isp.upstream}", f"expected the outside answer, got {answer!r}"
        result, ms = probe(guest, "tcp")
        assert result == "open", f"tcp 853 from guest: {result}"
        result, ms = probe(guest, "udp")
        assert result == "timeout", f"udp 853 from guest: {result}"
        internet.wait_until_succeeds("[ -s /tmp/853-udp ]", timeout=10)
  '';
}
