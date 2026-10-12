# Probes from the collector, for what no exporter on the probed host can say
# about itself: whether each resolver answers a client on port 53, and whether
# the public resolvers answer a ping, which is traffic leaving the house
# through gate. Imported by modules/metrics.nix, whose store scrapes the jobs
# below. docs/observability.md has the design and the queries.
#
# The exporter listens on loopback alone: only VictoriaMetrics, on the same
# host, asks it to probe anything, so nothing on the LAN can point it
# elsewhere.
{ net, ... }:
let
  address = "127.0.0.1:${toString net.ports.blackboxExporter}";

  # JSON is YAML, which is what the exporter reads.
  config = builtins.toJSON {
    modules = {
      # The name in lib/net.nix, which Unbound answers NXDOMAIN from its own
      # `lan` zone. Anything else is a failure: SERVFAIL, a refusal, an
      # answer, or nothing within the timeout. AdGuard's fallback answers it
      # too, NXDOMAIN, when Unbound is down, and that counts as answering,
      # since clients are answered the same way; unbound_up and the fallback's
      # share say which path did it. Over UDP, as clients mostly ask.
      resolver = {
        prober = "dns";
        timeout = "5s";
        dns = {
          transport_protocol = "udp";
          preferred_ip_protocol = "ip4";
          ip_protocol_fallback = false;
          query_name = net.resolverProbe;
          query_type = "A";
          valid_rcodes = [ "NXDOMAIN" ];
        };
      };

      # An echo request. The exporter tries an unprivileged ICMP socket first,
      # which NixOS's default net.ipv4.ping_group_range allows, so it needs
      # no capability, which nixpkgs' sandbox for it would drop anyway.
      ping = {
        prober = "icmp";
        timeout = "5s";
        icmp = {
          preferred_ip_protocol = "ip4";
          ip_protocol_fallback = false;
        };
      };
    };
  };

  # The exporter's /probe, with the target and module as parameters. Each
  # target keeps the `instance` it is given, the resolver's name or the public
  # resolver's address, rather than the exporter's own.
  probes = module: targets: {
    job_name = "probe-${module}";
    metrics_path = "/probe";
    params.module = [ module ];
    static_configs = map (t: {
      targets = [ t.target ];
      labels.instance = t.instance;
    }) targets;
    relabel_configs = [
      {
        source_labels = [ "__address__" ];
        target_label = "__param_target";
      }
      {
        target_label = "__address__";
        replacement = address;
      }
    ];
  };
in
{
  services.prometheus.exporters.blackbox = {
    enable = true;
    listenAddress = "127.0.0.1";
    port = net.ports.blackboxExporter;
    configFile = builtins.toFile "blackbox.yml" config;
  };

  services.victoriametrics.prometheusConfig.scrape_configs = [
    # Each resolver through AdGuard, at its address on port 53, as a client
    # on servers asks it. The resolvers open 53 on their LAN interface to
    # everyone, so this needs no rule of its own.
    (probes "resolver" (
      map (name: {
        target = net.hosts.${name}.ip;
        instance = name;
      }) net.resolvers
    ))
    # The two public resolvers, by address, which needs no lookup. What
    # leaves the house is an echo request to each every 30 seconds, from the
    # WAN address, as any ping would.
    (probes "ping" (
      map (ip: {
        target = ip;
        instance = ip;
      }) net.publicResolvers
    ))
  ];
}
