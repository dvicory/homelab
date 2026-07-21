{ self, ... }: {
  den.environments.dev = {
    id = 2;
    domain = "dev.plus2.danielvicory.dev";
    networks.default = {
      cidr = "10.99.0.0/16";
      dnsServers = [ "1.1.1.1" "1.0.0.1" ];
    };
    timezone = "America/Los_Angeles";
    tags.environment = "dev";
  };
}
