# Claude Code configuration.
#
# Plugin marketplaces are pinned as flake inputs, so each lands in the store as
# a plain source path. Declaring them here as "directory" sources means Claude
# Code registers them during startup with no imperative `claude plugin`
# commands on a new machine, and with no network access. Claude only ever reads
# a marketplace path, so a read-only store path is safe.
#
# Third-party skills are consumed upstream this way rather than vendored into
# nnorx/claude-plugins, so `nix flake update <input>` is the whole update path.
#
# settings.json is written as a real file rather than linked from the store,
# because Claude Code rewrites the whole file itself: /model, /config and the
# plugin commands all do. Against a read-only store symlink those writes fail,
# which left editing this file and re-switching as the only way to change
# model. The merge below keeps the declarative half without costing that.
#
#   managed   Nix owns outright, rewritten on every switch. Marketplace paths
#             are store paths that move on `nix flake update`, plugin
#             enablement is meant to be declarative, and the sandbox and the
#             Read deny list are a security boundary, so a value that drifts
#             here is a bug rather than a preference.
#
#             This file is one settings scope among several. /sandbox writes
#             to the project's .claude/settings.local.json, which outranks
#             it, so a sandbox switched off there stays off for that project
#             until the entry is removed. On forge, hosts/forge/claude.nix
#             puts the same policy in managed settings, which nothing
#             outranks.
#
#   defaults  Seeded only when the key is absent, so a fresh machine comes up
#             on opus/xhigh and afterwards /model owns the value.
#
# Everything else Claude Code stores here is carried through untouched.

{
  config,
  pkgs,
  lib,
  claudeMarketplaces,
  ...
}:
let
  # nix's caches for commands in the sandbox, apart from ~/.cache/nix. See
  # filesystem.allowWrite below.
  sandboxNixCache = "${config.home.homeDirectory}/.cache/nix-sandbox";

  # The boundary itself: strict mode and the age key denied. Shared with the
  # managed settings on forge so the two cannot drift apart.
  policy = import ../lib/claude-sandbox.nix {
    inherit lib;
    isDarwin = pkgs.stdenv.isDarwin;
  };

  managed = {
    extraKnownMarketplaces = lib.mapAttrs (_name: src: {
      source = {
        source = "directory";
        path = "${src}";
      };
    }) claudeMarketplaces;

    # "<plugin>@<marketplace>". The marketplace half must match the `name`
    # field in that marketplace's .claude-plugin/marketplace.json, NOT the
    # attribute key above. A mismatch fails with a misleading
    # "Plugin not found".
    enabledPlugins = {
      "core@nnorx" = true;
      "improve@improve" = true;
    };

    # The sandbox does not cover Claude's own Read tool, and the Mac has no
    # sandbox; this rule costs nothing there.
    permissions.deny = map (dir: "Read(${dir}/**)") policy.keyDirs;
  }
  # Linux only. The sandbox is there to keep the sops key from commands, and
  # the Mac does not hold it, so there it would only break work repos'
  # tooling and the hooks they run inside it. del(.sandbox) in the merge below
  # clears what an earlier generation left.
  // lib.optionalAttrs pkgs.stdenv.isLinux {
    # lib/claude-sandbox.nix says what the sandbox denies. This adds how
    # commands are approved and what they may reach. Both set `filesystem`,
    # so the merge is recursive.
    sandbox = lib.recursiveUpdate policy.strict {
      # On by default, it would run every sandboxed command unprompted,
      # `gh pr merge` included once github.com is allowed. The sandbox only
      # adds containment; approval stays as it was.
      autoAllowBashIfSandboxed = false;

      # Hosts that commands reach themselves: flake inputs, the flake registry
      # and `nix path-info --store`. Substitution goes through nix-daemon,
      # outside the sandbox. Anything else is decided per command.
      #
      # This keeps commands to known hosts but does not contain them. A
      # fixed-output derivation builds in nix-daemon with the host's network,
      # and the daemon takes one from any user, so a command can send what it
      # can read anywhere by building one. Nix cannot limit that for an
      # untrusted user short of taking the build users off the network, which
      # breaks every build of a source no cache has. The boundary is what
      # commands cannot read (lib/claude-sandbox.nix).
      #
      # nix talks to the daemon over a Unix socket, and the Linux sandbox
      # blocks every Unix socket with a seccomp filter bundled in the binary.
      # The per-path list is ignored there, so the only way to reach the
      # daemon is to open them all, Docker's included on a host whose user is
      # in the docker group (hosts/forge/claude.nix).
      network = {
        allowedDomains = [
          "github.com"
          "api.github.com"
          "codeload.github.com"
          "channels.nixos.org"
          "nnorx-nix-config.cachix.org"
        ];
        allowAllUnixSockets = true;
      };

      # Commands may write only under the working directory and $TMPDIR. nix
      # needs a writable cache directory, or every fetch of a new source fails
      # and every evaluation logs an ignored error. It gets its own, because
      # ~/.cache/nix is trusted by the nix that runs outside: a command that
      # adds a derivation through the daemon and points a cached drvPath at it
      # makes the next `nix build` of that attribute, `hms` included, build
      # the command's derivation instead of the checkout's, and activate it.
      # Tried on a scratch flake. See also .gitmodules.
      filesystem.allowWrite = [ sandboxNixCache ];

      # Plain ssh ignores the sandbox's proxy, so it reaches nothing from
      # inside. fleet-ssh (home/ssh.nix) is the one command that runs
      # outside: it takes a fleet host and a remote command and fixes
      # everything else. `ssh *` would not be safe here, because ProxyCommand
      # and LocalCommand run an arbitrary local command, unsandboxed.
      excludedCommands = [ "fleet-ssh *" ];
    };

    # Points nix in Claude Code's commands at the cache above. A key under
    # `env` rather than all of it, so variables set by hand survive.
    env.NIX_CACHE_HOME = sandboxNixCache;
  };

  defaults = {
    model = "opus";
    effortLevel = "xhigh";
    switchModelsOnFlag = false;
  };
in
{
  # The Bash sandbox's backend on Linux; macOS uses its built-in sandbox-exec.
  # `claude plugin eval` refuses to grant a shell tool without it, and its child
  # agents run commands through the login shell, so an ad-hoc `nix shell` is
  # not enough: they have to be on the profile's PATH.
  home.packages = lib.optionals pkgs.stdenv.isLinux [
    pkgs.bubblewrap
    pkgs.socat
  ];

  # No repository's .git/hooks ever runs. The sandbox lets a command write
  # there (it protects .git/config, not hooks), and a hook runs on the next
  # commit made outside it, with access to the sops key. Here rather than in
  # git.nix, which the fleet imports too, and Linux only, like the sandbox:
  # work repos on the Mac use hooks. A repo that needs them can set its own
  # core.hooksPath, since .git/config is out of a command's reach.
  programs.git.settings.core.hooksPath = lib.mkIf pkgs.stdenv.isLinux "${pkgs.emptyDirectory}";

  home.activation.claudeSettings = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
    settings="$HOME/.claude/settings.json"
    mkdir -p "$HOME/.claude"
    ${lib.optionalString pkgs.stdenv.isLinux "mkdir -p ${lib.escapeShellArg sandboxNixCache}"}

    # Earlier generations linked this path into the store. linkGeneration drops
    # that symlink when it is the one Home Manager wrote, but clear it here too
    # so a hand-made link cannot make the write below land in /nix/store.
    if [ -L "$settings" ]; then
      rm -f "$settings"
    fi

    # Anything unparseable is treated as absent rather than failing the switch,
    # which would otherwise leave the whole activation half-applied.
    existing='{}'
    if [ -f "$settings" ] && ${pkgs.jq}/bin/jq -e . "$settings" >/dev/null 2>&1; then
      existing="$(cat "$settings")"
    fi

    # `*` merges objects but replaces arrays, so a managed object must be
    # deleted first or its stale keys survive. A managed array is replaced
    # either way, and is listed so what is managed can be read off here.
    printf '%s' "$existing" | ${pkgs.jq}/bin/jq -S \
      --argjson defaults ${lib.escapeShellArg (builtins.toJSON defaults)} \
      --argjson managed ${lib.escapeShellArg (builtins.toJSON managed)} \
      '$defaults * del(.extraKnownMarketplaces, .enabledPlugins, .sandbox, .permissions.deny) * $managed' \
      > "$settings.next"
    mv "$settings.next" "$settings"
  '';
}
