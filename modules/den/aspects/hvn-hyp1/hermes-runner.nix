{
  den.aspects.hvn-hyp1.hermes-runner = {
    homeManager = {
      home.stateVersion = "26.05";
      virtualisation.quadlet = {
        containers = {
          hermes-qa-tailscale = {
            autoStart = true;
            containerConfig = {
              image = "docker.io/tailscale/tailscale:latest";
              addCapabilities = [ "NET_ADMIN" ];
              devices = [ "/dev/net/tun" ];
              environments = {
                TS_STATE_DIR = "/var/lib/tailscale";
                TS_AUTHKEY = "file:/run/secrets/tailscale-auth-key";
                TS_HOSTNAME = "hermes-qa";
              };
              volumes = [
                "hermes-qa-tailscale:/var/lib/tailscale"
                "/run/agenix/hermes-qa-tailscale:/run/secrets/tailscale-auth-key:ro"
              ];
            };
          };

          hermes-qa = {
            autoStart = true;
            containerConfig = {
              image = "localhost/hermes-qa:latest";
              networks = [ "container:hermes-qa-tailscale" ];
              environments = {
                HOME = "/home/hermes-runner";
                HERMES_HOME = "/home/hermes-runner/.hermes";
                WORKSPACE_DIR = "/home/hermes-runner/workspace/homelab";
                SECRETS_DIR = "/run/secrets";
              };
              volumes = [
                "hermes-qa-state:/home/hermes-runner/.hermes"
                "hermes-qa-workspace:/home/hermes-runner/workspace"
                "/run/agenix/hermes-qa-env:/run/secrets/hermes-env:ro"
                "/run/agenix/hermes-qa-github-pat:/run/secrets/hermes-github-pat:ro"
              ];
            };
            serviceConfig = {
              TimeoutStopSec = 150;
            };
          };
        };
      };
    };
  };
}
