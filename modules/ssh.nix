# SSH server hardening — key-only auth with modern crypto
{
  lib,
  hostname,
  sshPubKeys,
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

    # Bind the address this host is reached on, rather than every address it
    # holds. modules/firewall.nix already scopes port 22 per interface, so this
    # is the second layer, not the first: bound to 0.0.0.0, sshd is one
    # firewall mistake away from every network the host can see. On gate that
    # includes the internet, and the ways the ruleset could fail open are not
    # hypothetical: this file's `openFirewall` default, an interface whose
    # meaning changed under its name (see `sshInterfaces` on gate in
    # lib/net.nix), or a ruleset flushed while debugging.
    #
    # Hosts with no `ip` in lib/net.nix are not covered here. That is gate,
    # which holds an address in every segment and binds them itself, in
    # hosts/gate/routing.nix and hosts/gate/wireguard.nix, alongside the rules
    # that open each one.
    #
    # Loopback is not bound, so `ssh localhost` stops working. Nothing in the
    # fleet uses it.
    listenAddresses = lib.optionals (host ? ip) [
      {
        addr = host.ip;
        # No port: sshd then listens on everything in `ports`, so the port
        # stays stated once.
        port = null;
      }
    ];

    settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      PermitRootLogin = "no";
      X11Forwarding = false;
      MaxAuthTries = 3;
      AllowUsers = [ hostname ];
    };
    extraConfig = ''
      KexAlgorithms curve25519-sha256,curve25519-sha256@libssh.org
      Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com
      MACs hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com
    '';
  };

  # Lets sshd bind an address before any interface holds it. Without this a
  # bound address is a boot race: sshd starts after network.target, which
  # promises nothing about any interface being configured, and gate's
  # `br-trusted` is a bridge over a VLAN sub-interface, among the last things
  # up. Losing the race outright fails the bind. Losing it on some addresses
  # is worse: sshd runs on the ones it got and never retries the others, so a
  # late `wg0` would leave gate with no SSH over the tunnel until something
  # restarted it. With this the socket exists from the start and begins
  # answering the moment its address appears.
  #
  # Ordering after each interface's address unit was the alternative, and the
  # first draft of this change. It narrows the race without closing it, and
  # does nothing for an interface whose unit fails, such as WireGuard when its
  # key will not decrypt.
  #
  # System-wide, not per-socket: any daemon here may now bind an address the
  # host does not hold, so a wrong address binds silently rather than failing.
  # Every address bound this way comes from lib/net.nix, which is where a typo
  # would be caught. IPv4 only, as is everything sshd binds today.
  boot.kernel.sysctl."net.ipv4.ip_nonlocal_bind" = 1;

  # A backstop for whatever this does not cover. systemd's defaults retry every
  # 100ms and give up for good after five failures in ten seconds. sshd is the
  # way back into every host in this fleet, so it keeps trying instead.
  systemd.services.sshd = {
    serviceConfig.RestartSec = 5;
    unitConfig.StartLimitIntervalSec = 0;
  };

  # Every admin machine's key, from lib/ssh-keys.nix
  users.users.${hostname}.openssh.authorizedKeys.keys = sshPubKeys;
}
