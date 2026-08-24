# Shared NixOS configuration for every host.
#
# Boot and storage live in pi.nix (Pis) or the host's own directory (x86), since
# those genuinely differ per platform. Everything here applies fleet-wide.
{
  pkgs,
  lib,
  hostname,
  net,
  ...
}:
let
  host = net.hosts.${hostname} or { };
in
{
  imports = [
    ../../modules/baseline.nix
    ../../modules/ssh.nix
    ../../modules/firewall.nix
    ../../modules/fail2ban.nix
  ];

  system.stateVersion = "25.11";

  # Locale and timezone
  time.timeZone = "America/New_York";
  i18n.defaultLocale = "en_US.UTF-8";

  # Networking. Addressing is derived from lib/net.nix rather than repeated per
  # host, so that file's promise — renumbering the LAN is a one-file change —
  # holds structurally instead of depending on every host repeating the same
  # block correctly. Hosts with no `ip` there keep their DHCP lease.
  networking = {
    useDHCP = false;
    hostName = hostname;
  }
  // lib.optionalAttrs (host ? ip) {
    interfaces.${host.iface}.ipv4.addresses = [
      {
        address = host.ip;
        inherit (net.lan) prefixLength;
      }
    ];
    defaultGateway = net.lan.gateway;
  };

  # User account — hostname doubles as username (core4, core5, lifeline)
  users.users.${hostname} = {
    isNormalUser = true;
    initialPassword = "changeme"; # Change on first login with: passwd
    extraGroups = [
      "wheel"
    ];
    shell = pkgs.zsh;
  };

  # Zsh must be enabled system-wide for it to work as a login shell
  programs.zsh.enable = true;

  # Minimal set of system packages
  environment.systemPackages = with pkgs; [
    git
    vim
    curl
    htop
    dnsutils # dig/delv — diagnose the DNS path from the host, root included
  ];
}
