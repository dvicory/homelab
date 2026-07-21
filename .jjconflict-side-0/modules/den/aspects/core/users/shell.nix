{
  den.aspects.core.users.shell = {
    os = {
      programs.zsh = {
        enable = true;
        enableCompletion = true;
      };

      programs.fish.enable = true;

      environment.enableAllTerminfo = true;
    };

    nixos =
      { pkgs, ... }:
      {
        users.users.root.shell = pkgs.bashInteractive;
        users.defaultUserShell = pkgs.fish;
      };
  };
}
