# What preflight's flake check evaluates (scripts/preflight.sh, step 3): what
# `nix flake check --all-systems --no-build` would, but for the hosts, whose
# toplevels step 4 evaluates in full. One nix process keeps everything it has
# evaluated, so preflight evaluates each piece in a process of its own.
#
# Without `only`, the pieces' names. Every evaluation of this fails on an
# output it does not know, so a new kind of output is never left unchecked.
{
  ref,
  only ? null,
}:
let
  flake = builtins.getFlake ref;
  inherit (flake) outputs;
  inherit (flake.inputs.nixpkgs) lib;

  drv = name: d: if lib.isDerivation d then d.drvPath else throw "${name} is not a derivation";
  # The program's string context carries its derivation, so this evaluates it.
  app =
    name: a:
    if a.type or null == "app" && lib.hasPrefix "${builtins.storeDir}/" a.program then
      a.program
    else
      throw "${name} is not an app with a program in the store";

  # One piece per attribute: a VM test alone holds a gigabyte or more.
  each =
    out:
    lib.concatMapAttrs (
      system:
      lib.mapAttrs' (n: v: lib.nameValuePair "${out}.${system}.${n}" (drv "${out}.${system}.${n}" v))
    ) outputs.${out};

  pieces =
    each "checks"
    // each "packages"
    // {
      apps = lib.mapAttrs (s: lib.mapAttrs (n: app "apps.${s}.${n}")) outputs.apps;
      formatter = lib.mapAttrs (s: drv "formatter.${s}") outputs.formatter;
    };

  # Step 4 evaluates the hosts' toplevels and the Home Manager configs, and
  # flake check leaves legacyPackages unevaluated.
  elsewhere = [
    "nixosConfigurations"
    "homeConfigurations"
    "legacyPackages"
  ];
  unknown = lib.subtractLists (
    elsewhere
    ++ [
      "checks"
      "packages"
      "apps"
      "formatter"
    ]
  ) (builtins.attrNames outputs);
in
if unknown != [ ] then
  throw "preflight checks no flake output ${lib.concatStringsSep ", " unknown}: add it to scripts/preflight-outputs.nix"
else if only == null then
  builtins.attrNames pieces
else
  pieces.${only}
