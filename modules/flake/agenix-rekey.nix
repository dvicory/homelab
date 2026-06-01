{ inputs, ... }: {
  perSystem =
    { ... }:
    {
      agenix-rekey = {
        nixosConfigurations = inputs.self.outputs.nixosConfigurations or { };
        darwinConfigurations = { };
      };
    };
}
