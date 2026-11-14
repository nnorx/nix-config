# The security alerts, over the fleet's journals in VictoriaLogs: the rules
# vmalert-logs evaluates on the collector (modules/alerting.nix), as vmalert's
# rule file. tests/log-alerts.nix raises each from a real journal line.
#
# Each query counts the matching lines by host over its window, which is also
# how long the alert holds after the last of them, so a burst is one push. A
# line uploaded later than its window, after core5 or the link was down, is in
# the store but raises nothing.
#
# `instance` is the line's `_HOSTNAME`, the name the sending host gives itself.
# The address, user and key a line names stay in the store, where `fleet-ssh
# core5` queries them (docs/observability.md), and leave the house in neither a
# label nor an annotation.
let
  byHost = name: ''
    | stats by (_HOSTNAME) count() as ${name}
    | rename _HOSTNAME as instance
  '';
in
{
  groups = [
    {
      name = "security";
      type = "vlogs";
      interval = "1m";
      rules = [
        {
          # pam_unix's line for each wrong password, whoever typed it.
          alert = "SudoFailed";
          expr = ''
            _time:15m SYSLOG_IDENTIFIER:=sudo "authentication failure"
            ${byHost "failures"}
          '';
          labels.severity = "critical";
          annotations.summary = "sudo refused a password on {{ $labels.instance }}.";
        }
        {
          # Not "Restore Ban", which fail2ban logs for each ban still running
          # when it starts.
          alert = "Fail2banBan";
          expr = ''
            _time:15m _SYSTEMD_UNIT:=fail2ban.service "] Ban " -"Restore Ban"
            ${byHost "bans"}
          '';
          labels.severity = "warning";
          annotations.summary = "fail2ban banned an address on {{ $labels.instance }}.";
        }
        {
          # A login as the user named for the host (modules/ssh.nix), and not
          # diag's or deploy's, which are fleet-ssh and fleet-deploy. OpenSSH
          # logs it from sshd-session; sshd is its older name. The window is
          # an hour, and modules/alerting.nix batches these into one push an
          # hour at most.
          alert = "HostUserLogin";
          expr = ''
            _time:1h SYSLOG_IDENTIFIER:in(sshd, sshd-session) "Accepted"
            | extract "Accepted <_> for <user> from "
            | filter user:eq_field(_HOSTNAME)
            ${byHost "logins"}
          '';
          labels.severity = "info";
          annotations.summary = "Someone logged in to {{ $labels.instance }} as its own user over SSH.";
        }
      ];
    }
  ];
}
