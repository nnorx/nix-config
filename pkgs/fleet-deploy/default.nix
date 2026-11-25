# fleet-deploy, TypeScript run on Node, which strips the types. preflight
# type-checks it and runs tests/fleet-deploy/ against it.
# home/fleet-deploy.nix says what it is for.
{
  lib,
  writeShellApplication,
  coreutils,
  curl,
  openssh,
  nodejs_24,
  deployKey,
}:
let
  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./package.json
      ./src
    ];
  };
in
writeShellApplication {
  name = "fleet-deploy";
  # nix and git are the ones on PATH, as for preflight, so they talk to the
  # daemon and the checkout the way everything else on the machine does.
  runtimeInputs = [
    coreutils
    curl
    openssh
    nodejs_24
  ];
  runtimeEnv.FLEET_DEPLOY_KEY = deployKey;
  text = ''exec node ${src}/src/main.ts "$@"'';
  meta.platforms = lib.platforms.linux;
}
