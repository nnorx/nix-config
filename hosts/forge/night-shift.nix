# The night shift: Nick queues issues in Linear, and background Claude Code
# agents on forge work them into PR handoffs while he is away from the desk.
# hosts/forge/night-shift.sh is the dispatcher; docs/night-shift.md is how to
# set it up and use it.
#
# A user timer, so it runs only while forge is awake and Nick is logged in,
# with Persistent catching up after sleep. Each run takes finished work back to
# Linear and starts what is queued, at most `max` agents at a time.
#
# The agents are the same as any `claude --bg` session: Nick's settings, his
# sandbox, his auto mode, and `claude agents` or `claude attach` to look in on
# them. What is new is a credential, the Linear key. The dispatcher runs
# outside the sandbox and is the only thing that reads it; hosts/forge/claude.nix
# keeps /run/secrets.d, where sops-nix puts it, out of every sandboxed command
# and Claude's own Read. A key that leaks costs Linear issues, not code: it
# cannot push, merge or deploy, which is why one is acceptable here where a
# GitHub token is not (CLAUDE.md, "Deploying and merging").
#
# Secrets, in secrets/forge.yaml, both owned by nick since the timer is his:
#
#   linear-api-key  A personal API key. It acts as Nick, so Linear does not
#                   notify him of what the night shift writes; ntfy does.
#   ntfy-url        The fleet's topic (modules/alerts.nix), for a push when an
#                   issue is ready or needs him, and when runs keep failing.
#
# Evaluation fails until both exist (modules/sops-assertions.nix), rather than
# sops-nix failing the build after merge.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  user = "nick";
  home = config.users.users.${user}.home;
  secrets = [
    "linear-api-key"
    "ntfy-url"
  ];

  # Hidden from preflight on an agent's branch, which evaluates code the agent
  # wrote. Claude's sandbox policy, taken from the same file so the two cannot
  # drift, plus forge's sops secrets (claude.nix) and Nick's credentials:
  # evaluation runs with the network on, so nothing it could read and send
  # may be readable.
  policy = import ../../lib/claude-sandbox.nix {
    inherit lib;
    isDarwin = false;
  };
  hidden =
    policy.strict.filesystem.denyRead
    ++ map (c: c.path) policy.strict.credentials.files
    ++ [
      "/run/secrets.d"
      "~/.ssh"
      "~/.claude/.credentials.json"
      "~/.config/gh"
      "~/.git-credentials"
      "~/.local/share/kwalletd"
    ];

  night-shift = pkgs.writeShellApplication {
    name = "night-shift";
    runtimeInputs = [
      config.nix.package
      pkgs.git
      pkgs.jq
      pkgs.curl
      pkgs.coreutils
      pkgs.gnused
      pkgs.gawk
      pkgs.gnugrep # -P, for the hidden-character check on drafts
      pkgs.util-linux # flock
      pkgs.bubblewrap # preflight on an agent's branch, confined
      config.systemd.package # systemd-run, to start claude outside the unit
    ];
    runtimeEnv = {
      NIGHT_SHIFT_HIDE = lib.concatLines hidden;
      NIGHT_SHIFT_KEY_FILE = config.sops.secrets.linear-api-key.path;
      NIGHT_SHIFT_NTFY_FILE = config.sops.secrets.ntfy-url.path;
      NIGHT_SHIFT_PROJECTS = "${home}/projects";
      NIGHT_SHIFT_MAX = "2";
      NIGHT_SHIFT_STALL_HOURS = "4";
      NIGHT_SHIFT_FAILED_RUNS = "3";
    };
    text = builtins.readFile ./night-shift.sh;
  };
in
{
  sops.secrets = lib.genAttrs secrets (_: {
    owner = user;
  });

  # `night-shift check` and `night-shift status` from a shell, too.
  environment.systemPackages = [ night-shift ];

  # System aliases, like nrs and nrb in modules/baseline.nix, since the command
  # exists only on forge.
  environment.shellAliases = {
    ns = "night-shift";
    nsr = "night-shift run";
    nss = "night-shift status";
    nsf = "night-shift file";
  };

  systemd.user.services.night-shift = {
    description = "Take finished night-shift work back to Linear and start what is queued";
    unitConfig.ConditionUser = user;
    # The agents inherit this PATH, and a unit's `path` replaces the user
    # manager's, so it carries what a login shell has: setuid wrappers, the
    # user and system profiles, and ~/.local/bin, where Claude Code's own
    # installer puts it. Each entry gains /bin.
    path = [
      "/run/wrappers"
      "${home}/.local"
      "/etc/profiles/per-user/${user}"
      "/run/current-system/sw"
    ];
    # A rebuild would otherwise stop a run mid-preflight and start a new one,
    # and hold the switch until it finished. The timer's next run picks up the
    # new version.
    restartIfChanged = false;
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${lib.getExe night-shift} run";
      # A run that finishes agents waits on preflight, minutes per issue.
      TimeoutStartSec = "1h";
      # KillMode stays the default, so a run ends whole, its children with it.
      # The agents outlive it because the dispatcher starts claude in a scope
      # of its own (`cl` in night-shift.sh), outside this unit's cgroup.
      # Counts runs that failed, however they ended, and pushes when they
      # keep failing (after_run in night-shift.sh).
      ExecStopPost = "${lib.getExe night-shift} _after";
    };
  };

  systemd.user.timers.night-shift = {
    wantedBy = [ "timers.target" ];
    unitConfig.ConditionUser = user;
    timerConfig = {
      OnCalendar = "*:0/10";
      Persistent = true;
    };
  };
}
