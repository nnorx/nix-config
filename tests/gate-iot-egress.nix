# gate's iot egress chain, end to end in VMs: an iot address in the
# `iot-trial` set is dropped out `wan` and counted, while it still resolves;
# a connection it already had survives until `conntrack -D` ends it;
# and another iot address still reaches the internet and the Pis; flushing the
# chain gives the member its internet back, and reloading the ruleset empties
# the set. docs/privacy.md, "Internet for iot", has the design and the
# commands this runs, as Nick would run them on gate.
#
# `nix build .#checks.x86_64-linux.gate-iot-egress`. It needs KVM, which
# forge's daemon has; CI evaluates it without building.
#
# The topology is ./gate-dns.nix's: gate is hosts/gate/routing.nix itself, the
# fleet's resolvers are one VM holding both their addresses, and "the
# internet" is one VM holding the public resolvers' addresses, here also
# listening on 443 as a device's cloud would.
{ net }:
let
  seg = net.segments;
  publicResolver = builtins.head net.publicResolvers;
  pi = net.hosts.${builtins.head net.resolvers}.ip;
  filteredName = "filtered.example";

  # RFC 5737 documentation addresses, as in ./gate-dns.nix.
  isp = {
    gate = "203.0.113.2";
    upstream = "203.0.113.1";
  };

  wire = {
    wan = 1;
    trunk = 2;
    wired = 3;
  };

  # The two ends of iot's pool: one goes into the trial set, one stays out.
  addressOf = {
    member = seg.iot.pool.first;
    other = seg.iot.pool.last;
  };

  # A device on iot, at `address`, as one behind the AP is.
  onIot =
    address:
    { pkgs, ... }:
    {
      virtualisation.interfaces.trunk.vlan = wire.trunk;
      networking = {
        useDHCP = false;
        vlans.iot = {
          inherit (seg.iot) id;
          interface = "trunk";
        };
        interfaces.iot.ipv4.addresses = [
          {
            inherit address;
            inherit (seg.iot) prefixLength;
          }
        ];
        defaultGateway = {
          address = seg.iot.gateway;
          interface = "iot";
        };
      };
      environment.systemPackages = [
        pkgs.dnsutils
        (probe pkgs)
        (hold pkgs)
      ];
    };

  # Holds one connection open, as a device does to its cloud, sending a byte a
  # second and reading it back, and writes "alive" or, once that fails,
  # "dead" to a file.
  hold =
    pkgs:
    pkgs.writers.writePython3Bin "hold" { } ''
      import socket
      import sys
      import time

      host, port, out = sys.argv[1], int(sys.argv[2]), sys.argv[3]
      s = socket.create_connection((host, port), timeout=5)
      s.settimeout(3)
      while True:
          try:
              s.sendall(b"x")
              if s.recv(1) != b"x":
                  raise OSError("closed")
              state = "alive"
          except OSError:
              state = "dead"
          with open(out, "w") as f:
              f.write(state)
          if state == "dead":
              break
          time.sleep(1)
    '';

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
  name = "gate-iot-egress";

  node.specialArgs = { inherit net; };

  nodes = {
    gate =
      { lib, pkgs, ... }:
      {
        imports = [ ../hosts/gate/routing.nix ];

        virtualisation.interfaces = {
          wan.vlan = wire.wan;
          lan0.vlan = wire.trunk;
          lan1.vlan = wire.wired;
        };

        # Kea requires carrier on every interface it serves, and leases are
        # not what is under test. The devices here are static.
        services.kea.dhcp4.enable = lib.mkForce false;

        # As hosts/gate/default.nix installs it, for the trial's `conntrack -D`.
        environment.systemPackages = [ pkgs.conntrack-tools ];

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
      services.dnsmasq = dns "0.0.0.0";
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
        services.dnsmasq = dns isp.upstream;
        # Echoes, so a device can hold a connection open as it would to its
        # cloud; a probe's connection ends when the probe exits.
        systemd.services.listen-443 = {
          wantedBy = [ "multi-user.target" ];
          script = "${pkgs.socat}/bin/socat TCP-LISTEN:443,fork,reuseaddr EXEC:${pkgs.coreutils}/bin/cat";
        };
      };

    member = onIot addressOf.member;
    other = onIot addressOf.other;
  };

  testScript = ''
    import json
    import re

    start_all()

    fleet.wait_for_unit("dnsmasq.service")
    internet.wait_for_unit("dnsmasq.service")
    internet.wait_for_open_port(443)
    gate.wait_for_unit("nftables.service")
    gate.wait_for_unit("network.target")
    for d in (member, other):
        d.wait_for_unit("network.target")
        d.wait_until_succeeds("ping -c1 -W1 ${publicResolver}", timeout=60)

    def counter(name):
        out = json.loads(gate.succeed(f"nft -j list counter inet nixos-fw {name}"))
        return next(o["counter"]["packets"] for o in out["nftables"] if "counter" in o)

    def reaches_cloud(device):
        return device.succeed("probe ${publicResolver} 443").strip()

    def resolves(device):
        # Straight to a Pi, and to an outside resolver, which the redirect
        # sends to the Pis too. The fleet's answer either way.
        for server in ("${pi}", "${publicResolver}"):
            answer = device.succeed(f"dig +short +tries=1 +time=3 @{server} ${filteredName}").strip()
            assert answer == "0.0.0.0", f"@{server}: expected the fleet's answer, got {answer!r}"

    with subtest("with the set empty, both reach the internet, and are counted"):
        before = counter("iot-wan")
        for d in (member, other):
            assert reaches_cloud(d) == "open"
        assert counter("iot-wan") > before, "iot-wan did not count iot's flows"
        assert counter("iot-trial-dropped") == 0

    with subtest("a connection already open survives joining the set, until conntrack -D ends it"):
        member.succeed("systemd-run --unit hold hold ${publicResolver} 443 /tmp/hold")
        member.wait_until_succeeds("grep -qx alive /tmp/hold", timeout=20)
        gate.succeed("nft add element inet nixos-fw iot-trial '{ ${addressOf.member} }'")
        member.sleep(5)
        assert member.succeed("cat /tmp/hold").strip() == "alive", "the set alone ended an established connection"
        # Exits non-zero when it deletes nothing, so execute, and read the count.
        _, out = gate.execute("conntrack -D -s ${addressOf.member} 2>&1")
        deleted = re.search(r"(\d+) flow entries have been deleted", out)
        assert deleted and int(deleted.group(1)) > 0, f"conntrack -D deleted nothing:\n{out}"
        member.wait_until_succeeds("grep -qx dead /tmp/hold", timeout=30)

    print(gate.succeed("nft list set inet nixos-fw iot-trial"))

    with subtest("a member is dropped out wan, and counted"):
        assert reaches_cloud(member) == "timeout", "member reached the internet"
        assert counter("iot-trial-dropped") > 0, "the drops were not counted"

    with subtest("a member still resolves"):
        resolves(member)

    with subtest("a non-member still reaches the internet and the Pis"):
        assert reaches_cloud(other) == "open"
        other.succeed("ping -c1 -W2 ${publicResolver}")
        resolves(other)

    with subtest("the commands docs/privacy.md gives read the counters"):
        listed = gate.succeed("nft list counters table inet nixos-fw")
        print(listed)
        for name in ("iot-wan", "iot-trial-dropped"):
            assert f"counter {name} " in listed, f"{name} missing from:\n{listed}"

    with subtest("taking the member out of the set restores it"):
        gate.succeed("nft delete element inet nixos-fw iot-trial '{ ${addressOf.member} }'")
        assert reaches_cloud(member) == "open"
        gate.succeed("nft add element inet nixos-fw iot-trial '{ ${addressOf.member} }'")
        assert reaches_cloud(member) == "timeout"

    with subtest("flushing the chain restores the member, and the non-member is unchanged"):
        gate.succeed("nft flush chain inet nixos-fw iot-egress")
        assert reaches_cloud(member) == "open"
        assert reaches_cloud(other) == "open"
        resolves(member)

    with subtest("reloading the ruleset restores the chain, empties the set, and zeroes the counters"):
        gate.succeed("systemctl reload nftables")
        assert counter("iot-trial-dropped") == 0, "iot-trial-dropped survived the reload"
        chain = gate.succeed("nft list chain inet nixos-fw iot-egress")
        assert "@iot-trial" in chain, f"chain not restored:\n{chain}"
        elements = json.loads(gate.succeed("nft -j list set inet nixos-fw iot-trial"))
        s = next(o["set"] for o in elements["nftables"] if "set" in o)
        assert "elem" not in s, f"set not emptied: {s}"
        assert reaches_cloud(member) == "open"

    with subtest("after the reload, adding the member again drops it again"):
        gate.succeed("nft add element inet nixos-fw iot-trial '{ ${addressOf.member} }'")
        assert reaches_cloud(member) == "timeout", "the reloaded chain let a member out"
        assert counter("iot-trial-dropped") > 0, "the reloaded chain did not count the drop"
  '';
}
