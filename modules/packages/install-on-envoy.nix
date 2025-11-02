{ lib, self, ... }:
{
  config.perSystem =
    {
      pkgs,
      config,
      inputs',
      ...
    }:
    let
      # TODO: this should be way better to avoid including non-nixos systems
      # Embed the hosts configuration as JSON for runtime lookup
      hostsJson = builtins.toJSON (
        lib.filterAttrs (_: host: host.enable && lib.hasInfix "linux" host.system) self.dlab.hosts
      );
    in
    {
      packages.install-on-envoy = pkgs.writeShellApplication {
        name = "install-on-envoy";
        runtimeInputs = [
          inputs'.nixos-anywhere.packages.nixos-anywhere
          pkgs.sops
          pkgs.jq
        ];

        text = ''
          # install-on-envoy
          # Implements secure secret handling via FIFO pattern and nixos-anywhere execution

          FLAKE_ROOT="''$(${lib.getExe config.flake-root.package})"
          export FLAKE_ROOT
          export SOPS_AGE_KEY_FILE="''${FLAKE_ROOT}/sops.key"

          # Embedded hosts configuration
          hosts_json='${hostsJson}'

          # Parse command line arguments
          host=""
          while getopts "h:" opt; do
            case $opt in
              h) host=''${OPTARG} ;;
              *) echo "Usage: $0 -h <host> [-- <nixos-anywhere args>]" >&2; exit 1 ;;
            esac
          done
          shift $((OPTIND-1))

          # Validate host exists in configuration
          if ! host_config=$(echo "$hosts_json" | jq -e ".\"$host\" // empty" 2>/dev/null); then
            echo "Error: Host '$host' not found in configuration" >&2
            echo "Available hosts: $(echo "$hosts_json" | jq -r 'keys | join(", ")')" >&2
            exit 1
          fi

          # Extract host configuration fields
          target=$(echo "$host_config" | jq -r '.deploy.target')
          user=$(echo "$host_config" | jq -r '.deploy.user // "root"')
          ssh_port=$(echo "$host_config" | jq -r '.deploy.sshPort // 22')
          known_hosts_path=$(echo "$host_config" | jq -r '.deploy.knownHostsPath')
          tailscale_client_secret=$(echo "$host_config" | jq -r '.remoteUnlock.tailscaleClientSecretPath')
          boot_host_key_path=$(echo "$host_config" | jq -r '.deploy.bootHostKeyPath')
          runtime_host_key_path=$(echo "$host_config" | jq -r '.deploy.runtimeHostKeyPath')

          # Extract secrets configuration
          host_sops_file=$(echo "$host_config" | jq -r '.secrets.hostSopsFile')
          root_passphrase_sops_path=$(echo "$host_config" | jq -r '.secrets.rootPassphraseSopsPath')

          # Validate required fields
          if [[ -z "$target" || -z "$known_hosts_path" || -z "$boot_host_key_path" || -z "$runtime_host_key_path" ]]; then
            echo "Error: Missing required deployment configuration for host '$host'" >&2
            exit 1
          fi

          if [[ -z "$host_sops_file" || -z "$root_passphrase_sops_path" ]]; then
            echo "Error: Missing required secrets configuration for host '$host'" >&2
            exit 1
          fi

          # Create FIFO for root passphrase (runtime-only, never touches Nix store)
          root_passphrase=$(mktemp -u)
          mkfifo -m600 "$root_passphrase"

          # Defer expansion until trap execution; safely handle unset decrypt_pid.
          trap 'kill "''${decrypt_pid:-}" 2>/dev/null || :; rm -f "$root_passphrase"' EXIT

          # Background decrypt root passphrase to FIFO
          sops decrypt --extract "$root_passphrase_sops_path" "$host_sops_file" > "$root_passphrase" &
          decrypt_pid=$!

          # Execute nixos-anywhere with proper arguments
          # TODO: get facter path from host config or something instead
          nixos-anywhere \
            -p "$ssh_port" \
            --ssh-option UserKnownHostsFile="$known_hosts_path" \
            --generate-hardware-config nixos-facter "modules/hosts/$host/facter.json" \
            --disk-encryption-keys /tmp/boot_host_key "$boot_host_key_path" \
            --disk-encryption-keys /tmp/runtime_host_key "$runtime_host_key_path" \
            --disk-encryption-keys /tmp/tailscale_client_secret "$tailscale_client_secret" \
            --disk-encryption-keys /tmp/root_passphrase "$root_passphrase" \
            -f ".#$host" \
            "$@" \
            "$user"@"$target"

          # Ensure the background decrypt process is reaped (ignore errors)
          wait "''${decrypt_pid:-}" 2>/dev/null || true
        '';
      };
    };
}
