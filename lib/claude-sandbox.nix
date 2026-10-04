# The part of Claude Code's sandbox policy that two places write, kept in one
# so the key path and the strict settings cannot drift apart:
#
#   home/claude.nix         user settings: the sandbox on Linux, and a Read
#                           deny on every machine, the Mac included
#   hosts/forge/claude.nix  managed settings, which no other scope outranks
#
# Takes `isDarwin` rather than `pkgs`: this is data, not a module.
{ lib, isDarwin }:
let
  # Where sops looks for the age key that decrypts every host's secrets: the
  # XDG config directory, or on macOS the Application Support directory when
  # XDG_CONFIG_HOME is unset.
  keyDirs = [
    "~/.config/sops"
  ]
  ++ lib.optional isDarwin "~/Library/Application Support/sops";
in
{
  inherit keyDirs;

  # What makes the sandbox a boundary rather than a convenience.
  #
  # failIfUnavailable: without bubblewrap, refuse to start rather than run
  #   every command unsandboxed.
  # allowUnsandboxedCommands: no retrying a failed command outside it.
  # credentials.files: the age key, denied to every process a shell command
  #   starts. A permission rule matches command text, so `nix shell
  #   nixpkgs#sops -c sops -d`, `bash -c` or `builtins.readFile` all walk past
  #   a deny on `sops` or `Read`. The kernel enforces this one, whatever the
  #   process is called.
  # filesystem.denyRead: on Linux every Unix socket is open, so nix can reach
  #   its daemon (home/claude.nix). Reaching the key is then a matter of
  #   finding a socket that runs commands outside the sandbox: the session
  #   bus and systemd's user manager (`systemd-run --user`), the Wayland and
  #   X11 displays (keystrokes into a terminal), VS Code's IPC. They live in
  #   /run/user and /tmp/.X11-unix, which the sandbox mounts empty here.
  #   ~/.ssh/agent holds ssh-agent's socket, which would let any command sign
  #   with Nick's keys and reach GitHub over SSH through the sandbox's proxy.
  #   fleet-ssh runs outside the sandbox and still sees it. A Chromium-based
  #   browser (Brave here) listens in /tmp/org.chromium.Chromium.*, under a
  #   new name each launch, and opens whatever URL a client asks for, in a
  #   browser signed in to Nick's accounts. The sandbox expands the glob each
  #   time a command starts. Abstract sockets need nothing, since commands
  #   get their own network namespace.
  #
  # Not a boundary on what leaves the machine: nix builds run in the daemon,
  # outside all of this (home/claude.nix, network). What holds is what
  # commands cannot read.
  #
  # Linux only: the Mac has no sandbox (home/claude.nix).
  strict = {
    enabled = true;
    failIfUnavailable = true;
    allowUnsandboxedCommands = false;
    credentials.files = map (path: {
      inherit path;
      mode = "deny";
    }) keyDirs;
    filesystem.denyRead = [
      "/run/user"
      "/tmp/.X11-unix"
      "/tmp/org.chromium.Chromium.*"
      "~/.ssh/agent"
    ];
  };
}
