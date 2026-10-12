# A resolver's DNS metrics, end to end in VMs: core5 can scrape Unbound's
# exporter and AdGuard's counts on a resolver, nothing else on servers can, the
# counts answer the questions in docs/observability.md, and the work segment
# and every client and name stay out of them.
#
# `nix build .#checks.x86_64-linux.dns-metrics`. It needs KVM, which forge's
# daemon has; CI's vm-tests job runs it on pull requests.
#
# The resolver is core4's AdGuard and Unbound, from modules/adguardhome.nix and
# modules/unbound.nix, with modules/node-exporter.nix. sops-nix is a stand-in
# that renders templates from test values, since the real secrets decrypt only
# on the hosts. The VMs have no internet, so every recursion fails, which is
# what makes SERVFAIL countable here; a name blocked by a user rule stands in
# for the blocklists, which cannot be fetched. Another host on servers answers
# as the fallback, so AdGuard has one to turn to when Unbound is stopped.
{ net }:
let
  seg = net.segments;
  resolver = net.hosts.core4;
  fallback = net.hosts.lifeline;
  collector = net.hosts.${net.metricsCollector};
  unbound = "http://${resolver.ip}:${toString net.ports.unboundExporter}/metrics";
  node = "http://${resolver.ip}:${toString net.ports.nodeExporter}/metrics";
  blackbox = "http://127.0.0.1:${toString net.ports.blackboxExporter}/probe";
  store = "127.0.0.1:${toString net.ports.victoriaMetrics}";

  # A device on the work segment, on the same wire as the resolver: an address
  # from that segment's pool, with a route to the resolver on the link, and
  # one back. gate would route between them; the source address AdGuard sees
  # is the same either way.
  workIp = seg.work.pool.first;

  # Test values only: the hosts' own are in sops.
  password = "test-metrics-password";
  hash = "$2y$10$2ZMx0m3OrqiM5BJqcxHoi.ABohczlg1.tMY/tMxZyyCdonshadB6q";

  # sops-nix, as far as modules/adguardhome.nix uses it: secrets declared,
  # and templates written with each placeholder already replaced.
  sopsStub =
    { lib, pkgs, ... }:
    {
      options.sops = {
        secrets = lib.mkOption {
          type = lib.types.attrsOf lib.types.attrs;
          default = { };
        };
        placeholder = lib.mkOption { type = lib.types.attrsOf lib.types.str; };
        templates = lib.mkOption {
          default = { };
          type = lib.types.attrsOf (
            lib.types.submodule (
              { name, config, ... }:
              {
                options.content = lib.mkOption { type = lib.types.str; };
                options.path = lib.mkOption {
                  type = lib.types.str;
                  default = toString (pkgs.writeText name config.content);
                };
              }
            )
          );
        };
      };
      config.sops.placeholder = {
        adguard-admin-hash = "$2b$10$00000000000000000000000000000000000000000000000000000";
        adguard-metrics-hash = hash;
        adguard-metrics-password = password;
      };
    };

  wire = 1;
  onServers =
    ip:
    { pkgs, ... }:
    {
      virtualisation.interfaces.end0.vlan = wire;
      environment.systemPackages = [ pkgs.dnsutils ];
      networking = {
        useDHCP = false;
        firewall.enable = false;
        interfaces.end0.ipv4.addresses = [
          {
            address = ip;
            inherit (seg.servers) prefixLength;
          }
        ];
      };
    };
in
{
  name = "dns-metrics";

  node.specialArgs = {
    inherit net;
    hostname = "core4";
  };

  nodes = {
    resolver =
      { pkgs, ... }:
      {
        imports = [
          sopsStub
          # As hosts/core4 imports them, but for the fallback.
          (import ../modules/adguardhome.nix {
            adminUser = "core4";
            upstreamDns = [ "127.0.0.1:${toString net.ports.unbound}" ];
            fallbackDns = [ fallback.ip ];
          })
          (import ../modules/unbound.nix { })
          ../modules/node-exporter.nix
        ];

        virtualisation.interfaces.end0.vlan = wire;
        environment.systemPackages = [ pkgs.dnsutils ];
        networking = {
          useDHCP = false;
          interfaces.end0 = {
            ipv4.addresses = [
              {
                address = resolver.ip;
                inherit (seg.servers) prefixLength;
              }
            ];
            ipv4.routes = [
              {
                address = workIp;
                prefixLength = 32;
              }
            ];
          };
          # As hosts/core4 opens it.
          firewall.interfaces.end0 = {
            allowedTCPPorts = [ 53 ];
            allowedUDPPorts = [ 53 ];
          };
        };

        services.adguardhome.settings.user_rules = [ "||blocked.test^" ];

        # modules/ssh.nix sets it on every host, and the exporters' binds rely
        # on it at boot.
        boot.kernel.sysctl."net.ipv4.ip_nonlocal_bind" = 1;
      };

    # The collector's probes, with a store of its own scraping them every 5
    # seconds, so the scrape jobs and their labels are tested as well as the
    # exporter. Its ping targets are the public resolvers, which no VM reaches.
    core5 = {
      imports = [
        (onServers collector.ip)
        ../modules/blackbox.nix
      ];
      services.victoriametrics = {
        enable = true;
        listenAddress = store;
        prometheusConfig.global.scrape_interval = "5s";
      };
    };

    # Another host on servers, as the switch or the AP is, refused by the
    # exporters. It answers DNS as the resolver's fallback, with one address
    # for every name.
    other = {
      imports = [ (onServers fallback.ip) ];
      services.dnsmasq = {
        enable = true;
        resolveLocalQueries = false;
        settings = {
          no-resolv = true;
          address = "/#/192.0.2.1";
        };
      };
    };

    work =
      { pkgs, ... }:
      {
        virtualisation.interfaces.end0.vlan = wire;
        environment.systemPackages = [ pkgs.dnsutils ];
        networking = {
          useDHCP = false;
          firewall.enable = false;
          interfaces.end0 = {
            ipv4.addresses = [
              {
                address = workIp;
                inherit (seg.work) prefixLength;
              }
            ];
            ipv4.routes = [
              {
                address = resolver.ip;
                prefixLength = 32;
              }
            ];
          };
        };
      };
  };

  testScript = ''
    import re

    start_all()

    resolver.wait_for_unit("adguardhome.service")
    resolver.wait_for_unit("unbound.service")
    resolver.wait_for_unit("prometheus-unbound-exporter.service")
    resolver.wait_for_unit("prometheus-node-exporter.service")
    other.wait_for_unit("dnsmasq.service")
    for m in (core5, work):
        m.wait_for_unit("network.target")
    resolver.wait_until_succeeds("dig +time=2 +tries=1 @127.0.0.1 example.lan | grep -q 'status: NXDOMAIN'", timeout=60)

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

    def total(text, name):
        return sum(v for _, v in series(text, name))

    def scrape(url):
        return core5.wait_until_succeeds(f"curl -sf --max-time 5 {url}", timeout=60)

    def adguard():
        # The timer runs it every 30 seconds; this reads now instead. Asked
        # this often, systemd's start limit would refuse it.
        resolver.succeed("systemctl reset-failed adguard-metrics.service; systemctl start adguard-metrics.service")
        return scrape("${node}")

    def probe(module, target):
        text = core5.succeed(f"curl -sf --max-time 10 '${blackbox}?module={module}&target={target}'")
        return one(text, "probe_success")

    def dig(m, name, n=1):
        for i in range(n):
            m.succeed(f"dig +time=5 +tries=1 @${resolver.ip} {name} > /dev/null")

    with subtest("both exporters bind the resolver's address alone"):
        listening = resolver.succeed("ss -ltnH")
        print(listening)
        for port in ("${toString net.ports.nodeExporter}", "${toString net.ports.unboundExporter}"):
            assert f"${resolver.ip}:{port} " in listening, f"nothing on ${resolver.ip}:{port}"
            for wildcard in ("0.0.0.0", "*", "[::]"):
                assert f"{wildcard}:{port} " not in listening, f"{port} listens on {wildcard}"

    with subtest("another host on servers is refused"):
        other.fail("curl -sf --max-time 5 ${unbound}")
        other.fail("curl -sf --max-time 5 ${node}")

    # From core5, as any trusted client would ask: a name that fails
    # recursion, a local name twice, so the second is a cache hit, and a
    # blocked one.
    dig(core5, "example.com", 3)
    dig(core5, "printer.lan", 2)
    dig(core5, "ads.blocked.test", 4)

    text = scrape("${unbound}")
    stats = adguard()

    with subtest("Unbound: answers by code, cache, latency, DNSSEC, drops"):
        print(f"{sum(1 for l in text.splitlines() if l.startswith('unbound_'))} Unbound series")
        assert one(text, "unbound_up") == 1
        assert one(text, "unbound_answer_rcodes_total", rcode="SERVFAIL") >= 1
        assert one(text, "unbound_answer_rcodes_total", rcode="NXDOMAIN") >= 2
        assert total(text, "unbound_queries_total") >= 5
        assert total(text, "unbound_cache_hits_total") >= 1
        one(text, "unbound_response_time_seconds_count")
        one(text, "unbound_answers_bogus")
        one(text, "unbound_rrset_bogus_total")
        for name in ("unbound_queries_discard_timeout", "unbound_queries_wait_limit", "unbound_request_list_exceeded_total"):
            assert series(text, name), f"no {name}"

    with subtest("AdGuard: queries, blocks, time, and its upstreams by role"):
        print("\n".join(l for l in stats.splitlines() if l.startswith("fleet_adguard")))
        assert one(stats, "fleet_adguard_up") == 1
        assert one(stats, "fleet_adguard_queries_total") >= 9
        assert one(stats, "fleet_adguard_blocked_total") >= 4
        assert one(stats, "fleet_adguard_processing_seconds_total") > 0
        assert one(stats, "fleet_adguard_upstream_responses_total", upstream="primary") >= 1
        assert one(stats, "fleet_adguard_upstream_seconds_total", upstream="primary") > 0
        assert one(stats, "fleet_adguard_upstream_responses_total", upstream="fallback") == 0
        roles = {l["upstream"] for l, _ in series(stats, "fleet_adguard_upstream_responses_total")}
        assert roles == {"primary", "fallback"}, roles

    with subtest("the work segment is counted by Unbound alone, and by no client"):
        before = adguard()
        beforeUnbound = total(scrape("${unbound}"), "unbound_queries_total")
        # Names that reach Unbound, and one that AdGuard blocks.
        dig(work, "work-a.example.net", 5)
        dig(work, "ads.blocked.test", 5)
        after = adguard()
        afterUnbound = total(scrape("${unbound}"), "unbound_queries_total")
        # Not higher: AdGuard's count can only fall, at the top of an hour.
        assert one(after, "fleet_adguard_queries_total") <= one(before, "fleet_adguard_queries_total")
        assert one(after, "fleet_adguard_blocked_total") <= one(before, "fleet_adguard_blocked_total")
        assert afterUnbound >= beforeUnbound + 5, (beforeUnbound, afterUnbound)

    with subtest("no client address and no name in either source"):
        ours = [l for l in adguard().splitlines() if l.startswith("fleet_adguard")]
        for t in (scrape("${unbound}").splitlines(), ours):
            for line in t:
                if line.startswith("#"):
                    continue
                for needle in ("${collector.ip}", "${workIp}", "example", "blocked.test", ".lan"):
                    assert needle not in line, line

    with subtest("core5's probes: each resolver answers, and pings leave"):
        core5.wait_for_unit("prometheus-blackbox-exporter.service")
        before = one(adguard(), "fleet_adguard_queries_total")
        assert probe("resolver", "${resolver.ip}") == 1
        assert probe("ping", "${fallback.ip}") == 1
        # Through the store, under the resolver's name.
        core5.wait_until_succeeds("curl -sf --get http://${store}/api/v1/query --data-urlencode 'query=probe_success{job=\"probe-resolver\",instance=\"core4\"} == 1' | grep -q '\"core4\"'", timeout=60)
        # A failure looks like one: the public resolvers are out of reach here.
        core5.wait_until_succeeds("curl -sf --get http://${store}/api/v1/query --data-urlencode 'query=probe_success{job=\"probe-ping\"} == 0' | grep -q probe-ping", timeout=60)
        # The probes pass through AdGuard without being counted there.
        assert one(adguard(), "fleet_adguard_queries_total") <= before
        # Nor logged, where the queries before them are. AdGuard keeps recent
        # entries in memory, so this asks it rather than reading the file.
        querylog = resolver.succeed("curl -sf -u metrics:${password} 'http://127.0.0.1:${toString net.ports.adguardWeb}/control/querylog?limit=1000'")
        assert "blocked.test" in querylog, "the query log is empty"
        assert "${net.resolverProbe}" not in querylog, "the probe is in the query log"

    with subtest("AdGuard down is fleet_adguard_up 0, with no counters"):
        resolver.succeed("systemctl stop adguardhome.service")
        down = adguard()
        assert one(down, "fleet_adguard_up") == 0
        assert not series(down, "fleet_adguard_queries_total")
        assert probe("resolver", "${resolver.ip}") == 0
        resolver.succeed("systemctl start adguardhome.service")
        resolver.wait_until_succeeds("dig +time=2 +tries=1 @127.0.0.1 example.lan | grep -q 'status: NXDOMAIN'", timeout=60)

    with subtest("Unbound stopped: AdGuard answers from its fallback, and says so"):
        resolver.succeed("systemctl stop unbound.service")
        core5.succeed("dig +time=10 +tries=1 @${resolver.ip} fallback.example.org | grep -q 192.0.2.1")
        stats = adguard()
        assert one(stats, "fleet_adguard_upstream_responses_total", upstream="fallback") >= 1
        # Each failed exchange with Unbound wrote the name to AdGuard's
        # stderr, and journald dropped the line. The rest of AdGuard's log is
        # still there, so the filter is not dropping everything. --sync waits
        # for journald to take in what was written before it.
        resolver.succeed("journalctl --sync")
        failed = resolver.succeed("journalctl -q --no-pager -o cat -u adguardhome -g 'exchange failed' || true")
        assert failed.strip() == "", f"a failed exchange is in the journal:\n{failed}"
        assert "fallback.example.org" not in resolver.succeed("journalctl -q --no-pager -o cat -u adguardhome")
        resolver.succeed("journalctl -q --no-pager -o cat -u adguardhome -g 'dnsproxy: starting dns proxy server' | grep -q .")
        # Stopping Unbound stopped its exporter, which requires it, and
        # starting Unbound again does not start the exporter with it.
        resolver.succeed("systemctl start unbound.service prometheus-unbound-exporter.service")
        assert one(scrape("${unbound}"), "unbound_up") == 1
  '';
}
