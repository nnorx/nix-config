# core5's DNS, in VMs: a host lookup goes over TLS to the outside resolver; a
# container's lookup, from a user-defined network as the UniFi containers'
# are, does too; and with 853 dropped, lookups fail rather than go out in
# plaintext.
#
# core5 here is hosts/core5/dns.nix and Docker on one NIC, whose default route
# is the outside node. That node holds the addresses of `encryptedResolvers`
# and `publicResolvers`, and unbound on them answers on 853 with TLS, with a
# certificate from a CA only core5 trusts, and on 53 in plaintext, so a leak
# resolves and is counted rather than timing out.
{ net }:
let
  outside = map (r: r.ip) net.encryptedResolvers;
  outsideName = (builtins.head net.encryptedResolvers).name;
  every = outside ++ builtins.filter (ip: !builtins.elem ip outside) net.publicResolvers;
  set = builtins.concatStringsSep ", " every;

  answer = "192.0.2.3";

  # Documentation addresses: nothing in the fleet, so they belong here rather
  # than in lib/net.nix.
  wire = {
    outside = "203.0.113.1";
    core5 = "203.0.113.2";
  };

  certs =
    pkgs:
    pkgs.runCommand "core5-dns-test-certs" { nativeBuildInputs = [ pkgs.openssl ]; } ''
      mkdir $out
      openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
        -days 36500 -subj /CN=core5-dns-test-ca -keyout ca.key -out $out/ca.pem
      openssl req -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
        -subj /CN=${outsideName} -keyout $out/key.pem -out leaf.csr
      printf 'subjectAltName=DNS:${outsideName}\n' > ext
      openssl x509 -req -in leaf.csr -CA $out/ca.pem -CAkey ca.key -CAcreateserial \
        -days 36500 -extfile ext -out $out/cert.pem
    '';

  addrs =
    prefixLength:
    map (address: {
      inherit address prefixLength;
    });

  image =
    pkgs:
    pkgs.dockerTools.buildImage {
      name = "lookup";
      tag = "latest";
      copyToRoot = [ pkgs.busybox ];
    };
in
{
  name = "core5-dns";

  node.specialArgs = { inherit net; };

  nodes = {
    core5 =
      { pkgs, ... }:
      {
        imports = [
          ../hosts/core5/dns.nix
          ../modules/docker.nix
        ];
        virtualisation.interfaces.wan.vlan = 1;
        networking = {
          useDHCP = false;
          interfaces.wan.ipv4.addresses = addrs 24 [ wire.core5 ];
          defaultGateway = {
            address = wire.outside;
            interface = "wan";
          };
        };
        security.pki.certificateFiles = [ "${certs pkgs}/ca.pem" ];
        virtualisation.memorySize = 2048;
        environment.etc."lookup-image.tar.gz".source = image pkgs;
      };

    outside =
      { pkgs, ... }:
      {
        virtualisation.interfaces.wan.vlan = 1;
        networking = {
          useDHCP = false;
          firewall.enable = false;
          nftables.enable = true;
          interfaces.wan.ipv4.addresses = addrs 24 [ wire.outside ] ++ addrs 32 every;
          nftables.ruleset = ''
            table inet outside {
              counter plaintext {}
              counter tls {}
              chain input {
                type filter hook input priority 0; policy accept;
                ip daddr { ${set} } meta l4proto { tcp, udp } th dport 53 counter name plaintext
                ip daddr { ${set} } tcp dport 853 tcp flags syn counter name tls
              }
            }
          '';
        };
        services.unbound = {
          enable = true;
          resolveLocalQueries = false;
          enableRootTrustAnchor = false;
          settings.server = {
            interface = map (ip: "${ip}@853") outside ++ map (ip: "${ip}@53") every;
            tls-port = 853;
            tls-service-key = "${certs pkgs}/key.pem";
            tls-service-pem = "${certs pkgs}/cert.pem";
            access-control = [ "0.0.0.0/0 allow" ];
            local-zone = [ ". static" ];
            local-data = [ ''"probe.test. A ${answer}"'' ];
          };
        };
      };
  };

  testScript = ''
    import re

    start_all()

    outside.wait_for_unit("unbound.service")
    outside.wait_for_open_port(853, "${builtins.head outside}")
    core5.wait_for_unit("systemd-resolved.service")
    core5.wait_for_unit("docker.service")
    core5.succeed("docker load < /etc/lookup-image.tar.gz")
    core5.succeed("docker network create unifi")

    def counter(name):
        out = outside.succeed(f"nft list counter inet outside {name}")
        match = re.search(r"packets (\d+)", out)
        assert match, out
        return int(match.group(1))

    def transactions():
        out = core5.succeed("resolvectl statistics")
        match = re.search(r"Total Transactions:\s*(\d+)", out)
        assert match, out
        return int(match.group(1))

    def container_lookup():
        return core5.execute(
            "docker run --rm --network unifi lookup:latest nslookup -type=a probe.test"
        )

    with subtest("the host resolves over TLS, and nothing in plaintext"):
        plaintext, tls = counter("plaintext"), counter("tls")
        out = core5.succeed("resolvectl query --cache=no -4 probe.test")
        print(out)
        assert "${answer}" in out, out
        assert "encrypted transport: yes" in out, out
        assert counter("tls") > tls
        assert counter("plaintext") == plaintext

    with subtest("a container on a user-defined network resolves, and nothing in plaintext"):
        plaintext, asked = counter("plaintext"), transactions()
        status, out = container_lookup()
        print(out)
        assert status == 0 and "${answer}" in out, out
        # Through resolved, not to the upstream servers directly.
        assert transactions() > asked
        assert counter("plaintext") == plaintext, f"plaintext: {counter('plaintext') - plaintext} packets"

    with subtest("with 853 dropped, lookups fail and nothing goes out in plaintext"):
        outside.succeed("nft add rule inet outside input tcp dport 853 drop")
        core5.succeed("resolvectl flush-caches")
        plaintext = counter("plaintext")
        core5.fail("timeout 60 resolvectl query --cache=no -4 probe.test")
        status, out = container_lookup()
        print(out)
        assert "${answer}" not in out, out
        assert counter("plaintext") == plaintext

    with subtest("nothing went to the outside resolvers in plaintext"):
        assert counter("plaintext") == 0
  '';
}
