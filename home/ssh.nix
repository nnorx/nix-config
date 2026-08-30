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
# Linux-only: macOS has its native launchd ssh-agent + Keychain, so this is
# scoped out there (mirrors the isDarwin split in git.nix).
{ pkgs, lib, ... }:
{
  programs.keychain = lib.mkIf pkgs.stdenv.isLinux {
    enable = true;
    # keychain 2.9.0+ auto-detects the ssh agent, so `agents` is deprecated
    # and omitted. Key names resolve relative to ~/.ssh.
    #
    # id_ed25519_pis was left out on the grounds that it is used via
    # IdentityFile rather than the agent. That does not follow: the key has a
    # passphrase, and IdentityFile only says which key to offer, not who signs
    # with it. Without an agent holding it, every connection to a Pi — or now
    # to gate — prompts, and each new shell starts with an empty agent.
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
