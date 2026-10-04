# Pushes the newest backup an application already wrote to the private
# `homelab-state` repo, age-encrypted. Each `offboxPush.<unit>` is one daily
# oneshot named after its attribute; modules/unifi-backup.nix and
# modules/home-assistant-backup.nix say why each application gets one.
#
# Nothing here makes a backup. Each application writes its own, in the format
# its own restore flow expects, and a second path into a database whose
# migrations are one-way is worse than none. The job is only to get the file
# off the host that holds the original.
#
# Encrypted with age before it leaves the host, which makes the destination
# untrusted by construction: these files carry credentials, and a private repo
# is still a copy outside the house. age needs only the *public* half to
# encrypt, so core5 holds nothing that could read these back. The private half
# lives in the password manager and ~/.config/sops/age.
{
  config,
  pkgs,
  lib,
  hostname,
  ...
}:
let
  cfg = config.offboxPush;

  repoUrl = "git@github.com:nnorx/homelab-state.git";
  branch = "main";

  # The `nick` recipient, read from its anchor in .sops.yaml so there is one
  # copy. Nix has no YAML parser, but the anchor line is plain text. Anything
  # other than exactly one match fails evaluation, rather than encrypting the
  # backups to a key nobody holds.
  ageRecipient =
    let
      matches = lib.filter lib.isList (
        builtins.split "&nick (age1[0-9a-z]+)" (builtins.readFile ../.sops.yaml)
      );
    in
    if lib.length matches == 1 then
      lib.head (lib.head matches)
    else
      throw "modules/offbox-push.nix: expected one `&nick age1...` anchor in .sops.yaml, found ${toString (lib.length matches)}";

  # GitHub's published host keys, from https://api.github.com/meta, pinned
  # rather than accepted on first use. A backup job that trusts whatever
  # answers on port 22 is a backup job that can be pointed elsewhere.
  knownHosts = pkgs.writeText "github-known-hosts" ''
    github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl
  '';

  # One deploy key for every job: it is core5's key to one repo, so a second
  # key would add a secret without separating anything. The name predates the
  # second job and stays, since renaming it means re-keying the sops file.
  keyPath = config.sops.secrets.unifi-backup-deploy-key.path;

  # A hint to stderr, one argument per line. A single command, because Nix
  # does not re-indent an interpolated string past its first line.
  echoLines =
    text:
    "printf '%s\\n' ${
      lib.concatMapStringsSep " " lib.escapeShellArg (lib.splitString "\n" (lib.removeSuffix "\n" text))
    } >&2";

  # In the unit's PrivateTmp, which the stage step and the push share and
  # systemd deletes when the unit stops. The push removes it too, but a push
  # killed by its timeout or a reboot never runs its trap, and a plaintext copy
  # in the StateDirectory would outlive it.
  stagedPath = job: "/tmp/staged.${job.extension}";

  # RandomizedDelaySec, in minutes, so the reboot-window assertion can count it.
  randomDelayMin = 20;

  # "HH:MM" to minutes after midnight. toIntBase10, since toInt refuses "07".
  minutesOf = t: lib.toIntBase10 (lib.substring 0 2 t) * 60 + lib.toIntBase10 (lib.substring 3 2 t);

  # Finds the newest backup and leaves its path in `newest`, or exits with the
  # reason. Runs in the push itself, or in the stage step for a job whose
  # files only root can read.
  select =
    job:
    ''
      # Listing failures and an empty listing are different faults with
      # different fixes, so they are reported apart. find's own error (missing
      # directory, permission denied) reaches the journal above this message
      # rather than being folded into advice about the schedule.
      if ! listing=$(find ${job.sourceDir} -maxdepth 1 -name '${job.pattern}' -mmin +2 -printf '%T@ %p\n'); then
        echo "cannot list ${job.sourceDir} as $(id -un); the error above is the cause." >&2
        ${echoLines job.missingHint}
        exit 1
      fi

      # Newest file, not a named one: the application rotates these and the
      # filename carries a timestamp that is its own. `-mmin +2` above skips a
      # file the application may still be writing.
      newest=$(printf '%s\n' "''${listing}" | sort -rn | sed -n '1s/^[^ ]* //p')

      if [ -z "''${newest}" ]; then
        echo "no ${job.pattern} older than two minutes in ${job.sourceDir}." >&2
        ${echoLines job.emptyHint}
        exit 1
      fi
    ''
    + lib.optionalString (job.maxMiB != null) ''

      # Every version stays in the repo's history for good, and GitHub refuses
      # any file over 100 MB, so an oversized backup is refused here, with its
      # cause and before anything reads it, rather than by the push.
      size=$(stat -c %s "''${newest}")
      if [ "''${size}" -gt ${toString (job.maxMiB * 1024 * 1024)} ]; then
        echo "''${newest} is ''${size} bytes, over the ${toString job.maxMiB} MiB limit." >&2
        ${lib.optionalString (job.oversizeHint != "") (echoLines job.oversizeHint)}
        exit 1
      fi
    '';

  runtimeInputs = with pkgs; [
    coreutils
    findutils
    gnused
  ];

  # Root's whole part in a staged job: copy one file to where the job's user
  # can read it. No network, no git, and the unit's sandboxing still applies.
  mkStage =
    name: job:
    pkgs.writeShellApplication {
      name = "${name}-stage";
      inherit runtimeInputs;
      text = select job + ''

        # Through a temporary name, so the push never reads a partial copy.
        install -o ${job.user} -m 0400 "''${newest}" ${stagedPath job}.tmp
        mv ${stagedPath job}.tmp ${stagedPath job}
      '';
    };

  mkPush =
    name: job:
    let
      workDir = "/var/lib/${name}";
      latest = "${job.repoDir}/latest.${job.extension}";
    in
    pkgs.writeShellApplication {
      name = "${name}-push";
      runtimeInputs = runtimeInputs ++ [
        pkgs.age
        pkgs.git
        pkgs.openssh
      ];
      text = ''
        # Keepalives, so a stalled connection ends the push instead of hanging
        # it. The unit's TimeoutStartSec is the outer bound; this is what makes a
        # dead TCP session fail in a minute rather than at that bound.
        export GIT_SSH_COMMAND="ssh -i ${keyPath} -o IdentitiesOnly=yes \
          -o UserKnownHostsFile=${knownHosts} -o StrictHostKeyChecking=yes \
          -o HostKeyAlgorithms=ssh-ed25519 \
          -o ConnectTimeout=30 -o ServerAliveInterval=15 -o ServerAliveCountMax=4"

        export GIT_AUTHOR_NAME=${hostname} GIT_COMMITTER_NAME=${hostname}
        export GIT_AUTHOR_EMAIL=${hostname}@nix-config.invalid GIT_COMMITTER_EMAIL=${hostname}@nix-config.invalid

      ''
      + (
        if job.stage then
          ''
            # The stage step put it here, readable by this user, and it is
            # this run's to remove. Only the unit runs that step, so run by
            # hand there is nothing here to push.
            snapshot=${stagedPath job}
            if [ ! -f "''${snapshot}" ]; then
              echo "nothing staged at ''${snapshot}. Start ${name}.service rather than this script, so the stage step runs first." >&2
              exit 1
            fi
          ''
        else
          select job
          + ''

            # One read of the live file. Hashing and encrypting it separately
            # would read it twice, and the hash recorded could describe a
            # different file from the one pushed.
            snapshot=$(mktemp)
            cp "''${newest}" "''${snapshot}"
          ''
      )
      + ''
        trap 'rm -f "''${snapshot}"' EXIT
        hash=$(sha256sum "''${snapshot}" | cut -d' ' -f1)

        # Repeats WorkingDirectory= on purpose, so the script also runs by hand,
        # for a job without a stage step.
        cd ${workDir}
        if [ ! -d repo/.git ]; then
          git clone --branch ${branch} ${repoUrl} repo
        fi
        cd repo

        # Twice at most. Jobs share the branch, so another job may push between
        # this one's fetch and its push. The second attempt starts again from
        # the fetched branch rather than rebasing, so no git operation is ever
        # left half-done in the working copy for the next run to trip on.
        for attempt in 1 2; do
          git fetch origin ${branch}
          git checkout --force -B ${branch} origin/${branch}

          # checkout does not touch untracked files. A first run killed between
          # writing ${job.repoDir}/ and committing it leaves a latest.sha256
          # that matches the newest backup, and without this every later run
          # would read it, report "already pushed", and exit 0 while nothing
          # ever left the host.
          git clean -fdx

          # Compare the *plaintext* hash, not the encrypted blob. This runs
          # daily but the application writes a new file only when its own
          # schedule fires, and age uses a fresh ephemeral key per run, so the
          # same file encrypts differently every time. Comparing ciphertext
          # would re-commit an already-pushed backup every day.
          if [ -f ${job.repoDir}/latest.sha256 ] && [ "$(cat ${job.repoDir}/latest.sha256)" = "''${hash}" ]; then
            echo "newest backup already pushed (''${hash}); nothing to do"
            exit 0
          fi

          mkdir -p ${job.repoDir}
          age --recipient ${ageRecipient} --output ${latest}.age "''${snapshot}"
          printf '%s\n' "''${hash}" > ${job.repoDir}/latest.sha256

          git add ${job.repoDir}
          git commit -m "${job.commitSubject} $(date -u +%Y-%m-%d)"
          if git push origin ${branch}; then
            echo "pushed ''${hash}"
            exit 0
          fi
          echo "push attempt ''${attempt} failed" >&2
        done
        exit 1
      '';
    };

  jobType = lib.types.submodule (
    { config, ... }:
    {
      options = {
        description = lib.mkOption {
          type = lib.types.str;
          description = "The service's description.";
        };
        sourceDir = lib.mkOption {
          type = lib.types.str;
          description = "Where the application writes its backups.";
        };
        extension = lib.mkOption {
          type = lib.types.str;
          description = "The backup files' extension, without the dot. Names the copy in the repo.";
        };
        pattern = lib.mkOption {
          type = lib.types.str;
          default = "*.${config.extension}";
          description = "Which files in `sourceDir` are candidates, as a find -name glob.";
        };
        repoDir = lib.mkOption {
          type = lib.types.str;
          description = "Directory in homelab-state. Unique per job, asserted below.";
        };
        commitSubject = lib.mkOption {
          type = lib.types.str;
          description = "Commit subject, before the date.";
        };
        user = lib.mkOption {
          type = lib.types.str;
          description = "Who the push runs as. Must be able to read the deploy key.";
        };
        stage = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = ''
            Whether root copies the backup to `user` first, for an application
            whose files only root can read. Root then never runs git or ssh.
          '';
        };
        at = lib.mkOption {
          type = lib.types.strMatching "([01][0-9]|2[0-3]):[0-5][0-9]";
          description = ''
            Daily start time, HH:MM. Must be after the automatic upgrade's
            reboot window. A bare time, so the assertion below can compare it.
          '';
        };
        missingHint = lib.mkOption {
          type = lib.types.lines;
          description = "Printed when `sourceDir` cannot be listed.";
        };
        emptyHint = lib.mkOption {
          type = lib.types.lines;
          description = "Printed when there is no backup to push.";
        };
        maxMiB = lib.mkOption {
          type = lib.types.nullOr lib.types.ints.positive;
          default = null;
          description = "Refuse backups larger than this, or null for no check.";
        };
        oversizeHint = lib.mkOption {
          type = lib.types.lines;
          default = "";
          description = "Printed when a backup is over `maxMiB`.";
        };
      };
    }
  );
in
{
  options.offboxPush = lib.mkOption {
    type = lib.types.attrsOf jobType;
    default = { };
    description = "Daily off-box pushes of application backups, keyed by unit name.";
  };

  config = lib.mkIf (cfg != { }) {
    # Declared here with no `sopsFile`; see the note in modules/adguardhome.nix.
    # Owned by the host user, which every job's push runs as.
    sops.secrets.unifi-backup-deploy-key = {
      owner = hostname;
      mode = "0400";
    };

    # A push fails loudly, but only into the journal, and a backup that
    # stopped weeks ago is found at the moment it is needed. Every job reports
    # failure as it happens and success every day, so silence alerts too
    # (modules/alerts.nix).
    fleetAlerts.failure = lib.attrNames cfg;
    fleetAlerts.heartbeat = lib.attrNames cfg;

    systemd.services = lib.mapAttrs (name: job: {
      inherit (job) description;
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];

      serviceConfig = {
        Type = "oneshot";
        User = job.user;

        # systemd creates and owns this, so nothing here needs a tmpfiles rule.
        StateDirectory = name;
        WorkingDirectory = "/var/lib/${name}";

        # `!` runs the stage step as root but keeps every sandboxing setting
        # below, where `+` would drop them all.
        ExecStartPre = lib.mkIf job.stage "!${lib.getExe (mkStage name job)}";
        ExecStart = lib.getExe (mkPush name job);

        # Oneshot units have no start timeout unless one is set, and a timer
        # will not start a unit that is still active. Without this a hung push
        # would sit in "activating" forever and every later backup would
        # silently not happen. A push of a few MB takes seconds; this is only
        # the backstop.
        TimeoutStartSec = "15min";

        # systemd sets HOME to the account's home for User= services, and
        # ProtectHome below makes that unreachable. git reads its global config
        # from $HOME, so it is pointed somewhere it can read. ssh is unaffected
        # either way: it resolves ~ from the passwd entry rather than $HOME, and
        # is handed its key and known_hosts explicitly.
        Environment = [ "HOME=/var/lib/${name}" ];

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
    }) cfg;

    # Daily, after the automatic-upgrade reboot window closes. A reboot inside
    # it kills a push mid-way, and because the timer has already fired for that
    # day the off-box copy lags a day. Nothing corrupts, since the next run
    # cleans the working copy, but the assertion below keeps the two apart if
    # the window moves.
    systemd.timers = lib.mapAttrs (name: job: {
      description = "${job.description}, daily";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = job.at;
        RandomizedDelaySec = "${toString randomDelayMin}m";
        Persistent = true;
      };
    }) cfg;

    assertions =
      lib.mapAttrsToList (
        name: job:
        let
          upgrade = config.system.autoUpgrade;
          window = upgrade.rebootWindow;

          # The start can land anywhere from `at` to `at` plus the random
          # delay, so that whole span has to miss the window, not just `at`.
          # A window that spans midnight is not supported.
          start = minutesOf job.at;
          overlaps = start < minutesOf window.upper && start + randomDelayMin >= minutesOf window.lower;
        in
        {
          assertion = !(upgrade.enable && upgrade.allowReboot && window != null && overlaps);
          message = ''
            offboxPush.${name} starts between ${job.at} and ${toString randomDelayMin}
            minutes later, which reaches the automatic upgrade reboot window
            (${window.lower}-${window.upper}). A reboot there kills the push
            mid-way. Move it after the window.
          '';
        }
      ) cfg
      ++ [
        (
          let
            dirs = lib.mapAttrsToList (_: job: job.repoDir) cfg;
          in
          {
            # Each job trusts its own directory's latest.sha256. Two jobs
            # sharing one would overwrite each other's, and each would push
            # every day.
            assertion = lib.length dirs == lib.length (lib.unique dirs);
            message = "offboxPush: each job needs its own repoDir, got ${toString dirs}.";
          }
        )
      ];
  };
}
