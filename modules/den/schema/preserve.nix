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

  consistencyType = genTypes.enum [
    "live"
    "crash"
    "filesystem"
    "application"
    "database"
  ];

  scratchType = types.submodule {
    options = {
      nativeParent = mkOption { type = types.str; };
      mountRoot = mkOption { type = types.str; };
    };
  };

  bindingType = types.submodule {
    options = {
      state = mkOption { type = types.raw; };
      route = mkOption { type = types.raw; };
      integration = mkOption {
        type = types.nullOr types.raw;
        default = null;
      };
      source = mkOption {
        type = types.submodule {
          options = {
            subpath = mkOption {
              type = types.nullOr types.str;
              default = null;
            };
            include = mkOption {
              type = types.listOf types.str;
              default = [ ];
            };
            exclude = mkOption {
              type = types.listOf types.str;
              default = [ ];
            };
          };
        };
        default = { };
      };
      nativeOverrides = mkOption {
        type = types.attrsOf types.anything;
        default = { };
      };
    };
  };

  integrationTargetType = types.submodule {
    options = {
      integration = mkOption { type = types.raw; };
      target = mkOption { type = types.raw; };
      native = mkOption {
        type = types.attrsOf types.anything;
        default = { };
      };
    };
  };
in
{
  options.den.preserve = {
    bindings = mkOption {
      type = types.listOf bindingType;
      default = [ ];
      description = "Optional per-State/Route wiring overrides.";
    };
    integrationTargets = mkOption {
      type = types.listOf integrationTargetType;
      default = [ ];
      description = "Shared Integration+Target native destination wiring.";
    };
    scratchDestinations = mkOption {
      type = types.attrsOf scratchType;
      default = { };
      description = "Authorized scratch restore destinations.";
    };
    slots = schemaLib.mkInstanceRegistry den.schema."preserve-slot" {
      description = "Reusable state-slot semantics";
      refs.suggestedPolicy = config.den.preserve.policies;
      extraModules = [ { config._identity.keys = [ "slotId" ]; } ];
    };
    states = schemaLib.mkInstanceRegistry den.schema."preserve-state" {
      description = "Stable logical state instances";
      refs = {
        slot = config.den.preserve.slots;
        explicitPolicy = config.den.preserve.policies;
        selectorPolicies = config.den.preserve.policies;
      };
      extraModules = [ { config._identity.keys = [ "stateId" ]; } ];
    };
    policies = schemaLib.mkInstanceRegistry den.schema."preserve-policy" {
      description = "Named instance protection policies";
      refs.routes = config.den.preserve.routes;
      extraModules = [ { config._identity.keys = [ "policyId" ]; } ];
    };
    routes = schemaLib.mkInstanceRegistry den.schema."preserve-route" {
      description = "State-protection route obligations";
      refs = {
        target = config.den.preserve.targets;
        integration = config.den.preserve.integrations;
      };
      extraModules = [ { config._identity.keys = [ "routeId" ]; } ];
    };
    targets = schemaLib.mkInstanceRegistry den.schema."preserve-target" {
      description = "Logical protection targets";
      extraModules = [ { config._identity.keys = [ "targetId" ]; } ];
    };
    integrations = schemaLib.mkInstanceRegistry den.schema."preserve-integration" {
      description = "Lifecycle-owner integrations";
      extraModules = [ { config._identity.keys = [ "integrationId" ]; } ];
    };
  };

  config = {
    den.schema."preserve-slot".imports = [
      {
        options = {
          slotId = requiredGenOption genTypes.str;
          dataKind = requiredGenOption genTypes.str;
          requiredConsistency = requiredGenOption consistencyType;
          requiredFidelity = genOption (genTypes.listOf genTypes.str) [ ];
          acceptedPayloadFormats = genOption (genTypes.listOf genTypes.str) [ ];
          suggestedPolicy = genOption (genTypes.nullOr (schemaLib.ref "preserve-policy")) null;
        };
      }
    ];

    den.schema."preserve-state".imports = [
      {
        options = {
          stateId = requiredGenOption genTypes.str;
          slot = requiredGenOption (schemaLib.ref "preserve-slot");
          mode = genOption (genTypes.enum [
            "plan-only"
            "enabled"
          ]) "plan-only";
          explicitPolicy = genOption (genTypes.nullOr (schemaLib.ref "preserve-policy")) null;
          selectorPolicies = genOption (schemaLib.setOf (schemaLib.ref "preserve-policy")) [ ];
        };
      }
    ];

    den.schema."preserve-policy".imports = [
      {
        options = {
          policyId = requiredGenOption genTypes.str;
          disposable = genOption genTypes.bool false;
          routes = genOption (genTypes.listOf (schemaLib.ref "preserve-route")) [ ];
        };
      }
    ];

    den.schema."preserve-target".imports = [
      {
        options = {
          targetId = requiredGenOption genTypes.str;
          failureDomain = requiredGenOption (genTypes.attrsOf genTypes.str);
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
          requiredConsistency = genOption (genTypes.nullOr consistencyType) null;
          requiredFidelity = genOption (genTypes.listOf genTypes.str) [ ];
        };
      }
    ];

    den.schema."preserve-integration".imports = [
      {
        options = {
          integrationId = requiredGenOption genTypes.str;
          owner = requiredGenOption genTypes.str;
          adapter = requiredGenOption genTypes.str;
          protocolVersion = genOption genTypes.int 1;
          timeoutSeconds = genOption genTypes.int 30;
          maxResponseBytes = genOption genTypes.int 1048576;
          fixtureOnly = genOption genTypes.bool false;
          operations = requiredGenOption (genTypes.listOf genTypes.str);
          dataKinds = requiredGenOption (genTypes.listOf genTypes.str);
          requiredSourceCapabilities = requiredGenOption (genTypes.listOf genTypes.str);
          guaranteedConsistency = requiredGenOption consistencyType;
          fidelityGuarantees = requiredGenOption (genTypes.listOf genTypes.str);
          payloadRepresentation = genOption (genTypes.nullOr genTypes.str) null;
          nativePointRepresentations = requiredGenOption (genTypes.listOf genTypes.str);
          realizationKindConstraints = genOption (genTypes.listOf genTypes.str) [ ];
        };
      }
    ];
  };
}
