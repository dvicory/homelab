# Deterministic UIDs/GIDs — consistent IDs across all hosts for NFS and service accounts.
#
# Ported from main:modules/_legacy/core/deterministic-uids/
# The option module defines `users.deterministicIds` which auto-assigns uid/gid
# to users/groups via mkDefault. The data module provides the central ID registry.
#
# UID/GID Layout:
#   10        wheel (standard Linux)
#   500-599   All groups — access control, POSIX, service groups (100 slots)
#   600-649   Core system daemons (50 slots)
#   650-699   Infrastructure services (50 slots)
#   700-749   Identity & security services (50 slots)
#   750-799   Media services (50 slots)
#   800-849   Web, storage, and automation (50 slots)
#   850-899   Monitoring and observability (50 slots)
#   900-949   Networking (50 slots)
#   950-999   Desktop, hardware, and runtime (50 slots)
#   1000-1099 Interactive human users (100 slots)
#   1100-1199 Workload service users — normal accounts for container
#             runners, CI agents, and other non-interactive workloads
#             (100 slots)
#
# Each range has 50 slots for services and 100 for groups. When adding a new
# entry, pick the appropriate range and assign the next sequential ID.
{
  den.aspects.core.users.deterministic-uids = {
    nixos =
      { config, lib, ... }:
      let
        inherit (lib)
          mkDefault
          mkIf
          mkOption
          types
          concatLists
          flip
          mapAttrsToList
          ;

        cfg = config.users.deterministicIds;

        uidGid = id: {
          uid = id;
          gid = id;
        };
      in
      {
        options.users = {
          deterministicIds = mkOption {
            default = { };
            description = "Maps user/group name to expected uid/gid values.";
            type = types.attrsOf (
              types.submodule {
                options = {
                  uid = mkOption {
                    type = types.nullOr types.int;
                    default = null;
                  };
                  gid = mkOption {
                    type = types.nullOr types.int;
                    default = null;
                  };
                  subUidRanges = mkOption {
                    type = types.listOf (
                      types.submodule {
                        options = {
                          startUid = mkOption { type = types.int; };
                          count = mkOption { type = types.int; };
                        };
                      }
                    );
                    default = [ ];
                  };
                  subGidRanges = mkOption {
                    type = types.listOf (
                      types.submodule {
                        options = {
                          startGid = mkOption { type = types.int; };
                          count = mkOption { type = types.int; };
                        };
                      }
                    );
                    default = [ ];
                  };
                };
              }
            );
          };

          # Extend users.users — if a matching entry exists in deterministicIds,
          # auto-assign uid/subUidRanges via mkDefault so they don't need to be
          # set explicitly on every user account.
          users = mkOption {
            type = types.attrsOf (
              types.submodule (
                { name, ... }:
                {
                  config = {
                    uid =
                      let
                        v = cfg.${name}.uid or null;
                      in
                      mkIf (v != null) (mkDefault v);
                    subUidRanges =
                      let
                        v = cfg.${name}.subUidRanges or [ ];
                      in
                      mkIf (v != [ ]) (mkDefault v);
                    subGidRanges =
                      let
                        v = cfg.${name}.subGidRanges or [ ];
                      in
                      mkIf (v != [ ]) (mkDefault v);
                  };
                }
              )
            );
          };

          # Extend users.groups — same pattern for GIDs.
          groups = mkOption {
            type = types.attrsOf (
              types.submodule (
                { name, ... }:
                {
                  config.gid =
                    let
                      v = cfg.${name}.gid or null;
                    in
                    mkIf (v != null) (mkDefault v);
                }
              )
            );
          };
        };

        config.users.deterministicIds = {
          # ── Standard Linux groups ────────────────────────────────────
          wheel = { gid = 10; };

          # ── All groups (500-599) ────────────────────────────────────
          # Access control groups
          admins = { gid = 500; };
          system-access = { gid = 501; };
          server-access = { gid = 502; };
          workstation-access = { gid = 503; };

          # POSIX service groups (add as needed)
          docker = { gid = 510; };
          kvm = { gid = 511; };
          audio = { gid = 512; };
          video = { gid = 513; };
          render = { gid = 514; };
          i2c = { gid = 515; };

          # ── Core system daemons (600-649) ───────────────────────────
          systemd-oom = uidGid 600;
          systemd-coredump = uidGid 601;
          sshd = uidGid 602;
          nscd = uidGid 603;
          polkituser = uidGid 604;
          chrony = uidGid 605;
          mandb = uidGid 606;

          # ── Infrastructure services (650-699) ───────────────────────
          podman = uidGid 650;
          incus = uidGid 651;
          incus-admin = uidGid 652;

          nix-remote-build = uidGid 654;
          git = uidGid 655;
          acme = uidGid 656;
          nginx = uidGid 657;
          haproxy = uidGid 658;
          traefik = uidGid 659;
          tang = uidGid 660;
          crowdsec = uidGid 661;
          vault = uidGid 662;
          hermes = uidGid 663;

          # ── Identity & security (700-749) ───────────────────────────
          kanidm = uidGid 700;
          oauth2-proxy = uidGid 701;
          authelia = uidGid 702;
          headscale = uidGid 703;
          atticd = uidGid 704;

          # ── Media services (750-799) ────────────────────────────────
          grafana = uidGid 750;
          jellyfin = uidGid 751;
          radarr = uidGid 752;
          sonarr = uidGid 753;
          lidarr = uidGid 754;
          prowlarr = uidGid 755;
          qbittorrent = uidGid 756;
          sabnzbd = uidGid 757;
          seerr = uidGid 758;
          recyclarr = uidGid 759;
          ollama = uidGid 760;
          open-webui = uidGid 761;

          # ── Web, storage, and automation (800-849) ──────────────────
          forgejo = uidGid 800;
          minio = uidGid 801;
          samba = uidGid 802;
          nfs = uidGid 803;
          arangodb = uidGid 804;
          mosquitto = uidGid 805;
          zigbee2mqtt = uidGid 806;
          homeassistant = uidGid 807;

          # ── Monitoring and observability (850-899) ──────────────────
          alloy = uidGid 850;
          node-exporter = uidGid 851;
          process-exporter = uidGid 852;
          loki = uidGid 853;
          promtail = uidGid 854;
          victoriametrics = uidGid 855;
          victorialogs = uidGid 856;
          blackbox-exporter = uidGid 857;

          # ── Networking (900-949) ────────────────────────────────────
          frr = uidGid 900;
          frrvty = uidGid 901;
          bird = uidGid 902;
          dnsmasq = uidGid 903;
          coredns = uidGid 904;
          keepalived = uidGid 905;

          # ── Desktop, hardware, and runtime (950-999) ────────────────
          avahi = uidGid 950;
          rtkit = uidGid 951;
          colord = uidGid 952;
          geoclue = uidGid 953;
          gnome-remote-desktop = uidGid 954;
          gnome-initial-setup = uidGid 955;
          openrazer = uidGid 956;
          wireshark = uidGid 957;
          tss = uidGid 958;
          resolvconf = uidGid 959;
          fwupd-refresh = uidGid 960;
          adbusers = uidGid 961;
          wpa_supplicant = uidGid 962;
          uinput = uidGid 963;
          gamemode = uidGid 964;
          greeter = uidGid 965;
          pcscd = uidGid 966;
          msr = uidGid 967;
          nm-iodine = uidGid 968;

          # ── Workload service users (1100-1199) ────────────────────
          hermes-runner = uidGid 1100;
        };

        # Enforce that every user and group has a deterministic ID.
        # This prevents silent UID drift between hosts — if a NixOS module
        # creates a user without assigning a UID, the build fails with a
        # clear message instead of silently auto-assigning.
        config.assertions =
          concatLists (
            flip mapAttrsToList config.users.users (
              name: user: [
                {
                  assertion = user.uid != null;
                  message = "den: non-deterministic uid for '${name}', assign via users.deterministicIds";
                }
                {
                  assertion = !user.autoSubUidGidRange;
                  message = "den: non-deterministic subUids/subGids for: ${name}";
                }
              ]
            )
          )
          ++ flip mapAttrsToList config.users.groups (
            name: group: {
              assertion = group.gid != null;
              message = "den: non-deterministic gid for '${name}', assign via users.deterministicIds";
            }
          );
      };
  };
}
