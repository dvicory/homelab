{
  config,
  lib,
  self,
  ...
}:
{
  # Temporary recurrence diagnostic, not an admission check or a fault repair.
  # Build only this selector on an ordinary native x86 runner; do not retry it.
  perSystem =
    { pkgs, system, ... }:
    lib.optionalAttrs (system == "x86_64-linux") (
      let
        inherit
          (import ./_compute-configurations.nix {
            inherit self lib system;
            hostName = config.den.clusters.prod-home.hostName;
          })
          hostConfig
          ;
        selected = hostConfig.virtualisation.incus.package;
        coreutils = "${pkgs.coreutils}/bin";
        # This runs while GDB has the inferior stopped. Only sandbox paths and
        # kernel memory counters are read, never files from the test database.
        context = pkgs.writeShellScript "incus-sigbus-context" ''
          set -u
          (
            paths=(. "$TMPDIR")
            if [ -d /dev/shm ]; then paths+=(/dev/shm); fi
            printf '\n=== crash-time filesystem capacity and inode counts ===\n'
            ${coreutils}/df -PT -- "''${paths[@]}"
            ${coreutils}/df -Pi -- "''${paths[@]}"
            ${coreutils}/stat -f --format='path=%n type=%T block_size=%S blocks=%b free=%f available=%a inodes=%c free_inodes=%d' -- "''${paths[@]}"
            printf '\n=== crash-time system memory counters ===\n'
            ${coreutils}/head -c 8192 /proc/meminfo
          ) 2>&1 | ${bounded 12288}
        '';
        # Drain after the byte cap so a closed pipe cannot interrupt GDB's
        # command list before it passes SIGBUS back to the native inferior.
        bounded = bytes: "${pkgs.bash}/bin/bash -c '${coreutils}/head -c ${toString bytes}; ${coreutils}/cat > /dev/null'";
        commands = pkgs.writeText "incus-sigbus.gdb" ''
          set pagination off
          set confirm off
          set auto-load off
          set debuginfod enabled off
          set startup-with-shell off
          set disable-randomization off
          set print thread-events off
          set print frame-arguments none
          set print entry-values no
          set backtrace limit 32
          handle SIGURG SIGPIPE nostop noprint pass
          handle SIGBUS stop noprint pass
          catch signal SIGBUS
          commands
            silent
            disable
            printf "\n=== native SIGBUS: first delivery, before Go handles it ===\n"
            printf "si_signo=%d si_code=%d fault_address=%p pc=%p\n", $_siginfo.si_signo, $_siginfo.si_code, $_siginfo._sifields._sigfault.si_addr, $pc
            printf "\n=== faulting thread: at most 32 frames / 8 KiB ===\n"
            pipe backtrace 32 | ${bounded 8192}
            printf "\n=== all native threads: at most 16 frames each / 32 KiB total ===\n"
            pipe thread apply all -q -c backtrace 16 | ${bounded 32768}
            printf "\n=== process mappings: at most 16 KiB ===\n"
            pipe info proc mappings | ${bounded 16384}
            printf "\n=== process status: at most 4 KiB ===\n"
            pipe info proc status | ${bounded 4096}
            printf "\n=== faulting instructions: at most 8 instructions / 4 KiB ===\n"
            pipe x/8i $pc | ${bounded 4096}
            printf "\n=== filesystem and memory context: at most 12 KiB ===\n"
            shell ${context}
            printf "\n=== end bounded capture; delivering original SIGBUS ===\n"
            continue
          end
          run
          if !$_isvoid($_exitcode)
            quit $_exitcode
          end
          if !$_isvoid($_exitsignal)
            quit 128 + $_exitsignal
          end
          echo Diagnostic stopped before native termination; refusing success.\n
          quit 125
        '';
        capture = pkgs.writeShellScript "incus-sigbus-exec" ''
          set -eu
          case "$1" in
            */cluster.test)
              # Child-only resource limit: do not generate/publish a raw core.
              ulimit -c 0
              export SHELL=${pkgs.bash}/bin/bash
              exec ${coreutils}/timeout --kill-after=10s 15m \
                ${pkgs.gdb}/bin/gdb --nx --batch --return-child-result \
                -iex 'set auto-load off' -iex 'set debuginfod enabled off' \
                -x ${commands} --args "$@"
              ;;
            *) exec "$@" ;;
          esac
        '';
      in
      {
        checks.incus-sigbus-capture =
          assert lib.assertMsg
            (selected.drvPath == "/nix/store/aq3212g95732idfwgkjvayjgr2r8ifzp-incus-7.4.0.drv")
            "Incus SIGBUS capture must use the exact recurrent package";
          selected.overrideAttrs (old: {
            pname = "${old.pname}-sigbus-capture";
            # Keep the builder's entire checkPhase, hooks, exclusions, flags,
            # install checks, source, toolchain and libraries unchanged.
            checkFlags = (old.checkFlags or [ ]) ++ [ "-exec=${capture}" ];
          });
      }
    );
}
