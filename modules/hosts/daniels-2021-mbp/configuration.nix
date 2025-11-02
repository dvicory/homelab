{
  flake.dlab.hosts = {
    daniels-2021-mbp = {
      system = "aarch64-darwin";
      tags = [
        "home"
      ];
    };
  };

  flake.modules.darwin.hosts-daniels-2021-mbp =
    { pkgs, ... }:
    {
      environment.systemPackages = with pkgs; [
        git
      ];
    };
}
