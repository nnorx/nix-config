# CWWK N100 (4x Intel i226) — the router.
#
# Not routing yet. This stage only brings the box under nix-config with the
# fleet baseline (SSH hardening, firewall, fail2ban) while keeping its existing
# DHCP lease so it stays reachable. Interface renaming, nftables NAT, and Kea
# land in follow-ups; see docs/router.md for the sequence.
{
  pkgs,
  lib,
  hostname,
  net,
  ...
}:
let
  host = net.hosts.${hostname};
in
{
  imports = [
    ./hardware-configuration.nix
    # Automatic rollback for reboots that go wrong. Not fleet-wide: the Pis are
    # a card-pull away from recovery, and gate is the host where an
    # unreachable box means the house has no router.
    ../../modules/deploy-guard.nix
  ];

  # Installed from 26.05, unlike the Pis. hosts/common defaults this to 25.11,
  # which is the release *they* were installed from; lowering it here would
  # apply older compatibility defaults than the box was ever set up with.
  system.stateVersion = "26.05";

  # Same reasoning on the Home Manager side, which tracks its own release.
  home-manager.users.gate.home.stateVersion = "26.05";

  # UEFI + systemd-boot. The Pis boot via extlinux from hosts/common/pi.nix,
  # which this host deliberately does not import.
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # The default is unbounded. gate is the only host with a separate ESP, at
  # 953M, and the Pis are immune because extlinux writes to their ext4 root.
  # Phases 3 and 4 are repeated boot-and-reboot cycles, and each generation
  # leaves a kernel and initrd here, so without a cap the partition fills and
  # the failure surfaces partway through installing the bootloader.
  boot.loader.systemd-boot.configurationLimit = 10;

  # hosts/common sets networking.useDHCP = false fleet-wide, so opt the one
  # cabled interface back in.
  #
  # This does not guarantee the same address. The switch replaces
  # NetworkManager with dhcpcd, which presents a different client identifier,
  # and hosts/common changes the hostname from `router` to `gate` at the same
  # time, so the Nest may treat it as a new client and lease a different
  # address on the interface the SSH session is running over. Deploy with
  # `boot` and a reboot, with a console at the box.
  networking.interfaces.${host.wanIface}.useDHCP = true;

  # The fleet cap is 200M, sized for SD-card wear. gate has NVMe with 218G
  # free and is the host whose logs are worth having: a week of firewall drops
  # and DHCP churn is the evidence for every question this box will raise.
  services.journald.extraConfig = lib.mkForce ''
    SystemMaxUse=2G
    MaxRetentionSec=3month
  '';

  # i226 link flapping under ASPM is a known failure on these NICs, and
  # diagnosing it needs the driver's firmware revision and the PCI stepping.
  # Neither tool is in the fleet baseline, and a router is the one host where
  # being unable to inspect a NIC is the whole problem.
  environment.systemPackages = with pkgs; [
    ethtool
    pciutils
  ];
}
