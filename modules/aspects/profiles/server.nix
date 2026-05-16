{ den, ... }: {
  den.aspects."dlab/profile/server" = {
    includes = [
      den.aspects."dlab/services/crowdsec"
      den.aspects."dlab/services/crowdsec".provides.bouncer
    ];

    nixos = { ... }: {
      services.crowdsec.enable = true;
      services.crowdsec-firewall-bouncer.enable = true;
    };
  };
}
