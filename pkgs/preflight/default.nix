# `nix run .#preflight`: every check a change needs, and what CI runs. See
# scripts/preflight.sh.
{
  stdenv,
  writeShellApplication,
  git,
  jq,
  coreutils,
  gnused,
  time,
  gawk,
  gnugrep,
  util-linux,
  flock,
}:
writeShellApplication {
  name = "preflight";
  meta.description = "Format, flake check, evaluate every config, and report what a change touches";
  runtimeInputs = [
    git
    jq
    coreutils
    gnused
    # GNU time, for each evaluation's peak memory.
    time
    # The rest for the night-shift dispatcher's tests
    # (tests/night-shift/run.sh), which run it as forge does,
    # and fleet-deploy's (tests/fleet-deploy/run.sh).
    gawk
    gnugrep
    # flock, and script for the case that needs a terminal. On
    # macOS, the portable flock instead, since util-linux is
    # built for Linux first; the terminal case skips there.
    (if stdenv.hostPlatform.isLinux then util-linux else flock)
  ];
  runtimeEnv = {
    PREFLIGHT_EVAL = "${../../scripts/preflight-eval.nix}";
    PREFLIGHT_BRIEF = "${../../scripts/preflight-brief.jq}";
  };
  text = builtins.readFile ../../scripts/preflight.sh;
}
