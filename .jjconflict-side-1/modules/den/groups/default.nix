# Group definitions for access policy resolution.
#
# Transitive membership: members of a group inherit that group's privileges.
# Example: system-access → workstation-access → wheel
# means anyone with system-access transitively gets wheel.
#
# GIDs match deterministic-uids.nix registry.
{
  den.groups = {
    # Standard Linux group (GID 10, conventional)
    wheel = {
      description = "Sudo access";
      labels = [ "posix" ];
      gid = 10;
      members = [ "workstation-access" ];
    };

    # Access control groups (500-509)
    admins = {
      description = "Full administrative access";
      labels = [ "posix" ];
      gid = 500;
    };

    system-access = {
      description = "Grants Unix account creation on hosts with matching system-access-groups";
      labels = [ "posix" ];
      gid = 501;
    };

    server-access = {
      description = "Access to server hosts (implies system-access)";
      labels = [ "posix" ];
      gid = 502;
      members = [ "system-access" ];
    };

    workstation-access = {
      description = "Access to workstation hosts (implies system-access, wheel)";
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
