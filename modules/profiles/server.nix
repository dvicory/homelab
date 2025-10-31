/**
  # Server Profile Aspect (Dendritic style)

  Common configuration for all homelab servers.

  This profile includes:
  - CrowdSec intrusion detection
  - Remote unlock via Tailscale
  - Future: monitoring, logging, etc.
  ```
*/
{ self, ... }:
{
  flake.modules.nixos.profiles-server =
    { config, ... }:
    {
      imports = with self.modules.nixos; [
        services-crowdsec
        profiles-remote-unlock-tailscale
      ];

      # CrowdSec intrusion detection
      services.crowdsec = {
        enable = true;

        # Wire secrets for CrowdSec engine
        secrets = {
          # Bouncer API key - used by engine to register bouncers
          # Every host should have this in their secrets.yaml at: <hostname>.crowdsec.bouncerApiKey
          bouncerApiKeyFile.result = (config.dlab.sops.secret."crowdsec/bouncer-api-key".result);

          # Enrollment key - connects to CrowdSec cloud (shared across all hosts)
          enrollKeyFile.result = config.dlab.sops.secret."crowdsec/enrollment-key".result;
        };
      };

      # Firewall bouncer - automatically blocks malicious IPs
      services.crowdsec-firewall-bouncer = {
        enable = true;

        # Wire secret for bouncer authentication
        secrets.apiKeyFile.result = config.dlab.sops.secret."crowdsec/bouncer-api-key".result;
      };

      # SOPS secret wiring for CrowdSec
      dlab.sops.secret."crowdsec/bouncer-api-key" = {
        request = config.services.crowdsec.secrets.bouncerApiKeyFile.request;
        settings = {
          key = "${config.dlab.hostName}/crowdsec/bouncerApiKey";
        };
      };

      dlab.sops.secret."crowdsec/enrollment-key" = {
        request = config.services.crowdsec.secrets.enrollKeyFile.request;
        settings = {
          sopsFile = ../../shared/secrets.yaml;
          key = "crowdsec/enrollment_key";
        };
      };
    };
}
