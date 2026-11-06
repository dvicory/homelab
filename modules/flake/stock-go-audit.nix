{ inputs, lib, ... }:
{
  perSystem =
    { pkgs, system, ... }:
    lib.optionalAttrs (system == "x86_64-linux") (
      let
        host = inputs.self.nixosConfigurations.hvn-hyp1.config;
        securityPkgs = inputs.nixpkgs-security.legacyPackages.${system};
      in
      {
        packages.stock-go-audit = pkgs.writeShellApplication {
          name = "stock-go-audit";
          runtimeInputs = [
            securityPkgs.go_1_27
            securityPkgs.govulncheck
            securityPkgs.osv-scanner
            pkgs.jq
          ];
          text = ''
            export GOTOOLCHAIN=local GOWORK=off
            temporary=$(mktemp -d)
            trap 'rm -rf -- "$temporary"' EXIT
            status=0

            audit_binary() {
              local binary=$1 application_version=$2
              printf '\nAuditing %s (application version from evaluated Nix: %s)\n' "$binary" "$application_version"
              go version -m -json "$binary" > "$temporary/buildinfo.json"
              jq -e '
                (.GoVersion | startswith("go")) and
                (.Main.Path | type == "string") and
                all(.Deps[]?; (.Replace // .) | (.Version | test("^v[0-9]")))
              ' "$temporary/buildinfo.json" > /dev/null
              jq --arg applicationVersion "v$application_version" '
                def component($name; $version): {
                  type: "library", name: $name, version: $version,
                  purl: ("pkg:golang/" + $name + "@" + $version)
                };
                {
                  bomFormat: "CycloneDX", specVersion: "1.6", version: 1,
                  components: [
                    component("stdlib"; (.GoVersion | ltrimstr("go"))),
                    (component(.Main.Path; $applicationVersion) + {
                      properties: [{name: "homelab:version-source", value: "evaluated Nix package"}]
                    }),
                    (.Deps[]? | (.Replace // .) | component(.Path; .Version))
                  ]
                }
              ' "$temporary/buildinfo.json" > "$temporary/binary.cdx.json"
              # Keep both reports and all binaries even when an advisory is found.
              govulncheck -mode=binary "$binary" || status=1
              osv-scanner scan source -L "$temporary/binary.cdx.json" \
                --all-vulns --no-call-analysis=go || status=1
            }

            audit_binary ${lib.escapeShellArg "${host.virtualisation.incus.package}/bin/incusd"} ${lib.escapeShellArg host.virtualisation.incus.package.version}
            audit_binary ${lib.escapeShellArg "${host.virtualisation.incus.clientPackage}/bin/incus"} ${lib.escapeShellArg host.virtualisation.incus.clientPackage.version}
            # Tailscale's daemon and CLI share this multicall ELF; don't scan its shell wrapper twice.
            audit_binary ${lib.escapeShellArg "${host.services.tailscale.package}/bin/.tailscaled-wrapped"} ${lib.escapeShellArg host.services.tailscale.package.version}
            exit "$status"
          '';
        };
      }
    );
}
