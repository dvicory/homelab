# mergerfs pool helpers.
#
# Shared by the pooling module and by anything that has to order itself after a
# pool, so the unit-name escaping lives in exactly one place.
{ lib }:
{
  # `/srv/media` -> `mergerfs-mnt-srv-media.service`, the unit the pooling module
  # creates for that pool.
  unitNameFor =
    path: "mergerfs-mnt-${lib.strings.sanitizeDerivationName (builtins.substring 1 (-1) path)}.service";

  # mergerfs accepts an ordinary directory as a branch, so the branch path
  # existing proves nothing: if the branch's own filesystem (today gocryptfs,
  # later LUKS) is absent, the pool silently becomes a view of whatever sits on
  # the root filesystem and applications write there. Require every branch to be
  # a mount before the pool is served.
  #
  # `branches-mount-timeout` is not a substitute: it waits and then drops an
  # unmounted branch, which produces a smaller pool rather than a refusal.
  branchGuard =
    branches:
    lib.concatMapStrings (branch: ''
      if ! mountpoint -q ${lib.escapeShellArg branch}; then
        echo "mergerfs: branch ${branch} is not a mountpoint; refusing to serve a pool over an unmounted branch" >&2
        exit 1
      fi
    '') branches;
}
