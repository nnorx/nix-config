# Shared NixOS configuration for every host.
#
# Boot and storage live in pi.nix (Pis) or the host's own directory (x86), since
# those genuinely differ per platform. Everything here applies fleet-wide.
{
  config,
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
    ../../modules/net-assertions.nix
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

  # Every secret this fleet has is per-host and lives at the same path, so name
  # it once here rather than in each module that reads one: one copy to change
  # on the day secrets/ moves into the private flake input that docs/network.md
  # anticipates.
  sops.defaultSopsFile = ../../secrets/${hostname}.yaml;

  # Networking. Addressing is derived from lib/net.nix rather than repeated per
  # host, so that file's promise — renumbering the LAN is a one-file change —
  # holds structurally instead of depending on every host repeating the same
  # block correctly. Hosts with no `ip` there keep their DHCP lease.
  networking = {
    useDHCP = false;
    hostName = hostname;
  }
  // lib.optionalAttrs (host ? ip) {
    # Address, prefix and default gateway all come from the one segment the
    # host names, and from no other. A second address on a network the
    # interface no longer reaches is not inert: the host answers nothing there
    # and silently blackholes everything it sends to it.
    interfaces.${host.iface}.ipv4.addresses = [
      {
        address = host.ip;
        inherit (net.segments.${host.segment}) prefixLength;
      }
    ];
    defaultGateway = net.segments.${host.segment}.gateway;
  };

  # The login and sudo password, from sops rather than a literal in a public
  # repo. It was `initialPassword = "changeme"`, which is worse than it sounds:
  # `security.sudo.wheelNeedsPassword` is true, so on any host where nobody
  # ever ran `passwd` that published string was the sudo password.
  #
  # `neededForUsers` is what makes this work at all. Users are created early in
  # activation, before the normal secrets are rendered, so a hash under
  # /run/secrets would not exist yet when it is read. This lands it in
  # /run/secrets-for-users, which sops-nix populates first.
  #
  # If this secret cannot be rendered, activation does not stop. The snippet
  # fails, the `users` snippet runs anyway, and the account is left locked. That
  # is not recoverable by rolling back, because /etc/shadow is mutable state
  # rather than part of a generation. docs/recovery.md has the full account, and
  # it is why a host's sops recipient must be registered before its first
  # activation rather than after.
  sops.secrets.user-password-hash.neededForUsers = true;

  # Declarative users, and inseparable from the `hashedPasswordFile` below
  # rather than a hardening preference: it is what makes that line take effect
  # at all.
  #
  # NixOS writes a declared password into an *existing* account's shadow entry
  # only when this is false. With it true, update-users-groups.pl merges the
  # current /etc/shadow and leaves the entry alone, applying a declared hash
  # only to accounts it is creating for the first time. Every account in this
  # fleet already exists, so setting hashedPasswordFile without this would have
  # changed nothing, reported nothing, and left `changeme` in place wherever it
  # was never changed.
  #
  # Three costs, all deliberate:
  #
  #   - `passwd` on a host no longer persists. The next activation rewrites the
  #     entry from the sops value, so rotating means editing the secret.
  #   - root is left locked (`!`), because nothing declares a password for it.
  #     That also means `sulogin` refuses a shell at an emergency prompt, so
  #     physical recovery is the USB or a card pull. See docs/recovery.md.
  #   - undeclared accounts and groups are removed, and group memberships added
  #     by hand with `usermod -aG` are dropped. On a freshly flashed Pi that
  #     retires the image's leftover `nixos` account on first activation.
  users.mutableUsers = false;

  # User account — hostname doubles as username (core4, core5, lifeline, gate)
  users.users.${hostname} = {
    isNormalUser = true;
    hashedPasswordFile = config.sops.secrets.user-password-hash.path;
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
