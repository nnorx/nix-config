# Off-box copy of Home Assistant's backups.
#
# Integrations, devices, users, dashboards and UI-made automations are state
# in /var/lib/hass, not in this repo. The package also comes from `unstable`
# and upgrades unattended, while Home Assistant migrates its storage forward
# and does not support downgrades, so going back across a version change needs
# a backup that version took. See modules/home-assistant.nix.
#
# Home Assistant's own automatic backup writes the file, set up in its UI as
# docs/home-assistant.md describes: settings only, unencrypted on local
# storage, at a fixed time after the upgrade. modules/offbox-push.nix moves the
# newest one off the host, encrypted with age instead.
{ config, hostname, ... }:
{
  imports = [ ./offbox-push.nix ];

  offboxPush.home-assistant-backup = {
    description = "Push Home Assistant's newest backup off-box";
    sourceDir = "${config.services.home-assistant.configDir}/backups";
    extension = "tar";
    repoDir = "home-assistant";
    commitSubject = "home-assistant: state";

    # Automatic backups only. Home Assistant names them "Automatic backup
    # <version>" and the file after the name (backup/manager.py, util.py in
    # 2026.9.4). A manual backup in the same directory may include the
    # database or Home Assistant's own encryption, and must not become
    # `latest` off-box.
    pattern = "Automatic_backup_*.tar";

    # The nixpkgs module runs Home Assistant with UMask=0077, so every backup
    # is 0600 to `hass`. Root copies the chosen file to the host user, and the
    # push runs as that user like UniFi's. Running the push as `hass` would
    # put the deploy key within reach of Home Assistant, and running it as
    # root would put git and ssh on the network as root.
    user = hostname;
    stage = true;

    # Home Assistant's backup runs at 06:15 when set as the runbook says. Its
    # default is 04:45 plus up to an hour of jitter, which lands on the 05:00
    # upgrade; a fixed time has none. Clear of the UniFi push's 06:30 plus
    # jitter too, though the push retries if they ever meet.
    at = "07:00";

    missingHint = "A missing directory means Home Assistant has not made a backup yet.";
    emptyHint = ''
      Home Assistant's automatic backup is what fills it:
        Settings > System > Backups. See docs/home-assistant.md.
    '';

    # Home Assistant backs up daily, so two days without a new file means it
    # stopped.
    maxAgeDays = 2;

    # A settings-only backup is a few MB. One with the recorder database grows
    # without bound, and every version stays in the repo's history.
    maxMiB = 50;
    oversizeHint = ''
      Is the automatic backup including the database? It should be settings only.
      See docs/home-assistant.md.
    '';
  };
}
