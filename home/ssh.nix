# SSH agent management for interactive dev hosts.
#
# Why keychain and not a systemd user service: WSL doesn't start a per-user
# systemd instance (logind creates no session, so /run/user/$UID and the user
# bus never exist), which means `services.ssh-agent` / a `systemd --user` unit
# can't run there. keychain is the portable alternative — it starts a single
# ssh-agent, reuses it across every shell and login, and prompts for each
# key's passphrase once per boot. The bash/zsh integrations source keychain's
# environment on startup so SSH_AUTH_SOCK is always wired up.
#
# forge does have a user systemd, but nothing there starts an agent either
# (Plasma does not, and programs.ssh.startAgent is off), so keychain serves it
# the same way and one mechanism covers every Linux dev host.
#
# Linux-only: macOS has its native launchd ssh-agent + Keychain, so this is
# scoped out there (mirrors the isDarwin split in git.nix). The fleet's host
# entries below are Linux-only too, for a different reason: the Linux dev
# hosts, WSL and forge, are the admin machines in lib/ssh-keys.nix, and the work
# Mac is deliberately not one.
{
  pkgs,
  lib,
  net,
  ...
}:
let
  # The servers have one address each in lib/net.nix. gate has none there,
  # holding .1 in every segment, and admin machines sit on trusted, so they
  # reach it at that segment's gateway.
  fleet =
    lib.mapAttrs (_name: host: host.ip) (lib.filterAttrs (_name: host: host ? ip) net.hosts)
    // {
      gate = net.segments.trusted.gateway;
    };
in
{
  # `ssh core4`, `ssh gate` and so on, from any admin machine. The login user
  # is the hostname, as hosts/common makes it.
  #
  # IdentitiesOnly, because otherwise ssh offers every key the agent holds
  # before the one named here, and the hosts allow three attempts
  # (modules/ssh.nix). Another key or two loaded first is a refused login.
  #
  # Home Manager owns ~/.ssh/config from here on. Hosts it does not generate,
  # such as the Hetzner box, go in ~/.ssh/config.local, which is read first, so
  # an entry there for a fleet host would win over the one generated here.
  programs.ssh = lib.mkIf pkgs.stdenv.isLinux {
    enable = true;
    # Home Manager's legacy defaults are deprecated, and none are wanted.
    enableDefaultConfig = false;
    includes = [ "config.local" ];
    settings = lib.mapAttrs (name: address: {
      HostName = address;
      User = name;
      IdentityFile = "~/.ssh/id_ed25519_pis";
      IdentitiesOnly = true;
    }) fleet;
  };

  programs.keychain = lib.mkIf pkgs.stdenv.isLinux {
    enable = true;
    # keychain 2.9.0+ auto-detects the ssh agent, so `agents` is deprecated
    # and omitted. Key names resolve relative to ~/.ssh.
    #
    # id_ed25519_pis is listed because it has a passphrase: IdentityFile only
    # says which key to offer, not who signs with it, so without an agent
    # holding it every connection to a Pi or to gate prompts, and each new
    # shell starts with an empty agent.
    keys = [
      "id_ed25519_hetzner"
      "id_ed25519_pis"
    ];

    # --noask: never prompt for a passphrase at shell startup. Without it,
    # every new shell asks for any listed key the agent does not already hold,
    # which is a prompt on every terminal for a project that may be dormant for
    # months. Declining does not help — keychain simply asks again next time.
    #
    # The keys stay declared, so this makes loading opt-in rather than removing
    # them: run `ssh-add ~/.ssh/id_ed25519_pis` once after a boot, and keychain
    # keeps that agent alive across every subsequent shell and login. Which is
    # the whole point of listing the Pi key: one prompt per boot covers every
    # host in the fleet, instead of one per connection.
    extraFlags = [
      "--quiet"
      "--noask"
    ];
  };
}
