# gate's Govee reply and command rules, in VMs: a light at its `net.devices`
# address answers Home Assistant on the reply port and hears it on the command
# port, and another iot device does neither. The multicast scan is left out.
#
# `nix build .#checks.x86_64-linux.gate-govee`. It needs KVM, which forge's
# daemon has; CI's vm-tests job runs it on pull requests.
{ net }:
let
  topology = import ./lib/gate-topology.nix { inherit net; };
  seg = net.segments;
  inherit (net.ports) goveeReply goveeCommand;
  homeAssistant = net.hosts.core5.ip;
  lightIp = net.devices.${builtins.head net.goveeLights}.ip;
  otherIp = seg.iot.pool.first;

  # Appends every datagram that reaches `port` to /tmp/got.
  receiving =
    port:
    { pkgs, ... }:
    {
      environment.systemPackages = [ pkgs.socat ];
      networking.firewall.allowedUDPPorts = [ port ];
      systemd.services.receive = {
        wantedBy = [ "multi-user.target" ];
        script = "${pkgs.socat}/bin/socat -u UDP-RECV:${toString port} OPEN:/tmp/got,creat,append";
      };
    };

  onIot = address: {
    imports = [
      (topology.onSegment "iot" address)
      (receiving goveeCommand)
    ];
  };
in
{
  name = "gate-govee";

  node.specialArgs = { inherit net; };

  nodes = {
    gate.imports = [
      (topology.router { })
      ../hosts/gate/govee.nix
    ];

    core5.imports = [
      (topology.onServers [ homeAssistant ])
      (receiving goveeReply)
    ];

    light = onIot lightIp;
    other = onIot otherIp;
  };

  testScript = ''
    import time

    start_all()

    gate.wait_for_unit("nftables.service")
    for m, gateway in ((core5, "${seg.servers.gateway}"), (light, "${seg.iot.gateway}"), (other, "${seg.iot.gateway}")):
        m.wait_for_unit("receive.service")
        m.wait_until_succeeds(f"ping -c1 -W1 {gateway}", timeout=60)

    def send(sender, word, address, port):
        sender.succeed(f"echo {word} | socat -u - UDP-SENDTO:{address}:{port}")

    def received(receiver, word):
        return receiver.execute(f"grep -qx {word} /tmp/got")[0] == 0

    # The device that must be refused is sent from, or to, first and again
    # each round, so by the time the light's datagram arrives the other's has
    # had every chance.
    def exchange(sender_ok, sender_no, receiver_ok, receiver_no, address_ok, address_no, port):
        for _ in range(30):
            send(sender_no, "other", address_no, port)
            send(sender_ok, "light", address_ok, port)
            if received(receiver_ok, "light"):
                break
            time.sleep(1)
        else:
            raise AssertionError("the light's datagram never arrived")
        assert not received(receiver_no, "other"), "the other iot device's datagram got through"

    with subtest("the light answers Home Assistant, and the other iot device cannot"):
        exchange(light, other, core5, core5, "${homeAssistant}", "${homeAssistant}", ${toString goveeReply})

    with subtest("Home Assistant commands the light, and not the other iot device"):
        exchange(core5, core5, light, other, "${lightIp}", "${otherIp}", ${toString goveeCommand})

    print(gate.succeed("nft list chain inet nixos-fw forward-allow"))
  '';
}
