{ den, ... }: {
  den.hosts.aarch64-darwin.daniels-2021-mbp = { };

  den.aspects.daniels-2021-mbp = {
    includes = [
      den.batteries.hostname
    ];

    darwin = { pkgs, ... }: {
      networking.hostName = "daniels-2021-mbp";

      environment.systemPackages = with pkgs; [
        git
      ];
    };
  };
}
