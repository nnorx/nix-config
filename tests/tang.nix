# Tang on lifeline and core5 (modules/tang.nix): each makes its keys and
# advertises them to gate's servers address, and another host on servers is
# refused. core5 runs Docker as it does on the fleet, so its rules are in
# place ahead of the request.
#
# `nix build .#checks.x86_64-linux.tang`. It needs KVM, which forge's daemon
# has; CI's vm-tests job runs it on pull requests.
{ net }:
let
  seg = net.segments;
  port = toString net.ports.tang;
  servers = [
    "lifeline"
    "core5"
  ];

  wire = 1;
  onServers =
    ip:
    { pkgs, ... }:
    {
      virtualisation.interfaces.end0.vlan = wire;
      environment.systemPackages = [ pkgs.curl ];
      networking = {
        useDHCP = false;
        interfaces.end0.ipv4.addresses = [
          {
            address = ip;
            inherit (seg.servers) prefixLength;
          }
        ];
      };
    };

  server = hostname: extra: {
    _module.args.hostname = hostname;
    imports = [
      (onServers net.hosts.${hostname}.ip)
      ../modules/tang.nix
    ]
    ++ extra;
  };
in
{
  name = "tang";

  node.specialArgs = { inherit net; };

  nodes = {
    lifeline = server "lifeline" [ ];
    core5 = server "core5" [ ../modules/docker.nix ];
    gate = onServers seg.servers.gateway;
    # The switch, the AP, or anything on an untagged port.
    other = onServers net.hosts.core4.ip;
  };

  testScript = ''
    start_all()
    for machine in (lifeline, core5):
        machine.wait_for_unit("tangd.socket")
    core5.wait_for_unit("docker.service")
    for machine in (gate, other):
        machine.wait_for_unit("network.target")

    for name, machine, ip in [${
      builtins.concatStringsSep ", " (map (h: ''("${h}", ${h}, "${net.hosts.${h}.ip}")'') servers)
    }]:
        url = f"http://{ip}:${port}/adv"

        with subtest(f"{name} advertises its keys to gate"):
            adv = gate.wait_until_succeeds(f"curl -sf --max-time 5 {url}", timeout=60)
            assert '"payload"' in adv, adv
            keys = int(machine.succeed("ls /var/lib/tang | wc -l"))
            assert keys >= 2, f"{keys} files in /var/lib/tang"

        with subtest(f"{name} refuses another servers address"):
            other.fail(f"curl -sf --max-time 5 {url}")

        with subtest(f"{name}'s socket refuses it past the firewall too"):
            rule = "nixos-fw -p tcp --dport ${port} -s ${net.hosts.core4.ip} -j nixos-fw-accept"
            machine.succeed(f"iptables -I {rule}")
            other.fail(f"curl -sf --max-time 5 {url}")
            machine.succeed(f"iptables -D {rule}")
  '';
}
