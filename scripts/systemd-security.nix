# The exposure score `systemd-analyze security --offline=yes` gives each unit
# named in `units` ("<host>/<unit>"), as one JSON object, for
# scripts/ratchets.sh. A file at `<standIns>/<host>/<unit>` replaces that unit,
# for scripts/test-ratchets-systemd.sh.
#
# Each unit is the text NixOS writes for it, so nothing of the host is built
# and the Pis need no aarch64 builder. Not listed: docker.service, which NixOS
# lays over the package's own file, and the docker-<name> units, which run only
# the docker client. Scored by the systemd of the flake's own nixpkgs.
#
# systemd-analyze wants /run/systemd even offline, and a build has no /run,
# so proot lends it one. proot needs no user namespaces, which CI's runners
# restrict.
{
  ref,
  units,
  standIns ? null,
}:
let
  flake = builtins.getFlake ref;
  pkgs = flake.inputs.nixpkgs.legacyPackages.${builtins.currentSystem};
  text =
    name:
    let
      host = builtins.head (builtins.split "/" name);
      unit = pkgs.lib.removePrefix "${host}/" name;
      config = flake.nixosConfigurations.${host}.config;
    in
    if standIns != null && builtins.pathExists "${standIns}/${name}" then
      builtins.readFile "${standIns}/${name}"
    else if config.systemd.units.${unit}.enable or false then
      builtins.unsafeDiscardStringContext config.systemd.units.${unit}.text
    else
      throw "systemd-security: ${host} has no enabled ${unit}";
in
pkgs.runCommand "systemd-security"
  {
    __structuredAttrs = true;
    units = pkgs.lib.genAttrs units text;
    nativeBuildInputs = [
      pkgs.systemd
      pkgs.proot
      pkgs.jq
    ];
  }
  ''
    mkdir run
    echo '{}' >scores.json
    jq -r '.units | keys[]' "$NIX_ATTRS_JSON_FILE" | while IFS= read -r name; do
      mkdir -p "units/''${name%/*}"
      jq -r --arg n "$name" '.units[$n]' "$NIX_ATTRS_JSON_FILE" >"units/$name"
      proot -b "$PWD/run:/run" systemd-analyze security --offline=yes --no-pager "$PWD/units/$name" >report
      score=$(sed -n 's/^→ Overall exposure level for .*: \([0-9.]*\) .*/\1/p' report)
      if [[ -z $score ]]; then
        cat report
        echo "systemd-security: no score for $name" >&2
        exit 1
      fi
      jq --arg n "$name" --argjson s "$score" '.[$n] = $s' scores.json >scores.next
      mv scores.next scores.json
    done
    mv scores.json "$out"
  ''
