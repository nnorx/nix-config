# SSH server hardening — key-only auth with modern crypto
{
  lib,
  hostname,
  sshPubKey,
  net,
  ...
}:
let
  host = net.hosts.${hostname} or { };
in
{
  services.openssh = {
    enable = true;

    # This defaults to true and adds port 22 to the *global* allowedTCPPorts,
    # which opens it on every interface and would quietly undo the per-interface
    # scoping in modules/firewall.nix. That module opens 22 on the interfaces
    # each host names in lib/net.nix instead.
    openFirewall = false;
    settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      PermitRootLogin = "no";
      X11Forwarding = false;
      MaxAuthTries = 3;
      AllowUsers = [ hostname ];
    };
    # Bind only the address this host answers on, rather than every address it
    # happens to hold. modules/firewall.nix already scopes port 22 to the
    # interfaces named in lib/net.nix, so this is the second layer, not the
    # first: without it sshd sits on 0.0.0.0 and the packet filter is the only
    # thing between it and everything else. On gate that "everything else"
    # became a routable public address at the cutover, so a single mistake in
    # one ruleset was the whole distance between a closed port and sshd on the
    # internet.
    #
    # Hosts with no `ip` in lib/net.nix are not covered here. That is gate,
    # which holds an address in every segment and sets this itself in
    # hosts/gate/routing.nix, the same split hosts/common makes for addressing.
    listenAddresses = lib.optionals (host ? ip) [
      {
        addr = host.ip;
        # No port: sshd then listens on everything in `ports`, so the port
        # stays stated once.
        port = null;
      }
    ];

    extraConfig = ''
      KexAlgorithms curve25519-sha256,curve25519-sha256@libssh.org
      Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com
      MACs hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com
    '';
  };

  # A bound address that does not exist yet is a failed sshd, and by default a
  # permanently failed one: systemd retries every 100ms and gives up after 5
  # attempts in 10 seconds, which a bind against an unconfigured interface
  # exhausts in about half a second. sshd is the way back into every host in
  # this fleet, so it must not be able to lose that race.
  #
  # Ordering first, so the retry is a safety net rather than the mechanism, the
  # same shape hosts/gate/routing.nix uses for Kea. The address unit is what
  # actually makes the interface bindable; `network-online.target` is what the
  # nixpkgs option documentation suggests and is kept as well, but on its own it
  # implies nothing about any particular interface being configured.
  #
  # Then the net: a five second gap between attempts and no start limit at all,
  # so a host that comes up slowly keeps trying instead of arriving with no
  # sshd and no way in.
  systemd.services.sshd = lib.mkIf (host ? ip) {
    wants = [ "network-online.target" ];
    after = [
      "network-online.target"
      "network-addresses-${host.iface}.service"
    ];
    serviceConfig.RestartSec = 5;
    unitConfig.StartLimitIntervalSec = 0;
  };

  # Deploy SSH public key for key-only access
  users.users.${hostname}.openssh.authorizedKeys.keys = [ sshPubKey ];
}
