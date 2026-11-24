# pr-handoff, TypeScript run on Node, which strips the types. preflight
# type-checks it and runs tests/pr-handoff/ against it. home/pr-handoff.nix
# says what it is for.
{
  lib,
  writeShellApplication,
  gh,
  git,
  gnugrep,
  less,
  nodejs_24,
}:
let
  # Rooted at pkgs/, for the color and framing it shares with night-shift.
  src = lib.fileset.toSource {
    root = ../.;
    fileset = lib.fileset.unions [
      ./package.json
      ./src
      ../night-shift/package.json
      ../night-shift/src/style.ts
    ];
  };
in
writeShellApplication {
  name = "pr-handoff";
  runtimeInputs = [
    gh
    git
    gnugrep
    less # the `d` answer pages the diff
    nodejs_24
  ];
  text = ''exec node ${src}/pr-handoff/src/main.ts "$@"'';
  meta.platforms = lib.platforms.unix;
}
