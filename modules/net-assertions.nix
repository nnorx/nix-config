# Consistency checks for lib/net.nix.
#
# That file promises renumbering the LAN is a one-file change, and it keeps the
# half of the promise it can: nothing else in the tree hardcodes an address.
# The half nothing checked is whether the values in the file agree with each
# other. A segment renumbered without its hosts leaves those hosts holding an
# address on one network and a default gateway on another, which fails exactly
# the way the router notes describe: the box is up, answers nothing at the
# address anyone knows, and routes its own traffic onto the wrong wire.
#
# Imported by hosts/common, so every host validates the whole file rather than
# only its own entry. A bad iot pool should fail a Pi rebuild too: the point is
# to catch the edit, not to catch it on the one host that happens to read that
# attribute.
{ lib, net, ... }:
let
  inherit (net) segments hosts;

  # Address arithmetic, kept to whole octets. Real prefix maths in Nix means
  # bit twiddling on parsed integers, and every segment here is byte-aligned;
  # `byteAligned` below refuses to let that assumption go unnoticed rather than
  # letting these comparisons quietly become too permissive.
  octets = addr: lib.splitString "." addr;
  networkPart = prefixLength: addr: lib.take (prefixLength / 8) (octets addr);

  # `subnet` is carried as CIDR because Kea and nftables both want it that way.
  # It therefore states the prefix twice, once here and once in `prefixLength`.
  network = seg: builtins.elemAt (lib.splitString "/" seg.subnet) 0;
  cidrPrefix = seg: lib.toInt (builtins.elemAt (lib.splitString "/" seg.subnet) 1);

  within = seg: addr: networkPart seg.prefixLength addr == networkPart seg.prefixLength (network seg);

  # Inside the subnet, and neither its network nor its broadcast address, which
  # are the host part all zeros and all ones.
  hostPart = seg: addr: lib.drop (seg.prefixLength / 8) (octets addr);
  isHostAddress =
    seg: addr:
    within seg addr
    && !(lib.all (o: o == "0") (hostPart seg addr))
    && !(lib.all (o: o == "255") (hostPart seg addr));

  byteAligned = seg: seg.prefixLength / 8 * 8 == seg.prefixLength;

  segmentChecks = lib.concatLists (
    lib.mapAttrsToList (
      name: seg:
      [
        {
          assertion = byteAligned seg;
          message = ''
            net.segments.${name} has a /${toString seg.prefixLength} prefix, which is not a
            whole number of octets. The containment checks in this file compare
            addresses octet by octet, so they would silently accept an address
            outside the subnet. Generalise `networkPart` before using this prefix.
          '';
        }
        {
          assertion = cidrPrefix seg == seg.prefixLength;
          message = ''
            net.segments.${name} declares subnet ${seg.subnet} but prefixLength
            ${toString seg.prefixLength}. These are two statements of the same fact and they
            disagree, so hosts would take their netmask from one and Kea its
            subnet from the other.
          '';
        }
        {
          assertion = within seg seg.gateway;
          message = ''
            net.segments.${name} has gateway ${seg.gateway}, which is outside its own
            subnet ${seg.subnet}. Every host on this segment takes that as its
            default gateway and would have no route off the segment.
          '';
        }
      ]
      ++ lib.optionals (seg ? pool) [
        {
          assertion = within seg seg.pool.first && within seg seg.pool.last;
          message = ''
            net.segments.${name} has pool ${seg.pool.first} - ${seg.pool.last}, which is not
            inside its subnet ${seg.subnet}. Kea would either refuse the subnet at
            startup or lease addresses that do not route.
          '';
        }
      ]
    ) segments
  );

  hostChecks = lib.concatLists (
    lib.mapAttrsToList (
      name: host:
      lib.optionals (host ? ip) [
        {
          assertion = host ? segment && segments ? ${host.segment};
          message = ''
            net.hosts.${name} sets `ip` but names no declared segment. The prefix and
            the default gateway are both read from it.
          '';
        }
        {
          assertion =
            !(host ? segment && segments ? ${host.segment}) || within segments.${host.segment} host.ip;
          message = ''
            net.hosts.${name} has address ${host.ip} but sits on segment
            ${host.segment or "?"}, which is ${segments.${host.segment}.subnet or "?"}. The address and the
            gateway would be on different networks, leaving the host unreachable
            at the address this file claims for it.
          '';
        }
      ]
    ) hosts
  );

  # A peer address is both its tunnel address and its identity in gate's
  # firewall, so two peers sharing one would share each other's access, and
  # WireGuard would route replies to whichever key it saw last.
  peerChecks = lib.concatLists (
    lib.mapAttrsToList (
      name: seg:
      let
        addresses = builtins.attrValues seg.peers;
      in
      [
        {
          assertion = lib.unique addresses == addresses;
          message = ''
            net.segments.${name}.peers gives two peers the same address. Each
            address is the peer's identity in gate's firewall, so they would
            share each other's access.
          '';
        }
      ]
      ++ lib.concatLists (
        lib.mapAttrsToList (peer: addr: [
          {
            assertion = isHostAddress seg addr && addr != seg.gateway;
            message = ''
              net.segments.${name}.peers.${peer} is ${addr}, which is not a host
              address in ${seg.subnet} other than the gateway ${seg.gateway}:
              it is outside the subnet, its network or broadcast address, or
              the gateway itself.
            '';
          }
        ]) seg.peers
      )
    ) (lib.filterAttrs (_: seg: seg ? peers) segments)
  );

  # hosts/core5 dereferences `net.hosts.<agent>.ip` unguarded to build its
  # firewall, so an agent without an address fails core5's evaluation with an
  # "attribute 'ip' missing" trace that names neither this list nor the host.
  agentChecks = map (name: {
    assertion = hosts ? ${name} && hosts.${name} ? ip;
    message = ''
      net.pimonAgents lists "${name}", which is not a host with an address in
      net.hosts. The collector opens a firewall port per agent and reads that
      address to do it.
    '';
  }) net.pimonAgents;

  # core5 builds its scrape targets from these addresses, and each target opens
  # its exporter's port to the collector's address alone, so a name without one
  # fails as a bare "attribute 'ip' missing", as pimonAgents would.
  #
  # The same segment, because every scrape is meant to stay on it: core5 to a
  # host anywhere else would cross gate's forward chain, which has no rule for
  # it, and the scrape would fail as a down host. gate has no `ip`, and is
  # scraped at the gateway of its `metricsSegment`, which is held to the same
  # rule.
  collector = hosts.${net.metricsCollector} or { };
  scrapeSegment = h: h.segment or h.metricsSegment or null;
  metricsChecks = [
    {
      assertion = collector ? ip;
      message = ''
        net.metricsCollector is "${net.metricsCollector}", which is not a host with an
        address in net.hosts. Every target opens its exporter's port to that
        address, and only to it.
      '';
    }
  ]
  ++ map (name: {
    assertion =
      hosts ? ${name}
      && (hosts.${name} ? ip || hosts.${name} ? metricsSegment)
      && scrapeSegment hosts.${name} == collector.segment or null;
    message = ''
      net.metricsTargets lists "${name}", which is not a host with an address on
      the collector's segment, ${collector.segment or "?"}, nor one whose
      `metricsSegment` is that segment. The collector scrapes each target at
      its address, and a scrape from another segment would have to cross
      gate's forward chain, which has no rule for it.
    '';
  }) net.metricsTargets
  # A resolver's DNS metrics are scraped like its node_exporter: Unbound's
  # through their own exporter, AdGuard's through node_exporter's textfile
  # collector. Both need the resolver to be a target, and the rule opening the
  # Unbound exporter's port is written for a host scraped across the wire,
  # not for the collector scraping itself.
  ++ map (name: {
    assertion = lib.elem name net.metricsTargets && name != net.metricsCollector;
    message = ''
      net.resolvers lists "${name}", which must also be in net.metricsTargets
      and must not be net.metricsCollector. Its DNS metrics are scraped like
      its node_exporter (modules/unbound.nix, modules/adguardhome.nix).
    '';
  }) net.resolvers
  # `metricsSegment` stands in for an `ip`, for a host that holds an address
  # on every segment. Both at once would leave two answers to where the host
  # is scraped, and the exporters bind only one of them.
  ++ lib.mapAttrsToList (name: host: {
    assertion = !(host ? ip) && segments ? ${host.metricsSegment};
    message = ''
      net.hosts.${name} sets metricsSegment "${host.metricsSegment}", which must
      name a declared segment, on a host with no `ip`. Its exporters bind that
      segment's gateway address, and core5 scrapes them there.
    '';
  }) (lib.filterAttrs (_: h: h ? metricsSegment) hosts);

  # One number, one name. Two names for a port read as two services, and a
  # firewall rule written for one opens the other: gate's tunnel grants and the
  # hosts' interface rules match on the number alone. Across TCP and UDP too,
  # since the names say nothing of the protocol.
  portNames = lib.groupBy (name: toString net.ports.${name}) (builtins.attrNames net.ports);
  portChecks = lib.mapAttrsToList (number: names: {
    assertion = builtins.length names == 1;
    message = ''
      net.ports gives ${number} more than one name: ${lib.concatStringsSep ", " names}.
      A firewall rule opened for one of them would open the others.
    '';
  }) portNames;
in
{
  assertions =
    segmentChecks ++ hostChecks ++ peerChecks ++ agentChecks ++ metricsChecks ++ portChecks;
}
