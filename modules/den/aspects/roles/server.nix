{ den, ... }: {
  den.aspects.roles.server = {
    includes = [
      den.aspects.services.crowdsec
      den.aspects.services.crowdsec.provides.bouncer
    ];

    nixos = { ... }: {
      services.crowdsec.enable = true;
      services.crowdsec-firewall-bouncer.enable = true;
    };
  };
}
