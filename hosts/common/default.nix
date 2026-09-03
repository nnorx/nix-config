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

  # sops-nix — each host decrypts with an age key derived from its own SSH host
  # key, so there is no key material to distribute. Re-imaging a host changes
  # that key: re-derive it into .sops.yaml and run `sops updatekeys`.
  sops.age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];

  # Networking. Addressing is derived from lib/net.nix rather than repeated per
  # host, so that file's promise — renumbering the LAN is a one-file change —
  # holds structurally instead of depending on every host repeating the same
  # block correctly. Hosts with no `ip` there keep their DHCP lease.
  networking = {
    useDHCP = false;
    hostName = hostname;
  }
  // lib.optionalAttrs (host ? ip) {
    # A host may carry a second address on the segment it is destined for,
    # while still holding its address on the flat LAN. That is what makes the
    # cutover survivable: when the switch uplink moves behind gate, the flat
    # address goes dark and the segment address becomes live, and the host is
    # reachable throughout rather than stranded at an address that no longer
    # routes and unfixable because it is unreachable.
    #
    # The default gateway is not doubled, because there can only be one. It
    # keeps pointing at the flat LAN, so after the move a host is reachable
    # from gate on its own segment but has no route off it until it is
    # rebuilt. See the cutover section in docs/router.md.
    interfaces.${host.iface}.ipv4.addresses = [
      {
        address = host.ip;
        inherit (net.lan) prefixLength;
      }
    ]
    ++ lib.optional (host ? segmentIp) {
      address = host.segmentIp;
      inherit (net.segments.${host.segment}) prefixLength;
    };
    # A host that has moved onto a segment routes through that segment's
    # gateway, not the flat LAN's. This is the second half of the cutover: the
    # segment address alone makes a host reachable *on* its segment, and this
    # is what gives it a route *off* it.
    #
    # Deliberately keyed on `segmentIp` rather than `segment`, so a host is
    # only pointed at gate once it actually holds an address there. Reversing
    # that order would send a host's default route to an address it cannot
    # reach and cut its internet before the move rather than after.
    defaultGateway =
      if (host ? segmentIp) then net.segments.${host.segment}.gateway else net.lan.gateway;
  };

  # User account — hostname doubles as username (core4, core5, lifeline, gate)
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
