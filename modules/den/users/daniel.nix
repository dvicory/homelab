{ den, ... }:
{
  den.users.registry.daniel = {
    system.uid = 1000;
    groups = [
      "admins"
      "system-access"
    ];
    identity = {
      displayName = "Daniel Vicory";
      email = "daniel@danielvicory.dev";
      sshKeys = [
        {
          tag = "mbp-2021";
          key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIItkbwb4903ks6RXq1AyRGRK3um1Wzo8tvo12lG9dete dvicory@mbp-2021-32gb";
        }
        {
          tag = "pixel-10-pro";
          key = "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBHdw5FFx3Muwt472yeE63su7NeCkTlItBcnQtkx0oxEQjbf5EY+yLJajxieZyGSx5z4numb4ztIHj5voGT8RH5g=";
        }
      ];
    };
  };
}
