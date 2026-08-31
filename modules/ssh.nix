# SSH server hardening — key-only auth with modern crypto
{ hostname, sshPubKey, ... }:
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
    extraConfig = ''
      KexAlgorithms curve25519-sha256,curve25519-sha256@libssh.org
      Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com
      MACs hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com
    '';
  };

  # Deploy SSH public key for key-only access
  users.users.${hostname}.openssh.authorizedKeys.keys = [ sshPubKey ];
}
