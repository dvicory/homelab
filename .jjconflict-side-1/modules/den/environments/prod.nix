{ self, ... }: {
  den.environments.prod = {
    id = 1;
    domain = "plus2.danielvicory.dev";
    networks.default = {
      cidr = "172.27.50.0/24";
      dnsServers = [ "1.1.1.1" "1.0.0.1" ];
    };
    timezone = "America/Los_Angeles";
    tags.environment = "prod";
  };
}
