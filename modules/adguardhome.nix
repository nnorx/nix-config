# AdGuard Home — DNS filtering, ad blocking, and web UI
# Parameterized for use by multiple hosts with different DNS backends
{
  adminUser,
  adminPasswordHash,
  upstreamDns,
  fallbackDns ? [ ],
  bootstrapDns ? [
    "1.1.1.1"
    "8.8.8.8"
  ],
  cacheEnabled ? false,
  cacheOptimistic ? cacheEnabled,
  dnssecEnabled ? false,
  upstreamTimeout ? "2s",
}:
{ ... }:
{
  services.adguardhome = {
    enable = true;
    mutableSettings = false;
    host = "0.0.0.0";
    port = 3000;
    openFirewall = false; # Managed per-interface in host config

    settings = {
      users = [
        {
          name = adminUser;
          password = adminPasswordHash;
        }
      ];

      dns = {
        bind_hosts = [ "0.0.0.0" ];
        port = 53;

        upstream_dns = upstreamDns;
        fallback_dns = fallbackDns;
        bootstrap_dns = bootstrapDns;

        cache_enabled = cacheEnabled;
        # Answer from cache immediately and refresh behind it, so an upstream
        # outage is invisible for anything already looked up once.
        cache_optimistic = cacheOptimistic;
        enable_dnssec = dnssecEnabled;

        # Default is 10s. That is how long AdGuard sits on a dead upstream
        # before it will try fallback_dns, which turns a working failover into
        # a 10-20s stall on every cache miss. Only reached when an upstream
        # stops answering without refusing the connection: a powered-off host
        # or a hung resolver, both of which drop packets rather than reset.
        upstream_timeout = upstreamTimeout;

        ratelimit = 300; # Per-client queries/sec — generous for normal use, limits abuse
      };

      filtering = {
        protection_enabled = true;
        filtering_enabled = true;
        parental_enabled = false;
        safe_search = {
          enabled = false;
        };
      };

      # Blocklists migrated from pihole gravity.db
      filters =
        let
          blocklists = [
            # Ad blocking
            {
              url = "https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts";
              name = "StevenBlack Unified";
            }
            {
              url = "https://raw.githubusercontent.com/PolishFiltersTeam/KADhosts/master/KADhosts.txt";
              name = "KADhosts";
            }
            {
              url = "https://v.firebog.net/hosts/static/w3kbl.txt";
              name = "Firebog w3kbl";
            }
            {
              url = "https://v.firebog.net/hosts/AdguardDNS.txt";
              name = "Firebog AdGuard DNS";
            }
            {
              url = "https://v.firebog.net/hosts/Admiral.txt";
              name = "Firebog Admiral";
            }
            {
              url = "https://raw.githubusercontent.com/anudeepND/blacklist/master/adservers.txt";
              name = "anudeepND adservers";
            }
            {
              url = "https://v.firebog.net/hosts/Easylist.txt";
              name = "Firebog Easylist";
            }
            {
              url = "https://pgl.yoyo.org/adservers/serverlist.php?hostformat=hosts&showintro=0&mimetype=plaintext";
              name = "Peter Lowe adservers";
            }
            {
              url = "https://raw.githubusercontent.com/bigdargon/hostsVN/master/hosts";
              name = "hostsVN";
            }
            # Privacy / tracking
            {
              url = "https://v.firebog.net/hosts/Easyprivacy.txt";
              name = "Firebog Easyprivacy";
            }
            {
              url = "https://v.firebog.net/hosts/Prigent-Ads.txt";
              name = "Firebog Prigent Ads";
            }
            {
              url = "https://raw.githubusercontent.com/crazy-max/WindowsSpyBlocker/master/data/hosts/spy.txt";
              name = "WindowsSpyBlocker";
            }
            {
              url = "https://hostfiles.frogeye.fr/firstparty-trackers-hosts.txt";
              name = "Frogeye first-party trackers";
            }
            # Malware / phishing
            {
              url = "https://raw.githubusercontent.com/DandelionSprout/adfilt/master/Alternate%20versions%20Anti-Malware%20List/AntiMalwareHosts.txt";
              name = "DandelionSprout Anti-Malware";
            }
            {
              url = "https://v.firebog.net/hosts/Prigent-Crypto.txt";
              name = "Firebog Prigent Crypto";
            }
            {
              url = "https://phishing.army/download/phishing_army_blocklist_extended.txt";
              name = "Phishing Army";
            }
            {
              url = "https://v.firebog.net/hosts/RPiList-Malware.txt";
              name = "Firebog RPiList Malware";
            }
            {
              url = "https://v.firebog.net/hosts/RPiList-Phishing.txt";
              name = "Firebog RPiList Phishing";
            }
            {
              url = "https://raw.githubusercontent.com/Spam404/lists/master/main-blacklist.txt";
              name = "Spam404";
            }
            {
              url = "https://raw.githubusercontent.com/AssoEchap/stalkerware-indicators/master/generated/hosts";
              name = "Stalkerware Indicators";
            }
            {
              url = "https://urlhaus.abuse.ch/downloads/hostfile/";
              name = "URLhaus";
            }
            {
              url = "https://lists.cyberhost.uk/malware.txt";
              name = "CyberHost Malware";
            }
            {
              url = "https://gitlab.com/quidsup/notrack-blocklists/-/raw/master/notrack-malware.txt";
              name = "NoTrack Malware";
            }
          ];
        in
        builtins.genList (i: {
          enabled = true;
          id = i + 1;
          inherit (builtins.elemAt blocklists i) url name;
        }) (builtins.length blocklists);
    };
  };
}
