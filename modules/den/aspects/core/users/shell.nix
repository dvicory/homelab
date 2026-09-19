{
  den.aspects.core.users.shell = {
    os =
      { pkgs, ... }:
      {
        programs.zsh = {
          enable = true;
          enableCompletion = true;
        };

        programs.fish.enable = true;
        environment.systemPackages = [
          pkgs.ncurses
          (if pkgs.stdenv.hostPlatform.isDarwin then pkgs.ghostty-bin.terminfo else pkgs.ghostty.terminfo)
        ];

      };

    nixos =
      { pkgs, ... }:
      {
        users.users.root.shell = pkgs.bashInteractive;
        users.defaultUserShell = pkgs.fish;
      };
  };
}
