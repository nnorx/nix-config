# gate's exit tunnel, end to end in VMs, with trusted in `exitSegments` and
# `exitResolvers` on: a trusted client, and a resolver's port 53, reach the
# internet from the provider's address, while work, another server's port 53
# and a resolver's other traffic leave from `wan`'s; with the provider down,
# the tunnel gone, or a routing rule deleted, the tunneled reach nothing and
# nothing of theirs leaves by `wan`; DoT is refused in the tunnel as out
# `wan`; gate's own traffic and wg0 stay on `wan`; the provider cannot send
# from a house address; and the rules unit reconciles what it finds. gate's
# metrics textfile reports all of it by role, never by address.
# docs/router.md, "Exit tunnel", has the design.
#
# `nix build .#checks.x86_64-linux.gate-exit`. It needs KVM, which forge's
# daemon has; CI's vm-tests job runs it on pull requests.
#
# The provider and a remote wg0 peer sit beyond "the internet", on a wire of
# their own, so gate reaches them by its default route, as it reaches real
# ones. Every key, address and endpoint here is a stand-in, rendered by a
# sops stand-in.
{ net }:
let
  testNet = net // {
    exitSegments = [ "trusted" ];
    exitResolvers = true;
  };
  topology = import ./lib/gate-topology.nix { net = testNet; };
  seg = net.segments;
  gate = net.hosts.gate;
  exit = gate.exitIface;
  inherit (topology) isp;

  farWire = 5;
  far = {
    internet = "198.51.100.1";
    provider = "198.51.100.2";
    remote = "198.51.100.3";
  };
  site = "192.0.2.80";
  house = seg.trusted.pool.first;
  outside = "198.51.100.77";
  providerPort = 51820;
  inner = {
    provider = "10.64.0.1";
    gate = "10.64.12.34";
  };

  keys = {
    gateExit = {
      private = "sBHmjmJRUv2eYuKtgkxVLrmriH+tBs1YfA11kMgZamk=";
      public = "slG4GmS9ck5Av4/keVIgr6vxZs5c1BpinKJP3/5fJk8=";
    };
    provider = {
      private = "SDk9q6wLR8AKasf0nXrECasHV7BhlTUIG5QIM6rolE8=";
      public = "EnHW92gK7+hwEeezHtstAEAqRZ4vIxMgfzOVqWlxL3g=";
    };
    gateWg0 = {
      private = "eOMLIvUgSTsEWIdQiYh0cw8S9/8UDS1AUNs46e0ZdWM=";
      public = "VswbfvZLRoggMZnSY/sM9GRnd3VeR/lbbbiuYxkzMCg=";
    };
    remote = {
      private = "qLSpGGu3tXbPHO/2+f/0FRnajQCgRmAKmF+EvjXx+kU=";
      public = "bbS5DBnEbMjLVwxLGJJUsKeKWGJMJ5szCramGqYXnjg=";
    };
    psk = "mczsLspGy5QeuUoFeczks1LW/jCl0OU6e5QJBra/luw=";
  };

  secrets = {
    exit-private-key = keys.gateExit.private;
    exit-primary-public-key = keys.provider.public;
    exit-primary-endpoint = "${far.provider}:${toString providerPort}";
    exit-address = "${inner.gate}/32";
    wireguard-private-key = keys.gateWg0.private;
    wireguard-psk-forge = keys.psk;
    wireguard-psk-phone = keys.psk;
  };

  # sops-nix, as far as gate's modules use it, with every value known.
  sopsStub =
    { lib, pkgs, ... }:
    let
      inherit (lib) mkOption types;
      file = name: content: toString (pkgs.writeText name content);
    in
    {
      options.sops = {
        placeholder = mkOption { type = types.attrsOf types.str; };
        secrets = mkOption {
          default = { };
          type = types.attrsOf (
            types.submodule (
              { name, ... }:
              {
                freeformType = types.attrsOf types.anything;
                options.path = mkOption { default = file name secrets.${name}; };
              }
            )
          );
        };
        templates = mkOption {
          default = { };
          type = types.attrsOf (
            types.submodule (
              { name, config, ... }:
              {
                freeformType = types.attrsOf types.anything;
                options.content = mkOption { type = types.str; };
                options.path = mkOption { default = file name config.content; };
                options.file = mkOption { default = file name config.content; };
              }
            )
          );
        };
      };
      config.sops.placeholder = secrets;
    };

  onFar = address: {
    virtualisation.interfaces.far.vlan = farWire;
    networking = {
      useDHCP = false;
      firewall.enable = false;
      interfaces.far.ipv4.addresses = [
        {
          inherit address;
          prefixLength = 24;
        }
      ];
      defaultGateway = {
        address = far.internet;
        interface = "far";
      };
    };
  };

  client =
    name:
    { pkgs, ... }:
    {
      imports = [ (topology.onSegment name seg.${name}.pool.first) ];
      environment.systemPackages = [
        pkgs.curl
        pkgs.socat
        (topology.probe pkgs)
      ];
    };

  # Both resolvers' addresses on one VM, and one of the fleet's other servers.
  resolverIps = map (h: net.hosts.${h}.ip) net.resolvers;
  otherServer = builtins.head (
    builtins.filter (
      h:
      !(builtins.elem h net.resolvers)
      && (net.hosts.${h}.segment or null) == net.hosts.${builtins.head net.resolvers}.segment
      && net.hosts.${h} ? ip
    ) (builtins.attrNames net.hosts)
  );

  # `ask udp|tcp host port [source]` sends a line and prints the first line
  # back, "timeout" when nothing comes, or "error" when ICMP refuses it.
  ask =
    pkgs:
    pkgs.writers.writePython3Bin "ask" { } ''
      import socket
      import sys

      proto, host, port = sys.argv[1], sys.argv[2], int(sys.argv[3])
      source = sys.argv[4] if len(sys.argv) > 4 else ""
      udp = proto == "udp"
      kind = socket.SOCK_DGRAM if udp else socket.SOCK_STREAM
      s = socket.socket(socket.AF_INET, kind)
      s.settimeout(5)
      s.bind((source, 0))
      try:
          s.connect((host, port))
          s.send(b"q\n")
          print(s.recv(64).decode().strip())
      except socket.timeout:
          print("timeout")
      except OSError:
          print("error")
    '';

  onServers =
    addresses:
    { pkgs, ... }:
    {
      imports = [ (topology.onServers addresses) ];
      environment.systemPackages = [
        pkgs.curl
        (ask pkgs)
      ];
    };
in
{
  name = "gate-exit";

  node.specialArgs = {
    net = testNet;
    hostname = "gate";
  };

  nodes = {
    gate =
      {
        config,
        lib,
        pkgs,
        ...
      }:
      {
        imports = [
          (topology.router { })
          ../hosts/gate/wireguard.nix
          ../hosts/gate/exit.nix
          ../hosts/gate/metrics.nix
          ../modules/node-exporter.nix
          sopsStub
        ];
        # Kea is off in this topology, so its exporter would only retry.
        services.prometheus.exporters.kea.enable = lib.mkForce false;
        # As modules/baseline.nix sets them.
        boot.kernel.sysctl = {
          "net.ipv4.conf.all.rp_filter" = 1;
          "net.ipv4.conf.default.rp_filter" = 1;
        };
        networking.wireguard.interfaces.${gate.vpnIface}.peers = lib.mkForce [
          {
            name = "forge";
            publicKey = keys.remote.public;
            presharedKeyFile = config.sops.secrets.wireguard-psk-forge.path;
            allowedIPs = [ "${seg.vpn.peers.forge}/32" ];
          }
        ];
        environment.systemPackages = [
          pkgs.curl
          pkgs.wireguard-tools
          (topology.probe pkgs)
          (ask pkgs)
        ];
        # After the firewall's rpfilter chain, at mangle + 10.
        networking.nftables.tables.past-rpfilter = {
          family = "inet";
          content = ''
            counter from-provider {}
            chain prerouting {
              type filter hook prerouting priority filter; policy accept;
              iifname "${exit}" icmp type echo-request counter name "from-provider"
            }
          '';
        };
      };

    # Says who connected: the body is the address it saw. Counts what arrives
    # from gate's `wan` address, which a tunneled client must never send.
    internet =
      { pkgs, ... }:
      let
        whoami = pkgs.writeShellScript "whoami" ''
          while IFS= read -r line; do
            line=''${line%$'\r'}
            [ -z "$line" ] && break
          done
          printf 'HTTP/1.0 200 OK\r\n\r\n%s\n' "$SOCAT_PEERADDR"
        '';
        # Reads the query first: unread input makes socat's read of the
        # answer fail with a reset.
        peer = pkgs.writeShellScript "peer" ''
          read -r _
          printf '%s\n' "$SOCAT_PEERADDR"
        '';
        # Over TCP, one answer per line, so a flow can be held open.
        answers = pkgs.writeShellScript "answers" ''
          while read -r _; do printf '%s\n' "$SOCAT_PEERADDR"; done
        '';
      in
      {
        imports = [
          topology.internet
          (onFar far.internet)
        ];
        networking.defaultGateway = pkgs.lib.mkForce null;
        networking.interfaces.wan.ipv4.addresses = [
          {
            address = site;
            prefixLength = 32;
          }
        ];
        boot.kernel.sysctl."net.ipv4.conf.all.forwarding" = true;
        systemd.services.listen-80 = {
          wantedBy = [ "multi-user.target" ];
          script = "${pkgs.socat}/bin/socat TCP-LISTEN:80,fork,reuseaddr EXEC:${whoami}";
        };
        systemd.services.listen-9000 = {
          wantedBy = [ "multi-user.target" ];
          script = "${pkgs.socat}/bin/socat -u TCP-LISTEN:9000,fork,reuseaddr OPEN:/dev/null";
        };
        systemd.services.listen-853 = {
          wantedBy = [ "multi-user.target" ];
          script = "${pkgs.socat}/bin/socat TCP-LISTEN:853,fork,reuseaddr EXEC:${pkgs.coreutils}/bin/true";
        };
        systemd.services.listen-53-udp = {
          wantedBy = [ "multi-user.target" ];
          # Bound, so answers come from the address asked; it may not be up yet.
          script = "${pkgs.socat}/bin/socat UDP-RECVFROM:53,bind=${site},fork EXEC:${peer}";
          serviceConfig.Restart = "on-failure";
          serviceConfig.RestartSec = 1;
        };
        systemd.services.listen-53-tcp = {
          wantedBy = [ "multi-user.target" ];
          script = "${pkgs.socat}/bin/socat TCP-LISTEN:53,fork,reuseaddr EXEC:${answers}";
        };
        networking.nftables = {
          enable = true;
          tables.seen = {
            family = "ip";
            content = ''
              counter tcp-from-wan {}
              counter udp-from-wan {}
              counter dns-from-wan {}
              chain input {
                type filter hook input priority filter; policy accept;
                ip saddr ${isp.gate} tcp dport { 80, 853 } counter name "tcp-from-wan"
                ip saddr ${isp.gate} udp dport { 53, 123 } counter name "udp-from-wan"
                ip saddr ${isp.gate} meta l4proto { tcp, udp } th dport 53 counter name "dns-from-wan"
              }
            '';
          };
        };
      };

    provider =
      { pkgs, ... }:
      {
        imports = [ (onFar far.provider) ];
        networking.wireguard.interfaces.wg-provider = {
          ips = [ "${inner.provider}/32" ];
          listenPort = providerPort;
          privateKeyFile = toString (pkgs.writeText "provider-key" keys.provider.private);
          peers = [
            {
              publicKey = keys.gateExit.public;
              allowedIPs = [ "${inner.gate}/32" ];
            }
          ];
        };
        networking.nat = {
          enable = true;
          externalInterface = "far";
          internalInterfaces = [ "wg-provider" ];
        };
      };

    # A tunnel peer away from home, holding forge's address and so its grants.
    remote =
      { pkgs, ... }:
      {
        imports = [ (onFar far.remote) ];
        environment.systemPackages = [ pkgs.wireguard-tools ];
        networking.wireguard.interfaces.wg-home = {
          ips = [ "${seg.vpn.peers.forge}/${toString seg.vpn.prefixLength}" ];
          privateKeyFile = toString (pkgs.writeText "remote-key" keys.remote.private);
          peers = [
            {
              publicKey = keys.gateWg0.public;
              presharedKeyFile = toString (pkgs.writeText "psk" keys.psk);
              endpoint = "${isp.gate}:${toString net.ports.wireguard}";
              allowedIPs = [ seg.vpn.subnet ];
            }
          ];
        };
      };

    trusted = client "trusted";
    work = client "work";
    resolver = onServers resolverIps;
    server = onServers [ net.hosts.${otherServer}.ip ];
  };

  testScript = ''
    import json
    import re
    import time

    start_all()

    internet.wait_for_open_port(80)
    internet.wait_for_open_port(853)
    internet.wait_for_open_port(9000)
    internet.wait_for_open_port(53)
    internet.wait_until_succeeds("ss -Hlun '( sport = :53 )' | grep -q .", timeout=30)
    provider.wait_for_unit("wireguard-wg-provider.service")
    gate.wait_for_unit("nftables.service")
    gate.wait_for_unit("exit-tunnel.service")
    for m in [gate, internet, provider, remote, trusted, work, resolver, server]:
        m.wait_for_unit("network.target")
    trusted.wait_until_succeeds("ping -c1 -W1 ${seg.trusted.gateway}", timeout=60)
    work.wait_until_succeeds("ping -c1 -W1 ${seg.work.gateway}", timeout=60)

    print(gate.succeed("ip rule; ip route show table ${net.exitTable.name}; nft list ruleset"))

    def counter(machine, table, name):
        out = json.loads(machine.succeed(f"nft -j list counter {table} {name}"))
        return next(o["counter"]["packets"] for o in out["nftables"] if "counter" in o)

    def leaked():
        return counter(gate, "inet nixos-fw", "exit-leak-dropped")

    def from_wan():
        return counter(internet, "ip seen", "tcp-from-wan")

    def dns_from_wan():
        return counter(internet, "ip seen", "dns-from-wan")

    def ask(machine, proto, source=""):
        return machine.succeed(f"ask {proto} ${site} 53 {source}").strip()

    resolvers = [${builtins.concatStringsSep ", " (map (ip: "\"${ip}\"") resolverIps)}]
    mark_rule = f"1200:\tfrom all fwmark {hex(${toString net.exitMark})} lookup ${net.exitTable.name}"

    fetch = "curl -sS -m 5 http://${site}/"

    def seen(client):
        return client.succeed(fetch).strip()

    def metrics():
        # Called many times in a row, past the unit's start limit otherwise.
        gate.succeed("systemctl reset-failed gate-metrics-facts.service; systemctl start gate-metrics-facts.service")
        return gate.succeed("cat /run/fleet-metrics/gate.prom")

    def one(text, name, **want):
        hits = []
        for line in text.splitlines():
            m = re.match(r"^([a-zA-Z_:][a-zA-Z0-9_:]*)(?:\{(.*)\})? (\S+)$", line)
            if m and m.group(1) == name:
                labels = dict(re.findall(r'(\w+)="([^"]*)"', m.group(2) or ""))
                if all(labels.get(k) == w for k, w in want.items()):
                    hits.append(float(m.group(3)))
        assert len(hits) == 1, f"{name} {want}: {hits}"
        return hits[0]

    def roles(text):
        return {r: one(text, "fleet_exit_server", role=r) for r in ("primary", "failover1", "failover2")}

    def bypasses(text):
        return {s: one(text, "fleet_exit_bypass_open", segment=s) for s in ("trusted", "resolvers")}

    # Every stand-in that would say whom gate reaches, and which account.
    identifying = ["${far.provider}", "${inner.gate}", "${inner.provider}", "${keys.provider.public}", "${keys.gateExit.public}"]

    def anonymous(text):
        for s in identifying:
            assert s not in text, [l for l in text.splitlines() if s in l]

    with subtest("the rules: main without its default, then trusted and the mark into the exit table"):
        rules = gate.succeed("ip rule show")
        assert "1000:\tfrom all lookup main suppress_prefixlength 0" in rules, rules
        assert "1100:\tfrom all iif br-trusted lookup ${net.exitTable.name}" in rules, rules
        assert mark_rule in rules, rules
        routes = gate.succeed("ip route show table ${net.exitTable.name}")
        assert "default dev ${exit}" in routes, routes
        assert "unreachable default metric 100" in routes, routes

    with subtest("a trusted client leaves through the provider"):
        trusted.wait_until_succeeds(f"{fetch} | grep -qx ${far.provider}", timeout=60)
        assert seen(trusted) == "${far.provider}"

    with subtest("the textfile reports the tunnel up, by role and never by address"):
        text = metrics()
        print(text)
        now = int(gate.succeed("date +%s"))
        handshake = one(text, "fleet_exit_last_handshake_timestamp_seconds")
        assert now - 180 < handshake <= now, f"handshake {handshake}, now {now}"
        assert one(text, "fleet_exit_receive_bytes_total") > 0
        assert one(text, "fleet_exit_transmit_bytes_total") > 0
        assert roles(text) == {"primary": 1, "failover1": 0, "failover2": 0}, roles(text)
        assert bypasses(text) == {"trusted": 0, "resolvers": 0}, bypasses(text)
        assert one(text, "fleet_exit_leak_dropped_packets_total") <= leaked()
        one(text, "fleet_exit_leak_dropped_bytes_total")
        anonymous(text)

    with subtest("the textfile follows the watchdog's and exit-bypass's state, and echoes neither"):
        gate.succeed("mkdir -p /run/exit-tunnel /run/exit-bypass")
        gate.succeed("echo failover1 > /run/exit-tunnel/server; touch /run/exit-bypass/trusted /run/exit-bypass/${far.provider}")
        text = metrics()
        assert roles(text) == {"primary": 0, "failover1": 1, "failover2": 0}, roles(text)
        assert bypasses(text) == {"trusted": 1, "resolvers": 0}, bypasses(text)
        anonymous(text)
        gate.succeed("echo ${far.provider}:${toString providerPort} > /run/exit-tunnel/server")
        text = metrics()
        assert roles(text) == {"primary": 0, "failover1": 0, "failover2": 0}, roles(text)
        anonymous(text)
        gate.succeed(": > /run/exit-tunnel/server")
        assert roles(metrics()) == {"primary": 0, "failover1": 0, "failover2": 0}
        gate.succeed("rm -r /run/exit-tunnel /run/exit-bypass")
        assert roles(metrics())["primary"] == 1

    with subtest("a work client leaves by wan"):
        assert seen(work) == "${isp.gate}"

    with subtest("each resolver's port 53 leaves through the provider, by UDP and TCP"):
        for ip in resolvers:
            resolver.wait_until_succeeds(f"ask udp ${site} 53 {ip} | grep -qx ${far.provider}", timeout=60)
            assert ask(resolver, "tcp", ip) == "${far.provider}"

    with subtest("a resolver's other traffic, and another server's port 53, leave by wan"):
        assert seen(resolver) == "${isp.gate}"
        assert ask(server, "udp") == "${isp.gate}"
        assert ask(server, "tcp") == "${isp.gate}"

    with subtest("gate reaches the internet through the exit when bound to it"):
        assert gate.succeed("curl -sS -m 5 --interface ${exit} http://${site}/").strip() == "${far.provider}"

    with subtest("from the provider, a house source is dropped by reverse-path, another passes"):
        provider.succeed("ip addr add ${house}/32 dev lo; ip addr add ${outside}/32 dev lo")
        def from_provider():
            return counter(gate, "inet past-rpfilter", "from-provider")
        before = from_provider()
        provider.execute("ping -c1 -W1 -I ${outside} ${inner.gate}")
        assert from_provider() == before + 1, "the control ping never reached gate"
        provider.execute("ping -c1 -W1 -I ${house} ${inner.gate}")
        assert from_provider() == before + 1, "a house-sourced packet passed reverse-path filtering"

    with subtest("DoT is refused in the tunnel, as out wan"):
        assert trusted.succeed("probe ${site} 853").strip() == "refused"
        assert work.succeed("probe ${site} 853").strip() == "refused"

    with subtest("gate's own NTP and DNS leave by wan"):
        before = counter(internet, "ip seen", "udp-from-wan")
        gate.succeed("probe udp ${site} 123")
        assert ask(gate, "udp") == "${isp.gate}"
        assert ask(gate, "tcp") == "${isp.gate}"
        assert counter(internet, "ip seen", "udp-from-wan") >= before + 2

    with subtest("a peer dialing wg0 on wan still handshakes"):
        remote.wait_until_succeeds("ping -c1 -W1 ${seg.vpn.gateway}", timeout=60)
        handshake = remote.succeed("wg show wg-home latest-handshakes").split()[1]
        assert int(handshake) > 0, handshake

    with subtest("the provider down: trusted and the resolvers time out, and nothing leaves by wan"):
        provider.succeed("systemctl stop wireguard-wg-provider.service")
        wan_before, dns_before = from_wan(), dns_from_wan()
        trusted.fail(fetch)
        assert from_wan() == wan_before, "trusted left by wan"
        for ip in resolvers:
            assert ask(resolver, "udp", ip) == "timeout"
        assert ask(resolver, "tcp", resolvers[0]) == "timeout"
        assert dns_from_wan() == dns_before, "a resolver's port 53 left by wan"
        assert seen(work) == "${isp.gate}"
        assert ask(server, "udp") == "${isp.gate}"
        provider.succeed("systemctl start wireguard-wg-provider.service")
        trusted.wait_until_succeeds(f"{fetch} | grep -qx ${far.provider}", timeout=90)
        resolver.wait_until_succeeds(f"ask udp ${site} 53 {resolvers[0]} | grep -qx ${far.provider}", timeout=90)

    with subtest("the tunnel gone: unreachable, not wan"):
        gate.succeed("systemctl stop exit-tunnel.service")
        before, wan_before, dns_before = leaked(), from_wan(), dns_from_wan()
        trusted.fail(fetch)
        assert from_wan() == wan_before, "trusted left by wan"
        assert ask(resolver, "udp", resolvers[0]) in ("timeout", "error")
        assert dns_from_wan() == dns_before, "a resolver's port 53 left by wan"
        assert leaked() == before, "the unreachable route let a packet through to forward"
        text = metrics()
        assert one(text, "fleet_exit_last_handshake_timestamp_seconds") == 0
        assert one(text, "fleet_exit_receive_bytes_total") == 0
        gate.succeed("systemctl start exit-tunnel.service")
        trusted.wait_until_succeeds(f"{fetch} | grep -qx ${far.provider}", timeout=90)

    with subtest("the routing rule gone: the leak drop catches trusted, and counts it"):
        # A flow held open too: netfilter ends a masqueraded flow whose way out
        # changes, so its next packets reach forward-allow's leak drop as new.
        trusted.succeed(
            "systemd-run --unit=hold -p Environment=PATH=/run/current-system/sw/bin "
            "sh -c 'while :; do echo x; sleep 0.2; done | socat -u STDIN TCP:${site}:9000'"
        )
        internet.wait_until_succeeds("ss -Htn state established '( sport = :9000 )' | grep -q .", timeout=30)
        gate.succeed("ip rule del priority 1100 iif br-trusted")
        held = leaked()
        for _ in range(30):
            if leaked() > held:
                break
            time.sleep(0.5)
        else:
            raise AssertionError("the established flow was not counted by the leak drop")
        trusted.succeed("systemctl stop hold")
        before, wan_before = leaked(), from_wan()
        trusted.fail(fetch)
        assert from_wan() == wan_before, "trusted left by wan"
        assert leaked() > before, "exit-leak-dropped did not rise"
        text = metrics()
        # Retransmits may still be dropped after the snapshot.
        assert before < one(text, "fleet_exit_leak_dropped_packets_total") <= leaked()
        assert one(text, "fleet_exit_leak_dropped_bytes_total") > 0
        anonymous(text)

    with subtest("the mark's rule gone: the leak drop catches the resolvers, and counts them"):
        # A query held open too, as for trusted above.
        resolver.succeed(
            "systemd-run --unit=hold -p Environment=PATH=/run/current-system/sw/bin "
            f"sh -c 'while :; do echo x; sleep 0.2; done | socat -u STDIN TCP:${site}:53,bind={resolvers[0]}'"
        )
        internet.wait_until_succeeds("ss -Htn state established '( sport = :53 )' | grep -q .", timeout=30)
        dns_before = dns_from_wan()
        gate.succeed("ip rule del priority 1200")
        held = leaked()
        for _ in range(30):
            if leaked() > held:
                break
            time.sleep(0.5)
        else:
            raise AssertionError("the resolver's established flow was not counted by the leak drop")
        resolver.succeed("systemctl stop hold")
        assert dns_from_wan() == dns_before, "the resolver's held flow left by wan"
        before = leaked()
        assert ask(resolver, "udp", resolvers[0]) == "timeout"
        assert ask(resolver, "tcp", resolvers[0]) == "timeout"
        assert dns_from_wan() == dns_before, "a resolver's port 53 left by wan"
        assert leaked() > before, "exit-leak-dropped did not rise"
        gate.succeed("systemctl restart exit-routing.service")
        resolver.wait_until_succeeds(f"ask udp ${site} 53 {resolvers[0]} | grep -qx ${far.provider}", timeout=60)

    with subtest("the rules unit restores what is listed, drops the rest, and adds no duplicate"):
        gate.succeed("ip rule add priority 1100 iif ${gate.trunkIface}.${toString seg.work.id} table ${toString net.exitTable.id}")
        # Strays into other tables, and the suppress rule gone beside one.
        gate.succeed("ip rule add priority 1100 iif lo table main")
        gate.succeed("ip rule del priority 1000 lookup main suppress_prefixlength 0")
        gate.succeed("ip rule add priority 1000 iif lo table main")
        # Beside the mark's: another mark, and near misses of the right one.
        gate.succeed("ip rule add priority 1200 fwmark ${toString (net.exitMark + 1)} table main")
        gate.succeed("ip rule add priority 1200 iif lo fwmark ${toString net.exitMark} table ${toString net.exitTable.id}")
        gate.succeed("ip rule add priority 1200 not fwmark ${toString net.exitMark} table ${toString net.exitTable.id}")
        gate.succeed("ip rule add priority 1200 fwmark ${toString net.exitMark}/0xff table ${toString net.exitTable.id}")
        gate.succeed("systemctl restart exit-routing.service")
        gate.succeed("systemctl restart exit-routing.service")
        # Right as it stands, so a restart leaves it untouched.
        rewrites = "journalctl -u exit-routing.service -o cat | grep -c 'rewriting the rules at 1200'"
        n = gate.succeed(rewrites).strip()
        gate.succeed("systemctl restart exit-routing.service")
        assert gate.succeed(rewrites).strip() == n, "exit-routing rewrote a rule that was right"
        assert "lookup main suppress_prefixlength 0" in gate.succeed("ip rule show priority 1000")
        gate.succeed("ip rule del priority 1000 iif lo table main")
        assert gate.succeed("ip rule show priority 1000").count("\n") == 1
        rules = gate.succeed("ip rule show priority 1100")
        assert rules.strip() == "1100:\tfrom all iif br-trusted lookup ${net.exitTable.name}", rules
        rules = gate.succeed("ip rule show priority 1200")
        assert rules.strip() == mark_rule, rules
        assert seen(trusted) == "${far.provider}"
        assert ask(resolver, "udp", resolvers[0]) == "${far.provider}"
        assert seen(work) == "${isp.gate}"
  '';
}
