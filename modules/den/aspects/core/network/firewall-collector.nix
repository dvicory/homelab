{
  den.aspects.core.network.firewall-collector = {
    nixos = { firewall, lib, ... }: {
      imports = [ ./_firewall-lifetime.nix ];
      config = lib.mkMerge firewall;
    };
  };
}
