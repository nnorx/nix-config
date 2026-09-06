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
in
{
  assertions = segmentChecks ++ hostChecks ++ agentChecks;
}
