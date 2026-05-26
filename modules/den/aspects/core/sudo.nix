_: {
  den.aspects.core.sudo = {
    nixos = {
      security.sudo.enable = false;
      security.sudo-rs = {
        enable = true;
        wheelNeedsPassword = true;
      };
    };
  };
}
