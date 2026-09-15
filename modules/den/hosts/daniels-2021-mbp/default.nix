{ den, ... }: {
  den.hosts.aarch64-darwin.daniels-2021-mbp = {
    environment = "home";
    system-access-groups = [ "workstation-access" ];
  };

  den.aspects.daniels-2021-mbp = {
    includes = [ den.aspects.secrets.agenix ];

    darwin = { pkgs, ... }: {
      networking.hostName = "daniels-2021-mbp";
      system.primaryUser = "daniel.vicory";

      nix.linux-builder = {
        enable = true;
        package = pkgs.darwin.linux-builder-vz;
        systems = [
          "aarch64-linux"
          "x86_64-linux"
        ];
        supportedFeatures = [
          "benchmark"
          "big-parallel"
        ];
      };

      environment.systemPackages = with pkgs; [
        git
      ];
    };
  };
}
