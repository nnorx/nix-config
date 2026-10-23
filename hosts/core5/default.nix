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
    ../../modules/unifi-backup.nix
    ../../modules/home-assistant.nix
    ../../modules/home-assistant-backup.nix
    ../../modules/metrics.nix
    # The root's NVMe drive, by its namespace, which needs no reboot to read
    # (modules/smartctl.nix). There is one NVMe drive, so the name is stable.
    (import ../../modules/smartctl.nix { devices = [ "/dev/nvme0n1" ]; })
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

  # The metrics stack failing to start says so through the hosted path, which
  # does not depend on it (modules/alerts.nix, docs/observability.md).
  fleetAlerts.failure = [
    "victoriametrics"
    "vmalert"
    "alertmanager"
    "grafana"
  ];

  # This host's user, which the UniFi container runs as.
  #
  # The uid is pinned because the UniFi container needs a numeric PUID at
  # evaluation time, and NixOS otherwise allocates normal-user ids at
  # activation, leaving `users.users.<n>.uid` null in the config.
  #
  # 1000, not 1001. It was 1001 before the NVMe migration, but that install
  # allocated ids in a different order and `/var/lib/nixos`, which holds the
  # allocation state, was not carried across. Declaring a uid does not move an
  # existing account, so the pin and the account disagreed and home-manager
  # refused to activate with `UID is "1000", expected "1001"`. The number is
  # arbitrary; agreeing with the account on disk is the requirement.
  #
  # Not in `docker`, which is root-equivalent: the socket starts a container
  # with the host's root mounted, and no password is asked. Root here goes
  # through sudo and its password, as on every other host, so `sudo docker`
  # it is. The containers and their backups run as systemd units and need no
  # group.
  users.users.${hostname}.uid = 1000;

  # Pi 5 boot — override the extlinux default from hosts/common
  boot.loader.generic-extlinux-compatible.enable = lib.mkForce false;
  boot.loader.raspberry-pi.bootloader = "kernel";

  # Onboard Bluetooth off, in config.txt. Nothing here uses it and BlueZ is not
  # running, but Home Assistant's bluetooth integration, which default_config
  # pulls in, still finds the adapter and errors without BlueZ to drive it.
  # Removing the adapter is simpler than running a stack for no device. The
  # firmware reads config.txt only at boot, so this takes effect on a reboot.
  hardware.raspberry-pi.config.all.dt-overlays.disable-bt.enable = true;

  # Root on NVMe rather than the SD card. Addressed by UUID, not label: while
  # both devices are attached there are two firmware partitions and two Linux
  # roots, and the SD's label and UUID are the fixed ones every NixOS Pi image
  # ships, so neither identifies this host's card specifically. UUIDs generated
  # by mkfs are unique by construction.
  #
  # The SD stays in the slot and stays behind NVMe in the EEPROM BOOT_ORDER, so
  # it remains the fallback. BOOT_ORDER is EEPROM state and Nix does not manage
  # it; see docs/pi-install.md.
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
  # make monitoring depend on the thing it monitors.
  networking.nameservers = net.publicResolvers;

  # The switch and AP need all four UniFi ports: the UI for us, inform for
  # device state, STUN to stay reachable, and discovery for adoption. The
  # MongoDB port is deliberately absent, since it is published to nothing and
  # lives on the container network.
  #
  # The UniFi ports are listed here for clarity, not for scoping. Docker DNATs
  # them to the container before INPUT, so these rules never see that traffic;
  # the address modules/unifi.nix publishes them on is what scopes them. The
  # one exception is a discovery broadcast, which Docker does not DNAT, so it
  # does pass through here, and the rule for it is what admits it.
  #
  # Home Assistant is opened here rather than with the module's `openFirewall`,
  # which opens the port on every interface.
  networking.firewall.interfaces.${net.hosts.${hostname}.iface} = {
    allowedTCPPorts = [
      net.ports.unifiUi
      net.ports.unifiInform
      net.ports.homeAssistant
    ];
    allowedUDPPorts = [
      net.ports.unifiStun
      net.ports.unifiDiscovery
    ];
  };

  # pimon collector — allow the collector port only from other Pis
  networking.firewall.extraCommands =
    lib.concatMapStrings (h: ''
      iptables -A nixos-fw -p tcp --dport ${toString net.ports.pimon} -s ${net.hosts.${h}.ip} -j nixos-fw-accept
    '') agentHosts
    # Govee lights answer Home Assistant's scan and report status here. Only
    # from iot, where the lights are and whence gate lets this one port
    # through; see hosts/gate/govee.nix.
    + ''
      iptables -A nixos-fw -p udp --dport ${toString net.ports.goveeReply} -s ${net.segments.iot.subnet} -j nixos-fw-accept
    '';
}
