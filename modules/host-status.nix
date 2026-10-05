# `host-status`: what this host is running, in a form fleet-status
# (home/ssh.nix) reads from every host at once, and that `fleet-ssh <host>
# host-status` gives one at a time.
#
# The revision is the check that matters. A host that falls back to an older
# root, as core5 did onto its SD card, boots a generation that predates any
# check added since, so nothing on the host can notice. Its revision is still
# what it is, and fleet-status compares it with main from outside.
#
# Read-only, needs no root, and prints nothing that identifies the network:
# one tab-separated `key value` line per fact.
{ pkgs, ... }:
let
  host-status = pkgs.writeShellApplication {
    name = "host-status";
    runtimeInputs = with pkgs; [
      coreutils
      gawk
      systemd
      util-linux
    ];
    text = ''
      field() { printf '%s\t%s\n' "$1" "$2"; }

      field revision "$(nixos-version --configuration-revision 2>/dev/null || echo unknown)"
      field root "$(findmnt -no SOURCE /)"

      failed=$(systemctl --failed --no-legend --plain | awk '{ printf "%s ", $1 }')
      field failed "''${failed:-none}"

      # From the journal rather than the unit's state, which systemd resets on
      # every boot: the upgrade reboots for a new kernel, and a host that
      # rebooted after a failed run would otherwise show nothing wrong.
      if [ "$(systemctl show nixos-upgrade.service -p LoadState --value)" = loaded ]; then
        field upgrade "$(journalctl -u nixos-upgrade.service -o short-iso -q --no-pager --since -14days |
          awk '/: Failed with result |Finished / {
                 at = substr($1, 1, 16); sub("T", " ", at)
                 result = ($0 ~ /Failed with result/) ? "failed" : "success"
               }
               END { if (result) print result, at; else print "none in 14 days" }')"
      else
        field upgrade manual
      fi
    '';
  };
in
{
  environment.systemPackages = [ host-status ];
}
