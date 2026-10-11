{ lib, ... }:
{
  # incus-mount-isolation decides what to unmount from the kernel mount table.
  # This runs that decision on fixed tables, including one captured on
  # hvn-hyp1, where /persist is its own dataset whose peer group also holds
  # unrelated binds. The VM test cannot build that layout.
  perSystem =
    { pkgs, system, ... }:
    {
      checks = lib.optionalAttrs (lib.hasSuffix "-linux" system) {
        incus-mount-isolation-decisions =
          pkgs.runCommand "incus-mount-isolation-decisions" { nativeBuildInputs = [ pkgs.python3 ]; }
            ''
              python3 ${./incus-mount-isolation-decisions.py} \
                ${../den/aspects/virtualization/incus-mount-isolation.py}
              touch $out
            '';
      };
    };
}
