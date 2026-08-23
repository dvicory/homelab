# Group definitions for access policy resolution.
#
# `members` points from a containing group to member groups. A direct member
# of the listed group therefore inherits membership in this containing group.
#
# GIDs match deterministic-uids.nix registry.
{
  den.groups = {
    # Standard Linux group (GID 10, conventional)
    wheel = {
      description = "Sudo access";
      labels = [ "posix" ];
      gid = 10;
      members = [ "admins" ];
    };

    # Access control groups (500-509)
    admins = {
      description = "Administrative role; privilege only, not machine login";
      labels = [ "posix" ];
      gid = 500;
    };

    system-access = {
      description = "Broad login access to ordinary machines";
      labels = [ "posix" ];
      gid = 501;
    };

    server-access = {
      description = "Login access to server hosts";
      labels = [ "posix" ];
      gid = 502;
      members = [ "system-access" ];
    };

    workstation-access = {
      description = "Login access to workstation hosts";
      labels = [ "posix" ];
      gid = 503;
      members = [ "system-access" ];
    };

    workload-access = {
      description = "Service account access for container runners and CI agents";
      labels = [ "posix" ];
      gid = 504;
    };
  };
}
