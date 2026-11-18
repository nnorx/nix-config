# What forge tells a network about itself. A hotel's or café's DHCP server and
# its neighbours on the segment otherwise see the Wi-Fi radio's permanent MAC
# and the hostname, a device ID that follows forge from network to network.
# docs/privacy.md, "forge", has the reasons; docs/laptop.md the
# home profile's exemption.
{ ... }:
{
  networking.networkmanager.settings.connection = {
    # A MAC per network, derived from a secret and the connection, so it
    # holds still on each network and differs between them.
    "wifi.cloned-mac-address" = "stable";
    "ipv4.dhcp-send-hostname" = "no";
    # Prefer temporary IPv6 addresses for outgoing connections.
    "ipv6.ip6-privacy" = 2;
  };
}
