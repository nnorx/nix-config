# `nix run .#dns-top-domains`: the domains each segment looks up most, from the
# resolvers' query logs, for docs/privacy.md. See scripts/dns-top-domains.sh.
{
  writeShellApplication,
  writeText,
  curl,
  jq,
  coreutils,
  gawk,
  net,
}:
writeShellApplication {
  name = "dns-top-domains";
  meta.description = "Summarise the resolvers' query logs as top domains per segment, without client addresses";
  runtimeInputs = [
    curl
    jq
    coreutils
    gawk
  ];
  runtimeEnv = {
    DNS_TOP_NET = writeText "net.json" (builtins.toJSON net);
    DNS_TOP_ROWS = "${../../scripts/dns-top-domains.jq}";
  };
  text = builtins.readFile ../../scripts/dns-top-domains.sh;
}
