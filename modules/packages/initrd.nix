{ lib, ... }:
{
  perSystem =
    { pkgs, ... }:
    {
      packages = lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
        initrdShowIp = pkgs.writeShellApplication {
          name = "initrd-show-ip";

          runtimeInputs = with pkgs; [
            iproute2
            coreutils
          ];

          text = ''
            # Wait for network to be ready
            sleep 1

            # Get the current IP address
            IP=$(ip route get 1.1.1.1 2>/dev/null | head -1 | cut -d' ' -f7 || echo "unknown")

            # Display with message (can be customized via environment variable)
            MESSAGE="''${IP_DISPLAY_MESSAGE:-🌐 Current IP Address}"

            echo ""
            echo "$MESSAGE: $IP"
            echo "   Use this IP to connect: ssh root@$IP"
            echo ""
          '';

          meta.platforms = lib.platforms.linux;
        };

        initrdZfsRollback = pkgs.writeShellApplication {
          name = "initrd-zfs-rollback";

          runtimeInputs = with pkgs; [
            zfs
          ];

          text = ''
            # Get pool name from environment variable
            POOL_NAME="''${INITRD_POOL_NAME:-rpool}"

            # Rollback to blank snapshot for impermanence
            echo "Performing ZFS rollback for impermanence..."
            if zfs list -t snapshot "$POOL_NAME/local/root@blank" > /dev/null 2>&1; then
              echo "Rolling back $POOL_NAME/local/root to blank snapshot..."
              zfs rollback -r "$POOL_NAME/local/root@blank"
              echo "ZFS rollback completed"
            else
              echo "Warning: No blank snapshot found at $POOL_NAME/local/root@blank"
            fi
          '';

          meta.platforms = lib.platforms.linux;
        };

        initrdZfsSetup = pkgs.writeShellApplication {
          name = "initrd-zfs-setup";

          runtimeInputs = with pkgs; [
            zfs
            iproute2
            gnugrep
            coreutils
            systemd
            util-linux # for kill command
          ];

          text = ''
                    # Get configuration from environment variables
                    POOL_NAME="''${INITRD_POOL_NAME:-rpool}"
                    SSH_PORT="''${INITRD_SSH_PORT:-2222}"

                    # Wait for ZFS module and devices to be ready
                    echo "Waiting for ZFS pools to become available..."

                    # Try to import pools with retries (like traditional skarabox timing)
                    for attempt in 1 2 3 4 5; do
                      echo "Import attempt $attempt/5..."

                      if zpool import -a 2>/dev/null; then
                        echo "ZFS pools imported successfully on attempt $attempt"
                        break
                      fi

                      if [ $attempt -eq 5 ]; then
                        echo "Failed to import pools after 5 attempts"
                        echo "Available devices:"
                        ls -la /dev/disk/by-* || true
                        exit 1
                      fi

                      echo "No pools found yet, waiting 3 seconds..."
                      sleep 3
                    done

                    echo "ZFS pools imported successfully"
                    zpool list

                    # Check for additional pools (dataPools) that might need attention
                    all_pools=$(zpool list -H -o name)
                    echo "Available ZFS pools: $all_pools"

                    # Set up SSH unlock profile for manual unlock
                    # Write to .profile for login shells
                    cat >> /root/.profile << EOF
            export PATH=\$PATH:/run/current-system/sw/bin

            echo "🔐 ZFS Remote Unlock Required"
            echo "Pool status:"
            zpool status "$POOL_NAME" || echo "Pool not found"
            echo ""
            echo "Available pools:"
            zpool list || echo "No pools available"
            echo ""
            echo "Manual unlock required:"
            echo "Run: zfs load-key $POOL_NAME"
            echo ""
            echo "Boot will continue automatically after unlock."
            EOF

                    # Also create .bashrc that sources .profile for interactive shells
                    cat > /root/.bashrc << 'EOF'
            # Source .profile for interactive shells
            if [ -f /root/.profile ]; then
                source /root/.profile
            fi
            EOF

                    echo "⏸️  ZFS pools imported but encryption key required"
                    # Get IP address
                    current_ip=$(ip route get 1.1.1.1 2>/dev/null | head -1 | cut -d' ' -f7 || echo "unknown")
                    echo "🌐 Connect via SSH to unlock: ssh root@$current_ip -p $SSH_PORT"
                    echo "🖥️  Or enter passphrase at the console prompt"
                    echo "💤 Boot will pause until ZFS is unlocked..."

                    # Start systemd password prompt in background with retry loop
                    (
                      while true; do
                        passphrase=$(systemd-ask-password --timeout=0 "Enter ZFS passphrase for $POOL_NAME:")
                        if echo "$passphrase" | zfs load-key "$POOL_NAME" 2>/dev/null; then
                          echo "✅ ZFS unlocked via console!"
                          break
                        else
                          echo "❌ Incorrect passphrase, please try again..."
                          sleep 1
                        fi
                      done
                    ) &
                    console_pid=$!

                    # Wait for manual unlock - periodically check if key becomes available
                    while true; do
                      key_status=$(zfs get -H keystatus "$POOL_NAME" | cut -f3)
                      if [ "$key_status" = "available" ]; then
                        echo "✅ ZFS key is now available! Performing impermanence rollback..."
                        kill $console_pid 2>/dev/null || true

                        echo "🚀 Boot will continue automatically..."
                        exit 0
                      fi
                      sleep 5
                    done
          '';

          meta.platforms = lib.platforms.linux;
        };
      };
    };
}
