# Each metricsTarget's journal, uploaded to VictoriaLogs on the collector as it
# is written (./logs.nix): through vmauth on the collector's address, or on
# the collector itself straight to the store on loopback. Imported by
# hosts/common and inert elsewhere, as ./node-exporter.nix is. Lines a unit
# keeps in a journal namespace of its own stay on the host, as Kea's do on
# gate (hosts/gate/routing.nix).
{
  config,
  lib,
  pkgs,
  hostname,
  net,
  ...
}:
let
  collector = net.hosts.${net.metricsCollector};
  url =
    if hostname == net.metricsCollector then
      "http://127.0.0.1:${toString net.ports.victoriaLogs}/insert/journald"
    else
      "http://${collector.ip}:${toString net.ports.victoriaLogsInsert}/insert/journald";

  # The upload resumes from the cursor it saves. Its first start has none
  # and would send the whole journal, so it starts from the newest entry.
  state = "/var/lib/systemd/journal-upload/state";
  seed = pkgs.writeShellScript "journal-upload-seed" ''
    if [ ! -e ${state} ]; then
      cursor=$(${config.systemd.package}/bin/journalctl -q -n 1 -o export --output-fields=__CURSOR | ${pkgs.gnused}/bin/sed -n 's/^__CURSOR=//p')
      if [ -n "$cursor" ]; then printf 'LAST_CURSOR=%s\n' "$cursor" > ${state}; fi
    fi
  '';
in
lib.mkIf (lib.elem hostname net.metricsTargets) {
  services.journald.upload = {
    enable = true;
    settings.Upload.URL = url;
  };

  systemd.services.systemd-journal-upload.serviceConfig.ExecStartPre = [ seed ];
}
