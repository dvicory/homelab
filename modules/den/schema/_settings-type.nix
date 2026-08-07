{ lib, den }:
let
  inherit (lib) mkOption types;
  inherit (den.lib.aspects.fx.keyClassification) structuralKeysSet;
  classKeys = den.classes or { };
  quirkKeys = den.quirks or { };
  skipKey = key: structuralKeysSet ? ${key} || classKeys ? ${key} || quirkKeys ? ${key};

  reshapeSettings =
    raw:
    if raw ? options then
      {
        imports = raw.imports or [ ];
        config = raw.config or { };
        inherit (raw) options;
      }
    else
      {
        imports = raw.imports or [ ];
        config = raw.config or { };
        options = removeAttrs raw [
          "imports"
          "config"
        ];
      };

  hasSettingsDeep =
    node:
    builtins.isAttrs node
    && (
      (node ? settings)
      || lib.any (key: !(skipKey key) && hasSettingsDeep (node.${key} or null)) (builtins.attrNames node)
    );

  nodeModule =
    node:
    let
      ownSettings =
        if node ? settings then
          reshapeSettings node.settings
        else
          {
            imports = [ ];
            config = { };
            options = { };
          };
      settingChildren = lib.filterAttrs (
        key: value: !(skipKey key) && builtins.isAttrs value && hasSettingsDeep value
      ) node;
      childOptions = lib.mapAttrs (
        name: child:
        mkOption {
          type = types.submodule (nodeModule child);
          default = { };
          description = "Settings under ${name}";
        }
      ) settingChildren;
    in
    {
      imports = ownSettings.imports or [ ];
      config = ownSettings.config or { };
      options = (ownSettings.options or { }) // childOptions;
    };
in
types.submodule (nodeModule (den.aspects or { }))
