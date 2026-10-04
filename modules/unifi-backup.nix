# Off-box copy of the UniFi controller's backups.
#
# The controller's database holds adoption state, SSIDs, PSKs, VLAN
# assignments and port profiles. docs/unifi.md is blunt that none of it is in
# this repo under any approach, which makes it the one part of the network a
# rebuilt core5 could not reproduce from the flake.
#
# The controller already writes `.unf` files on a schedule set in its own UI,
# and that format is what its restore flow expects. A `mongodump` would be a
# second, unsupported path into a database whose migrations are one-way.
# modules/offbox-push.nix moves the newest one off the host, encrypted.
{ hostname, ... }:
{
  imports = [ ./offbox-push.nix ];

  offboxPush.unifi-backup = {
    description = "Push the UniFi controller's newest backup off-box";
    sourceDir = "/var/lib/unifi/config/data/backup/autobackup";
    extension = "unf";
    repoDir = "unifi";
    commitSubject = "unifi: controller state";

    # The controller's config volume is 0750 and owned by the host user (see
    # modules/unifi.nix), so root is not what needs to read it.
    user = hostname;

    # Ordering against the controller is a soft dependency. Its schedule runs
    # in UTC whatever the container's TZ says, so "12:30 AM" in its UI is the
    # previous evening here, well before this. If it has not written a new
    # file yet, the hash check makes this a no-op and the change is picked up
    # the next day.
    at = "06:30";

    missingHint = "A missing directory means the controller has not started since a reset.";
    emptyHint = ''
      The controller's own backup schedule is what fills it:
        Settings > System > Backups. See docs/unifi.md.
    '';

    # The controller's schedule is daily, so two days without a new file
    # means it stopped. A schedule changed in its UI must change this too.
    maxAgeDays = 2;
  };
}
