{
  den.aspects.core.users.shell = {
    os = {
      programs.zsh = {
        enable = true;
        enableCompletion = true;
      };

      programs.fish.enable = true;
    };

    nixos =
      { pkgs, ... }:
      {
        environment.enableAllTerminfo = true;
        users.users.root.shell = pkgs.bashInteractive;
        users.defaultUserShell = pkgs.fish;
      };
  };
}
