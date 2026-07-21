{ den, ... }: {
  den.aspects.roles.server = {
    includes = with den.aspects; [
      core.security.openssh

      services.security.crowdsec
      services.security.crowdsec.provides.bouncer
    ];

    nixos = {
      services.crowdsec.enable = true;
      services.crowdsec-firewall-bouncer.enable = true;
    };
  };
}
