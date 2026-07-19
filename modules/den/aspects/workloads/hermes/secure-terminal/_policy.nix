# Policy rendering for the Gondolin secure-terminal backend (V3 §11).
#
# Nix is the authoring DSL: this file composes the hard safety floor,
# reviewed templates, bundles, and credential capabilities with a profile's
# selections and renders inert, versioned JSON. The broker validates and
# evaluates it; it never executes Nix or arbitrary predicates.
{ }:

let
  # Hard safety floor (§11.3): absolute ceilings and non-negotiable denials.
  # No layer may weaken these; the broker enforces them independently.
  floor = {
    maxResources = {
      cpus = 4;
      memoryMiB = 8192;
      diskMiB = 32768;
      pidsMax = 512;
      maxOutputBytes = 8388608; # 8 MiB per stream
      maxExecsPerVm = 64;
      maxCommandMs = 600000;
      ringBufferBytes = 262144;
    };
    maxVms = 8;
    maxVmStartsPerMinute = 12;
    maxFrameBytes = 1048576;
    maxInputBytes = 1048576;
  };

  # Credential capabilities reference a network bundle, a logical secret id,
  # a reviewed adapter, bounded targets/actions, and an activation mode.
  # Secret VALUES never appear here — logical IDs only (§12.5).
  credentialCapabilities = {
    github-private-read = {
      networkBundle = "git-public";
      adapter = "github";
      secretRef = "hermes-terminal-github";
      targets = [ { owner = "daniel-vicory"; } ];
      actions = [ "git.fetch" ];
      activation = "approval";
      maximumGrantScope = "task";
    };
    github-push = {
      networkBundle = "git-public";
      adapter = "github";
      secretRef = "hermes-terminal-github";
      targets = [
        {
          owner = "daniel-vicory";
          repositories = [ "homelab-den" ];
        }
      ];
      actions = [ "git.push" ];
      activation = "approval";
      maximumGrantScope = "once";
    };
  };

  # Reviewed sandbox templates (§11.4). A template has at most one writable
  # workspace authority; moving to broader egress or different mounts
  # creates a new VM generation.
  templates = {
    project = {
      version = 1;
      asset = "general";
      network = {
        mode = "bundles";
        bundles = [
          "git-public"
          "npm-public"
          "pypi-public"
          "nix-cache-public"
        ];
      };
      workspace.type = "private";
      resources = {
        cpus = 2;
        memoryMiB = 4096;
      };
      envAllow = [ ];
      grantScopes = [
        "once"
        "task"
      ];
      credentials = [
        "github-private-read"
        "github-push"
      ];
      grantable = [ ];
    };
    research = {
      version = 1;
      asset = "general";
      network.mode = "public-anonymous";
      workspace.type = "private";
      resources = {
        cpus = 2;
        memoryMiB = 4096;
      };
      envAllow = [ ];
      grantScopes = [ ];
      credentials = [ ];
      grantable = [ ];
    };
    offline = {
      version = 1;
      asset = "minimal";
      network.mode = "deny-all";
      workspace.type = "private";
      resources = {
        cpus = 1;
        memoryMiB = 2048;
      };
      envAllow = [ ];
      grantScopes = [ ];
      credentials = [ ];
      grantable = [ ];
    };
    authenticated-action = {
      version = 1;
      asset = "minimal";
      network = {
        mode = "bundles";
        bundles = [ "git-public" ];
      };
      workspace.type = "private";
      resources = {
        cpus = 1;
        memoryMiB = 2048;
      };
      envAllow = [ ];
      grantScopes = [ "once" ];
      credentials = [
        "github-private-read"
        "github-push"
      ];
      grantable = [ ];
    };
  };

  # Render one profile's policy.json content (before policyId).
  mkPolicyDoc =
    {
      bundles,
      assets,
      profile,
      defaultTemplate,
      allowedPairs,
      maximum,
      worklanes ? { },
      ...
    }:
    {
      version = 1;
      inherit floor assets credentialCapabilities templates;
      inherit bundles;
      profiles.${profile} = {
        inherit defaultTemplate allowedPairs maximum worklanes;
      };
    };

in
{
  inherit floor templates credentialCapabilities;

  # Render policy.json with a content-derived policyId (§11: inert,
  # versioned JSON; the policy hash feeds VM generation identity).
  mkPolicy =
    { pkgs, profile, ... }@args:
    let
      doc = mkPolicyDoc args;
      policyId = builtins.hashString "sha256" (builtins.toJSON doc);
      rendered = doc // { inherit policyId; };
    in
    {
      json = pkgs.writeText "hermes-${profile}-sandbox-policy.json" (builtins.toJSON rendered);
      inherit policyId;
    };
}
