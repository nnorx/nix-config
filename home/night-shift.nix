# The night shift on a Mac, in work mode: pkgs/night-shift's dispatcher, run
# by launchd every ten minutes against a Linear team Nick shares at work, its
# agents in Claude Code's sandbox. docs/night-shift.md, "On a Mac", is how to
# set it up and use it.
#
# Nix holds what is the same for every repository: the dispatcher, its
# schedule, and the sandbox. What would name the employer, its repositories or
# its Linear team does not belong in this public repo: that is
# ~/.config/night-shift/config.json, written by hand, with the repos'
# setup commands and checks and what each adds to the sandbox. The Linear key
# is in the login keychain.
#
# The Mac's own Claude sessions have no sandbox (home/claude.nix), so the
# night shift's get theirs from the settings below, given with --settings,
# which outranks the user's and every project's. `cld-safe` starts an
# interactive session in the same one.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  home = config.home.homeDirectory;
  policy = import ../lib/claude-sandbox.nix {
    inherit lib;
    isDarwin = pkgs.stdenv.isDarwin;
  };

  # The only place outside a worktree that commands in the sandbox may write:
  # caches of their own, never Nick's, which tools outside it trust (the same
  # reasoning as the nix cache in home/claude.nix).
  cache = "${home}/.cache/night-shift";
  log = "${home}/Library/Logs/night-shift.log";

  # The age key, Nick's credentials, the keychain and the rest of ~/Library
  # (lib/claude-sandbox.nix), and the night shift's own config, which lists
  # the work repositories.
  hidden = policy.keyDirs ++ policy.credentialPaths ++ [ "~/.config/night-shift" ];

  settings = {
    sandbox = lib.recursiveUpdate policy.strict {
      # As on Linux (home/claude.nix): containment, not approval. Auto mode
      # approves what the agents run.
      autoAllowBashIfSandboxed = false;

      # Each of these opens a way out on macOS: Apple Events let `open` and
      # `osascript` drive other apps, Mach lookups reach services that act
      # outside the sandbox, and the weaker modes loosen it. Off is the
      # default, but a key --settings leaves unset comes from the scopes
      # below it, a repository's included, so they are set here.
      allowAppleEvents = false;
      enableWeakerNetworkIsolation = false;
      enableWeakerNestedSandbox = false;

      network = {
        # GitHub without a login. A repository adds the rest in config.json,
        # the package registries its setup and checks need among them, so
        # each reaches only its own.
        allowedDomains = [
          "github.com"
          "codeload.github.com"
        ];
        # No Unix socket at all: Docker's would be root on the machine's VM,
        # and the SSH agent's would sign as Nick. Nothing a check needs.
        allowAllUnixSockets = false;
        allowUnixSockets = [ ];
      };

      # A list, so recursiveUpdate would replace the shared one.
      filesystem.denyRead = policy.strict.filesystem.denyRead ++ hidden;
      filesystem.allowWrite = [ cache ];
    };

    env = {
      UV_CACHE_DIR = "${cache}/uv";
      npm_config_cache = "${cache}/npm";
      # Nothing to sign in with, should a login be within reach anyway, and
      # nothing that waits on a prompt nobody will answer.
      GH_CONFIG_DIR = "/var/empty";
      GIT_TERMINAL_PROMPT = "0";
      SSH_AUTH_SOCK = "";
      # LFS objects come with a login, which the agents have none of. Setup
      # fetched them (work_bootstrap in night-shift.sh).
      GIT_LFS_SKIP_SMUDGE = "1";
    };

    permissions.deny =
      # The sandbox does not cover Claude's own Read tool.
      lib.concatMap (p: [
        "Read(${p})"
        "Read(${p}/**)"
      ]) hidden
      ++ [
        # Not the boundary, which is the sandbox, but no use trying either,
        # and a deny outranks a repository's allow, which might name them.
        "Bash(git push:*)"
        "Bash(gh:*)"
        "Bash(docker:*)"
        "Bash(security:*)"
        "Bash(osascript:*)"
        "Bash(open:*)"
        "Bash(launchctl:*)"
        # Its own settings, in the worktree: commands in the sandbox cannot
        # write them, and neither may Claude's editing tools.
        "Edit(**/.claude/settings*.json)"
        "Write(**/.claude/settings*.json)"
      ];

    # The repo's .mcp.json may list Linear's server, which acts as Nick and
    # could queue work by adding the label. The dispatcher also passes
    # --strict-mcp-config.
    enableAllProjectMcpServers = false;

    # Hooks, the status line and file suggestions run outside the sandbox,
    # with Nick's full access, and a repository's hook may run a script the
    # agent can rewrite. A scalar, so --settings outranks every project.
    disableAllHooks = true;

    # The one plugin the agents use, for its pr-handoff skill. The dispatcher
    # turns off every other plugin any scope enables (work_settings in
    # night-shift.sh), since their LSP servers also run outside the sandbox.
    enabledPlugins."core@nnorx" = true;
  };
  settingsFile = pkgs.writeText "night-shift-settings.json" (builtins.toJSON settings);

  night-shift = pkgs.callPackage ../pkgs/night-shift {
    # merged_pr_gh: whether a PR merged, from a private repository.
    extraRuntimeInputs = [ config.programs.gh.package ];
    runtimeEnv = {
      NIGHT_SHIFT_MODE = "work";
      NIGHT_SHIFT_PLATFORM = "darwin";
      NIGHT_SHIFT_CONFIG = "${home}/.config/night-shift/config.json";
      NIGHT_SHIFT_SETTINGS = "${settingsFile}";
      NIGHT_SHIFT_KEY_CMD = "/usr/bin/security find-generic-password -s night-shift-linear -w";
      NIGHT_SHIFT_PROJECTS = "${home}/projects";
      NIGHT_SHIFT_LOG = log;
      NIGHT_SHIFT_MAX = "2";
      NIGHT_SHIFT_STALL_HOURS = "4";
      NIGHT_SHIFT_FAILED_RUNS = "3";
    };
  };
in
{
  home.packages = [ night-shift ];

  shell-common.aliases = {
    ns = "night-shift";
    nsr = "night-shift run";
    nss = "night-shift status";
    nsres = "night-shift resume";
    # An interactive session in the night shift's sandbox, for a task worth
    # the containment. Plain claude keeps the Mac's usual unsandboxed one,
    # which docker and the dev stack need. Hooks are off here too, but not a
    # repository's plugins, which only the dispatcher turns off.
    cld-safe = "claude --settings ${settingsFile} --strict-mcp-config";
  };

  # The dispatcher also writes the sandbox into each agent's worktree, as
  # .claude/settings.local.json (work_settings in night-shift.sh). Not for
  # the agent to commit.
  programs.git.ignores = [ ".claude/settings.local.json" ];

  home.activation.nightShiftCache = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    mkdir -p ${lib.escapeShellArg cache}
  '';

  # While Nick is logged in and the Mac awake, like forge's user timer; runs
  # missed during sleep come together as one. Each run's agents outlive it
  # because AbandonProcessGroup leaves them be. With no config.json yet, a
  # run does nothing.
  launchd.agents.night-shift = {
    enable = true;
    config = {
      ProgramArguments = [
        (lib.getExe night-shift)
        "_tick"
      ];
      StartInterval = 600;
      RunAtLoad = true;
      ProcessType = "Background";
      AbandonProcessGroup = true;
      # The agents inherit this. ~/.local/bin is where Claude Code's own
      # installer puts it; config.json's `path` adds the repos' tools.
      EnvironmentVariables = {
        HOME = home;
        USER = config.home.username;
        LANG = "en_US.UTF-8";
        PATH = lib.concatStringsSep ":" [
          "${home}/.local/bin"
          "${home}/.nix-profile/bin"
          "/nix/var/nix/profiles/default/bin"
          "/opt/homebrew/bin"
          "/usr/local/bin"
          "/usr/bin"
          "/bin"
          "/usr/sbin"
          "/sbin"
        ];
      };
      StandardOutPath = log;
      StandardErrorPath = log;
    };
  };
}
