# gate's exit tunnel, end to end in VMs, with trusted in `exitSegments` and
# `exitResolvers` on: a trusted client, and a resolver's port 53, reach the
# internet from the provider's address, while work, another server's port 53
# and a resolver's other traffic leave from `wan`'s; with the provider down,
# the tunnel gone, or a routing rule deleted, the tunneled reach nothing and
# nothing of theirs leaves by `wan`; DoT is refused in the tunnel as out
# `wan`; gate's own traffic and wg0 stay on `wan`; the provider cannot send
# from a house address; the rules unit reconciles what it finds; with the
# provider's server gone, the watchdog moves gate to a second, and with every
# one gone it stays closed; and exit-bypass lets trusted, or the resolvers,
# out `wan` while the provider is down, until it expires or is closed, with a
# push each way. gate's metrics textfile reports all of it by role, never by
# address. docs/router.md, "Exit tunnel", has the design.
#
# `nix build .#checks.x86_64-linux.gate-exit`. It needs KVM, which forge's
# daemon has; CI's vm-tests job runs it on pull requests.
#
# Two provider servers and a remote wg0 peer sit beyond "the internet", on
# a wire of their own, so gate reaches them by its default route, as it
# reaches real ones. Every key, address and endpoint here is a stand-in,
# rendered by a sops stand-in.
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
    failover = "198.51.100.4";
    # failover2's endpoint, where nothing answers.
    nobody = "198.51.100.5";
  };
  site = "192.0.2.80";
  house = seg.trusted.pool.first;
  outside = "198.51.100.77";
  providerPort = 51820;
  ntfyPort = 8080;
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
    failover = {
      private = "wLT+tdAwTBC0eWeCNsdD1LKLnhlMZdhCbefq7V5EQ3g=";
      public = "V2YXIV3LigLMZwl4waOCcJjbbPYZGEl7ec59o9PmoFg=";
    };
    nobody.public = "+/o1u/fP9mttAVL7EEswwjwDtvmEkvHPbhysPDa0riI=";
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
    exit-failover1-public-key = keys.failover.public;
    exit-failover1-endpoint = "${far.failover}:${toString providerPort}";
    exit-failover2-public-key = keys.nobody.public;
    exit-failover2-endpoint = "${far.nobody}:${toString providerPort}";
    exit-address = "${inner.gate}/32";
    wireguard-private-key = keys.gateWg0.private;
    wireguard-psk-forge = keys.psk;
    wireguard-psk-phone = keys.psk;
    ntfy-url = "http://${site}:${toString ntfyPort}/exit-bypass";
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

  # A provider server. Both take gate's one key and inner address, as a real
  # provider's servers take the account's.
  server =
    address: key:
    { pkgs, ... }:
    {
      imports = [ (onFar address) ];
      networking.wireguard.interfaces.wg-provider = {
        ips = [ "${inner.provider}/32" ];
        listenPort = providerPort;
        privateKeyFile = toString (pkgs.writeText "provider-key" key);
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
        pkgs.socat
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
        # ntfy, as far as exit-bypass uses it: a line per push, saying where
        # it came from. Reads the body, for the reason given at `peer`.
        ntfy = pkgs.writeShellScript "ntfy" ''
          len=0
          while IFS= read -r line; do
            line=''${line%$'\r'}
            [ -z "$line" ] && break
            case $line in
              Title:*) title=''${line#Title: } ;;
              Content-Length:*) len=''${line#Content-Length: } ;;
            esac
          done
          body=$(head -c "$len")
          printf '%s|%s|%s\n' "$SOCAT_PEERADDR" "$title" "$body" >>/run/pushes
          printf 'HTTP/1.0 200 OK\r\nContent-Length: 0\r\n\r\n'
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
        systemd.services.listen-ntfy = {
          wantedBy = [ "multi-user.target" ];
          script = "${pkgs.socat}/bin/socat TCP-LISTEN:${toString ntfyPort},fork,reuseaddr EXEC:${ntfy}";
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

    provider = server far.provider keys.provider.private;
    failover = server far.failover keys.failover.private;

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
    for p in [provider, failover]:
        p.wait_for_unit("wireguard-wg-provider.service")
    gate.wait_for_unit("nftables.service")
    gate.wait_for_unit("exit-tunnel.service")
    for m in [gate, internet, provider, failover, remote, trusted, work, resolver, server]:
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
    identifying = ["${far.provider}", "${far.failover}", "${far.nobody}", "${keys.failover.public}", "${keys.nobody.public}", "${inner.gate}", "${inner.provider}", "${keys.provider.public}", "${keys.gateExit.public}"]

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

    def exit_role():
        return gate.succeed("cat /run/exit-tunnel/server").strip()

    with subtest("the watchdog names the primary, in a file node_exporter's user can read"):
        assert exit_role() == "primary"
        assert gate.succeed("stat -c %a /run/exit-tunnel /run/exit-tunnel/server").split() == ["755", "644"]

    with subtest("the textfile follows the watchdog's and exit-bypass's state, and echoes neither"):
        gate.succeed("mkdir -p /run/exit-bypass")
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
        gate.succeed("rm -r /run/exit-tunnel/server /run/exit-bypass")
        assert roles(metrics())["primary"] == 1
        # Restarted alone, it finds the server in use by its key.
        gate.succeed("systemctl restart exit-watchdog.service")
        gate.wait_until_succeeds("grep -qx primary /run/exit-tunnel/server", timeout=30)

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

    def pushes():
        # Where each came from, its title and its body.
        return [p.split("|") for p in internet.succeed("cat /run/pushes 2>/dev/null || true").splitlines()]

    def bypass_rules():
        return gate.succeed("ip rule show priority 1050").strip()

    with subtest("exit-bypass refuses a name outside the list, and a duration that is not one"):
        for args in ["work", "servers", "vpn", "close work", "trusted forever", "trusted 0", "trusted infinity", "trusted 25h"]:
            gate.fail(f"exit-bypass {args}")
        assert "not one of" in gate.fail("exit-bypass work 2>&1")
        assert bypass_rules() == ""
        assert pushes() == []
        assert gate.succeed("exit-bypass status") == "resolvers: closed\ntrusted: closed\n"

    with subtest("exit-bypass, every server down: trusted leaves by wan, through a ruleset reload and restart, until it expires"):
        # An outage is every server down, or the watchdog would move to one up.
        for m in [provider, failover]:
            m.succeed("systemctl stop wireguard-wg-provider.service")
        trusted.fail(fetch)
        print(gate.succeed("exit-bypass trusted 2min"))
        before = leaked()
        assert seen(trusted) == "${isp.gate}"
        assert leaked() == before, "the leak drop counted a bypassed segment"
        assert bypass_rules() == "1050:\tfrom all iif br-trusted lookup main", bypass_rules()
        status = gate.succeed("exit-bypass status")
        assert re.search(r"^trusted: open until .*, [12] min left$", status, re.M), status
        assert bypasses(metrics()) == {"trusted": 1, "resolvers": 0}
        assert [p[:2] for p in pushes()] == [["${isp.gate}", "gate: exit bypass open for trusted"]], pushes()
        assert "already open" in gate.fail("exit-bypass trusted 2>&1")
        # Trusted's bypass lets out trusted alone.
        assert ask(resolver, "udp", resolvers[0]) == "timeout"
        assert "not one of" in gate.fail("exit-bypass close ../exit-tunnel 2>&1")
        # A reload, or a restart, empties the set while the rule stays; the
        # bypass comes back whole after each.
        gate.succeed("systemctl reload nftables.service")
        gate.succeed("systemctl restart nftables.service")
        assert gate.succeed("journalctl -u nftables.service -o cat").count("trusted kept open") == 2
        assert seen(trusted) == "${isp.gate}"
        assert ask(resolver, "udp", resolvers[0]) == "timeout"
        assert "missing" not in gate.succeed("exit-bypass status")
        gate.wait_until_fails("test -e /run/exit-bypass/trusted", timeout=180)
        wan_before = from_wan()
        trusted.fail(fetch)
        assert from_wan() == wan_before, "trusted left by wan after its bypass expired"
        assert bypass_rules() == ""
        assert "trusted: closed" in gate.succeed("exit-bypass status")
        assert bypasses(metrics()) == {"trusted": 0, "resolvers": 0}
        p = pushes()
        assert len(p) == 2 and p[1][:2] == ["${isp.gate}", "gate: exit bypass closed for trusted"], p
        assert "time ran out" in p[1][2], p

    with subtest("exit-bypass resolvers, every server down: their port 53 leaves by wan until it is closed"):
        assert ask(resolver, "udp", resolvers[0]) == "timeout"
        gate.succeed("exit-bypass resolvers 10min")
        before, dns_before = leaked(), dns_from_wan()
        for ip in resolvers:
            assert ask(resolver, "udp", ip) == "${isp.gate}"
        assert ask(resolver, "tcp", resolvers[0]) == "${isp.gate}"
        assert dns_from_wan() > dns_before
        assert leaked() == before, "the leak drop counted the bypassed resolvers"
        assert bypasses(metrics()) == {"trusted": 0, "resolvers": 1}
        trusted.fail(fetch)
        gate.succeed("exit-bypass close resolvers")
        dns_before = dns_from_wan()
        assert ask(resolver, "udp", resolvers[0]) == "timeout"
        assert ask(resolver, "tcp", resolvers[0]) == "timeout"
        assert dns_from_wan() == dns_before, "a resolver's port 53 left by wan after its bypass closed"
        assert bypass_rules() == ""
        gate.fail("systemctl is-active exit-bypass-expire-resolvers.timer")
        assert bypasses(metrics()) == {"trusted": 0, "resolvers": 0}
        p = pushes()[2:]
        assert [x[:2] for x in p] == [["${isp.gate}", "gate: exit bypass open for resolvers"], ["${isp.gate}", "gate: exit bypass closed for resolvers"]], p
        assert "closed by hand" in p[1][2], p
        for m in [provider, failover]:
            m.succeed("systemctl start wireguard-wg-provider.service")
        # Back to the primary, wherever the watchdog went meanwhile.
        gate.succeed("systemctl restart exit-tunnel.service")
        gate.wait_until_succeeds("grep -qx primary /run/exit-tunnel/server", timeout=30)
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
        # Beside the mark's: another mark, and the right one limited to lo.
        gate.succeed("ip rule add priority 1200 fwmark ${toString (net.exitMark + 1)} table main")
        gate.succeed("ip rule add priority 1200 iif lo fwmark ${toString net.exitMark} table ${toString net.exitTable.id}")
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

    with subtest("a near miss alone at the mark's priority is rewritten"):
        for miss in ["not fwmark ${toString net.exitMark}", "fwmark ${toString net.exitMark}/0xff", f"from {resolvers[0]} fwmark ${toString net.exitMark}"]:
            gate.succeed("ip rule del priority 1200")
            gate.succeed(f"ip rule add priority 1200 {miss} table ${toString net.exitTable.id}")
            # Many restarts in a row would hit the unit's start limit.
            gate.succeed("systemctl reset-failed exit-routing.service; systemctl restart exit-routing.service")
            rules = gate.succeed("ip rule show priority 1200")
            assert rules.strip() == mark_rule, f"{miss}: {rules}"
        assert ask(resolver, "udp", resolvers[0]) == "${far.provider}"

    # The watchdog at its production 180 s: WireGuard rekeys a live peer only
    # every two minutes, so a live server's handshake is often over 120 s old,
    # and a lower threshold would leave the live one too.
    def watchdog_log():
        log = gate.succeed("journalctl -u exit-watchdog.service -o cat")
        anonymous(log)
        return log

    with subtest("the primary down: failover1 within four minutes, and nothing by wan meanwhile"):
        provider.succeed("systemctl stop wireguard-wg-provider.service")
        wan_before = from_wan()
        trusted.wait_until_succeeds(f"{fetch} | grep -qx ${far.failover}", timeout=240)
        assert from_wan() == wan_before, "trusted left by wan"
        assert exit_role() == "failover1"
        assert "no handshake from primary in 180 s, switched to failover1" in watchdog_log()
        text = metrics()
        assert roles(text) == {"primary": 0, "failover1": 1, "failover2": 0}, roles(text)
        anonymous(text)

    with subtest("the primary back: failover1 holds until the tunnel restarts"):
        provider.succeed("systemctl start wireguard-wg-provider.service")
        time.sleep(25)
        assert exit_role() == "failover1"
        assert seen(trusted) == "${far.failover}"
        # Restarted alone, it names the server in use by its key, off the primary.
        gate.succeed("rm /run/exit-tunnel/server; systemctl restart exit-watchdog.service")
        gate.wait_until_succeeds("test -s /run/exit-tunnel/server", timeout=30)
        assert exit_role() == "failover1"
        assert seen(trusted) == "${far.failover}"
        gate.succeed("systemctl restart exit-tunnel.service")
        gate.wait_until_succeeds("grep -qx primary /run/exit-tunnel/server", timeout=30)
        trusted.wait_until_succeeds(f"{fetch} | grep -qx ${far.provider}", timeout=60)

    with subtest("both down: closed, nothing by wan, and the watchdog moves on past each"):
        provider.succeed("systemctl stop wireguard-wg-provider.service")
        failover.succeed("systemctl stop wireguard-wg-provider.service")
        wan_before = from_wan()
        for role in ("failover1", "failover2"):
            gate.wait_until_succeeds(f"grep -qx {role} /run/exit-tunnel/server", timeout=240)
            trusted.fail(fetch)
        assert from_wan() == wan_before, "trusted left by wan"
        assert "no handshake from failover1 in 180 s, switched to failover2" in watchdog_log()

    with subtest("restarting the tunnel returns it to the primary"):
        provider.succeed("systemctl start wireguard-wg-provider.service")
        failover.succeed("systemctl start wireguard-wg-provider.service")
        gate.succeed("systemctl restart exit-tunnel.service")
        gate.wait_until_succeeds("grep -qx primary /run/exit-tunnel/server", timeout=30)
        trusted.wait_until_succeeds(f"{fetch} | grep -qx ${far.provider}", timeout=60)
        assert roles(metrics())["primary"] == 1

    with subtest("by hand, with the watchdog stopped, one switch to a named role"):
        gate.succeed("systemctl stop exit-watchdog.service")
        out = gate.succeed("exit-watchdog failover1")
        assert out.strip() == "switched to failover1", out
        assert exit_role() == "failover1"
        # syncconf leaves the new server alone, the old one dropped.
        peers = gate.succeed("wg show ${net.hosts.gate.exitIface} peers").split()
        assert peers == ["${keys.failover.public}"], len(peers)
        trusted.wait_until_succeeds(f"{fetch} | grep -qx ${far.failover}", timeout=60)
        gate.fail("exit-watchdog nowhere")
        assert exit_role() == "failover1"
        gate.succeed("systemctl restart exit-tunnel.service")
        gate.wait_until_succeeds("grep -qx primary /run/exit-tunnel/server", timeout=30)
        gate.succeed("systemctl is-active exit-watchdog.service")
        trusted.wait_until_succeeds(f"{fetch} | grep -qx ${far.provider}", timeout=60)
  '';
}
