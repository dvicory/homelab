# Merges all age-secrets quirk pipe data (collected from aspects) into
# the host's NixOS age.secrets config.
{
  den.aspects.core.secrets-collector = {
    nixos = { age-secrets, lib, ... }: lib.mkMerge age-secrets;
  };
}
