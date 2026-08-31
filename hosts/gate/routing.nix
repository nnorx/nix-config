# Phase 4: gate actually routes.
#
# Still behind the Nest. `wan` keeps its DHCP lease, so everything here sits
# behind double NAT, which breaks inbound and UPnP and nothing this phase is
# testing. The point is to prove the routing path works before anything in the
# house depends on it.
#
# Scope is one segment, trusted, served untagged on lan0 to a single directly
# cabled client. VLANs, the trunk to the Flex switch, and the other three
# segments are Phase 6.
{
  lib,
  net,
  ...
}:
let
  trusted = net.segments.trusted;

  # The one LAN interface this phase serves. Named once so the Kea listener,
  # the address, the nat internal interface, the firewall scope and the
  # systemd ordering below cannot drift apart.
  lanIface = "lan0";

  # Clients are handed both Pi resolvers directly rather than gate proxying to
  # them, which is what keeps AdGuard's per-client attribution meaningful. The
  # Pis are still on the old flat LAN at this point, so queries reach them out
  # through wan and arrive masqueraded from gate's lease. That is fine for a
  # test and stops being true in Phase 6, when they move to `servers`.
  resolvers = [
    net.hosts.core4.ip
    net.hosts.lifeline.ip
  ];
in
{
  # nftables backend rather than iptables. The reason is filterForward below:
  # NixOS only offers a filtered forward chain on this backend, and a router
  # whose forward chain defaults to accept is not a firewall.
  networking.nftables.enable = true;

  # Masquerade lan0 out of wan, and enable IPv4 forwarding. Using the nat
  # module rather than a hand-written ruleset on purpose: it is the
  # well-trodden path, and hand-rolled NAT on a box that is becoming the house
  # router is a poor place to be original.
  networking.nat = {
    enable = true;
    externalInterface = net.hosts.gate.wanIface;
    internalInterfaces = [ lanIface ];
  };

  networking = {
    interfaces.${lanIface}.ipv4.addresses = [
      {
        address = trusted.gateway;
        inherit (trusted) prefixLength;
      }
    ];

    firewall = {
      # Default-drop forwarding. Without this the forward chain accepts
      # everything, and a router whose forward chain defaults to accept is not
      # a firewall.
      #
      # No extraForwardRules: the nat module already emits
      # `iifname { "lan0" } oifname "wan" accept` from `internalInterfaces`
      # above, and the base ruleset accepts established and related. Adding the
      # same rule by hand duplicates it and, worse, decouples it from
      # `internalInterfaces`, so a later port added there would be silently
      # unmatched by the hand-written copy. Verified by reading the rendered
      # chain rather than assuming.
      filterForward = true;

      # DHCP requests arrive before the client has an address, so they cannot
      # be covered by anything address-based. Scoped to lan0 so this does not
      # open a DHCP server to the WAN side.
      interfaces.${lanIface}.allowedUDPPorts = [ 67 ];
    };
  };

  # The default is sized for a desktop making a few hundred connections. A
  # router holds the state for every device in the house at once, and the
  # failure mode when the table fills is dropped connections with
  # "nf_conntrack: table full" in dmesg, which reads like a network fault
  # rather than a tuning problem.
  boot.kernel.sysctl."net.netfilter.nf_conntrack_max" = 262144;

  # Ordering, so the retries above are a safety net rather than the mechanism.
  # The address unit assigning lan0's address is what makes the interface
  # bindable, and Kea's stock ordering only reaches network-online.target.
  systemd.services.kea-dhcp4-server.after = [ "network-addresses-${lanIface}.service" ];

  services.kea.dhcp4 = {
    enable = true;
    settings = {
      interfaces-config = {
        interfaces = [ lanIface ];

        # Kea tries once by default and, on failure, runs with no listening
        # socket rather than exiting. Observed on the first deploy: it started
        # while lan0 was still down, logged "no interface configured to listen
        # to DHCP traffic", and stayed up and deaf.
        #
        # That is the worst shape a DHCP failure can take on a router. Nothing
        # breaks immediately, because existing leases keep working; the house
        # falls over an hour later when clients try to renew, with no event
        # anywhere near the cause.
        #
        # Retry instead, and require every configured interface, so a
        # persistent failure exits non-zero and the unit's Restart=on-failure
        # keeps trying. Failing loudly and recovering beats running silently
        # and not.
        service-sockets-max-retries = 5;
        service-sockets-retry-wait-time = 5000;
        service-sockets-require-all = true;
      };

      # Leases survive a restart of the daemon and a reboot of the box. Without
      # persistence every reboot is a fresh pool and clients renumber, which on
      # a router is indistinguishable from a fault.
      lease-database = {
        type = "memfile";
        persist = true;
        name = "/var/lib/kea/dhcp4.leases";
      };

      valid-lifetime = 3600;
      renew-timer = 900;
      rebind-timer = 1800;

      subnet4 = [
        {
          id = trusted.id;
          inherit (trusted) subnet;
          pools = [ { pool = "${trusted.pool.first} - ${trusted.pool.last}"; } ];
          option-data = [
            {
              name = "routers";
              data = trusted.gateway;
            }
            {
              name = "domain-name-servers";
              data = lib.concatStringsSep ", " resolvers;
            }
          ];
        }
      ];
    };
  };
}
