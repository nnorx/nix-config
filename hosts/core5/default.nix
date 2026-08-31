# Raspberry Pi 5 — future homelab
# Boot handled by nixos-raspberrypi (kernel bootloader + Pi firmware, not U-Boot)
{
  hostname,
  lib,
  net,
  ...
}:
let
  # Collector allow list, one rule per agent. Adding a host means adding it to
  # net.pimonAgents and then rebuilding *this* host: until core5 is rebuilt the
  # new agent's POSTs are dropped, and pimon's Restart=always hides that.
  agentHosts = lib.filter (h: h != hostname) net.pimonAgents;
in
{
  imports = [
    ../../modules/docker.nix
    (import ../../modules/pimon.nix {
      mode = "collector";
      bind = "0.0.0.0";
      port = net.ports.pimon;
    })
    (import ../../modules/pimon.nix {
      mode = "agent";
      collectorUrl = "http://127.0.0.1:${toString net.ports.pimon}";
    })
  ];

  # Docker access for this host's user
  users.users.${hostname}.extraGroups = [ "docker" ];

  # Pi 5 boot — override the extlinux default from hosts/common
  boot.loader.generic-extlinux-compatible.enable = lib.mkForce false;
  boot.loader.raspberry-pi.bootloader = "kernel";

  # Pi 5 firmware partition (managed by nixos-raspberrypi bootloader module)
  fileSystems."/boot/firmware" = {
    device = "/dev/disk/by-label/FIRMWARE";
    fsType = "vfat";
    options = [
      "noatime"
      "noauto"
      "x-systemd.automount"
      "x-systemd.idle-timeout=1min"
    ];
  };

  # Public resolvers rather than the fleet's own. Deliberate as far as it goes:
  # core5 runs the pimon collector, so pointing it at core4 or lifeline would
  # make monitoring depend on the thing it monitors. Two operators, and not
  # Google.
  networking.nameservers = [
    "1.1.1.1" # Cloudflare
    "9.9.9.9" # Quad9
  ];

  # pimon collector — allow the collector port only from other Pis
  networking.firewall.extraCommands = lib.concatMapStrings (h: ''
    iptables -A nixos-fw -p tcp --dport ${toString net.ports.pimon} -s ${net.hosts.${h}.ip} -j nixos-fw-accept
  '') agentHosts;
}
