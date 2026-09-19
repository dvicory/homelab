{ ... }:
{
  perSystem =
    {
      config,
      pkgs,
      system,
      ...
    }:
    let
      preserve = config.packages.homelab-preserve;
      fixtureAdapter = config.packages.homelab-preserve-fixture-adapter;
    in
    {
      checks.preserve-protocol =
        pkgs.runCommand "preserve-protocol"
          {
            nativeBuildInputs = [
              preserve
              fixtureAdapter
              pkgs.jq
            ];
          }
          ''
            set -euo pipefail
            mkdir -p "$TMPDIR/source" "$TMPDIR/target" "$TMPDIR/scratch"
            manifest="$TMPDIR/manifest.json"
            cat > "$manifest" <<EOF
            {
              "schemaVersion": 1,
              "kind": "executable-plan",
              "fixtureOnly": true,
              "scratchDestinations": {
                "scratch": {
                  "nativeParent": "fixture/scratch",
                  "mountRoot": "$TMPDIR/scratch"
                }
              },
              "states": [
                {
                  "stateId": "fixture/state",
                  "mode": "enabled",
                  "operational": true,
                  "realization": {
                    "kind": "host-filesystem",
                    "owner": {"kind": "host", "id": "fixture"},
                    "locator": "fixture/source",
                    "path": "$TMPDIR/source",
                    "boundary": {
                      "recursive": false,
                      "requiredChildren": [],
                      "exclusions": []
                    },
                    "access": [],
                    "physicalBacking": null
                  },
                  "routes": [
                    {
                      "routeId": "fixture-route",
                      "obligationId": "fixture/state::fixture-route",
                      "target": {
                        "targetId": "fixture-target",
                        "failureDomain": {"site": "fixture", "domain": "one-domain"}
                      },
                      "integration": {
                        "integrationId": "fixture-integration",
                        "owner": "fixture-owner",
                        "adapter": "${fixtureAdapter}/bin/homelab-preserve-fixture-adapter",
                        "protocolVersion": 1,
                        "timeoutSeconds": 5,
                        "maxResponseBytes": 1048576,
                        "fixtureOnly": true,
                        "operations": ["describe","status","points","run","restore","verify"],
                        "fidelityGuarantees": ["posix-filesystem"],
                        "guaranteedConsistency": "live",
                        "nativePointRepresentations": ["fixture-directory/v1"],
                        "payloadRepresentation": null
                      },
                      "operation": "run",
                      "eligibleIntegrations": ["fixture-integration"],
                      "semanticRequirements": {
                        "dataKind": "filesystem",
                        "requiredConsistency": "live",
                        "routeRequiredConsistency": "live",
                        "requiredFidelity": ["posix-filesystem"],
                        "acceptedPayloadFormats": []
                      },
                      "guaranteedConsistency": "live",
                      "payloadRepresentation": null,
                      "nativePointRepresentations": ["fixture-directory/v1"],
                      "ownerConfig": {
                        "source": {
                          "subpath": null,
                          "include": [],
                          "exclude": []
                        },
                        "native": {
                          "root": "$TMPDIR/catalog",
                          "atomicAction": "fixture-retain"
                        }
                      },
                      "status": "resolved",
                      "issues": []
                    }
                  ],
                  "issues": []
                }
              ]
            }
            EOF

            homelab-preserve --manifest "$manifest" --json plan > "$TMPDIR/plan.json"
            jq -e '.kind == "executable-plan" and .fixtureOnly == true and (.states | length) == 1' "$TMPDIR/plan.json" >/dev/null
            jq -e '.states[0] | has("caveats") | not' "$TMPDIR/plan.json" >/dev/null
            jq -e '.states[0].routes[0].target | (has("purpose") or has("kind") or has("locator") or has("ownerData")) | not' \
              "$TMPDIR/plan.json" >/dev/null
            jq -e '.states[0].routes[0] | (has("binding") or has("failureDomainIndependent")) | not' \
              "$TMPDIR/plan.json" >/dev/null
            jq -e '.states[0].routes[0].ownerConfig | has("bindingApplied") | not' "$TMPDIR/plan.json" >/dev/null
            jq -e '.states[0].routes[0].target.failureDomain | length > 0' "$TMPDIR/plan.json" >/dev/null
            jq -e '.states[0].routes[0].semanticRequirements.dataKind == "filesystem" and
              .states[0].routes[0].semanticRequirements.requiredConsistency == "live" and
              .states[0].routes[0].semanticRequirements.requiredFidelity == ["posix-filesystem"] and
              .states[0].routes[0].guaranteedConsistency == "live" and
              .states[0].routes[0].nativePointRepresentations == ["fixture-directory/v1"]' \
              "$TMPDIR/plan.json" >/dev/null

            homelab-preserve --manifest "$manifest" plan > "$TMPDIR/plan-human.txt"
            test -s "$TMPDIR/plan-human.txt"
            homelab-preserve --manifest "$manifest" status > "$TMPDIR/status-human.txt"
            test -s "$TMPDIR/status-human.txt"

            jq '.fixtureOnly = false' "$manifest" > "$TMPDIR/nonfixture.json"
            if homelab-preserve --manifest "$TMPDIR/nonfixture.json" plan >/dev/null 2>&1; then
              echo "fixture-only integration unexpectedly allowed in a non-fixture plan" >&2
              exit 1
            fi

            jq '.kind = "desired-inventory" | .states[0].mode = "plan-only" | .states[0].operational = false | .states[0].routes[0].integration.adapter = "/does/not/exist"' \
              "$manifest" > "$TMPDIR/plan-only.json"
            homelab-preserve --manifest "$TMPDIR/plan-only.json" --json plan > "$TMPDIR/plan-only-output.json"
            if homelab-preserve --manifest "$TMPDIR/plan-only.json" points fixture/state >/dev/null 2>&1; then
              echo "plan-only state unexpectedly operated" >&2
              exit 1
            fi

            homelab-preserve --manifest "$manifest" --json status > "$TMPDIR/configured.json"
            jq -e '.states[0].routes[0].observed == false and .states[0].routes[0].pointCount == null' \
              "$TMPDIR/configured.json" >/dev/null
            homelab-preserve --manifest "$manifest" --json status --observe > "$TMPDIR/observed-empty.json"
            jq -e '.states[0].routes[0].observed == true and .states[0].routes[0].pointCount == 0' \
              "$TMPDIR/observed-empty.json" >/dev/null

            homelab-preserve --manifest "$manifest" --json points fixture/state > "$TMPDIR/empty-points.json"
            jq -e '.kind == "points" and .stateId == "fixture/state" and
              .routes[0].status == "ok" and (.routes[0].points | length) == 0' \
              "$TMPDIR/empty-points.json" >/dev/null
            homelab-preserve --manifest "$manifest" --json run fixture/state --route fixture-route > "$TMPDIR/run.json"
            jq -e '.evidence == "retained" and .details.atomicAction == "fixture-retain"' "$TMPDIR/run.json" >/dev/null

            homelab-preserve --manifest "$manifest" --json points fixture/state > "$TMPDIR/points.json"
            jq -e '.routes[0].status == "ok" and (.routes[0].points | length) == 1 and
              .routes[0].points[0].nativeId == "fixture-point-1"' "$TMPDIR/points.json" >/dev/null
            jq -e '.routes[0].points[0].producerProvenance["fixture.applicationVersion"] == "1.2.3"' "$TMPDIR/points.json" >/dev/null
            jq -e '.routes[0].points[0].producerProvenance["postgresql.serverVersion"] == "16"' "$TMPDIR/points.json" >/dev/null
            jq -e '.routes[0].points[0].producerProvenance["application.schema"].major == 4' "$TMPDIR/points.json" >/dev/null
            jq -e '.routes[0].points[0].nativeRepresentation.kind == "fixture-directory/v1" and .routes[0].points[0].payloadRepresentation == null' \
              "$TMPDIR/points.json" >/dev/null
            homelab-preserve --manifest "$manifest" points fixture/state > "$TMPDIR/points-human.txt"
            test -s "$TMPDIR/points-human.txt"

            jq '.states[0].routes[0].integration.nativePointRepresentations = ["other/v1"]' \
              "$manifest" > "$TMPDIR/wrong-representation.json"
            homelab-preserve --manifest "$TMPDIR/wrong-representation.json" --json points fixture/state \
              > "$TMPDIR/wrong-representation-report.json"
            jq -e '.routes[0].status == "failed" and (.routes[0].points | length) == 0 and
              .routes[0].error.code == "unsupported-point-representation"' \
              "$TMPDIR/wrong-representation-report.json" >/dev/null
            jq '.states[0].routes[0].integration.payloadRepresentation = "fixture-payload/v1"' \
              "$manifest" > "$TMPDIR/wrong-payload.json"
            homelab-preserve --manifest "$TMPDIR/wrong-payload.json" --json points fixture/state \
              > "$TMPDIR/wrong-payload-report.json"
            jq -e '.routes[0].status == "failed" and (.routes[0].points | length) == 0 and
              .routes[0].error.code == "unsupported-point-payload"' \
              "$TMPDIR/wrong-payload-report.json" >/dev/null

            jq -e '.routes[0].points[0].ownerProvenance["fixture.executable"] == "/does/not/execute"' \
              "$TMPDIR/points.json" >/dev/null

            jq '.states[0].routes[0].ownerConfig.native.capabilities = ["describe","status","points"] |
                .states[0].routes[0].ownerConfig.native.root = "'$TMPDIR'/catalog-no-run"' \
              "$manifest" > "$TMPDIR/unsupported-run.json"
            if homelab-preserve --manifest "$TMPDIR/unsupported-run.json" run fixture/state \
              --route fixture-route >/dev/null 2>&1; then
              echo "unsupported run capability unexpectedly succeeded" >&2
              exit 1
            fi
            test ! -e "$TMPDIR/catalog-no-run"

            jq '.states[0].routes[0].ownerConfig.native.capabilities = ["describe","status"] |
                .states[0].routes[0].ownerConfig.native.root = "'$TMPDIR'/catalog-no-points"' \
              "$manifest" > "$TMPDIR/missing-baseline.json"
            homelab-preserve --manifest "$TMPDIR/missing-baseline.json" --json points fixture/state \
              > "$TMPDIR/missing-baseline-report.json"
            jq -e '.routes[0].status == "failed" and (.routes[0].points | length) == 0 and
              .routes[0].error.code == "unsupported-baseline-operation"' \
              "$TMPDIR/missing-baseline-report.json" >/dev/null
            test ! -e "$TMPDIR/catalog-no-points"

            jq '.states[0].routes[0].ownerConfig.native.root = "/dev/null/secret-looking-value"' \
              "$manifest" > "$TMPDIR/leaky-adapter.json"
            if homelab-preserve --manifest "$TMPDIR/leaky-adapter.json" --json run fixture/state \
              --route fixture-route 2>"$TMPDIR/leaky-stderr.txt"; then
              echo "adapter error unexpectedly allowed run" >&2
              exit 1
            fi
            if grep -q "secret-looking-value" "$TMPDIR/leaky-stderr.txt"; then
              echo "coordinator diagnostic leaked raw adapter stderr" >&2
              exit 1
            fi
            grep -q "fixture-error" "$TMPDIR/leaky-stderr.txt"
            test ! -e "/dev/null/secret-looking-value"
            test -z "$(ls -A "$TMPDIR/scratch")"

            jq '.states[0].routes[0].ownerConfig.native.explicitScratch = false' \
              "$manifest" > "$TMPDIR/unsafe-restore.json"
            if homelab-preserve --manifest "$TMPDIR/unsafe-restore.json" restore fixture/state \
              --from fixture-route --point fixture-point-1 --to scratch:unsafe-dest >/dev/null 2>&1; then
              echo "non-explicit-scratch adapter unexpectedly passed restore preflight" >&2
              exit 1
            fi
            test ! -e "$TMPDIR/scratch/unsafe-dest"

            jq '.states[0].routes[0].ownerConfig.native.reportedProtocolVersion = 2' \
              "$manifest" > "$TMPDIR/version-mismatch.json"
            if homelab-preserve --manifest "$TMPDIR/version-mismatch.json" run fixture/state \
              --route fixture-route >/dev/null 2>&1; then
              echo "adapter protocol version mismatch unexpectedly accepted" >&2
              exit 1
            fi

            jq '.states[0].routes[0].ownerConfig.native.targetRoot = "'$TMPDIR'/scratch"' \
              "$manifest" > "$TMPDIR/target-alias.json"
            if homelab-preserve --manifest "$TMPDIR/target-alias.json" restore fixture/state \
              --from fixture-route --point fixture-point-1 --to scratch:aliasdest \
              --execute --receipt "$TMPDIR/alias-receipt.json" >/dev/null 2>&1; then
              echo "destination under native target root unexpectedly restored" >&2
              exit 1
            fi
            test ! -e "$TMPDIR/scratch/aliasdest"
            test ! -e "$TMPDIR/alias-receipt.json"

            homelab-preserve --manifest "$manifest" --json restore fixture/state \
              --from fixture-route --point fixture-point-1 --to scratch:rehearsal > "$TMPDIR/preflight.json"
            jq -e '.kind == "restore-preflight" and .mutation == false and .point.nativeId == "fixture-point-1"' \
              "$TMPDIR/preflight.json" >/dev/null
            test ! -e "$TMPDIR/scratch/rehearsal"
            if homelab-preserve --manifest "$manifest" restore fixture/state \
              --from fixture-route --point absent-point --to scratch:unknown >/dev/null 2>&1; then
              echo "unknown point unexpectedly passed restore preflight" >&2
              exit 1
            fi
            test ! -e "$TMPDIR/scratch/unknown"

            if homelab-preserve --manifest "$manifest" --json restore fixture/state \
              --from fixture-route --point fixture-point-1 --to scratch:rehearsal \
              --execute --receipt "$TMPDIR/missing-dir/receipt.json" >/dev/null 2>&1; then
              echo "unusable receipt parent unexpectedly accepted" >&2
              exit 1
            fi
            test ! -e "$TMPDIR/scratch/rehearsal"
            homelab-preserve --manifest "$manifest" --json restore fixture/state \
              --from fixture-route --point fixture-point-1 --to scratch:rehearsal \
              --execute --receipt "$TMPDIR/receipt.json" > "$TMPDIR/restore.json"
            test -f "$TMPDIR/scratch/rehearsal/content.txt"
            test -f "$TMPDIR/receipt.json"
            jq -e '.producerProvenance["fixture.applicationVersion"] == "1.2.3"' "$TMPDIR/receipt.json" >/dev/null
            jq -e '.point.nativeRepresentation.kind == "fixture-directory/v1" and .point.payloadRepresentation == null' \
              "$TMPDIR/receipt.json" >/dev/null
            homelab-preserve --manifest "$manifest" --json verify "$TMPDIR/receipt.json" > "$TMPDIR/verify.json"
            jq -e '.verified == true and .evidence == "verified"' "$TMPDIR/verify.json" >/dev/null

            printf altered > "$TMPDIR/scratch/rehearsal/content.txt"
            if homelab-preserve --manifest "$manifest" verify "$TMPDIR/receipt.json" >/dev/null 2>&1; then
              echo "altered restore unexpectedly verified" >&2
              exit 1
            fi
            if homelab-preserve --manifest "$manifest" restore fixture/state \
              --from fixture-route --point fixture-point-1 --to scratch:rehearsal >/dev/null 2>&1; then
              echo "existing destination unexpectedly accepted" >&2
              exit 1
            fi
            if homelab-preserve --manifest "$manifest" restore fixture/state \
              --from fixture-route --point fixture-point-1 --to scratch:../escape >/dev/null 2>&1; then
              echo "traversal destination unexpectedly accepted" >&2
              exit 1
            fi
            if homelab-preserve --manifest "$manifest" restore fixture/state \
              --from fixture-route --point fixture-point-1 --to scratch:forced --force >/dev/null 2>&1; then
              echo "force bypass unexpectedly accepted" >&2
              exit 1
            fi

            printf '%s' '{"protocolVersion":1,"requestId":"describe","operation":"describe","stateId":"fixture/state","routeId":"fixture-route","targetId":"fixture-target","ownerPayload":{}}' \
              | homelab-preserve-fixture-adapter protocol > "$TMPDIR/describe.json"
            jq -e '.result.capabilities | index("run") != null and index("restore") != null and index("capture") == null and index("protect") == null and index("retry") == null' \
              "$TMPDIR/describe.json" >/dev/null

            touch "$out"
          '';
    };
}
