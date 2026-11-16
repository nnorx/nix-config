# exit-bypass: break-glass for a long provider outage. It sends one tunneled
# segment, or the resolvers' recursion, out `wan` for a bounded time, and
# pushes on open and on close. docs/router.md, "Exit tunnel", has when to use
# it; ./exit-bypass.sh has how.
{
  config,
  lib,
  pkgs,
  net,
  segmentOn,
  ...
}:
let
  # After the suppress rule, ahead of ./exit.nix's rules into the exit table.
  priority = 1050;

  ifaceOf = lib.mapAttrs' (iface: segment: lib.nameValuePair segment iface) segmentOn;
  targets =
    lib.genAttrs net.exitSegments (s: "iif ${ifaceOf.${s}}")
    // lib.optionalAttrs net.exitResolvers { resolvers = "fwmark ${toString net.exitMark}"; };

  exit-bypass = pkgs.writeShellApplication {
    name = "exit-bypass";
    runtimeInputs = with pkgs; [
      coreutils
      curl
      gnused
      iproute2
      nftables
      systemd
      util-linux
    ];
    text = ''
      host=${config.networking.hostName}
      priority=${toString priority}
      state=/run/exit-bypass
      ntfy_url=${config.sops.secrets.ntfy-url.path}
      declare -A target=(${
        lib.concatStrings (lib.mapAttrsToList (name: sel: " [${name}]=\"${sel}\"") targets)
      } )
    ''
    + builtins.readFile ./exit-bypass.sh;
  };
  # Ignored if it fails: the ruleset stays, and a bypass not put back fails
  # closed, as `exit-bypass status` then shows.
  restore = "-${lib.getExe exit-bypass} restore";
in
{
  sops.secrets.ntfy-url = { };

  environment.systemPackages = [ exit-bypass ];

  # Loading the ruleset empties the bypass sets while the rules to `main`
  # stay, which would send an open bypass into the leak drop. So each load
  # puts back what is open, or closes it with its push.
  systemd.services.nftables.serviceConfig = {
    ExecStartPost = lib.mkAfter [ restore ];
    ExecReload = lib.mkAfter [ restore ];
  };
}
