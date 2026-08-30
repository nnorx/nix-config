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

  # mkDefault so a host installed from a later release can keep its own. This
  # pins backward-compatible defaults for stateful data, not the release in
  # use, so it should record the release a host was *installed* from.
  system.stateVersion = lib.mkDefault "25.11";

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

  # Deploy shortcuts. nixos-rebuild resolves the flake attribute from the
  # hostname when #name is omitted, so one literal string is correct on every
  # host — no templating, and gate inherits it.
  #
  # --refresh matters: `github:` refs are cached for an hour by default, so
  # without it you can silently deploy a stale main. --accept-flake-config is
  # redundant once modules/baseline.nix has put the caches in nix.conf, but is
  # still needed on a freshly flashed host, and costs nothing here.
  #
  # nrb (boot) is for changes that reconfigure the interface you are connected
  # over — a static IP moving, or gate's routing — where switch would pull the
  # network out from under the session mid-activation.
  environment.shellAliases = {
    nrs = "sudo nixos-rebuild switch --flake github:nnorx/nix-config --accept-flake-config --refresh";
    nrb = "sudo nixos-rebuild boot --flake github:nnorx/nix-config --accept-flake-config --refresh";
  };

  # Minimal set of system packages
  environment.systemPackages = with pkgs; [
    git
    vim
    curl
    htop
    dnsutils # dig/delv — diagnose the DNS path from the host, root included
  ];
}
