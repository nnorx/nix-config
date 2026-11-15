# gate's exit tunnel, end to end in VMs, with trusted in `exitSegments`: a
# trusted client reaches the internet from the provider's address and work
# from `wan`'s; with the provider down, the tunnel gone, or the routing rule
# deleted, trusted reaches nothing and nothing of it leaves by `wan`; DoT is
# refused in the tunnel as out `wan`; gate's own traffic and wg0 stay on
# `wan`; and the rules unit reconciles what it finds. docs/router.md, "Exit
# tunnel", has the design.
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
        (topology.probe pkgs)
      ];
    };
in
{
  name = "gate-exit";

  node.specialArgs.net = testNet;

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
          sopsStub
        ];
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
        ];
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
        systemd.services.listen-853 = {
          wantedBy = [ "multi-user.target" ];
          script = "${pkgs.socat}/bin/socat TCP-LISTEN:853,fork,reuseaddr EXEC:${pkgs.coreutils}/bin/true";
        };
        networking.nftables = {
          enable = true;
          tables.seen = {
            family = "ip";
            content = ''
              counter tcp-from-wan {}
              counter udp-from-wan {}
              chain input {
                type filter hook input priority filter; policy accept;
                ip saddr ${isp.gate} tcp dport { 80, 853 } counter name "tcp-from-wan"
                ip saddr ${isp.gate} udp dport { 53, 123 } counter name "udp-from-wan"
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
  };

  testScript = ''
    import json

    start_all()

    internet.wait_for_open_port(80)
    internet.wait_for_open_port(853)
    provider.wait_for_unit("wireguard-wg-provider.service")
    gate.wait_for_unit("nftables.service")
    gate.wait_for_unit("exit-tunnel.service")
    for m in [gate, internet, provider, remote, trusted, work]:
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

    fetch = "curl -sS -m 5 http://${site}/"

    def seen(client):
        return client.succeed(fetch).strip()

    with subtest("the rules: main without its default, then trusted into the exit table"):
        rules = gate.succeed("ip rule show")
        assert "1000:\tfrom all lookup main suppress_prefixlength 0" in rules, rules
        assert "1100:\tfrom all iif br-trusted lookup ${net.exitTable.name}" in rules, rules
        routes = gate.succeed("ip route show table ${net.exitTable.name}")
        assert "default dev ${exit}" in routes, routes
        assert "unreachable default metric 100" in routes, routes

    with subtest("a trusted client leaves through the provider"):
        trusted.wait_until_succeeds(f"{fetch} | grep -qx ${far.provider}", timeout=60)
        assert seen(trusted) == "${far.provider}"

    with subtest("a work client leaves by wan"):
        assert seen(work) == "${isp.gate}"

    with subtest("gate reaches the internet through the exit when bound to it"):
        assert gate.succeed("curl -sS -m 5 --interface ${exit} http://${site}/").strip() == "${far.provider}"

    with subtest("DoT is refused in the tunnel, as out wan"):
        assert trusted.succeed("probe ${site} 853").strip() == "refused"
        assert work.succeed("probe ${site} 853").strip() == "refused"

    with subtest("gate's own NTP and DNS leave by wan"):
        before = counter(internet, "ip seen", "udp-from-wan")
        gate.succeed("probe udp ${site} 123; probe udp ${site} 53")
        assert counter(internet, "ip seen", "udp-from-wan") >= before + 2

    with subtest("a peer dialing wg0 on wan still handshakes"):
        remote.wait_until_succeeds("ping -c1 -W1 ${seg.vpn.gateway}", timeout=60)
        handshake = remote.succeed("wg show wg-home latest-handshakes").split()[1]
        assert int(handshake) > 0, handshake

    with subtest("the provider down: trusted times out, and nothing leaves by wan"):
        provider.succeed("systemctl stop wireguard-wg-provider.service")
        wan_before = from_wan()
        trusted.fail(fetch)
        assert from_wan() == wan_before, "trusted left by wan"
        assert seen(work) == "${isp.gate}"
        provider.succeed("systemctl start wireguard-wg-provider.service")
        trusted.wait_until_succeeds(f"{fetch} | grep -qx ${far.provider}", timeout=90)

    with subtest("the tunnel gone: unreachable, not wan"):
        gate.succeed("systemctl stop exit-tunnel.service")
        before, wan_before = leaked(), from_wan()
        trusted.fail(fetch)
        assert from_wan() == wan_before, "trusted left by wan"
        assert leaked() == before, "the unreachable route let a packet through to forward"
        gate.succeed("systemctl start exit-tunnel.service")
        trusted.wait_until_succeeds(f"{fetch} | grep -qx ${far.provider}", timeout=90)

    with subtest("the routing rule gone: the leak drop catches trusted, and counts it"):
        gate.succeed("ip rule del priority 1100 iif br-trusted")
        before, wan_before = leaked(), from_wan()
        trusted.fail(fetch)
        assert from_wan() == wan_before, "trusted left by wan"
        assert leaked() > before, "exit-leak-dropped did not rise"

    with subtest("the rules unit restores what is listed, drops the rest, and adds no duplicate"):
        gate.succeed("ip rule add priority 1100 iif ${gate.trunkIface}.${toString seg.work.id} table ${toString net.exitTable.id}")
        gate.succeed("systemctl restart exit-routing.service")
        gate.succeed("systemctl restart exit-routing.service")
        assert gate.succeed("ip rule show priority 1000").count("\n") == 1
        rules = gate.succeed("ip rule show priority 1100")
        assert rules.strip() == "1100:\tfrom all iif br-trusted lookup ${net.exitTable.name}", rules
        assert seen(trusted) == "${far.provider}"
        assert seen(work) == "${isp.gate}"
  '';
}
