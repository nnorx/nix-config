# Kea's statistics by segment name, for the rule that reads them
# (modules/alert-rules.nix, DhcpPoolLow) and the dashboard that draws them
# (modules/dashboards.nix, DHCP), so the two can never name a segment
# differently.
#
# Kea labels its statistics with the subnet in CIDR form and with Kea's
# subnet id, which hosts/gate/routing.nix sets to the segment's VLAN id. These
# name the segment instead, so no address leaves the house.
{ lib, net }:
rec {
  # The segments Kea serves: those with a pool.
  pooled = lib.attrNames (lib.filterAttrs (_: s: s ? pool) net.segments);

  # `expr` with a `segment` label beside `subnet_id`.
  bySegment =
    expr:
    lib.foldl' (
      e: name:
      ''label_replace(${e}, "segment", "${name}", "subnet_id", "${toString net.segments.${name}.id}")''
    ) expr pooled;

  # The share of each segment's pool leased. The pools' series alone, so a
  # pool is counted once, and since every segment has one pool, summed by
  # segment. A pool's count leaves out reservations below it, which the
  # subnet's count includes and the pool can never run out of.
  poolUsed = lib.removeSuffix "\n" ''
    sum by (instance, segment) (${bySegment ''kea_dhcp4_addresses_assigned_total{pool!=""}''})
      / sum by (instance, segment) (${bySegment ''kea_dhcp4_addresses_total{pool!=""}''})
  '';

  # How full a pool gets before DhcpPoolLow fires, and where the dashboard
  # marks it: as a percentage for the alert's text, and as the ratio
  # `poolUsed` is compared with. A whole number, since Nix's toString writes
  # a float with six decimals.
  poolLowPercent = 90;
  poolLow = poolLowPercent / 100.0;
}
