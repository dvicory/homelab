{ den, ... }: {
  den.hosts.aarch64-darwin.daniels-2021-mbp = {
    environment = "home";
    system-access-groups = [ "workstation-access" ];
  };

  den.aspects.daniels-2021-mbp = {
    darwin = { pkgs, ... }: {
      networking.hostName = "daniels-2021-mbp";

      environment.systemPackages = with pkgs; [
        git
      ];
    };
  };
}
