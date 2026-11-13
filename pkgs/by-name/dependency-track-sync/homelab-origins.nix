{ flake, host }:
let
  configuration =
    if builtins.hasAttr host (flake.nixosConfigurations or { }) then
      flake.nixosConfigurations.${host}
    else
      throw "unsupported origin target: unknown NixOS configuration";
  system = configuration.config.nixpkgs.hostPlatform.system;
  package = value: {
    inherit (value) name drvPath;
    outputPath = toString value;
  };
  # definitionsWithLocations has already discharged conditions and priorities.
  definitions =
    option: values: effective:
    builtins.concatMap (
      definition:
      map
        (value: {
          inherit option;
          definition = definition.file;
          package = package value;
        })
        (
          builtins.filter (
            value:
            builtins.any (
              selected: selected.drvPath == value.drvPath && toString selected == toString value
            ) effective
          ) (values definition.value)
        )
    );
  source =
    value:
    let
      info = value.sourceInfo or value;
    in
    {
      storePath = toString value.outPath;
      revision = info.rev or null;
      narHash = info.narHash or null;
    };
  # Follow the evaluated input graph, including follows and non-flake sources.
  inputs = builtins.genericClosure {
    startSet = [
      {
        key = toString flake.outPath;
        value = flake;
      }
    ];
    operator =
      node:
      map (value: {
        key = toString value.outPath;
        inherit value;
      }) (builtins.attrValues (node.value.inputs or { }));
  };
  aspects = flake.debug.config.den.hosts.${system}.${host}.aspects;
in
{
  inherit system;
  source = source flake;
  # An outPath field would make Nix's JSON serializer coerce this object to a string.
  root = {
    drvPath = configuration.config.system.build.toplevel.drvPath;
    outputPath = toString configuration.config.system.build.toplevel;
  };
  inputs = map (node: source node.value) inputs;
  aspects = map (aspect: {
    inherit (aspect) identityKey;
    file = aspect.meta.file or null;
  }) aspects;
  origins =
    definitions "environment.systemPackages" (value: value)
      configuration.config.environment.systemPackages
      configuration.options.environment.systemPackages.definitionsWithLocations
    ++ definitions "systemd.package" (value: [ value ]) [
      configuration.config.systemd.package
    ] configuration.options.systemd.package.definitionsWithLocations;
}
