# Each drive's own health, read from its SMART or NVMe health log by
# smartctl_exporter: the critical-warning field, the SMART verdict, the spare
# and its threshold, media errors and wear, which DriveFailing and DriveWearing
# read (modules/alert-rules.nix). A function of the devices to read, imported
# by the host that has them. docs/observability.md, "Drive health", has the
# design.
#
# nixpkgs' module as it is: a dynamic user in the `disk` group, with
# CAP_SYS_RAWIO and CAP_SYS_ADMIN for smartctl's passthrough commands and
# DeviceAllow for disk and NVMe devices alone. Its udev rule grants NVMe
# controllers (/dev/nvme0) to the exporter only when the device is added, so
# after a switch, until the next boot, only a namespace (/dev/nvme0n1), which
# `disk` can already read, is readable. Name namespaces.
#
# Loopback alone, as modules/blackbox.nix, since the collector scrapes itself.
# A host other than the collector needs a listen address the collector can
# reach and a firewall rule for it, as modules/node-exporter.nix has; the
# assertion below holds the line until one does.
{ devices }:
{
  lib,
  hostname,
  net,
  ...
}:
let
  address = "127.0.0.1:${toString net.ports.smartctlExporter}";
in
{
  assertions = [
    {
      assertion = hostname == net.metricsCollector;
      message = ''
        ${hostname} imports modules/smartctl.nix, which listens on loopback
        for net.metricsCollector, "${net.metricsCollector}", to scrape. A host
        that is not the collector needs the exporter on an address the
        collector can reach first.
      '';
    }
    {
      # The exporter labels each device with its path, less /dev/ and
      # /dev/disk/by-id/. A by-id path holds the drive's serial number, which
      # would then be in every series. And no devices at all means a scan.
      assertion =
        devices != [ ] && lib.all (d: builtins.match "/dev/(nvme[0-9]+n[0-9]+|sd[a-z]+)" d != null) devices;
      message = ''
        modules/smartctl.nix on ${hostname} needs at least one device, each a
        kernel name such as /dev/nvme0n1 or /dev/sda, not a /dev/disk path.
      '';
    }
  ];

  services.prometheus.exporters.smartctl = {
    enable = true;
    listenAddress = "127.0.0.1";
    port = net.ports.smartctlExporter;
    inherit devices;
  };

  services.victoriametrics.prometheusConfig.scrape_configs = [
    {
      job_name = "smartctl";
      static_configs = [
        {
          targets = [ address ];
          labels.instance = hostname;
        }
      ];
      # smartctl_device carries the drive's serial number as `serial_number`,
      # which identifies the physical drive. In smartctl_exporter 0.14.0 no
      # other label does: model, firmware and the device's kernel name stay.
      # The pattern is wider than that one label, for the WWN, EUI-64, NGUID
      # or UUID a later version might add, so that an upgrade cannot store one
      # unnoticed.
      metric_relabel_configs = [
        {
          action = "labeldrop";
          regex = ".*(serial|wwn|eui|nguid|uuid).*";
        }
      ];
    }
  ];
}
