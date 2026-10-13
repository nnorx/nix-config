# The resolvers' local copy of the root zone, end to end in VMs: a resolver
# with no copy yet still resolves, by asking the root; once it has a copy, a
# name under no TLD is answered NXDOMAIN with the root unreachable; a
# transfer whose ZONEMD does not match its contents is refused, and the root
# asked instead; and a restart starts from the last good copy on disk.
#
# `nix build .#checks.x86_64-linux.unbound-root-zone`. It needs KVM, which
# forge's daemon has; CI's vm-tests job runs it on pull requests.
#
# The resolver is modules/unbound.nix as gate imports it. The root is a BIND
# serving a root zone of its own, with a ZONEMD computed here, so the root
# hints, the transfer source and the trust anchor are the three things the
# test replaces: the real root is unreachable from a VM, and its signatures
# would not cover this zone. Without a trust anchor nothing is validated, so
# this checks the digest alone; on the hosts the ZONEMD's signature is checked
# too.
{ net }:
{ hostPkgs, ... }:
let
  # RFC 5737 documentation addresses: nothing in the fleet, so they belong
  # here rather than in lib/net.nix.
  rootIp = "192.0.2.53";
  resolverIp = "192.0.2.10";
  prefixLength = 24;
  exampleIp = "192.0.2.80";
  tamperedIp = "192.0.2.66";

  hints = hostPkgs.writeText "root.hints" ''
    .                   3600000 NS a.root-servers.net.
    a.root-servers.net. 3600000 A  ${rootIp}
  '';

  # The root zone, at serial 1 with a ZONEMD that matches it, and at serial 2
  # with one of its records changed after the digest was taken, as a transfer
  # altered in flight would arrive. `example` stands for every TLD that
  # exists; anything else is a name the root has never heard of.
  zoneTemplate = hostPkgs.writeText "root.zone.in" ''
    .                   86400  IN SOA a.root-servers.net. nstld.verisign-grs.com. SERIAL 1800 900 604800 86400
    .                   518400 IN NS  a.root-servers.net.
    a.root-servers.net. 518400 IN A   ${rootIp}
    www.example.        3600   IN A   ${exampleIp}
    mail.example.       3600   IN A   ${exampleIp}
  '';
  digest = hostPkgs.writeText "zonemd.py" ''
    import sys
    import dns.name, dns.rdata, dns.zone, dns.zonetypes

    template, serial, tamper, out = sys.argv[1:]
    with open(template) as f:
        text = f.read().replace("SERIAL", serial)
    z = dns.zone.from_text(text, origin=dns.name.root, relativize=False)
    zonemd = z.compute_digest(dns.zonetypes.DigestHashAlgorithm.SHA384)
    with z.writer() as txn:
        txn.add(dns.name.root, 86400, zonemd)
    z.verify_digest()
    if tamper == "tamper":
        with z.writer() as txn:
            txn.replace(
                dns.name.from_text("mail.example."),
                3600,
                dns.rdata.from_text("IN", "A", "${tamperedIp}"),
            )
    z.to_file(out, relativize=False)
  '';
  zones =
    hostPkgs.runCommand "test-root-zones"
      { nativeBuildInputs = [ (hostPkgs.python3.withPackages (p: [ p.dnspython ])) ]; }
      ''
        mkdir $out
        python3 ${digest} ${zoneTemplate} 1 keep $out/good.zone
        python3 ${digest} ${zoneTemplate} 2 tamper $out/tampered.zone
      '';

  # Where BIND reads the zone, a link the test points at one file or the other.
  servedZone = "/var/lib/root-test/root.zone";

  onWire =
    ip:
    { pkgs, ... }:
    {
      virtualisation.interfaces.end0.vlan = 1;
      environment.systemPackages = [ pkgs.dnsutils ];
      networking = {
        useDHCP = false;
        interfaces.end0.ipv4.addresses = [
          {
            address = ip;
            inherit prefixLength;
          }
        ];
      };
    };
in
{
  name = "unbound-root-zone";

  node.specialArgs = {
    net = net // {
      rootZoneSources = [ rootIp ];
    };
    hostname = "gate";
  };

  nodes = {
    root = {
      imports = [ (onWire rootIp) ];
      services.bind = {
        enable = true;
        # The zone is read through a link created at boot, which the build's
        # check cannot follow.
        checkConfig = false;
        extraOptions = ''
          recursion no;
          querylog yes;
        '';
        zones."." = {
          master = true;
          file = servedZone;
          slaves = [ resolverIp ];
        };
      };
      systemd.tmpfiles.rules = [ "L+ ${servedZone} - - - - ${zones}/good.zone" ];

      # Queries over UDP, and transfers, which are TCP, refused until the test
      # allows them: a resolver whose first transfer fails, as a fresh host's
      # would with the sources unreachable.
      networking.firewall = {
        allowedUDPPorts = [ 53 ];
        rejectPackets = true;
      };
    };

    resolver =
      { lib, ... }:
      {
        imports = [
          (onWire resolverIp)
          # As hosts/gate imports it.
          (import ../modules/unbound.nix {
            port = 53;
            resolveLocalQueries = true;
          })
        ];
        services.unbound = {
          enableRootTrustAnchor = false;
          settings.server.root-hints = lib.mkForce "${hints}";
        };
      };
  };

  testScript =
    { nodes, ... }:
    let
      control = "${nodes.resolver.services.unbound.package}/bin/unbound-control -c /etc/unbound/unbound.conf";
      zoneFile = "${nodes.resolver.services.unbound.stateDir}/root.zone";
    in
    ''
      def rcode(name):
          out = resolver.succeed(f"dig @127.0.0.1 {name} A")
          return out.split("status: ")[1].split(",")[0]

      def address(name):
          return resolver.succeed(f"dig @127.0.0.1 {name} A +short").strip()

      start_all()
      root.wait_for_unit("bind.service")
      root.wait_for_open_port(53)
      resolver.wait_for_unit("unbound.service")

      with subtest("with no copy, the resolver asks the root"):
          resolver.fail("test -s ${zoneFile}")
          assert address("www.example.") == "${exampleIp}"
          assert rcode("printer.") == "NXDOMAIN"
          root.wait_until_succeeds("journalctl -u bind.service | grep -qi 'query: printer IN A'")

      with subtest("once transferred, the copy answers with the root unreachable"):
          root.succeed("iptables -I nixos-fw -p tcp --dport 53 -j nixos-fw-accept")
          resolver.succeed("${control} auth_zone_transfer .")
          resolver.wait_until_succeeds("grep -q ZONEMD ${zoneFile}")
          resolver.wait_until_succeeds("${control} list_auth_zones | grep -q 'serial 1'")
          root.succeed("systemctl stop bind.service")
          assert rcode("scanner.") == "NXDOMAIN"
          assert address("mail.example.") == "${exampleIp}"

      # Unbound drops its copy as expired rather than keep serving the older
      # serial, and falls back to the root. The file keeps the last good zone,
      # which a restart loads and checks again.
      with subtest("a transfer that fails its ZONEMD is refused, and the root asked"):
          root.succeed("ln -sfn ${zones}/tampered.zone ${servedZone}")
          root.succeed("systemctl start bind.service")
          root.wait_for_open_port(53)
          resolver.succeed("${control} auth_zone_transfer .")
          resolver.wait_until_succeeds(
              "journalctl -u unbound.service | grep -q 'ZONEMD verification failed: incorrect digest'"
          )
          resolver.wait_until_succeeds("${control} list_auth_zones | grep -q expired")
          resolver.fail("grep -q ${tamperedIp} ${zoneFile}")
          resolver.succeed("grep -q ZONEMD ${zoneFile}")
          assert rcode("fax.") == "NXDOMAIN"
          root.wait_until_succeeds("journalctl -u bind.service | grep -qi 'query: fax IN A'")

      with subtest("a restart starts from the last good copy"):
          root.succeed("systemctl stop bind.service")
          resolver.succeed("systemctl restart unbound.service")
          resolver.wait_until_succeeds("${control} list_auth_zones | grep -q 'serial 1'")
          assert rcode("modem.") == "NXDOMAIN"
    '';
}
