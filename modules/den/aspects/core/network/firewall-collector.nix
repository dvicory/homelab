{
  den.aspects.core.network.firewall-collector = {
    # Producers return full NixOS configuration fragments; mkMerge retains
    # interface declarations, conditional rules and source-scoped nft input.
    nixos = { firewall, lib, ... }: lib.mkMerge firewall;
  };
}
