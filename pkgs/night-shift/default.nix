# The night-shift dispatcher (night-shift.sh), for its two hosts: forge's
# systemd unit (hosts/forge/night-shift.nix) and a Mac's launchd agent
# (home/night-shift.nix). Each passes its own environment, which picks the
# mode and the platform, and forge adds the tools only it calls.
{
  lib,
  stdenv,
  writeShellApplication,
  git,
  jq,
  curl,
  coreutils,
  gnused,
  gawk,
  gnugrep,
  util-linux,
  flock,
  extraRuntimeInputs ? [ ],
  runtimeEnv ? { },
}:
writeShellApplication {
  name = "night-shift";
  runtimeInputs = [
    git
    jq
    curl
    # GNU's, on macOS too: date -d and -r, timeout --foreground.
    coreutils
    gnused
    gawk
    gnugrep # -P, for the hidden-character check on drafts
    # flock. util-linux is built for Linux first, so the portable one on
    # macOS, as preflight does for the tests (flake.nix).
    (if stdenv.hostPlatform.isLinux then util-linux else flock)
  ]
  ++ extraRuntimeInputs;
  inherit runtimeEnv;
  text = builtins.readFile ./night-shift.sh;
  meta.platforms = lib.platforms.unix;
}
