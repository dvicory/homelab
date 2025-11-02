{ self, ... }:
{
  # Define the darwin class module
  flake.modules.darwin.darwin =
    { ... }:
    {
      imports = [
        # Base profile - provides reasonable defaults for all Darwin systems
        self.modules.darwin.profiles-base
      ];
    };

  flake.modules.darwin.aarch64-darwin = { };
  flake.modules.darwin.x86_64-darwin = { };
}
