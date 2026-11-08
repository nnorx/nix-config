# The night-shift dispatcher, for its two hosts: forge's systemd unit
# (hosts/forge/night-shift.nix) and a Mac's launchd agent
# (home/night-shift.nix). Each passes its own environment, which picks the
# mode and the platform, and forge adds the tools only it calls.
#
# night-shift.sh is the entry point; check, status and file are TypeScript
# (src/), run on Node, which strips the types. preflight type-checks them.
{
  lib,
  stdenv,
  writeShellApplication,
  bash,
  git,
  jq,
  curl,
  coreutils,
  gnused,
  gawk,
  gnugrep,
  util-linux,
  flock,
  nodejs_24,
  extraRuntimeInputs ? [ ],
  runtimeEnv ? { },
}:
let
  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./package.json
      ./src
      ./work-fields.graphql
    ];
  };
in
writeShellApplication {
  name = "night-shift";
  runtimeInputs = [
    # For NIGHT_SHIFT_KEY_CMD, which src/linear.ts runs.
    bash
    git
    jq
    curl
    # GNU's, on macOS too: date -d and -r, timeout --foreground.
    coreutils
    gnused
    gawk
    gnugrep
    # flock. util-linux is built for Linux first, so the portable one on
    # macOS, as preflight does for the tests (pkgs/preflight).
    (if stdenv.hostPlatform.isLinux then util-linux else flock)
    nodejs_24
  ]
  ++ extraRuntimeInputs;
  runtimeEnv = {
    NIGHT_SHIFT_TS = "${src}/src/main.ts";
  }
  // runtimeEnv;
  text = builtins.readFile ./night-shift.sh;
  meta.platforms = lib.platforms.unix;
}
