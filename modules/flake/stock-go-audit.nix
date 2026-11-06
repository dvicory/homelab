{ inputs, lib, ... }:
{
  perSystem =
    { pkgs, system, ... }:
    lib.optionalAttrs (system == "x86_64-linux") (
      let
        host = inputs.self.nixosConfigurations.hvn-hyp1.config;
        findingSummary = pkgs.writeText "stock-go-audit-findings.jq" ''
          {
            binary: $binary,
            extraction: {precision: $precision, symbolCount: $symbolCount},
            unresolved: ($precision != "extracted-symbols" or any(.[]; has("finding"))),
            findings: [
              .[] | .finding? // empty |
              . + {
                audit_precision:
                  if $precision != "extracted-symbols" then $precision
                  elif .trace[0].function? then "extracted-symbol"
                  elif .trace[0].package? then "package"
                  else "module"
                  end
              }
            ]
          }
        '';
      in
      {
        packages.stock-go-audit = pkgs.writeShellApplication {
          name = "stock-go-audit";
          runtimeInputs = [
            pkgs.go_1_27
            pkgs.govulncheck
            pkgs.osv-scanner
            pkgs.jq
            pkgs.coreutils
          ];
          text = ''
            export GOTOOLCHAIN=local GOWORK=off
            if (( $# > 1 )); then
              echo "usage: stock-go-audit [REPORT_DIRECTORY]" >&2
              exit 2
            fi
            report_directory=''${1:-}
            if [[ -z "$report_directory" ]]; then
              report_directory=$(mktemp -d -t stock-go-audit.XXXXXXXX)
            else
              mkdir -p -- "$report_directory"
            fi
            printf 'Retaining audit reports in %s\n' "$report_directory"
            status=0

            audit_binary() {
              local binary=$1 application_version=$2 name=$3
              local report="$report_directory/$name" precision=unavailable symbol_count=0
              mkdir -p -- "$report"
              printf '\nAuditing %s (application version from evaluated Nix: %s)\n' "$binary" "$application_version"
              go version -m -json "$binary" > "$report/buildinfo.json"
              jq -e '
                (.GoVersion | startswith("go")) and
                (.Main.Path | type == "string") and
                all(.Deps[]?; (.Replace // .) | (.Version | test("^v[0-9]")))
              ' "$report/buildinfo.json" > /dev/null
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
              ' "$report/buildinfo.json" > "$report/binary.cdx.json"

              # Binary-mode findings alone do not disclose extraction fallback.
              if govulncheck -mode=extract "$binary" > "$report/extract.json" 2> "$report/extract.stderr"; then
                if symbol_count=$(jq -s '[.[] | (.pkgSymbols // [] | length)] | add // 0' "$report/extract.json"); then
                  if (( symbol_count > 0 )); then
                    precision=extracted-symbols
                  else
                    precision=module-fallback
                  fi
                fi
              fi
              cat "$report/extract.stderr"
              printf 'Extraction precision: %s (%s symbols)\n' "$precision" "$symbol_count"
              if [[ "$precision" != extracted-symbols ]]; then
                echo 'Advisory function names are not evidence of extracted ELF symbols; audit remains unresolved.'
              fi

              # JSON mode exits zero even for findings: inspect the full stream.
              govulncheck -mode=binary -format=json "$binary" \
                > "$report/govulncheck.json" 2> "$report/govulncheck.stderr" || status=1
              cat "$report/govulncheck.stderr"
              if jq -s --arg binary "$binary" --arg precision "$precision" \
                --argjson symbolCount "$symbol_count" -f ${findingSummary} \
                "$report/govulncheck.json" > "$report/govulncheck-summary.json"; then
                cat "$report/govulncheck-summary.json"
                jq -e '.unresolved == false' "$report/govulncheck-summary.json" > /dev/null || status=1
              else
                status=1
              fi
              osv-scanner scan source -L "$report/binary.cdx.json" \
                --all-vulns --no-call-analysis=go 2>&1 | tee "$report/osv.txt" || status=1
            }

            audit_binary ${lib.escapeShellArg "${host.virtualisation.incus.package}/bin/incusd"} ${lib.escapeShellArg host.virtualisation.incus.package.version} incusd
            audit_binary ${lib.escapeShellArg "${host.virtualisation.incus.clientPackage}/bin/incus"} ${lib.escapeShellArg host.virtualisation.incus.clientPackage.version} incus
            # Tailscale's daemon and CLI share this multicall ELF; don't scan its shell wrapper twice.
            audit_binary ${lib.escapeShellArg "${host.services.tailscale.package}/bin/.tailscaled-wrapped"} ${lib.escapeShellArg host.services.tailscale.package.version} tailscale
            exit "$status"
          '';
        };
        checks.stock-go-audit-report =
          pkgs.runCommand "stock-go-audit-report" { nativeBuildInputs = [ pkgs.jq ]; } ''
            printf '%s\n' \
              '{"finding":{"osv":"GO-TEST","trace":[{"module":"example"}]}}' \
              '{"finding":{"osv":"GO-TEST","trace":[{"module":"example","package":"example/p"}]}}' \
              '{"finding":{"osv":"GO-TEST","trace":[{"module":"example","package":"example/p","function":"Vulnerable"}]}}' \
              > findings.json
            summarize() {
              jq -s --arg binary fixture --arg precision "$1" --argjson symbolCount "$2" \
                -f ${findingSummary} findings.json
            }
            summarize module-fallback 0 > fallback.json
            jq -e '
              .unresolved and (.findings | length == 3) and
              all(.findings[]; .audit_precision == "module-fallback") and
              .findings[2].trace[0].function == "Vulnerable"
            ' fallback.json
            summarize extracted-symbols 1 > symbols.json
            jq -e '
              .unresolved and
              [.findings[].audit_precision] == ["module", "package", "extracted-symbol"]
            ' symbols.json
            summarize unavailable 0 > unavailable.json
            jq -e '.unresolved and all(.findings[]; .audit_precision == "unavailable")' unavailable.json
            printf '%s\n' '{"config":{"scan_level":"symbol"}}' > findings.json
            summarize extracted-symbols 1 > empty.json
            jq -e '(.unresolved | not) and .findings == []' empty.json
            summarize module-fallback 0 > incomplete.json
            jq -e '.unresolved and .findings == []' incomplete.json
            touch "$out"
          '';
      }
    );
}
