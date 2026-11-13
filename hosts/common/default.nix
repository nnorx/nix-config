# Shared NixOS configuration for every host. Boot and storage live per
# platform, in pi.nix or the host's own directory.
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
    ../../modules/kernel-hardening.nix
    ../../modules/ssh.nix
    ../../modules/diag-login.nix
    ../../modules/firewall.nix
    ../../modules/fail2ban.nix
    ../../modules/net-assertions.nix
    ../../modules/host-status.nix
    ../../modules/node-exporter.nix
    ../../modules/alerts.nix
  ]
  # The one role chosen here, by net.resolvers rather than by each host.
  ++ lib.optional (lib.elem hostname net.resolvers) ./resolver.nix;

  # mkDefault so a host installed from a later release keeps its own: it
  # records the release a host was installed from.
  system.stateVersion = lib.mkDefault "25.11";

  time.timeZone = "America/New_York";
  i18n.defaultLocale = "en_US.UTF-8";

  # Each host decrypts with an age key derived from its SSH host key.
  # Re-imaging changes it: re-derive it into .sops.yaml, run `sops updatekeys`.
  sops.age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];

  # Every secret is per host at the same path, so it is named once here.
  sops.defaultSopsFile = ../../secrets/${hostname}.yaml;

  # Addressing comes from lib/net.nix, from the one segment the host names
  # and no other: a second address on a network the interface no longer
  # reaches blackholes everything sent to it. Hosts with no `ip` keep DHCP.
  networking = {
    useDHCP = false;
    hostName = hostname;
  }
  // lib.optionalAttrs (host ? ip) {
    interfaces.${host.iface}.ipv4.addresses = [
      {
        address = host.ip;
        inherit (net.segments.${host.segment}) prefixLength;
      }
    ];
    defaultGateway = net.segments.${host.segment}.gateway;
  };

  # Users are created before normal secrets are rendered, so the hash goes to
  # /run/secrets-for-users. If it cannot render, the account is left locked
  # and a rollback does not fix it (docs/recovery.md), so a host's recipient
  # is registered before its first activation.
  sops.secrets.user-password-hash.neededForUsers = true;

  # What makes `hashedPasswordFile` apply to accounts that already exist.
  # Its costs: `passwd` does not persist, so rotating means editing the
  # secret; root stays locked, so `sulogin` refuses and recovery is the USB or
  # a card pull; and undeclared accounts, groups and memberships are removed,
  # the Pi image's `nixos` account among them.
  users.mutableUsers = false;

  users.users.${hostname} = {
    isNormalUser = true;
    hashedPasswordFile = config.sops.secrets.user-password-hash.path;
    extraGroups = [
      "wheel"
    ];
    shell = pkgs.zsh;
  };

  # Needed for zsh to work as a login shell.
  programs.zsh.enable = true;

  environment.systemPackages = with pkgs; [
    git
    vim
    curl
    htop
    dnsutils # dig/delv — diagnose the DNS path from the host, root included
  ];
}
