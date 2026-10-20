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

  # A NIC role is a name udev gives a port, from `nics`. One that names no key
  # there names an interface that never exists, and the failure would come at
  # runtime: an address unit waiting on a device, a firewall rule matching
  # nothing.
  nicRoles = [
    "wanIface"
    "trunkIface"
    "wiredIface"
  ];
  nicChecks = lib.concatLists (
    lib.mapAttrsToList (
      name: host:
      map (role: {
        assertion = host ? nics && host.nics ? ${host.${role}};
        message = ''
          net.hosts.${name}.${role} is "${host.${role}}", which is not a key of
          net.hosts.${name}.nics. Interfaces get their names from that list, so
          nothing would be called this.
        '';
      }) (builtins.filter (role: host ? ${role}) nicRoles)
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

  # What each tunnel peer may reach. gate renders its tunnel rules from it, and
  # the proxies read it too (docs/services.md), so a wrong entry fails every
  # host here rather than only the one that reads it. The check that every
  # peer with a key has an entry is gate's, in hosts/gate/wireguard.nix,
  # since the keys are.
  vpn = segments.vpn;
  grantChecks = lib.concatLists (
    lib.mapAttrsToList (peer: held: [
      {
        assertion = vpn.peers ? ${peer};
        message = ''
          net.segments.vpn.grants has an entry for "${peer}", which has no address
          in net.segments.vpn.peers. The address is what gate's firewall
          identifies the peer by, so the grant would match no one.
        '';
      }
      {
        assertion = builtins.isList held && lib.all (g: lib.elem g vpn.grantNames) held;
        message = ''
          net.segments.vpn.grants gives "${peer}" ${builtins.toJSON held}, but only
          ${lib.concatStringsSep ", " vpn.grantNames} mean anything: the names in
          net.segments.vpn.grantNames. An unknown grant would otherwise render
          no rule and fail silently closed.
        '';
      }
    ]) vpn.grants
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

  # The web UIs (docs/services.md, "The registry"). The resolvers, each
  # proxy, the firewall and core5's probes read it, each on its own host, so a
  # wrong entry fails every host here, with a message, rather than the one
  # that reads it with a trace.
  #
  # `upstream` and `grantable` are optional, and each reader supplies the
  # default, so a key outside these two lists is refused: a misspelt
  # `grantable = false` would otherwise read as true.
  serviceKeys = [
    "host"
    "port"
    "segments"
    "probe"
    "backup"
  ];
  serviceOptionalKeys = [
    "upstream"
    "grantable"
  ];

  # The segments that reach a host without a gate rule of their own: its own,
  # and trusted for a host on servers, through gate's "trusted reaches
  # servers". A service for iot or work is a gate rule, to design when one is
  # wanted.
  reachesHost =
    host:
    lib.optional (host ? segment) host.segment
    ++ lib.optional ((host.segment or null) == "servers") "trusted";

  # RFC 1123's rule for a host name label, which is what the name becomes.
  isDnsLabel = name: builtins.match "[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?" name != null;

  serviceChecks = lib.concatLists (
    lib.mapAttrsToList (
      name: svc:
      let
        keys = builtins.attrNames svc;
        missing = lib.subtractLists keys serviceKeys;
        unknown = lib.subtractLists (serviceKeys ++ serviceOptionalKeys) keys;
        host = hosts.${svc.host or ""} or { };
        reaching = reachesHost host;
        segs = svc.segments or [ ];
      in
      [
        {
          assertion = isDnsLabel name;
          message = ''
            net.services has an entry "${name}", which is not a DNS label. The name
            is the service's label under the domain, so it must be lowercase
            letters, digits and hyphens, neither starting nor ending with a
            hyphen, and at most 63 characters. Rename the entry.
          '';
        }
        {
          assertion = missing == [ ] && unknown == [ ];
          message = ''
            net.services.${name} ${
              lib.concatStringsSep " and " (
                lib.optional (missing != [ ]) "lacks ${lib.concatStringsSep ", " missing}"
                ++ lib.optional (unknown != [ ]) "has ${lib.concatStringsSep ", " unknown}, which no reader knows"
              )
            }.
            An entry carries ${lib.concatStringsSep ", " serviceKeys}, and may carry
            ${lib.concatStringsSep " and " serviceOptionalKeys}. Every reader ignores
            any other key, so a misspelt optional one would read as its default.
          '';
        }
        {
          assertion = host ? ip;
          message = ''
            net.services.${name}.host is "${svc.host or "?"}", which is not a host with
            an address in net.hosts. The service's name answers that address, and
            its proxy runs on that host. gate has neither, so set `host` to the
            host the service runs on.
          '';
        }
        {
          assertion = net.ports ? ${svc.port or ""};
          message = ''
            net.services.${name}.port is "${svc.port or "?"}", which is not a name in
            net.ports. The proxy reaches the service at that port on loopback,
            and the firewall keeps it closed, both by name. Add the port to
            net.ports or name the one it has there.
          '';
        }
        {
          # Left to the check above when the host is wrong.
          assertion = !(host ? ip) || (builtins.isList segs && lib.all (s: lib.elem s reaching) segs);
          message = ''
            net.services.${name}.segments is ${builtins.toJSON segs}, but only
            ${builtins.toJSON reaching} reach ${svc.host or "?"} without a gate rule of their
            own: the host's own segment, and trusted for a host on servers. A
            tunnel peer is granted a service in net.segments.vpn.grants, not
            here. Drop the segment, or design its gate rule first.
          '';
        }
        {
          assertion = lib.elem (svc.upstream or "http") [
            "http"
            "https"
          ];
          message = ''
            net.services.${name}.upstream is ${builtins.toJSON svc.upstream}, which must be
            "http" or "https": how the proxy speaks to the service on loopback.
            Leave it out for "http".
          '';
        }
        {
          assertion = builtins.isString (svc.probe or null) && lib.hasPrefix "/" svc.probe;
          message = ''
            net.services.${name}.probe is ${builtins.toJSON (svc.probe or null)}, which must be a
            path starting with "/". core5's probe asks for it at the service's
            name, so write the path alone, with no scheme or host.
          '';
        }
        {
          assertion = (svc.backup or null) == null || builtins.isString svc.backup;
          message = ''
            net.services.${name}.backup is ${builtins.toJSON svc.backup}, which must be the
            name of the offboxPush entry that copies the service's state off its
            host, or null for a service with none.
          '';
        }
        {
          assertion = builtins.isBool (svc.grantable or true);
          message = ''
            net.services.${name}.grantable is ${builtins.toJSON svc.grantable}, which must be
            true or false. Leave it out for true.
          '';
        }
      ]
    ) net.services
  );

  # Each proxy reaches its services at their ports on loopback, so two
  # services on one host naming the same port are one service under two
  # names, each with its own allowlist.
  serviceHostPorts = lib.groupBy (
    name: "${net.services.${name}.host or "?"}:${net.services.${name}.port or "?"}"
  ) (builtins.attrNames net.services);
  servicePortChecks = lib.mapAttrsToList (hostPort: names: {
    assertion = builtins.length names == 1;
    message = ''
      net.services ${lib.concatStringsSep ", " names} all name host and port ${hostPort}.
      Their proxy would send each name to the same service. Give each its
      own port in net.ports, or keep one entry.
    '';
  }) serviceHostPorts;
in
{
  assertions =
    segmentChecks
    ++ hostChecks
    ++ nicChecks
    ++ peerChecks
    ++ grantChecks
    ++ deviceChecks
    ++ goveeChecks
    ++ agentChecks
    ++ metricsChecks
    ++ rootZoneChecks
    ++ portChecks
    ++ serviceChecks
    ++ servicePortChecks;
}
