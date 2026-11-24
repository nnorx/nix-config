# sops and its key tools, plus secret-set and secret-check (./secret.sh), which
# write and compare a secret without printing it, as CLAUDE.md asks. forge
# only: it holds the age key.
{ pkgs, ... }:
let
  secret =
    mode:
    pkgs.writeShellApplication {
      name = "secret-${mode}";
      runtimeInputs = with pkgs; [
        sops
        jq
        git
      ];
      text = builtins.readFile ./secret.sh;
    };
in
{
  home.packages = with pkgs; [
    (secret "set")
    (secret "check")
    sops
    age
    ssh-to-age
  ];
}
