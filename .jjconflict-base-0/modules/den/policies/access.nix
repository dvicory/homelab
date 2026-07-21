# Fleet access grants.
# Maps environments and hosts to group-based access.
# Users whose registry groups intersect the granted groups get resolved onto hosts.
{
  fleet.user-access = {
    by-environment = {
      prod.groups = [ "system-access" "workload-access" ];
      dev.groups = [ "system-access" ];
    };
  };
}
