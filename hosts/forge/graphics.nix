# Hybrid graphics: the Radeon iGPU drives the desktop, the RTX 5070 module
# runs on demand through PRIME offload (`nvidia-offload <cmd>`, or "use
# dedicated GPU" in Plasma and Steam). nixos-hardware supplies the rest: the
# open kernel modules Blackwell requires, offload mode, and power management.
# On this driver, VRAM is saved across suspend and hibernate by the kernel
# module's own notifier (`powerManagement.kernelSuspendNotifier`), not by
# nvidia-suspend/-hibernate/-resume units, which do not exist here. Look in
# the kernel log, not systemd, when a resume goes wrong.
{
  hardware.nvidia = {
    # nixos-hardware ships example values that must be replaced. These come
    # from `lspci | grep -E "VGA|3D|Display"` on this machine, converted from
    # hex to decimal.
    #
    # They are not stable. They move when expansion cards or NVMe drives
    # change, so re-check them after the Windows drive goes into the 2230
    # slot. The symptom of a stale value is offload quietly doing nothing.
    prime = {
      # Read 2026-09-24 with only the 2 TB drive installed: c2:00.0 and
      # c1:00.0.
      amdgpuBusId = "PCI:194:0:0";
      nvidiaBusId = "PCI:193:0:0";
    };

    # Powers the dGPU fully off when nothing is using it. Offload mode only;
    # most of the battery difference between the two GPUs is this line.
    powerManagement.finegrained = true;
  };
}
