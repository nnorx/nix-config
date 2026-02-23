# Brute-force protection with escalating bans
{ ... }:
{
  services.fail2ban = {
    enable = true;
    maxretry = 3;
    bantime = "1h";
    bantime-increment.enable = true;
    jails.sshd = {
      settings = {
        enabled = true;
        filter = "sshd";
        maxretry = 3;
        findtime = "10m";
      };
    };
  };
}
