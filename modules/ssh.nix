# SSH server hardening — key-only auth with modern crypto
{
  config,
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
  # Without this a host with no `ip` falls back to every address it holds,
  # loopback and IPv6 included, and nothing says so. hosts/common supports
  # such hosts, for a DHCP lease.
  assertions = [
    {
      assertion = host ? ip || config.services.openssh.listenAddresses != [ ];
      message = ''
        Host "${hostname}" has no `ip` in lib/net.nix and sets no
        `services.openssh.listenAddresses` of its own, so sshd would listen on
        every address it holds. Give it an `ip`, or bind its addresses in its
        host config, as hosts/gate does.
      '';
    }
  ];

  services.openssh = {
    enable = true;

    # This defaults to true and adds port 22 to the *global* allowedTCPPorts,
    # which opens it on every interface and would quietly undo the per-interface
    # scoping in modules/firewall.nix. That module opens 22 on the interfaces
    # each host names in lib/net.nix instead.
    openFirewall = false;

    # Bind the address this host is reached on, rather than every address it
    # holds. Bound to 0.0.0.0, sshd on gate is one firewall mistake away from
    # the internet, and the ways the ruleset could fail open are not
    # hypothetical: this file's `openFirewall` default, an interface whose
    # meaning changed under its name (see `sshInterfaces` on gate in
    # lib/net.nix), or a ruleset flushed while debugging. Bound like this, the
    # only address the internet can send to is gate's WAN one, and sshd does
    # not hold it.
    #
    # This is not per-interface scoping, and does not replace the firewall's.
    # Linux accepts a packet for any local address on any interface, so a
    # device on iot or guest can still address 192.168.10.1 directly, and on
    # gate's LAN side modules/firewall.nix is still the only thing that stops
    # it. So is the ISP's own equipment, gate's next hop on `wan`.
    #
    # Hosts with no `ip` in lib/net.nix bind their own addresses, and the
    # assertion below holds them to it. That is gate, which holds an address in
    # every segment and binds them in hosts/gate/routing.nix and
    # hosts/gate/wireguard.nix, alongside the rules that open each one.
    #
    # Loopback is not bound, so `ssh localhost` stops working. Nothing in the
    # fleet uses it. No `port` either: sshd then listens on everything in
    # `ports`, so the port stays stated once.
    listenAddresses = lib.optionals (host ? ip) [ { addr = host.ip; } ];

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
