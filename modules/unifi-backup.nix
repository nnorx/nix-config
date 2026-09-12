# Off-box copy of the UniFi controller's backups.
#
# The controller's database holds adoption state, SSIDs, PSKs, VLAN
# assignments and port profiles. docs/unifi.md is blunt that none of it is in
# this repo under any approach, which makes it the one part of the network a
# rebuilt core5 could not reproduce from the flake.
#
# This module does not make a backup. The controller already writes `.unf`
# files on a schedule set in its own UI, and that format is what its restore
# flow expects. A `mongodump` would be a second, unsupported path into a
# database whose migrations are one-way. The job here is only to get the file
# the controller already wrote somewhere that is not core5.
#
# Encrypted with age before it leaves the host, which makes the destination
# untrusted by construction: a `.unf` carries Wi-Fi PSKs and device
# credentials, and a private repo is still a copy outside the house. age needs
# only the *public* half to encrypt, so core5 holds nothing that could read
# these back. The private half lives in Bitwarden and ~/.config/sops/age.
{
  config,
  pkgs,
  lib,
  hostname,
  ...
}:
let
  backupDir = "/var/lib/unifi/config/data/backup/autobackup";
  workDir = "/var/lib/unifi-backup";

  repoUrl = "git@github.com:nnorx/homelab-state.git";
  branch = "main";

  # The `nick` recipient from .sops.yaml. Duplicated rather than read from
  # there because Nix has no YAML parser and .sops.yaml is consumed by the sops
  # CLI, not by the module system. Same trade as the binary-cache list in
  # flake.nix and modules/baseline.nix: two copies, and they must agree.
  ageRecipient = "age1cl5fnqpulemu5gnf2ws3y7smjp70xcaa2xlsg8xsv4ss02v0t9dqt9j56c";

  # GitHub's published host keys, from https://api.github.com/meta, pinned
  # rather than accepted on first use. A backup job that trusts whatever
  # answers on port 22 is a backup job that can be pointed elsewhere.
  knownHosts = pkgs.writeText "github-known-hosts" ''
    github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl
  '';

  keyPath = config.sops.secrets.unifi-backup-deploy-key.path;

  push = pkgs.writeShellApplication {
    name = "unifi-backup-push";
    runtimeInputs = with pkgs; [
      age
      coreutils
      findutils
      git
      openssh
    ];
    text = ''
      export GIT_SSH_COMMAND="ssh -i ${keyPath} -o IdentitiesOnly=yes \
        -o UserKnownHostsFile=${knownHosts} -o StrictHostKeyChecking=yes \
        -o HostKeyAlgorithms=ssh-ed25519"

      # Newest autobackup, not a named one: the controller rotates these and
      # the filename carries a timestamp that is its own, not ours.
      newest=$(find ${backupDir} -maxdepth 1 -name '*.unf' -printf '%T@ %p\n' 2>/dev/null \
        | sort -rn | head -1 | cut -d' ' -f2- || true)

      if [ -z "''${newest}" ]; then
        echo "no .unf in ${backupDir}." >&2
        echo "The controller's own backup schedule is what fills it:" >&2
        echo "  Settings > System > Backups. See docs/unifi.md." >&2
        exit 1
      fi

      hash=$(sha256sum "''${newest}" | cut -d' ' -f1)

      cd ${workDir} || exit 1
      if [ ! -d repo/.git ]; then
        git clone --branch ${branch} ${repoUrl} repo
      fi
      cd repo || exit 1
      git fetch origin ${branch}
      git reset --hard origin/${branch}

      # Compare the *plaintext* hash, not the encrypted blob. This runs daily
      # but the controller writes a new file only when its own schedule fires,
      # and age uses a fresh ephemeral key per run, so the same file encrypts
      # differently every time. Comparing ciphertext would re-commit an
      # already-pushed backup every day.
      if [ -f unifi/latest.sha256 ] && [ "$(cat unifi/latest.sha256)" = "''${hash}" ]; then
        echo "newest backup already pushed (''${hash}); nothing to do"
        exit 0
      fi

      mkdir -p unifi
      age --recipient ${ageRecipient} --output unifi/latest.unf.age "''${newest}"
      printf '%s\n' "''${hash}" > unifi/latest.sha256

      git add unifi
      git -c user.name=core5 -c user.email=core5@nix-config.invalid \
        commit -m "unifi: controller state $(date -u +%Y-%m-%d)"
      git push origin ${branch}
      echo "pushed ''${hash}"
    '';
  };
in
{
  # Declared here with no `sopsFile`; see the note in modules/adguardhome.nix.
  # Owned by the host user because the unit runs as that user: the backup
  # directory is 0750 core5:users and root is not what needs to read it.
  sops.secrets.unifi-backup-deploy-key = {
    owner = hostname;
    mode = "0400";
  };

  systemd.services.unifi-backup = {
    description = "Push the UniFi controller's newest backup off-box";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];

    serviceConfig = {
      Type = "oneshot";
      User = hostname;

      # systemd creates and owns this, so nothing here needs a tmpfiles rule.
      StateDirectory = "unifi-backup";
      WorkingDirectory = workDir;

      ExecStart = lib.getExe push;

      # ProtectHome below makes /home unreachable, and both git and ssh want a
      # HOME they can read. Unset, git warns and ssh looks in / for a config.
      Environment = [ "HOME=${workDir}" ];

      # Hardening. Reads one directory, writes one, and talks to GitHub.
      NoNewPrivileges = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
      ProtectKernelTunables = true;
      ProtectControlGroups = true;
      RestrictNamespaces = true;
      RestrictSUIDSGID = true;
      ReadOnlyPaths = [ backupDir ];
    };
  };

  # Daily, and deliberately later than any sensible controller backup time.
  # The ordering is a soft dependency rather than a real one: if the
  # controller has not written a new file yet, the hash check makes this a
  # no-op and the change is picked up the next day. A one-day lag on config
  # that changes a few times a year is not worth a tighter coupling.
  systemd.timers.unifi-backup = {
    description = "Daily off-box push of the UniFi controller's backup";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "05:00";
      RandomizedDelaySec = "20m";
      Persistent = true;
    };
  };
}
