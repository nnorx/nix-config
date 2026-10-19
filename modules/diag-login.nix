# A `diag` login on every server, for the read-only diagnostics Claude
# sessions run through fleet-ssh (home/ssh.nix). It is a normal user outside
# wheel, so it has no sudo (`security.sudo.execWheelOnly` in
# modules/baseline.nix), and in `systemd-journal`, so it reads the system
# journal, host-status's upgrade line included.
#
# Its keys, from lib/diag-keys.nix, are one file key per admin machine,
# separate from id_ed25519_pis, since sshd tells logins apart by key. Each is
# `restrict`: no pty, no forwarding of any kind, no agent, no `~/.ssh/rc`. No
# forced command, so it is a general shell for reading the host. The alert
# agent's `triage` login (docs/fleet-agent.md) is the narrower one.
#
# No password: nothing declares one, so with `users.mutableUsers = false` the
# account is locked, as deploy's is, and only a key opens it.
{ diagPubKeys, ... }:
{
  users.users.diag = {
    isNormalUser = true;
    extraGroups = [ "systemd-journal" ];
    openssh.authorizedKeys.keys = map (key: "restrict ${key}") diagPubKeys;
  };

  # Added to the host's own user in modules/ssh.nix; the lists merge.
  services.openssh.settings.AllowUsers = [ "diag" ];

  # Nothing diag starts outlives its login. KillOnlyUsers has logind kill a
  # session's processes when it ends, for the users listed, whatever
  # KillUserProcesses says, so the host's own user keeps what it leaves
  # running. Deleting a key's line then ends everything that key started at
  # its logout, rather than at the next reboot.
  services.logind.settings.Login.KillOnlyUsers = "diag";

  # Only wheel uses the nix daemon (root always may). diag reads the host and
  # builds nothing, and a build runs as the daemon's own users, so whatever
  # holds diag to its own reach would not hold the build. Nothing on the
  # servers runs nix as anyone else: the upgrades and deploy-guard run as
  # root, and deploy-agent writes request files.
  nix.settings.allowed-users = [ "@wheel" ];
}
