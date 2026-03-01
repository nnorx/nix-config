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
  dnssecEnabled ? false,
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
        enable_dnssec = dnssecEnabled;

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
              url = "https://raw.githubusercontent.com/FadeMind/hosts.extras/master/add.Spam/hosts";
              name = "FadeMind Spam";
            }
            {
              url = "https://v.firebog.net/hosts/static/w3kbl.txt";
              name = "Firebog w3kbl";
            }
            {
              url = "https://adaway.org/hosts.txt";
              name = "AdAway";
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
              url = "https://raw.githubusercontent.com/FadeMind/hosts.extras/master/UncheckyAds/hosts";
              name = "FadeMind UncheckyAds";
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
              url = "https://raw.githubusercontent.com/FadeMind/hosts.extras/master/add.2o7Net/hosts";
              name = "FadeMind 2o7Net";
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
              url = "https://osint.digitalside.it/Threat-Intel/lists/latestdomains.txt";
              name = "DigitalSide Threat Intel";
            }
            {
              url = "https://v.firebog.net/hosts/Prigent-Crypto.txt";
              name = "Firebog Prigent Crypto";
            }
            {
              url = "https://raw.githubusercontent.com/FadeMind/hosts.extras/master/add.Risk/hosts";
              name = "FadeMind Risk";
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
