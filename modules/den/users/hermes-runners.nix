{ den, ... }:
let
  mkRunner =
    { uid, instance }:
    {
      aspect = den.aspects.workloads.hermes.account;
      groups = [ "workload-access" ];

      system = {
        inherit uid;
        kind = "workload";
        linger = true;
      };

      settings.workloads.hermes = {
        inherit instance;
        config = {
          model.default = "opencode-go/deepseek-v4-flash";
          agent.restart_drain_timeout = 120;
        }
        // (
          if instance == "qa" then
            {
              curator.enabled = false;
              skills = {
                creation_nudge_interval = 0;
                write_approval = true;
              };
              memory = {
                nudge_interval = 0;
                write_approval = true;
              };
            }
          else
            { }
        );
        tailscale.hostname = "hermes-${instance}";
      }
      // (
        if instance == "qa" then
          {
            # The sidecar is opt-in so prod remains unchanged until the browser
            # workflow has been exercised.
            fortress.enable = true;

            # QA exercises the Effect/HTTP Gondolin integration. The companion
            # sandbox account is derived inside the Hermes account aspect; this
            # registry entry selects the feature and its resource policy. This
            # is an integration-stage selection, not a production parity claim;
            # the V3 acceptance gates still govern promotion.
            secureTerminal = {
              enable = true;
              network = true;
              backend = "gondolin";
              workspaceHandoff = {
                enable = true;
                revisionLimits = {
                  maxLogicalBytes = 67108864;
                  maxEntries = 8192;
                  maxFileBytes = 16777216;
                  maxPathBytes = 1024;
                };
              };

              defaultTemplate = "project";
              allowedPairs = [
                {
                  asset = "general";
                  template = "project";
                }
                {
                  asset = "general";
                  template = "research";
                }
                {
                  asset = "general";
                  template = "offline";
                }
                {
                  asset = "minimal";
                  template = "offline";
                }
              ];
              maximum = {
                networkBundles = [
                  "git-public"
                  "npm-public"
                  "pypi-public"
                  "nix-cache-public"
                ];
                credentialCapabilities = [
                  "github-private-read"
                  "github-push"
                ];
                resources = {
                  cpus = 4;
                  memoryMiB = 8192;
                  diskMiB = 32768;
                };
                grantScopes = [
                  "once"
                  "task"
                ];
              };
              worklanes.codex = {
                allowedPairs = [
                  {
                    asset = "general";
                    template = "project";
                  }
                  {
                    asset = "minimal";
                    template = "offline";
                  }
                ];
                maximum.networkBundles = [
                  "git-public"
                  "npm-public"
                  "pypi-public"
                ];
              };
            };

            # Codex is a distinct coding-only Kanban worker. Its ChatGPT login and
            # threads persist in a dedicated rootless Podman volume.
            codex = {
              enable = true;
              allowedModels = [
                "gpt-5.6-luna"
                "gpt-5.6-terra"
              ];
              allowedReasoningEfforts = [
                "low"
                "medium"
                "high"
              ];
            };
          }
        else
          { }
      );
    };
in
{
  den.users.registry = {
    hermes-qa-runner = mkRunner {
      uid = 1100;
      instance = "qa";
    };
    hermes-prod-runner = mkRunner {
      uid = 1101;
      instance = "prod";
    };
  };

  # Placement remains explicit topology data. Both homes reuse the same
  # workload aspect; their behavior comes from the matching registry account.
  den.homes.x86_64-linux = {
    "hermes-qa-runner@hvn-hyp1".aspect = den.aspects.workloads.hermes.home;
    "hermes-prod-runner@hvn-hyp1".aspect = den.aspects.workloads.hermes.home;
  };
}
