{
  flake.modules.nixos.nixos = {
    # Move to sudo-rs
    security.sudo.enable = false;

    security.sudo-rs = {
      enable = true;
      wheelNeedsPassword = true;
    };
  };
}
