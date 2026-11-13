# The flake's checks.x86_64-linux. `nix flake check --no-build`, in preflight,
# only evaluates these. check.yml's `vm-tests` job builds, and so runs, every
# attribute here on pull requests, so a new test needs no workflow edit.
# cache-vm-tests.yml builds them on main and pushes them to Cachix, so a pull
# request copies each test whose inputs it leaves alone instead of running it.
# To run one locally, on a machine with KVM:
# `nix build --no-link .#checks.x86_64-linux.<name>`.
{
  pkgs,
  unstable,
  net,
}:
pkgs.lib.genAttrs
  [
    "gate-dns"
    "gate-metrics"
    "gate-iot-egress"
    "gate-servers-egress"
    "gate-tunnel"
    "deploy-agent"
    "deploy-guard"
    "diag-login"
    "dns-metrics"
    "forge-dns"
    "unbound-root-zone"
    "tang"
    "alerting"
    "grafana"
  ]
  (
    name:
    let
      test = import ./${name}.nix;
    in
    # Each test gets the arguments it names: most take `net`, grafana takes
    # `unstable` too, and deploy-agent takes none.
    pkgs.testers.runNixOSTest (
      test (builtins.intersectAttrs (builtins.functionArgs test) { inherit net unstable; })
    )
  )
// {
  # Not a VM: vmalert-tool, in the build.
  alert-rules = import ./alert-rules.nix { inherit pkgs net; };
}
