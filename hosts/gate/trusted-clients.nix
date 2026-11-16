# Counts devices Kea leases to on trusted for the first time, for core5's
# NewTrustedClient alert. The MACs it has seen stay in a state directory only
# root reads; the count alone is published, which ./metrics.nix exports.
#
# It reads Kea's lease files rather than its journal: each line carries the
# lease's subnet id, so trusted is told apart by lib/net.nix's id alone, and
# the files outlive the journal's retention. Kea's lease file cleanup moves
# lines to `.1`, `.2` and `.completed`, so those are read too; `.output` is
# being written, and is not.
{
  lib,
  pkgs,
  net,
  ...
}:
let
  leases = "/var/lib/kea/dhcp4.leases";
  state = "/var/lib/gate-trusted-clients";
  published = "/run/gate-trusted-clients";

  count = pkgs.writeShellApplication {
    name = "gate-trusted-clients";
    runtimeInputs = with pkgs; [
      coreutils
      gawk
    ];
    text = ''
      export LC_ALL=C
      files=(${leases})
      for f in ${leases}.1 ${leases}.2 ${leases}.completed; do
        if [ -e "$f" ]; then files+=("$f"); fi
      done

      # Columns by the header's names. A line with fewer fields than its
      # header is still being written, and a partial MAC would read as new.
      now=$(mktemp -p ${state})
      gawk -F, -v subnet=${toString net.segments.trusted.id} '
        FNR == 1 {
          hw = sn = 0
          for (i = 1; i <= NF; i++) { if ($i == "hwaddr") hw = i; if ($i == "subnet_id") sn = i }
          if (!hw || !sn) { print FILENAME ": no hwaddr or subnet_id column" > "/dev/stderr"; exit 1 }
          fields = NF
          next
        }
        NF == fields && $sn == subnet && tolower($hw) ~ /^([0-9a-f]{2}:){5}[0-9a-f]{2}$/ { print tolower($hw) }
      ' "''${files[@]}" | sort -u >"$now"

      # The first run knows every device leased to now, and counts none.
      if [ ! -e ${state}/seen ]; then
        echo 0 >${state}/count
        mv "$now" ${state}/seen
      else
        new=$(comm -13 ${state}/seen "$now" | wc -l)
        if [ "$new" -gt 0 ]; then
          # The count first: a run cut short between the two counts a device
          # twice rather than never.
          total=$(($(cat ${state}/count) + new))
          tmp=$(mktemp -p ${state})
          echo "$total" >"$tmp"
          mv "$tmp" ${state}/count
          sort -u ${state}/seen "$now" >"$now.all"
          mv "$now.all" ${state}/seen
        fi
        rm -f "$now"
      fi

      tmp=$(mktemp -p ${published})
      cat ${state}/count >"$tmp"
      chmod 0644 "$tmp"
      mv "$tmp" ${published}/count
    '';
  };
in
{
  systemd.services.gate-trusted-clients = {
    description = "Count devices new to trusted in Kea's leases";
    after = [ "kea-dhcp4-server.service" ];
    serviceConfig = import ../../lib/hardening.nix // {
      Type = "oneshot";
      ExecStart = lib.getExe count;
      # Root, so its state is root's alone, holding only the capability to
      # read Kea's 0600 lease files under the 0700 /var/lib/private.
      CapabilityBoundingSet = [ "CAP_DAC_READ_SEARCH" ];
      StateDirectory = baseNameOf state;
      StateDirectoryMode = "0700";
      UMask = "0077";
      RuntimeDirectory = baseNameOf published;
      RuntimeDirectoryMode = "0755";
      RuntimeDirectoryPreserve = true;
      PrivateNetwork = true;
      LogLevelMax = "notice";
    };
  };
  systemd.timers.gate-trusted-clients = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "1min";
      OnUnitActiveSec = "1min";
      AccuracySec = "1s";
    };
  };
}
