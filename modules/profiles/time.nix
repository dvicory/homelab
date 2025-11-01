{ ... }:
{
  flake.modules.nixos.profiles-time =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      logDir = "/var/log/chrony";
      servers = [
        "time.cloudflare.com"
        "stratum1.time.cifelli.xyz"
        "oregon.time.system76.com"
      ];
      user = config.users.users.chrony.name;
      group = config.users.groups.chrony.name;
    in
    {
      # Set timezone (can be overridden per-host)
      time.timeZone = lib.mkDefault "America/Los_Angeles";

      # Disable systemd-timesyncd to avoid conflicts
      services.timesyncd.enable = lib.mkForce false;

      # Use chrony for NTP with NTS support
      services.chrony = {
        inherit servers;
        enable = true;

        enableNTS = true;
        serverOption = "iburst";

        # Additional chrony configuration for better accuracy
        extraConfig = ''
          # Allow chrony to step the clock if step > 1 second
          makestep 1 -1

          # Log measurements and statistics
          logdir ${logDir}
          log measurements statistics tracking
        '';
      };

      # Ensure log directory exists
      systemd.tmpfiles.rules = [
        "d ${logDir} 0755 ${user} ${group} -"
      ];

      services.logrotate.settings."${logDir}/*.log" = {
        rotate = 4;
        frequency = "weekly";
        missingok = true;
        nocreate = true;
        sharedscripts = true;
        postrotate = ''
          ${pkgs.chrony}/bin/chronyc cyclelogs > /dev/null 2>&1 || true
        '';
      };

      # Configure impermanence for chrony logs and drift files
      dlab.impermanence.additionalDirectories = [
        {
          directory = logDir;
          inherit user group;
        }
        {
          directory = config.services.chrony.directory;
          inherit user group;
        }
      ];
    };
}
