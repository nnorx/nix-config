# UniFi Network Application, containerised, for adopting and managing the
# Flex switch and the U7 Pro.
#
# Containers rather than `services.unifi`, and the reason is not preference.
# Both `unifi` and `mongodb` are unfree (Ubiquiti's EULA and SSPL), so Hydra
# does not build them and cache.nixos.org does not carry them. The module path
# would mean a Pi compiling MongoDB from source, CI attempting the same build
# inside its 350-minute cap, and the result being pushed to a *public* Cachix,
# which is redistribution of both. Pinned images avoid all three.
#
# It also decouples controller upgrades from `nix flake update`. UniFi's
# database migrations are one-way: a lock bump that moved the controller would
# leave a generation rollback facing a newer schema with an older binary, which
# does not start. Here the version moves only when the digest below changes.
#
# What is NOT declarative either way: adoption state, SSIDs, VLAN assignments.
# Those live in MongoDB under both approaches. See the backup section in the
# README, which is the part that actually protects them.
{
  config,
  pkgs,
  lib,
  hostname,
  net,
  ...
}:
let
  stateDir = "/var/lib/unifi";
  dockerNet = "unifi";
  docker = "${config.virtualisation.docker.package}/bin/docker";

  user = config.users.users.${hostname};

  # The address devices are told to report to.
  #
  # Without this the controller advertises its own address, which on a bridge
  # network is something in 172.16/12 that no device on the LAN can reach. The
  # symptom is not an error: adoption appears to start and then loops forever,
  # because the device is adopted, cannot inform, and retries.
  #
  # It lives in system.properties inside the config volume, so it is state
  # rather than configuration, and clearing that volume silently reintroduces
  # the bug. Seeding it before every start makes it survive a wipe. The address
  # comes from lib/net.nix, so it follows the host when the Pis renumber.
  seedInformHost = pkgs.writeShellApplication {
    name = "unifi-seed-inform-host";
    runtimeInputs = with pkgs; [
      coreutils
      gnugrep
      gnused
    ];
    text = ''
      props=${stateDir}/config/data/system.properties
      want="system_ip=${net.hosts.${hostname}.ip}"

      mkdir -p "$(dirname "$props")"
      touch "$props"

      if grep -q "^system_ip=" "$props"; then
        sed -i "s|^system_ip=.*|$want|" "$props"
      else
        printf '%s\n' "$want" >> "$props"
      fi
    '';
  };

  # Runs on first database init only, from the mongo image's
  # /docker-entrypoint-initdb.d hook. Shell rather than the .js the upstream
  # docs suggest, because .sh hooks get the container environment: the password
  # arrives as $MONGO_PASS from the sops-rendered env file and never appears in
  # a store path. JS string concatenation builds the _stat database name so
  # this file needs no `${}` at all.
  mongoInit = pkgs.writeShellScript "unifi-mongo-init" ''
    mongosh --quiet --eval "
      db.getSiblingDB('$MONGO_DBNAME').createUser({
        user: '$MONGO_USER', pwd: '$MONGO_PASS',
        roles: [{ role: 'dbOwner', db: '$MONGO_DBNAME' }]
      });
      db.getSiblingDB('$MONGO_DBNAME' + '_stat').createUser({
        user: '$MONGO_USER', pwd: '$MONGO_PASS',
        roles: [{ role: 'dbOwner', db: '$MONGO_DBNAME' + '_stat' }]
      });
    "
  '';
in
{
  sops.secrets.unifi-mongo-password.sopsFile = ../secrets/${hostname}.yaml;

  # One env file for both containers: the application authenticates with the
  # same credential the database is initialised with, so splitting them is a
  # way to have them drift.
  sops.templates."unifi-db.env".content = ''
    MONGO_USER=unifi
    MONGO_PASS=${config.sops.placeholder.unifi-mongo-password}
    MONGO_DBNAME=unifi
  '';

  systemd.tmpfiles.rules = [
    # Traversable, so the host user can reach `config` below. It was 0750
    # root:root, which meant the documented backup command could not enter the
    # directory at all even though the directory it wanted was owned by that
    # user. Nothing sensitive lives at this level; the contents carry their own
    # modes.
    "d ${stateDir} 0755 root root -"

    # The database is root's. Mongo starts as root and drops privileges itself.
    "d ${stateDir}/db 0700 root root -"

    # Owned by the host user rather than a container-internal id, so the
    # backup in the README can read it without root.
    "d ${stateDir}/config 0750 ${hostname} ${user.group} -"
  ];

  # oci-containers does not create networks. Both containers need one so the
  # application can reach the database by name, and neither publishes the
  # database port, so mongo is reachable only from inside it.
  systemd.services."docker-network-${dockerNet}" = {
    description = "Docker network for the UniFi containers";
    after = [ "docker.service" ];
    requires = [ "docker.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      ${docker} network inspect ${dockerNet} >/dev/null 2>&1 \
        || ${docker} network create ${dockerNet}
    '';
  };

  virtualisation.oci-containers = {
    backend = "docker";
    containers = {
      unifi-db = {
        # mongo:8.0, pinned by manifest-list digest so the tag cannot move
        # under us. Multi-arch: resolves to linux/arm64 here.
        #
        # MongoDB 5+ requires ARMv8.2-A. The Pi 5's Cortex-A76 has it; the
        # Pi 4's Cortex-A72 does not, so this cannot be moved to core4 or
        # lifeline without changing database.
        image = "docker.io/library/mongo:8.0@sha256:02a0cc7939f5ed38f30f9bc714ef5f682d49baf9350c54acf302ce833087fe8a";
        environmentFiles = [ config.sops.templates."unifi-db.env".path ];
        volumes = [
          "${stateDir}/db:/data/db"
          "${mongoInit}:/docker-entrypoint-initdb.d/init.sh:ro"
        ];
        extraOptions = [ "--network=${dockerNet}" ];
      };

      unifi = {
        image = "lscr.io/linuxserver/unifi-network-application:10.6.101@sha256:3017d2baabbc3f3f123dc1c892794f40c05516ccac0b94b95a7f4a0f7a417c5e";
        dependsOn = [ "unifi-db" ];
        environment = {
          PUID = toString user.uid;
          PGID = toString config.users.groups.${user.group}.gid;
          TZ = config.time.timeZone;
          MONGO_HOST = "unifi-db";
          MONGO_PORT = "27017";
          # The database the credential was created in, which is the
          # application's own rather than `admin`.
          MONGO_AUTHSOURCE = "unifi";
        };
        environmentFiles = [ config.sops.templates."unifi-db.env".path ];
        volumes = [ "${stateDir}/config:/config" ];
        ports = [
          "${toString net.ports.unifiUi}:8443"
          "${toString net.ports.unifiInform}:8080"
          "${toString net.ports.unifiStun}:3478/udp"
          "${toString net.ports.unifiDiscovery}:10001/udp"
        ];
        extraOptions = [ "--network=${dockerNet}" ];
      };
    };
  };

  # Both containers wait for the network unit; without this they race it on
  # boot and fail with "network unifi not found", which Restart papers over
  # slowly rather than fixing.
  systemd.services.docker-unifi-db = {
    after = [ "docker-network-${dockerNet}.service" ];
    requires = [ "docker-network-${dockerNet}.service" ];
  };
  systemd.services.docker-unifi = {
    after = [ "docker-network-${dockerNet}.service" ];
    requires = [ "docker-network-${dockerNet}.service" ];

    # `+` so it runs as root: the config volume is owned by the container's
    # user, not by whatever the unit would otherwise run as.
    serviceConfig.ExecStartPre = [ "+${lib.getExe seedInformHost}" ];
  };
}
