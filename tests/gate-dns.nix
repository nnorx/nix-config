# gate's DNS rules, end to end in VMs: plaintext port 53 to an outside
# resolver lands on the fleet, and port 853 to one is refused fast enough that
# a client falls back rather than waits.
#
# `nix build .#checks.x86_64-linux.gate-dns`. It needs KVM, which forge's
# daemon has; CI's vm-tests job runs it on pull requests.
#
# The topology is ./lib/gate-topology.nix's: gate is hosts/gate/routing.nix
# itself, the fleet's resolvers are one VM, and "the internet" is another,
# here also listening for DoT and DoQ. These rules depend on none of what it
# leaves out of gate, Kea included.
{ net }:
let
  topology = import ./lib/gate-topology.nix { inherit net; };
  inherit (topology) isp filteredName;
  publicResolver = builtins.head net.publicResolvers;

  # A client on a tagged segment, at the first address of its pool.
  client =
    name:
    { pkgs, ... }:
    {
      imports = [ (topology.onSegment name net.segments.${name}.pool.first) ];
      environment.systemPackages = [
        pkgs.dnsutils
        pkgs.knot-dns
        (topology.probe pkgs)
      ];
    };
in
{
  name = "gate-dns";

  node.specialArgs = { inherit net; };

  nodes = {
    gate = topology.router { };

    inherit (topology) fleet;

    # The internet, plus a DoT and DoQ listener that records whatever reaches
    # it, so a refusal can be shown to be gate's rather than the far end's.
    internet =
      { pkgs, ... }:
      {
        imports = [ topology.internet ];
        services.dnsmasq = topology.answering isp.upstream;
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
