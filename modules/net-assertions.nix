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
  inherit (net) segments hosts devices;

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

  # An address as one number, for comparing against a pool's ends.
  addressValue = addr: lib.foldl (acc: o: acc * 256 + lib.toInt o) 0 (octets addr);
  inPool =
    seg: addr:
    seg ? pool
    && addressValue seg.pool.first <= addressValue addr
    && addressValue addr <= addressValue seg.pool.last;

  # Every address this file assigns, with the attribute that assigns it.
  addressOwners = lib.groupBy (o: o.ip) (
    lib.mapAttrsToList (name: host: {
      inherit (host) ip;
      owner = "net.hosts.${name}";
    }) (lib.filterAttrs (_: host: host ? ip) hosts)
    ++ lib.concatLists (
      lib.mapAttrsToList (
        name: seg:
        lib.mapAttrsToList (peer: ip: {
          inherit ip;
          owner = "net.segments.${name}.peers.${peer}";
        }) seg.peers
      ) (lib.filterAttrs (_: seg: seg ? peers) segments)
    )
    ++ lib.mapAttrsToList (name: device: {
      inherit (device) ip;
      owner = "net.devices.${name}";
    }) devices
  );

  # Devices a rule names (docs/device-identity.md). Each address is a Kea
  # reservation on gate, so the segment needs a pool, since gate runs Kea only
  # where one exists, and the address must sit outside it, where Kea leases it
  # to nothing else. The address is the device's identity in every rule that
  # names it, so a host, a peer or another device holding it too would be
  # granted that device's access.
  deviceChecks = lib.concatLists (
    lib.mapAttrsToList (
      name: device:
      let
        seg = segments.${device.segment} or null;
        others = lib.remove "net.devices.${name}" (map (o: o.owner) addressOwners.${device.ip});
      in
      [
        {
          assertion = seg ? pool;
          message = ''
            net.devices.${name} is on segment "${device.segment}", which is not a
            declared segment with a DHCP pool. Its address is a Kea reservation,
            and gate runs Kea only on segments with a pool.
          '';
        }
        {
          assertion = !(seg ? pool) || (isHostAddress seg device.ip && device.ip != seg.gateway);
          message = ''
            net.devices.${name} is ${device.ip}, which is not a host address in
            ${seg.subnet or "?"} other than the gateway ${seg.gateway or "?"}: it is
            outside the subnet, its network or broadcast address, or the gateway
            itself. Kea would reserve an address the device cannot hold.
          '';
        }
        {
          assertion = !(inPool seg device.ip);
          message = ''
            net.devices.${name} is ${device.ip}, inside the ${device.segment} pool
            ${seg.pool.first or "?"} - ${seg.pool.last or "?"}. Kea can lease a pool address to
            another device before this one asks for its reservation, and that
            device would then hold the address the rules name.
          '';
        }
        {
          assertion = others == [ ];
          message = ''
            net.devices.${name} has address ${device.ip}, which ${lib.concatStringsSep ", " others}
            also holds. Rules that name the device by address would grant its
            access to the other holder too.
          '';
        }
      ]
    ) devices
  );

  # The Govee rules on gate and core5 read each light's address from
  # net.devices, and the lights are on iot: gate routes the scan into iot and
  # nowhere else.
  goveeChecks = map (name: {
    assertion = (devices.${name}.segment or null) == "iot";
    message = ''
      net.goveeLights lists "${name}", which is not a device on iot in
      net.devices. The Govee rules read each light's address from there, and
      gate carries the lights' traffic to and from iot only.
    '';
  }) net.goveeLights;

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

  # Unbound reads each root zone source as an address only if it parses as one,
  # and otherwise as a host name, which it would have to resolve before it
  # could fetch the zone that resolves it. An address on the LAN, or anywhere
  # private, is a typo, since no root server sits there. ZONEMD would refuse a
  # zone from such a host, so the failure would be a quiet one: a source that
  # never works, and a timeout on every transfer that tries it.
  isOctet = o: builtins.match "0|[1-9][0-9]{0,2}" o != null && lib.toInt o <= 255;
  isIPv4 = addr: builtins.length (octets addr) == 4 && lib.all isOctet (octets addr);
  pow2 = n: lib.foldl (acc: _: acc * 2) 1 (lib.range 1 n);
  inCidr =
    cidr: addr:
    let
      base = addressValue (builtins.elemAt (lib.splitString "/" cidr) 0);
      size = pow2 (32 - lib.toInt (builtins.elemAt (lib.splitString "/" cidr) 1));
    in
    base <= addressValue addr && addressValue addr < base + size;
  notPublic = [
    "0.0.0.0/8"
    "10.0.0.0/8"
    "100.64.0.0/10"
    "127.0.0.0/8"
    "169.254.0.0/16"
    "172.16.0.0/12"
    "192.168.0.0/16"
    "224.0.0.0/3" # multicast, reserved and broadcast
  ];
  isPublic =
    addr:
    !(lib.any (cidr: inCidr cidr addr) notPublic)
    && !(lib.any (seg: within seg addr) (builtins.attrValues segments));

  rootZoneChecks = [
    {
      assertion = net.rootZoneSources != [ ] && lib.unique net.rootZoneSources == net.rootZoneSources;
      message = ''
        net.rootZoneSources is empty or names an address twice. Each Unbound
        fetches its copy of the root zone from these, in turn.
      '';
    }
  ]
  ++ map (addr: {
    assertion = isIPv4 addr && isPublic addr;
    message = ''
      net.rootZoneSources lists "${addr}", which is not a public IPv4 address.
      Unbound would take anything that does not parse as an address for a
      host name, and no root server sits on a private network. Unbound
      recurses over IPv4 only (modules/unbound.nix), so IPv6 sources would
      never be reached.
    '';
  }) net.rootZoneSources;

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
    segmentChecks
    ++ hostChecks
    ++ peerChecks
    ++ deviceChecks
    ++ goveeChecks
    ++ agentChecks
    ++ metricsChecks
    ++ rootZoneChecks
    ++ portChecks;
}
