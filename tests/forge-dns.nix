# forge's DNS, end to end in VMs: at home the fleet's resolvers answer alone;
# away the outside one answers over TLS and the network's own resolver sees
# nothing, not even while the connection comes up; both survive a
# NetworkManager restart, which a switch that changes its config causes; a
# tunnel profile's resolvers answer alone while it is up; and behind a captive
# portal lookups fail until portal-dns hands the network its resolver back.
#
# `nix build .#checks.x86_64-linux.forge-dns`. It needs KVM, which forge's
# daemon has; CI evaluates it without building.
#
# forge here is hosts/forge/dns.nix on three wired NICs: the house, a hotel,
# and a stand-in for the split tunnel, which is an ethernet profile carrying
# the tunnel's DNS settings rather than WireGuard, since its DNS is what is
# under test. Each resolver answers every name with its own address from RFC
# 5737's 192.0.2.0/24, so an answer says which one gave it. The outside
# resolver is unbound with TLS only, on `encryptedResolvers`' addresses, with a
# certificate for their name from a CA only forge trusts.
{ net }:
let
  seg = net.segments;
  fleet = map (h: net.hosts.${h}.ip) net.resolvers;
  outside = map (r: r.ip) net.encryptedResolvers;
  outsideName = (builtins.head net.encryptedResolvers).name;

  answers = {
    home = "192.0.2.1";
    hotel = "192.0.2.2";
    outside = "192.0.2.3";
  };

  # Documentation and shared address space: nothing in the fleet, so they
  # belong here rather than in lib/net.nix.
  hotel = {
    gateway = "198.51.100.1";
    gateway6 = "2001:db8:1::1";
    subnet = "198.51.100.0/24";
    first = "198.51.100.100";
    last = "198.51.100.200";
  };
  tunnel = {
    gateway = "100.64.0.1";
    forge = "100.64.0.2";
  };
  upstream = {
    internet = "203.0.113.1";
    home = "203.0.113.2";
    hotel = "203.0.113.3";
  };

  # Test VLANs, which are QEMU's virtual wires, not 802.1Q tags.
  wire = {
    home = 1;
    hotel = 2;
    tunnel = 3;
    upstream = 4;
  };

  certs =
    pkgs:
    pkgs.runCommand "forge-dns-test-certs" { nativeBuildInputs = [ pkgs.openssl ]; } ''
      mkdir $out
      openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
        -days 36500 -subj /CN=forge-dns-test-ca -keyout ca.key -out $out/ca.pem
      openssl req -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
        -subj /CN=${outsideName} -keyout $out/key.pem -out leaf.csr
      printf 'subjectAltName=DNS:${outsideName}\n' > ext
      openssl x509 -req -in leaf.csr -CA $out/ca.pem -CAkey ca.key -CAcreateserial \
        -days 36500 -extfile ext -out $out/cert.pem
    '';

  addrs =
    prefixLength:
    map (address: {
      inherit address prefixLength;
    });

  # A router between one network and the upstream wire.
  router = side: {
    networking = {
      useDHCP = false;
      firewall.enable = false;
      nftables.enable = true;
      defaultGateway = {
        address = upstream.internet;
        interface = "upstream";
      };
      interfaces.upstream.ipv4.addresses = addrs 24 [ upstream.${side} ];
    };
    virtualisation.interfaces.upstream.vlan = wire.upstream;
    boot.kernel.sysctl."net.ipv4.ip_forward" = 1;
  };

  # DHCP on `iface`, and a resolver answering every name with `answer`, with
  # each query logged.
  dhcpAndDns =
    {
      iface,
      range,
      gateway,
      resolvers,
      answer,
      extraInterfaces ? [ ],
      extraRanges ? [ ],
    }:
    {
      enable = true;
      resolveLocalQueries = false;
      settings = {
        interface = [ iface ] ++ extraInterfaces;
        bind-interfaces = true;
        no-resolv = true;
        address = "/#/${answer}";
        log-queries = true;
        dhcp-range = [ "${range},1h" ] ++ extraRanges;
        enable-ra = extraRanges != [ ];
        dhcp-option = [
          "option:router,${gateway}"
          "option:dns-server,${builtins.concatStringsSep "," resolvers}"
        ];
      };
    };
in
{
  name = "forge-dns";

  node.specialArgs = { inherit net; };

  nodes = {
    forge =
      { pkgs, ... }:
      {
        imports = [ ../hosts/forge/dns.nix ];

        virtualisation.interfaces = {
          home.vlan = wire.home;
          hotel.vlan = wire.hotel;
          tun.vlan = wire.tunnel;
        };

        networking.useDHCP = false;
        networking.networkmanager = {
          enable = true;
          unmanaged = [ "eth0" ];
          settings.main.no-auto-default = "*";
          ensureProfiles.profiles = {
            home-net = {
              connection = {
                id = "home-net";
                type = "ethernet";
                interface-name = "home";
                autoconnect = false;
              };
              ipv4.method = "auto";
              ipv6.method = "disabled";
            };
            hotel-net = {
              connection = {
                id = "hotel-net";
                type = "ethernet";
                interface-name = "hotel";
                autoconnect = false;
              };
              ipv4.method = "auto";
              ipv6.method = "auto";
            };
            # The DNS half of "home (split)" in hosts/forge/vpn.nix. TLS is off
            # by hand because this stand-in is ethernet, which dns.nix defaults
            # to TLS; the real profile is WireGuard, which it does not.
            tunnel = {
              connection = {
                id = "tunnel";
                type = "ethernet";
                interface-name = "tun";
                autoconnect = false;
                dns-over-tls = 0;
              };
              ipv4 = {
                method = "manual";
                address1 = "${tunnel.forge}/24";
                never-default = true;
                dns = builtins.concatStringsSep "" (map (ip: "${ip};") fleet);
                dns-search = "~;";
                dns-priority = -50;
              }
              // builtins.listToAttrs (
                builtins.genList (i: {
                  name = "route${toString (i + 1)}";
                  value = "${builtins.elemAt fleet i}/32,${tunnel.gateway}";
                }) (builtins.length fleet)
              );
              ipv6.method = "disabled";
            };
          };
        };

        security.pki.certificateFiles = [ "${certs pkgs}/ca.pem" ];

        # Looks a name up as fast as it can, to catch any lookup that reaches
        # a network's resolver while a connection comes up.
        environment.systemPackages = [
          (pkgs.writeShellScriptBin "lookup-loop" ''
            while :; do
              ${pkgs.systemd}/bin/resolvectl query --cache=no probe.test >/dev/null 2>&1
              ${pkgs.coreutils}/bin/sleep 0.02
            done
          '')
        ];
      };

    # gate, the fleet's two resolvers, and the tunnel's far end in one. 853 is
    # refused on the way out, as gate refuses it on trusted.
    home = {
      imports = [ (router "home") ];
      virtualisation.interfaces = {
        home.vlan = wire.home;
        tun.vlan = wire.tunnel;
      };
      networking = {
        interfaces.home.ipv4.addresses =
          addrs seg.trusted.prefixLength [ seg.trusted.gateway ] ++ addrs 32 fleet;
        interfaces.tun.ipv4.addresses = addrs 24 [ tunnel.gateway ];
        nftables.ruleset = ''
          table inet gate {
            counter refused {}
            chain forward {
              type filter hook forward priority 0; policy accept;
              tcp dport 853 counter name refused reject with tcp reset
            }
          }
        '';
      };
      services.dnsmasq = dhcpAndDns {
        iface = "home";
        extraInterfaces = [ "tun" ];
        range = "${seg.trusted.pool.first},${seg.trusted.pool.last},255.255.255.0";
        gateway = seg.trusted.gateway;
        resolvers = fleet;
        answer = answers.home;
      };
    };

    # Hands out its own resolver, which answers everything, as a captive
    # portal's does.
    hotel = {
      imports = [ (router "hotel") ];
      virtualisation.interfaces.hotel.vlan = wire.hotel;
      networking.interfaces.hotel.ipv4.addresses = addrs 24 [ hotel.gateway ];
      # IPv6 too, with its resolver in the router advertisements, as many
      # networks have.
      networking.interfaces.hotel.ipv6.addresses = addrs 64 [ hotel.gateway6 ];
      networking.nftables.ruleset = ''
        table inet portal {
          chain forward {
            type filter hook forward priority 0; policy accept;
          }
        }
      '';
      services.dnsmasq = dhcpAndDns {
        iface = "hotel";
        range = "${hotel.first},${hotel.last},255.255.255.0";
        inherit (hotel) gateway;
        resolvers = [ hotel.gateway ];
        extraRanges = [ "::,constructor:hotel,ra-only" ];
        answer = answers.hotel;
      };
    };

    # The outside resolver, over TLS and nothing else, with counters for what
    # arrives at its addresses.
    internet =
      { pkgs, ... }:
      {
        virtualisation.interfaces.upstream.vlan = wire.upstream;
        networking = {
          useDHCP = false;
          firewall.enable = false;
          nftables.enable = true;
          interfaces.upstream.ipv4.addresses = addrs 24 [ upstream.internet ] ++ addrs 32 outside;
          interfaces.upstream.ipv4.routes = [
            {
              address = builtins.head (builtins.split "/" seg.trusted.subnet);
              inherit (seg.trusted) prefixLength;
              via = upstream.home;
            }
            {
              address = builtins.head (builtins.split "/" hotel.subnet);
              prefixLength = 24;
              via = upstream.hotel;
            }
          ];
          nftables.ruleset = ''
            table inet outside {
              counter plaintext {}
              counter tls {}
              chain input {
                type filter hook input priority 0; policy accept;
                ip daddr { ${builtins.concatStringsSep ", " outside} } meta l4proto { tcp, udp } th dport 53 counter name plaintext
                ip daddr { ${builtins.concatStringsSep ", " outside} } tcp dport 853 tcp flags syn counter name tls
              }
            }
          '';
        };
        services.unbound = {
          enable = true;
          resolveLocalQueries = false;
          enableRootTrustAnchor = false;
          settings.server = {
            interface = map (ip: "${ip}@853") outside;
            tls-port = 853;
            tls-service-key = "${certs pkgs}/key.pem";
            tls-service-pem = "${certs pkgs}/cert.pem";
            access-control = [ "0.0.0.0/0 allow" ];
            local-zone = [ ". static" ];
            local-data = [ ''"probe.test. A ${answers.outside}"'' ];
          };
        };
      };
  };

  testScript = ''
    import re

    start_all()

    home.wait_for_unit("dnsmasq.service")
    hotel.wait_for_unit("dnsmasq.service")
    internet.wait_for_unit("unbound.service")
    internet.wait_for_open_port(853, "${builtins.head outside}")
    forge.wait_for_unit("NetworkManager.service")
    forge.wait_until_succeeds("nmcli connection show tunnel")
    forge.wait_for_unit("systemd-resolved.service")

    def counter(machine, table, name):
        out = machine.succeed(f"nft list counter inet {table} {name}")
        match = re.search(r"packets (\d+)", out)
        assert match, out
        return int(match.group(1))

    def hotel_queries():
        return int(hotel.succeed("journalctl -u dnsmasq -o cat | grep -c 'query\\[' || true").strip())

    def lookup():
        out = forge.succeed("resolvectl query --cache=no -4 probe.test")
        print(out)
        match = re.search(r"192\.0\.2\.\d+", out)
        assert match, out
        return match.group(0)

    def dispatched(message):
        return int(forge.succeed(f"journalctl -u NetworkManager-dispatcher -o cat | grep -c -E '{message}' || true").strip())

    def restart_networkmanager(message):
        before = dispatched(message)
        forge.succeed("systemctl restart NetworkManager")
        forge.wait_until_succeeds(
            f"[ $(journalctl -u NetworkManager-dispatcher -o cat | grep -c -E '{message}') -gt {before} ]",
            timeout=60,
        )

    def answered_by(expected):
        forge.wait_until_succeeds(
            f"resolvectl query --cache=no -4 probe.test | grep -F '{expected}'", timeout=60
        )
        assert lookup() == expected

    with subtest("home: the fleet's resolvers answer alone, and nothing goes out on 853"):
        tls = counter(internet, "outside", "tls")
        forge.succeed("nmcli connection up home-net")
        answered_by("${answers.home}")
        for _ in range(5):
            assert lookup() == "${answers.home}"
        print(forge.succeed("resolvectl status"))
        assert counter(home, "gate", "refused") == 0, "forge tried TLS at home"
        assert counter(internet, "outside", "tls") == tls
        assert dispatched("home: (pre-up|dhcp4-change): home") > 0

    with subtest("home: a NetworkManager restart, as a switch that changes its config does, keeps the fleet"):
        restart_networkmanager("home: (pre-up|dhcp4-change): home")
        answered_by("${answers.home}")
        print(forge.succeed("resolvectl status home"))
        forge.succeed("nmcli connection down home-net")

    with subtest("away: the outside resolver answers over TLS, and the hotel's sees nothing"):
        # Looking names up throughout, to catch any that reach the hotel's
        # resolver between NetworkManager handing it to resolved and
        # network-dns running.
        forge.succeed("systemd-run --unit=lookup-loop /run/current-system/sw/bin/lookup-loop")
        forge.succeed("nmcli connection up hotel-net")
        answered_by("${answers.outside}")
        # The hotel handed out an IPv6 resolver too, in its router advertisements.
        forge.succeed("journalctl -u systemd-resolved -o cat | grep -E 'hotel: Bus client set DNS server list to: .*fe80:'")
        for _ in range(5):
            assert lookup() == "${answers.outside}"
        forge.succeed("systemctl stop lookup-loop")
        print(forge.succeed("resolvectl status"))
        assert counter(internet, "outside", "tls") > 0
        assert hotel_queries() == 0, "the hotel's resolver saw a lookup"

    with subtest("away: a NetworkManager restart keeps the outside resolver"):
        restart_networkmanager("hotel: pre-up: away")
        answered_by("${answers.outside}")
        print(forge.succeed("resolvectl status hotel"))
        assert hotel_queries() == 0, "the hotel's resolver saw a lookup after a restart"

    with subtest("tunnel: its resolvers answer alone while it is up"):
        tls = counter(internet, "outside", "tls")
        forge.succeed("nmcli connection up tunnel")
        answered_by("${answers.home}")
        for _ in range(5):
            assert lookup() == "${answers.home}"
        assert counter(internet, "outside", "tls") == tls
        forge.succeed("nmcli connection down tunnel")
        answered_by("${answers.outside}")

    with subtest("captive portal: lookups fail closed until the network's resolver is handed back"):
        hotel.succeed("nft add rule inet portal forward tcp dport 853 reject with tcp reset")
        forge.succeed("nmcli connection up hotel-net")
        forge.fail("resolvectl query --cache=no -4 probe.test")
        assert hotel_queries() == 0, "the hotel's resolver saw a lookup before portal-dns"
        forge.succeed("portal-dns hotel")
        answered_by("${answers.hotel}")
        hotel.succeed("nft flush chain inet portal forward")
        forge.succeed("nmcli connection up hotel-net")
        answered_by("${answers.outside}")

    with subtest("nothing went to the outside resolver in plaintext"):
        assert counter(internet, "outside", "plaintext") == 0
  '';
}
