# Group definitions for access policy resolution.
#
# `members` points from a containing group to member groups. A direct member
# of the listed group therefore inherits membership in this containing group.
#
# GIDs match deterministic-uids.nix registry.
{
  den.groups = {
    # Upstream owns this group: NixOS creates wheel with its own GID, so
    # declaring a number here would only be wrong. The entry exists so the
    # membership graph can point at it.
    wheel = {
      description = "Sudo access";
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

    # Storage capabilities (505-509): the stable POSIX identity a workload
    # holds to reach a shared namespace. The GID is the contract — it is what
    # appears in file ownership on the host and what the compute boundary
    # preserves across the guest — while membership is what authorizes.
    media = {
      description = "Shared media namespace capability";
      labels = [ "posix" ];
      gid = 505;
    };
  };
}
