# Home Assistant on core5 loads the integrations modules/home-assistant.nix
# lists, and neither `cloud` nor `homeassistant_alerts`, the two of
# `default_config`'s that call Home Assistant's servers. Every one of them
# sets up from an empty YAML key, so a name that needs more fails here, and
# so does a Home Assistant upgrade that moves one.
#
# `nix build .#checks.x86_64-linux.home-assistant`. It needs KVM, which
# forge's daemon has; CI's vm-tests job runs it on pull requests.
{ net, unstable }:
{
  name = "home-assistant";

  node.specialArgs = { inherit net unstable; };

  nodes.core5 =
    { lib, ... }:
    {
      imports = [ ../modules/home-assistant.nix ];
      virtualisation.memorySize = 2048;
      # Setup and its end are logged at info, under these loggers alone.
      services.home-assistant.config.logger = {
        default = "warning";
        logs."homeassistant.setup" = "info";
        logs."homeassistant.bootstrap" = "info";
      };
    };

  testScript = ''
    core5.wait_for_unit("home-assistant.service")
    core5.wait_for_open_port(${toString net.ports.homeAssistant}, timeout=300)
    core5.wait_until_succeeds(
        "journalctl -u home-assistant -o cat | grep -q 'Home Assistant initialized'", timeout=300
    )

    out = core5.succeed("journalctl -u home-assistant -o cat --no-pager")
    core5.log(out)

    for name in ["mobile_app", "webhook", "zeroconf", "usage_prediction"]:
        assert f"Setting up {name}" in out, f"{name} did not set up"

    for name in ["cloud", "homeassistant_alerts"]:
        assert f"Setting up {name}\n" not in out, f"{name} set up"

    for bad in ["Setup failed", "does not support YAML", "Invalid config"]:
        assert bad not in out, bad
  '';
}
