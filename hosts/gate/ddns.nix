# Keeps an A record on Cloudflare pointed at gate's WAN address, which the ISP
# assigns over DHCP. WireGuard peers dial that name.
#
# DNS only, not proxied: Cloudflare's proxy carries no UDP. The token is scoped
# to DNS edit on the one zone.
#
# The hostname is in secrets/gate.yaml with the token, because it resolves to
# the house for anyone who asks, which makes it identifying in the way
# docs/network.md describes. That only keeps it private while it is hard to
# guess, so it is a random label rather than `vpn.` or `home.`, and it must
# never get a TLS certificate: certificate transparency logs publish every name
# a certificate is issued for.
{ config, ... }:
let
  cfg = config.services.cloudflare-ddns;
in
{
  sops.secrets = {
    cloudflare-api-token = { };
    ddns-hostname = { };
  };

  # The module passes the token to the service through this file, as an
  # EnvironmentFile. The hostname rides along so it never appears in the Nix
  # config, which is public. systemd documents that variables from an
  # EnvironmentFile override those set with Environment=, and that is what
  # replaces the empty `ip4Domains` below.
  sops.templates."cloudflare-ddns.env" = {
    owner = cfg.user;
    content = ''
      CLOUDFLARE_API_TOKEN=${config.sops.placeholder.cloudflare-api-token}
      IP4_DOMAINS=${config.sops.placeholder.ddns-hostname}
    '';
  };

  services.cloudflare-ddns = {
    enable = true;
    credentialsFile = config.sops.templates."cloudflare-ddns.env".path;

    # Overridden by IP4_DOMAINS from the file above. Set rather than left null
    # because the module refuses to evaluate with no domains at all.
    ip4Domains = [ ];

    # `local` reads the source address the kernel would use toward Cloudflare,
    # which on gate is the address on `wan`. No third party is asked what it
    # is. (`local.iface:wan` would be more direct, but upstream marks it
    # experimental.)
    provider.ipv4 = "local";

    # No global IPv6 here; see the IPv6 item in docs/router.md.
    provider.ipv6 = "none";

    proxied = "false";

    # Explicit, because the alternative deletes the record every time gate
    # reboots or the service restarts, and peers lose the name until it is
    # recreated.
    deleteOnStop = false;
  };
}
