# The servers' kernel settings. Not forge's: it hibernates, and debugs its
# own processes.
{
  # Sets kernel.kexec_load_disabled and nohibernate. Nothing here boots by
  # kexec or hibernates.
  security.protectKernelImage = true;

  boot.kernel.sysctl = {
    "kernel.kptr_restrict" = 2;
    "kernel.dmesg_restrict" = 1;
    # 1, unlike the kernel's default of 2, cannot be undone without a reboot.
    "kernel.unprivileged_bpf_disabled" = 1;
    "net.core.bpf_jit_harden" = 2;
    "kernel.yama.ptrace_scope" = 1;
    "fs.protected_fifos" = 2;
    "fs.protected_regular" = 2;
    "dev.tty.ldisc_autoload" = 0;
  };
}
