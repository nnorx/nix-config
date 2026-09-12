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
      gnused
      openssh
    ];
    text = ''
      # Keepalives, so a stalled connection ends the push instead of hanging
      # it. The unit's TimeoutStartSec is the outer bound; this is what makes a
      # dead TCP session fail in a minute rather than at that bound.
      export GIT_SSH_COMMAND="ssh -i ${keyPath} -o IdentitiesOnly=yes \
        -o UserKnownHostsFile=${knownHosts} -o StrictHostKeyChecking=yes \
        -o HostKeyAlgorithms=ssh-ed25519 \
        -o ConnectTimeout=30 -o ServerAliveInterval=15 -o ServerAliveCountMax=4"

      # Listing failures and an empty listing are different faults with
      # different fixes, so they are reported apart. find's own error (missing
      # directory, permission denied) reaches the journal above this message
      # rather than being folded into advice about the schedule.
      if ! listing=$(find ${backupDir} -maxdepth 1 -name '*.unf' -mmin +2 -printf '%T@ %p\n'); then
        echo "cannot list ${backupDir} as $(id -un); the error above is the cause." >&2
        echo "A missing directory means the controller has not started since a reset." >&2
        exit 1
      fi

      # Newest autobackup, not a named one: the controller rotates these and
      # the filename carries a timestamp that is its own. `-mmin +2` above
      # skips a file the controller may still be writing.
      newest=$(printf '%s\n' "''${listing}" | sort -rn | sed -n '1s/^[^ ]* //p')

      if [ -z "''${newest}" ]; then
        echo "no .unf older than two minutes in ${backupDir}." >&2
        echo "The controller's own backup schedule is what fills it:" >&2
        echo "  Settings > System > Backups. See docs/unifi.md." >&2
        exit 1
      fi

      # One read of the live file. Hashing and encrypting it separately would
      # read it twice, and the hash recorded could describe a different file
      # from the one pushed.
      snapshot=$(mktemp)
      trap 'rm -f "''${snapshot}"' EXIT
      cp "''${newest}" "''${snapshot}"
      hash=$(sha256sum "''${snapshot}" | cut -d' ' -f1)

      # Repeats WorkingDirectory= on purpose, so the script also runs by hand.
      cd ${workDir}
      if [ ! -d repo/.git ]; then
        git clone --branch ${branch} ${repoUrl} repo
      fi
      cd repo
      git fetch origin ${branch}
      git reset --hard origin/${branch}

      # reset does not touch untracked files. A first run killed between
      # writing unifi/ and committing it leaves a latest.sha256 that matches
      # the newest backup, and without this every later run would read it,
      # report "already pushed", and exit 0 while nothing ever left the host.
      git clean -fdx

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
      age --recipient ${ageRecipient} --output unifi/latest.unf.age "''${snapshot}"
      printf '%s\n' "''${hash}" > unifi/latest.sha256

      git add unifi
      git -c user.name=${hostname} -c user.email=${hostname}@nix-config.invalid \
        commit -m "unifi: controller state $(date -u +%Y-%m-%d)"
      git push origin ${branch}
      echo "pushed ''${hash}"
    '';
  };
in
{
  # Declared here with no `sopsFile`; see the note in modules/adguardhome.nix.
  # Owned by the host user because the unit runs as that user. The
  # controller's config volume is 0750 and owned by that user (see
  # modules/unifi.nix), so root is not what needs to read it.
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

      # Oneshot units have no start timeout unless one is set, and a timer will
      # not start a unit that is still active. Without this a hung push would
      # sit in "activating" forever and every later backup would silently not
      # happen. A 30 KB push takes seconds; this is only the backstop.
      TimeoutStartSec = "15min";

      # systemd sets HOME to the account's home for User= services, and
      # ProtectHome below makes that unreachable. git reads its global config
      # from $HOME, so it is pointed somewhere it can read. ssh is unaffected
      # either way: it resolves ~ from the passwd entry rather than $HOME, and
      # is handed its key and known_hosts explicitly.
      Environment = [ "HOME=${workDir}" ];

      # Hardening. ProtectSystem=strict leaves everything read-only except the
      # StateDirectory, which is all this needs: it reads the backup directory
      # and writes only its own working copy.
      NoNewPrivileges = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
      ProtectKernelTunables = true;
      ProtectControlGroups = true;
      RestrictNamespaces = true;
      RestrictSUIDSGID = true;
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
