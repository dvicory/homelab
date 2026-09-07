{ lib, ... }:
{
  den.aspects.kubernetes.services.monitoring.settings.webhookURL = lib.mkOption {
    type = lib.types.nullOr lib.types.str;
    default = null;
    description = "Operator-selected local Alertmanager webhook URL for smoke delivery; null retains alerts in Alertmanager without external delivery.";
  };

  den.aspects.kubernetes.services.monitoring.settings.alertmanagerConfigSecret = lib.mkOption {
    type = lib.types.nullOr lib.types.str;
    default = null;
    description = "Runtime Secret containing alertmanager.yaml for native SMTP/Telegram routing; credentials never enter rendered Nix values.";
  };
  den.aspects.kubernetes.services.monitoring.settings.alertmanagerSecretMounts = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    default = [ ];
    description = "Runtime Secret names mounted at /etc/alertmanager/secrets for native SMTP/Telegram *_file references in the operator-supplied Alertmanager config.";
  };


  den.aspects.kubernetes.services.monitoring.settings.recoveryMaxAgeSeconds = lib.mkOption {
    type = lib.types.ints.positive;
    default = 172800;
    description = "Maximum age of the complete household recovery point published by the standard node-exporter textfile collector.";
  };
}
