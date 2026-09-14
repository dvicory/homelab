{
  config,
  den,
  inputs,
  lib,
  ...
}:
let
  inherit (lib) mkOption types;
  genMerge = inputs.gen-schema.inputs.gen-merge.lib;
  schemaLib = inputs.gen-schema.lib;
  genTypes = genMerge.types;
  genOption = type: default: genMerge.mkOption { inherit type default; };
  requiredGenOption = type: genMerge.mkOption { inherit type; };

  slotType = types.submodule {
    options = {
      consistency = mkOption { type = types.str; };
      restoreSemantics = mkOption { type = types.str; };
      suggestedPolicy = mkOption {
        type = types.nullOr types.str;
        default = null;
      };
      caveats = mkOption {
        type = types.listOf types.str;
        default = [ ];
      };
    };
  };

  policyType = types.submodule {
    options = {
      disposable = mkOption {
        type = types.bool;
        default = false;
      };
      routes = mkOption {
        type = types.listOf types.str;
        default = [ ];
      };
    };
  };

  scratchType = types.submodule {
    options = {
      nativeParent = mkOption { type = types.str; };
      mountRoot = mkOption { type = types.str; };
    };
  };
in
{
  options.den.preserve = {
    slots = mkOption {
      type = types.attrsOf slotType;
      default = { };
      description = "Reusable state-slot semantics.";
    };
    policies = mkOption {
      type = types.attrsOf policyType;
      default = { };
      description = "Named instance protection policies.";
    };
    scratchDestinations = mkOption {
      type = types.attrsOf scratchType;
      default = { };
      description = "Authorized scratch restore destinations.";
    };
    states = schemaLib.mkInstanceRegistry den.schema."preserve-state" {
      description = "Stable logical state instances";
      extraModules = [ { config._identity.keys = [ "stateId" ]; } ];
    };
    targets = schemaLib.mkInstanceRegistry den.schema."preserve-target" {
      description = "State-protection targets";
      extraModules = [ { config._identity.keys = [ "targetId" ]; } ];
    };
    integrations = schemaLib.mkInstanceRegistry den.schema."preserve-integration" {
      description = "Lifecycle-owner integrations";
      extraModules = [ { config._identity.keys = [ "integrationId" ]; } ];
    };
    routes = schemaLib.mkInstanceRegistry den.schema."preserve-route" {
      description = "State-protection route obligations";
      refs = {
        target = config.den.preserve.targets;
        integration = config.den.preserve.integrations;
      };
      extraModules = [ { config._identity.keys = [ "routeId" ]; } ];
    };
  };

  config = {
    den.schema."preserve-state".imports = [
      {
        options = {
          stateId = requiredGenOption genTypes.str;
          slotId = requiredGenOption genTypes.str;
          mode = genOption (genTypes.enum [
            "plan-only"
            "enabled"
          ]) "plan-only";
          explicitPolicy = genOption (genTypes.nullOr genTypes.str) null;
          selectorPolicies = genOption (genTypes.listOf genTypes.str) [ ];
        };
      }
    ];

    den.schema."preserve-target".imports = [
      {
        options = {
          targetId = requiredGenOption genTypes.str;
          kind = requiredGenOption genTypes.str;
          locator = requiredGenOption genTypes.str;
          ownerData = genOption (genTypes.attrsOf genTypes.anything) { };
        };
      }
    ];

    den.schema."preserve-integration".imports = [
      {
        options = {
          integrationId = requiredGenOption genTypes.str;
          owner = requiredGenOption genTypes.str;
          adapter = requiredGenOption genTypes.str;
          fixtureOnly = genOption genTypes.bool false;
          operations = genOption (genTypes.listOf genTypes.str) [ ];
          realizationKinds = genOption (genTypes.listOf genTypes.str) [ ];
          targetKinds = genOption (genTypes.listOf genTypes.str) [ ];
          bindings = genOption (genTypes.attrsOf genTypes.anything) { };
        };
      }
    ];

    den.schema."preserve-route".imports = [
      {
        options = {
          routeId = requiredGenOption genTypes.str;
          target = genOption (genTypes.nullOr (schemaLib.ref "preserve-target")) null;
          integration = genOption (genTypes.nullOr (schemaLib.ref "preserve-integration")) null;
          operation = genOption genTypes.str "run";
          requiredConsistency = genOption genTypes.str "filesystem";
          requiredFidelity = genOption genTypes.str "filesystem";
        };
      }
    ];
  };
}
