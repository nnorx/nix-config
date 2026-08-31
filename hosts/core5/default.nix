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
    ../../modules/unifi.nix
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

  # Docker access for this host's user.
  #
  # The uid is pinned because the UniFi container needs a numeric PUID at
  # evaluation time, and NixOS otherwise allocates normal-user ids at
  # activation, leaving `users.users.<n>.uid` null in the config. 1001 is what
  # this host already assigned, so declaring it changes nothing on disk.
  users.users.${hostname} = {
    uid = 1001;
    extraGroups = [ "docker" ];
  };

  # Pi 5 boot — override the extlinux default from hosts/common
  boot.loader.generic-extlinux-compatible.enable = lib.mkForce false;
  boot.loader.raspberry-pi.bootloader = "kernel";

  # Root on NVMe rather than the SD card. Addressed by UUID, not label: while
  # both devices are attached there are two firmware partitions and two Linux
  # roots, and the SD's label and UUID are the fixed ones every NixOS Pi image
  # ships, so neither identifies this host's card specifically. UUIDs generated
  # by mkfs are unique by construction.
  #
  # The SD stays in the slot and stays behind NVMe in the EEPROM BOOT_ORDER, so
  # it remains the fallback. BOOT_ORDER is EEPROM state and Nix does not manage
  # it; see the README.
  fileSystems."/" = {
    device = "/dev/disk/by-uuid/cc1735c9-05a6-4cc5-b318-563129ad4efb";
    fsType = "ext4";
  };

  # Pi 5 firmware partition (managed by nixos-raspberrypi bootloader module)
  fileSystems."/boot/firmware" = {
    device = "/dev/disk/by-uuid/7E12-9BFD";
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

  # UniFi controller — LAN interface only. The switch and AP need all four:
  # the UI for us, inform for device state, STUN to stay reachable, and
  # discovery for adoption. The MongoDB port is deliberately absent, since it
  # is published to nothing and lives on the container network.
  networking.firewall.interfaces.${net.hosts.${hostname}.iface} = {
    allowedTCPPorts = [
      net.ports.unifiUi
      net.ports.unifiInform
    ];
    allowedUDPPorts = [
      net.ports.unifiStun
      net.ports.unifiDiscovery
    ];
  };

  # pimon collector — allow the collector port only from other Pis
  networking.firewall.extraCommands = lib.concatMapStrings (h: ''
    iptables -A nixos-fw -p tcp --dport ${toString net.ports.pimon} -s ${net.hosts.${h}.ip} -j nixos-fw-accept
  '') agentHosts;
}
