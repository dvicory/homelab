{
  den.aspects.core.localization.time = {
    os =
      { environment, ... }:
      {
        time.timeZone = environment.timezone;
      };

    nixos =
      { config, lib, pkgs, ... }:
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
        services.timesyncd.enable = lib.mkForce false;

        services.chrony = {
          inherit servers;
          enable = true;
          enableNTS = true;
          serverOption = "iburst";

          extraConfig = ''
            makestep 1 -1

            logdir ${logDir}
            log measurements statistics tracking
          '';
        };

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
      };

    persist = { config, ... }:
      let
        logDir = "/var/log/chrony";
        user = config.users.users.chrony.name;
        group = config.users.groups.chrony.name;
      in
      [
        {
          directories = [ config.services.chrony.directory ];
          inherit user group;
        }
        {
          directories = [ logDir ];
          inherit user group;
        }
      ];
  };
}
