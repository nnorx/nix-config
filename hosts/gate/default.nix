# CWWK N100 (4x Intel i226) — the router.
#
# Not routing yet. This stage only brings the box under nix-config with the
# fleet baseline (SSH hardening, firewall, fail2ban) while keeping its existing
# DHCP lease so it stays reachable. Interface renaming, nftables NAT, and Kea
# land in follow-ups; see docs/router.md for the sequence.
{
  pkgs,
  hostname,
  net,
  ...
}:
let
  host = net.hosts.${hostname};
in
{
  imports = [ ./hardware-configuration.nix ];

  # Installed from 26.05, unlike the Pis. hosts/common defaults this to 25.11,
  # which is the release *they* were installed from; lowering it here would
  # apply older compatibility defaults than the box was ever set up with.
  system.stateVersion = "26.05";

  # UEFI + systemd-boot. The Pis boot via extlinux from hosts/common/pi.nix,
  # which this host deliberately does not import.
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # hosts/common sets networking.useDHCP = false fleet-wide, so opt this one
  # interface back in. Keeping the lease means the box survives the switch off
  # NetworkManager onto scripted networking without changing address.
  networking.interfaces.${host.iface}.useDHCP = true;

  # i226 link flapping under ASPM is a known failure on these NICs, and
  # diagnosing it needs the driver's firmware revision and the PCI stepping.
  # Neither tool is in the fleet baseline, and a router is the one host where
  # being unable to inspect a NIC is the whole problem.
  environment.systemPackages = with pkgs; [
    ethtool
    pciutils
  ];
}
