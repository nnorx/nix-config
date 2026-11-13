# Tang, which unlocks gate's disk at boot without a passphrase while gate is
# inside the house. It answers gate's servers address alone, both in the
# socket's IP filter and in the firewall. tangd makes its keys in
# /var/lib/tang on its first request, so they never pass through the store.
{
  hostname,
  net,
  ...
}:
let
  host = net.hosts.${hostname};
  gate = net.segments.servers.gateway;
  port = toString net.ports.tang;
in
{
  services.tang = {
    enable = true;
    listenStream = [ "${host.ip}:${port}" ];
    ipAddressAllow = [ "${gate}/32" ];
  };

  # The address may not be up yet when sockets.target binds.
  systemd.sockets.tangd.socketConfig.FreeBind = true;

  networking.firewall.extraCommands = ''
    iptables -A nixos-fw -i ${host.iface} -p tcp --dport ${port} -s ${gate} -j nixos-fw-accept
  '';
}
