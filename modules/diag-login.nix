# A `diag` login on every server, for the read-only diagnostics Claude
# sessions run through fleet-ssh (home/ssh.nix). It is a normal user outside
# wheel, so it has no sudo (`security.sudo.execWheelOnly` in
# modules/baseline.nix), and in `systemd-journal`, so it reads the system
# journal, host-status's upgrade line included.
#
# Its keys, from lib/diag-keys.nix, are one file key per admin machine,
# separate from id_ed25519_pis, since sshd tells logins apart by key. Each is
# `restrict`: no pty, no forwarding of any kind, no agent, no `~/.ssh/rc`. No
# forced command, so it is a general shell for reading the host. The alert
# agent's `triage` login (docs/fleet-agent.md) is the narrower one.
#
# No password: nothing declares one, so with `users.mutableUsers = false` the
# account is locked, as deploy's is, and only a key opens it.
#
# It reads its host and reaches nothing else. A rule on diag's own traffic,
# matched by owner in the output path, lets the connections it starts go to
# loopback alone: it queries the host's own services, such as VictoriaMetrics'
# query API and the resolvers, and opens nothing to another host, a segment or
# the internet. A diagnostic of a host's outbound path is its own user's.
# Loopback is the interface, which carries everything addressed to the host
# itself, its own addresses included.
{
  config,
  lib,
  net,
  diagPubKeys,
  ...
}:
let
  # Refused even on loopback, so diag neither silences an alert nor drives
  # what pushes one, and no service there connects onward on its behalf. The
  # blackbox exporter probes whatever target a request gives it, so its port
  # is refused with the alerting ones, and diag's reach stays at the host
  # itself. All three run on core5 alone
  # (modules/alerting.nix, modules/blackbox.nix); the ports are refused on
  # every host so that the rule is one rule everywhere. VictoriaMetrics'
  # port stays open for queries, and its admin APIs take a key
  # (modules/metrics.nix).
  refusedPorts = [
    net.ports.alertmanager
    net.ports.vmalert
    net.ports.blackboxExporter
  ];

  # The chain diag's traffic jumps to, in each firewall's form. Traffic on a
  # connection already open passes, so the rule decides only what diag
  # starts. Loopback passes, but for the ports above. Everything else is
  # rejected rather than dropped, so a refused diagnostic fails at once,
  # "connection refused" rather than a timeout, and TCP gets the reset a
  # closed port sends.
  chain = "diag-output";
  iptablesPorts = lib.concatMapStringsSep "," toString refusedPorts;
  nftPorts = lib.concatMapStringsSep ", " toString refusedPorts;
in
{
  users.users.diag = {
    isNormalUser = true;
    extraGroups = [ "systemd-journal" ];
    openssh.authorizedKeys.keys = map (key: "restrict ${key}") diagPubKeys;
  };

  # Added to the host's own user in modules/ssh.nix; the lists merge.
  services.openssh.settings.AllowUsers = [ "diag" ];

  # Nothing diag starts outlives its login. KillOnlyUsers has logind kill a
  # session's processes when it ends, for the users listed, whatever
  # KillUserProcesses says, so the host's own user keeps what it leaves
  # running. Deleting a key's line then ends everything that key started at
  # its logout, rather than at the next reboot.
  services.logind.settings.Login.KillOnlyUsers = "diag";

  # Only wheel uses the nix daemon (root always may). diag reads the host and
  # builds nothing, and a build runs as the daemon's own users, so whatever
  # holds diag to its own reach would not hold the build. Nothing on the
  # servers runs nix as anyone else: the upgrades and deploy-guard run as
  # root, and deploy-agent writes request files.
  nix.settings.allowed-users = [ "@wheel" ];

  # The Pis' firewall is iptables, which runs these at every start and reload
  # of its own rules, so they take out what they put in before putting it in.
  networking.firewall = lib.mkIf (!config.networking.nftables.enable) {
    extraCommands = ''
      ip46tables -D OUTPUT -m owner --uid-owner diag -j ${chain} 2>/dev/null || true
      ip46tables -F ${chain} 2>/dev/null || true
      ip46tables -X ${chain} 2>/dev/null || true
      ip46tables -N ${chain}
      ip46tables -A ${chain} -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN
      ip46tables -A ${chain} -o lo -p tcp -m multiport --dports ${iptablesPorts} -j REJECT --reject-with tcp-reset
      ip46tables -A ${chain} -o lo -j RETURN
      ip46tables -A ${chain} -p tcp -j REJECT --reject-with tcp-reset
      ip46tables -A ${chain} -j REJECT
      ip46tables -A OUTPUT -m owner --uid-owner diag -j ${chain}
    '';
    extraStopCommands = ''
      ip46tables -D OUTPUT -m owner --uid-owner diag -j ${chain} 2>/dev/null || true
      ip46tables -F ${chain} 2>/dev/null || true
      ip46tables -X ${chain} 2>/dev/null || true
    '';
  };

  # gate's is nftables. A table of its own, with a chain on the output hook,
  # since the firewall module's table filters input and forwarding.
  networking.nftables = lib.mkIf config.networking.nftables.enable {
    tables.${chain} = {
      family = "inet";
      content = ''
        chain output {
          type filter hook output priority filter; policy accept;
          meta skuid "diag" jump diag
        }

        chain diag {
          ct state established,related return
          oifname "lo" tcp dport { ${nftPorts} } reject with tcp reset
          oifname "lo" return
          meta l4proto tcp reject with tcp reset
          reject
        }
      '';
    };

    # nft looks the name up as it loads the rules, and the build that checks
    # them has no diag user.
    preCheckRuleset = ''
      sed 's/skuid "diag"/skuid "nobody"/' -i ruleset.conf
    '';
  };
}
