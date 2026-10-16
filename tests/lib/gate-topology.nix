# The topology the gate VM tests share, so a fix to it lands in every one of
# them. Not a test itself, so not in flake.nix's checks.
#
# gate is hosts/gate/routing.nix itself, on VM NICs given gate's interface
# names, so the ruleset under test is the one gate renders. What it leaves out
# is everything that needs gate's hardware or secrets: WireGuard, DDNS and
# deploy-guard. "The internet" is one VM holding the public resolvers'
# addresses, and the fleet's resolvers are one VM holding both of theirs,
# answering a filtered name the way AdGuard blocks it, while the internet
# answers it differently, so an answer says which side it came from.
#
# Each piece is a module, and a test adds what only it needs beside it: a
# listener on the internet, packages on a client, more of gate's modules.
{ net }:
let
  seg = net.segments;
  gate = net.hosts.gate;
in
rec {
  # The link between gate and its upstream, standing in for the ISP. RFC 5737
  # documentation addresses: nothing in the fleet, so they belong here rather
  # than in lib/net.nix. `leases` is the range the internet hands out when it
  # serves gate's WAN address by DHCP.
  isp = {
    gate = "203.0.113.2";
    upstream = "203.0.113.1";
    prefix = "203.0.113.";
    leases = {
      first = "203.0.113.10";
      last = "203.0.113.20";
    };
  };

  # Test VLANs, which are QEMU's virtual wires, not 802.1Q tags.
  wire = {
    wan = 1;
    trunk = 2;
    # Nothing on it. gate's config expects its wired port, and without the
    # device its boot waits five minutes for it.
    wired = 3;
  };

  filteredName = "filtered.example";

  # Answers `filteredName` with `answer`, on every address it holds.
  answering = answer: {
    enable = true;
    resolveLocalQueries = false;
    settings = {
      no-resolv = true;
      address = "/${filteredName}/${answer}";
    };
  };

  # Connects to a port and says how it went: "open", "refused", which is a TCP
  # reset or an ICMP port-unreachable, or "timeout", which is what a drop
  # looks like. For UDP, which has no handshake, "timeout" means nothing came
  # back. `probe host port` is TCP; `probe tcp|udp host port` also prints how
  # many milliseconds it took, for the tests that time a refusal.
  probe =
    pkgs:
    pkgs.writers.writePython3Bin "probe" { } ''
      import socket
      import sys
      import time

      args = sys.argv[1:]
      proto = args.pop(0) if len(args) == 3 else None
      host, port = args[0], int(args[1])
      kind = socket.SOCK_DGRAM if proto == "udp" else socket.SOCK_STREAM
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
      if proto is None:
          print(result)
      else:
          print(result, int((time.monotonic() - start) * 1000))
    '';

  # gate. With `dhcp`, it takes its WAN address from the internet by DHCP and
  # serves leases with Kea, as gate does. Without, its WAN address is static
  # and Kea is off: Kea requires carrier on every interface it serves, and
  # the clients in those tests are static.
  router =
    {
      dhcp ? false,
    }:
    { lib, ... }:
    {
      imports = [ ../../hosts/gate/routing.nix ];

      virtualisation.interfaces = {
        ${gate.wanIface}.vlan = wire.wan;
        ${gate.trunkIface}.vlan = wire.trunk;
        ${gate.wiredIface}.vlan = wire.wired;
      };

      services.kea.dhcp4.enable = lib.mkIf (!dhcp) (lib.mkForce false);

      networking = {
        useDHCP = false;
        interfaces.${gate.wanIface} =
          if dhcp then
            { useDHCP = true; }
          else
            {
              ipv4.addresses = [
                {
                  address = isp.gate;
                  prefixLength = 24;
                }
              ];
            };
        defaultGateway = lib.mkIf (!dhcp) {
          address = isp.upstream;
          interface = gate.wanIface;
        };
      };
    };

  # The far side of gate's `wan`, holding every public resolver's address.
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
      ]
      ++ map (address: {
        inherit address;
        prefixLength = 32;
      }) net.publicResolvers;
    };
  };

  # A host untagged on the trunk, as everything on servers is, at each of
  # `addresses`.
  onServers = addresses: {
    virtualisation.interfaces.trunk.vlan = wire.trunk;
    networking = {
      useDHCP = false;
      firewall.enable = false;
      interfaces.trunk.ipv4.addresses = map (address: {
        inherit address;
        inherit (seg.servers) prefixLength;
      }) addresses;
      defaultGateway = {
        address = seg.servers.gateway;
        interface = "trunk";
      };
    };
  };

  # core4 and lifeline, as one host holding both their addresses, answering
  # `filteredName` as AdGuard answers a blocked name.
  fleet = {
    imports = [ (onServers (map (h: net.hosts.${h}.ip) net.resolvers)) ];
    services.dnsmasq = answering "0.0.0.0";
  };

  # A device on the tagged segment `name`, as one behind the AP is: at
  # `address`, or by DHCP from gate when it is null.
  onSegment = name: address: {
    virtualisation.interfaces.trunk.vlan = wire.trunk;
    networking = {
      useDHCP = false;
      vlans.${name} = {
        inherit (seg.${name}) id;
        interface = "trunk";
      };
    }
    // (
      if address == null then
        { interfaces.${name}.useDHCP = true; }
      else
        {
          interfaces.${name}.ipv4.addresses = [
            {
              inherit address;
              inherit (seg.${name}) prefixLength;
            }
          ];
          defaultGateway = {
            address = seg.${name}.gateway;
            interface = name;
          };
        }
    );
  };
}
