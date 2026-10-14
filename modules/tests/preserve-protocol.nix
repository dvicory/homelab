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
              "schemaVersion": 2,
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
                      "targetBoundaries": {
                        "paths": ["$TMPDIR/catalog"],
                        "nativeLocators": [],
                        "nativeNamespace": null
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
            jq '.protectedRealizations = [.states[] | {stateId, realization}]' \
              "$manifest" > "$TMPDIR/fenced-manifest.json"
            manifest="$TMPDIR/fenced-manifest.json"

            for invalid in missing null incomplete empty relative-path empty-locator unknown-owner old-schema; do
              case "$invalid" in
                missing) filter='del(.protectedRealizations)'; code=document-json ;;
                null) filter='.protectedRealizations = null'; code=document-json ;;
                incomplete) filter='.protectedRealizations = [{stateId:"fixture/state"}]'; code=document-json ;;
                empty) filter='.protectedRealizations = []'; code=missing-protected-realization ;;
                relative-path) filter='.protectedRealizations[0].realization.path = "relative"'; code=invalid-protected-realization ;;
                empty-locator) filter='.protectedRealizations[0].realization.locator = ""'; code=invalid-protected-realization ;;
                unknown-owner) filter='.protectedRealizations[0].realization.owner = {}'; code=invalid-protected-realization ;;
                old-schema) filter='.schemaVersion = 1'; code=unsupported-schema-version ;;
              esac
              jq "$filter" "$manifest" > "$TMPDIR/invalid-fences.json"
              if homelab-preserve --manifest "$TMPDIR/invalid-fences.json" --json \
                restore fixture/state --from fixture-route --point fixture-point-1 \
                --to scratch:invalid --execute --receipt "$TMPDIR/invalid-receipt.json" \
                >/dev/null 2>"$TMPDIR/invalid-fences-error.json"; then
                echo "$invalid authoritative fences unexpectedly allowed restore" >&2
                exit 1
              fi
              jq -e --arg code "$code" '.error.code == $code' "$TMPDIR/invalid-fences-error.json" >/dev/null
              test ! -e "$TMPDIR/scratch/invalid"
              test ! -e "$TMPDIR/invalid-receipt.json"
              test ! -e "$TMPDIR/catalog"
            done

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
            if homelab-preserve --manifest "$TMPDIR/plan-only.json" --json restore fixture/state \
              --from fixture-route --point fixture-point-1 --to scratch:plan-only \
              --execute --receipt "$TMPDIR/plan-only-receipt.json" \
              >/dev/null 2>"$TMPDIR/plan-only-error.json"; then
              echo "plan-only protection unexpectedly restored" >&2
              exit 1
            fi
            jq -e '.error.code == "plan-only-document"' "$TMPDIR/plan-only-error.json" >/dev/null
            test ! -e "$TMPDIR/scratch/plan-only"
            test ! -e "$TMPDIR/plan-only-receipt.json"

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
            jq '.states[0].routes[0].integration.operations -= ["run"] |
                .states[0].routes[0].ownerConfig.native.root = "'$TMPDIR'/catalog-unauthorized"' \
              "$manifest" > "$TMPDIR/unauthorized-run.json"
            if homelab-preserve --manifest "$TMPDIR/unauthorized-run.json" --json run fixture/state \
              --route fixture-route >/dev/null 2>"$TMPDIR/unauthorized-run-error.json"; then
              echo "runtime advertisement broadened configured run authority" >&2
              exit 1
            fi
            jq -e '.error.code == "unsupported-operation"' "$TMPDIR/unauthorized-run-error.json" >/dev/null
            test ! -e "$TMPDIR/catalog-unauthorized"
            homelab-preserve --manifest "$manifest" --json run fixture/state --route fixture-route >/dev/null

            homelab-preserve --manifest "$manifest" --json points fixture/state > "$TMPDIR/points.json"
            jq -e '.routes[0].status == "ok" and (.routes[0].points | length) == 1 and
              .routes[0].points[0].nativeId == "fixture-point-1"' "$TMPDIR/points.json" >/dev/null

            # Discovery reads the retained catalog, not metadata reconstructed from the request.
            jq '.producerProvenance["fixture.retainedWitness"] = "catalog-value"' \
              "$TMPDIR/catalog/point.json" > "$TMPDIR/catalog/point.json.tmp"
            mv "$TMPDIR/catalog/point.json.tmp" "$TMPDIR/catalog/point.json"
            homelab-preserve --manifest "$manifest" --json points fixture/state > "$TMPDIR/catalog-points.json"
            jq -e '.routes[0].points[0].producerProvenance["fixture.retainedWitness"] == "catalog-value"' \
              "$TMPDIR/catalog-points.json" >/dev/null
            cp "$TMPDIR/catalog/point.json" "$TMPDIR/retained-before.json"

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

            jq '.states[0].routes[0].ownerConfig.native.targetRoot = "'$TMPDIR'/scratch" |
                .states[0].routes[0].targetBoundaries.paths += ["'$TMPDIR'/scratch"]' \
              "$manifest" > "$TMPDIR/target-alias.json"
            if homelab-preserve --manifest "$TMPDIR/target-alias.json" restore fixture/state \
              --from fixture-route --point fixture-point-1 --to scratch:aliasdest \
              --execute --receipt "$TMPDIR/alias-receipt.json" >/dev/null 2>&1; then
              echo "destination under native target root unexpectedly restored" >&2
              exit 1
            fi
            test ! -e "$TMPDIR/scratch/aliasdest"
            test ! -e "$TMPDIR/alias-receipt.json"

            ln -s "$TMPDIR/absent" "$TMPDIR/scratch/dangling"
            if homelab-preserve --manifest "$manifest" restore fixture/state \
              --from fixture-route --point fixture-point-1 --to scratch:dangling \
              --execute --receipt "$TMPDIR/dangling-receipt.json" >/dev/null 2>&1; then
              echo "dangling symlink destination unexpectedly accepted" >&2
              exit 1
            fi
            test -L "$TMPDIR/scratch/dangling"
            test ! -e "$TMPDIR/dangling-receipt.json"
            rm "$TMPDIR/scratch/dangling"

            homelab-preserve --manifest "$manifest" --json restore fixture/state \
              --from fixture-route --point fixture-point-1 --to scratch:rehearsal > "$TMPDIR/preflight.json"
            jq -e '.kind == "restore-preflight" and .mutation == false and .point.nativeId == "fixture-point-1" and
              .checkedScope == "coordinator" and .nativeChecks == "required-during-execution"' \
              "$TMPDIR/preflight.json" >/dev/null
            test ! -e "$TMPDIR/scratch/rehearsal"
            if homelab-preserve --manifest "$manifest" restore fixture/state \
              --from fixture-route --point absent-point --to scratch:unknown >/dev/null 2>&1; then
              echo "unknown point unexpectedly passed restore preflight" >&2
              exit 1
            fi
            test ! -e "$TMPDIR/scratch/unknown"
            jq '.states[0].routes[0].integration.operations -= ["restore"]' \
              "$manifest" > "$TMPDIR/unauthorized-restore.json"
            if homelab-preserve --manifest "$TMPDIR/unauthorized-restore.json" --json restore fixture/state \
              --from fixture-route --point fixture-point-1 --to scratch:unauthorized \
              --execute --receipt "$TMPDIR/unauthorized-receipt.json" \
              >/dev/null 2>"$TMPDIR/unauthorized-restore-error.json"; then
              echo "runtime advertisement broadened configured restore authority" >&2
              exit 1
            fi
            jq -e '.error.code == "unsupported-operation"' "$TMPDIR/unauthorized-restore-error.json" >/dev/null
            test ! -e "$TMPDIR/scratch/unauthorized"
            test ! -e "$TMPDIR/unauthorized-receipt.json"

            if homelab-preserve --manifest "$manifest" --json restore fixture/state \
              --from fixture-route --point fixture-point-1 --to scratch:rehearsal \
              --execute --receipt "$TMPDIR/missing-dir/receipt.json" >/dev/null 2>&1; then
              echo "unusable receipt parent unexpectedly accepted" >&2
              exit 1
            fi
            test ! -e "$TMPDIR/scratch/rehearsal"
            for occupied in file dangling; do
              if test "$occupied" = file; then
                printf 'existing receipt\n' > "$TMPDIR/occupied-receipt.json"
                cp "$TMPDIR/occupied-receipt.json" "$TMPDIR/occupied-before.json"
              else
                ln -s "$TMPDIR/absent-receipt" "$TMPDIR/occupied-receipt.json"
              fi
              if homelab-preserve --manifest "$manifest" --json restore fixture/state \
                --from fixture-route --point fixture-point-1 --to scratch:receipt-blocked \
                --execute --receipt "$TMPDIR/occupied-receipt.json" \
                >/dev/null 2>"$TMPDIR/occupied-error.json"; then
                echo "occupied receipt name unexpectedly allowed mutation" >&2
                exit 1
              fi
              jq -e '.error.code == "receipt-exists"' "$TMPDIR/occupied-error.json" >/dev/null
              test ! -e "$TMPDIR/scratch/receipt-blocked"
              if test "$occupied" = file; then
                cmp "$TMPDIR/occupied-before.json" "$TMPDIR/occupied-receipt.json"
              else
                test -L "$TMPDIR/occupied-receipt.json"
                test ! -e "$TMPDIR/absent-receipt"
              fi
              rm "$TMPDIR/occupied-receipt.json"
            done
            homelab-preserve --manifest "$manifest" --json restore fixture/state \
              --from fixture-route --point fixture-point-1 --to scratch:rehearsal \
              --execute --receipt "$TMPDIR/receipt.json" > "$TMPDIR/restore.json"
            test -f "$TMPDIR/scratch/rehearsal/content.txt"
            test -f "$TMPDIR/receipt.json"
            homelab-preserve --manifest "$manifest" --json verify "$TMPDIR/receipt.json" > "$TMPDIR/verify.json"
            jq -e '.verified == true and .evidence == "verified"' "$TMPDIR/verify.json" >/dev/null
            jq '.states[0].routes[0].integration.operations -= ["verify"]' \
              "$manifest" > "$TMPDIR/unauthorized-verify.json"
            if homelab-preserve --manifest "$TMPDIR/unauthorized-verify.json" --json verify "$TMPDIR/receipt.json" \
              >/dev/null 2>"$TMPDIR/unauthorized-verify-error.json"; then
              echo "runtime advertisement broadened configured verify authority" >&2
              exit 1
            fi
            jq -e '.error.code == "unsupported-operation"' "$TMPDIR/unauthorized-verify-error.json" >/dev/null
            mkdir "$TMPDIR/outside-scratch"
            cp "$TMPDIR/scratch/rehearsal/content.txt" "$TMPDIR/outside-scratch/content.txt"
            jq --arg path "$TMPDIR/outside-scratch" '.destination.path = $path' \
              "$TMPDIR/receipt.json" > "$TMPDIR/redirected-receipt.json"
            if homelab-preserve --manifest "$manifest" --json verify "$TMPDIR/redirected-receipt.json" \
              >/dev/null 2>"$TMPDIR/redirected-error.json"; then
              echo "receipt redirected outside scratch unexpectedly verified" >&2
              exit 1
            fi
            jq -e '.error.code == "receipt-destination-mismatch"' "$TMPDIR/redirected-error.json" >/dev/null
            cmp "$TMPDIR/scratch/rehearsal/content.txt" "$TMPDIR/outside-scratch/content.txt"

            jq -e '.producerProvenance["fixture.retainedWitness"] == "catalog-value" and
              .ownerReceipt.captureId == .point.captureId and
              .ownerReceipt.nativeId == .point.nativeId' "$TMPDIR/receipt.json" >/dev/null
            (
              cd "$TMPDIR"
              homelab-preserve --manifest "$manifest" --json restore fixture/state \
                --from fixture-route --point fixture-point-1 --to scratch:second \
                --execute --receipt receipt-second.json >/dev/null
            )
            homelab-preserve --manifest "$manifest" --json verify "$TMPDIR/receipt-second.json" >/dev/null
            cmp "$TMPDIR/retained-before.json" "$TMPDIR/catalog/point.json"
            jq '.ownerReceipt.captureId = "wrong-capture"' "$TMPDIR/receipt-second.json" \
              > "$TMPDIR/wrong-receipt.json"
            if homelab-preserve --manifest "$manifest" verify "$TMPDIR/wrong-receipt.json" >/dev/null 2>&1; then
              echo "receipt with a mismatched capture unexpectedly verified" >&2
              exit 1
            fi

            # A retained catalog and receipt suffice without the synthetic live path.
            rmdir "$TMPDIR/source"
            homelab-preserve --manifest "$manifest" --json points fixture/state > "$TMPDIR/source-lost.json"
            jq -e '.routes[0].points[0].producerProvenance["fixture.retainedWitness"] == "catalog-value"' \
              "$TMPDIR/source-lost.json" >/dev/null
            homelab-preserve --manifest "$manifest" --json verify "$TMPDIR/receipt-second.json" >/dev/null

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

            # An allowlisted scratch root cannot write inside another active State.
            mkdir -p "$TMPDIR/other-live"
            printf 'other State remains unchanged\n' > "$TMPDIR/scratch/other-live-sentinel"
            cp "$TMPDIR/scratch/other-live-sentinel" "$TMPDIR/other-live-before.txt"
            for boundary in path native; do
              if test "$boundary" = path; then
                active_path="$TMPDIR/scratch"
                active_locator="fixture/other"
              else
                active_path="$TMPDIR/other-live"
                active_locator="fixture/scratch"
              fi
              jq --arg path "$active_path" --arg locator "$active_locator" \
                '.protectedRealizations += [{stateId: "fixture/other",
                  realization: (.states[0].realization |
                    .path = $path | .locator = $locator)}]' \
                "$manifest" > "$TMPDIR/other-state.json"
              for mode in preflight execute; do
                args=()
                if test "$mode" = execute; then
                  args=(--execute --receipt "$TMPDIR/other-state-receipt.json")
                fi
                if homelab-preserve --manifest "$TMPDIR/other-state.json" --json \
                  restore fixture/state --from fixture-route --point fixture-point-1 \
                  --to scratch:other-live-restore "''${args[@]}" \
                  >"$TMPDIR/other-state-output.json" 2>"$TMPDIR/other-state-error.json"; then
                  echo "restore into another State's $boundary boundary unexpectedly accepted" >&2
                  exit 1
                fi
                jq -e '.error.code == "source-alias" and .error.stateId == "fixture/state" and
                  .error.routeId == "fixture-route"' "$TMPDIR/other-state-error.json" >/dev/null
                test ! -e "$TMPDIR/scratch/other-live-restore"
                test ! -e "$TMPDIR/other-state-receipt.json"
                cmp "$TMPDIR/scratch/other-live-sentinel" "$TMPDIR/other-live-before.txt"
                cmp "$TMPDIR/retained-before.json" "$TMPDIR/catalog/point.json"
              done
              if homelab-preserve --manifest "$TMPDIR/other-state.json" --json \
                verify "$TMPDIR/receipt-second.json" \
                >/dev/null 2>"$TMPDIR/other-state-verify-error.json"; then
                echo "verify into a plan-only source boundary unexpectedly accepted" >&2
                exit 1
              fi
              jq -e '.error.code == "source-alias"' "$TMPDIR/other-state-verify-error.json" >/dev/null
            done
            # A different Route's retained Target is fenced even when its owner is not selected.
            for boundary in path native; do
              jq --arg boundary "$boundary" --arg scratch "$TMPDIR/scratch" \
                --arg active "$TMPDIR/other-live" \
                '.states[0].routes[0].targetBoundaries.nativeNamespace = "fixture-native" |
                 .states += [.states[0] | .stateId = "fixture/other-target-state" |
                   .realization.path = $active | .realization.locator = "fixture/other-target-state" |
                   .routes[0].routeId = "other-target-route" |
                   .routes[0].obligationId = "fixture/other-target-state::other-target-route" |
                   .routes[0].target.targetId = "other-target" |
                   .routes[0].targetBoundaries = {
                     paths: (if $boundary == "path" then [$scratch] else [] end),
                     nativeLocators: (if $boundary == "native" then ["fixture/scratch"] else [] end),
                     nativeNamespace: "fixture-native"
                   }] |
                 .protectedRealizations += [.states[1] | {stateId, realization}]' \
                "$manifest" > "$TMPDIR/other-target.json"
              for mode in preflight execute; do
                args=()
                if test "$mode" = execute; then
                  args=(--execute --receipt "$TMPDIR/other-target-receipt.json")
                fi
                if homelab-preserve --manifest "$TMPDIR/other-target.json" --json \
                  restore fixture/state --from fixture-route --point fixture-point-1 \
                  --to scratch:other-target-restore "''${args[@]}" \
                  >"$TMPDIR/other-target-output.json" 2>"$TMPDIR/other-target-error.json"; then
                  echo "restore into another Target's $boundary boundary unexpectedly accepted" >&2
                  exit 1
                fi
                jq -e '.error.code == "target-alias" and .error.stateId == "fixture/state" and
                  .error.routeId == "fixture-route"' "$TMPDIR/other-target-error.json" >/dev/null
                test ! -e "$TMPDIR/scratch/other-target-restore"
                test ! -e "$TMPDIR/other-target-receipt.json"
                cmp "$TMPDIR/scratch/other-live-sentinel" "$TMPDIR/other-live-before.txt"
                cmp "$TMPDIR/retained-before.json" "$TMPDIR/catalog/point.json"
              done
            done
            jq '.states[0].routes[0].targetBoundaries.nativeNamespace = null' \
              "$TMPDIR/other-target.json" > "$TMPDIR/unclassified-native.json"
            if homelab-preserve --manifest "$TMPDIR/unclassified-native.json" --json restore fixture/state \
              --from fixture-route --point fixture-point-1 --to scratch:unclassified \
              --execute --receipt "$TMPDIR/unclassified-receipt.json" \
              >/dev/null 2>"$TMPDIR/unclassified-error.json"; then
              echo "unclassified native destination bypassed retained Target fences" >&2
              exit 1
            fi
            jq -e '.error.code == "unknown-native-namespace"' "$TMPDIR/unclassified-error.json" >/dev/null
            test ! -e "$TMPDIR/scratch/unclassified"
            test ! -e "$TMPDIR/unclassified-receipt.json"
            jq '.states[0].routes[0].targetBoundaries.nativeNamespace = "separate-native-realm"' \
              "$TMPDIR/other-target.json" > "$TMPDIR/separate-native.json"
            homelab-preserve --manifest "$TMPDIR/separate-native.json" --json restore fixture/state \
              --from fixture-route --point fixture-point-1 --to scratch:separate \
              > "$TMPDIR/separate-preflight.json"
            jq -e '.mutation == false' "$TMPDIR/separate-preflight.json" >/dev/null
            homelab-preserve --manifest "$TMPDIR/separate-native.json" --json verify "$TMPDIR/receipt-second.json" >/dev/null
            if homelab-preserve --manifest "$TMPDIR/unclassified-native.json" --json verify "$TMPDIR/receipt-second.json" \
              >/dev/null 2>"$TMPDIR/unclassified-verify-error.json"; then
              echo "verification bypassed unclassified native fences" >&2
              exit 1
            fi
            jq -e '.error.code == "unknown-native-namespace"' "$TMPDIR/unclassified-verify-error.json" >/dev/null
            jq 'del(.states[0].routes[0].targetBoundaries)' "$manifest" \
              > "$TMPDIR/missing-target-boundaries.json"
            if homelab-preserve --manifest "$TMPDIR/missing-target-boundaries.json" --json \
              restore fixture/state --from fixture-route --point fixture-point-1 \
              --to scratch:missing-fences --execute --receipt "$TMPDIR/missing-fences-receipt.json" \
              >/dev/null 2>"$TMPDIR/missing-fences-error.json"; then
              echo "restore owner lacking retained fences unexpectedly accepted" >&2
              exit 1
            fi
            jq -e '.error.code == "missing-target-boundaries"' "$TMPDIR/missing-fences-error.json" >/dev/null
            test ! -e "$TMPDIR/scratch/missing-fences"
            test ! -e "$TMPDIR/missing-fences-receipt.json"
            rm "$TMPDIR/scratch/other-live-sentinel"
            rmdir "$TMPDIR/other-live"

            printf '%s' '{"protocolVersion":1,"requestId":"describe","operation":"describe","stateId":"fixture/state","routeId":"fixture-route","targetId":"fixture-target","ownerPayload":{}}' \
              | homelab-preserve-fixture-adapter protocol > "$TMPDIR/describe.json"
            jq -e '.result.capabilities | index("run") != null and index("restore") != null and index("capture") == null and index("protect") == null and index("retry") == null' \
              "$TMPDIR/describe.json" >/dev/null


            # Fixture catalog writes must not follow a planted predictable temporary link.
            mkdir -p "$TMPDIR/fixture-safety-catalog" "$TMPDIR/fixture-safety-target" \
              "$TMPDIR/fixture-safety-receipts"
            printf 'outside fixture catalog\n' > "$TMPDIR/fixture-safety-external.txt"
            cp "$TMPDIR/fixture-safety-external.txt" "$TMPDIR/fixture-safety-expected.txt"
            printf 'native target remains unchanged\n' > "$TMPDIR/fixture-safety-target/sentinel"
            cp "$TMPDIR/fixture-safety-target/sentinel" "$TMPDIR/fixture-safety-target-before.txt"
            ln -s "$TMPDIR/fixture-safety-target" "$TMPDIR/fixture-safety-target-alias"
            jq --arg root "$TMPDIR/fixture-safety-catalog" \
              --arg target "$TMPDIR/fixture-safety-target" \
              --arg alias "$TMPDIR/fixture-safety-target-alias" \
              '.scratchDestinations.scratch.mountRoot = $target |
               .states[0].routes[0].ownerConfig.native.root = $root |
               .states[0].routes[0].ownerConfig.native.targetRoot = $alias |
               .states[0].routes[0].targetBoundaries.paths = [$root, $alias]' \
              "$manifest" > "$TMPDIR/fixture-safety.json"
            for link in symlink hardlink; do
              if test "$link" = symlink; then
                ln -s "$TMPDIR/fixture-safety-external.txt" "$TMPDIR/fixture-safety-catalog/point.json.tmp"
              else
                ln "$TMPDIR/fixture-safety-external.txt" "$TMPDIR/fixture-safety-catalog/point.json.tmp"
              fi
              homelab-preserve --manifest "$TMPDIR/fixture-safety.json" --json run fixture/state \
                --route fixture-route >/dev/null
              cmp "$TMPDIR/fixture-safety-expected.txt" "$TMPDIR/fixture-safety-external.txt"
              cmp "$TMPDIR/fixture-safety-expected.txt" "$TMPDIR/fixture-safety-catalog/point.json.tmp"
              if test "$link" = symlink; then
                test -L "$TMPDIR/fixture-safety-catalog/point.json.tmp"
              else
                test "$TMPDIR/fixture-safety-catalog/point.json.tmp" -ef "$TMPDIR/fixture-safety-external.txt"
              fi
              homelab-preserve --manifest "$TMPDIR/fixture-safety.json" --json points fixture/state \
                > "$TMPDIR/fixture-safety-points-$link.json"
              jq -e '.routes[0].status == "ok" and (.routes[0].points | length) == 1 and
                .routes[0].points[0].nativeId == "fixture-point-1"' \
                "$TMPDIR/fixture-safety-points-$link.json" >/dev/null
              rm "$TMPDIR/fixture-safety-catalog/point.json.tmp"
              test "$(ls -A "$TMPDIR/fixture-safety-catalog")" = point.json
            done

            # Canonical native target aliases must fail before destination or receipt mutation.
            cp "$TMPDIR/fixture-safety-catalog/point.json" "$TMPDIR/fixture-safety-catalog-before.json"
            if homelab-preserve --manifest "$TMPDIR/fixture-safety.json" restore fixture/state \
              --from fixture-route --point fixture-point-1 --to scratch:alias-child \
              --execute --receipt "$TMPDIR/fixture-safety-receipts/receipt.json" \
              >/dev/null 2>"$TMPDIR/fixture-safety-alias-stderr.txt"; then
              echo "symlink alias to native target root unexpectedly restored" >&2
              exit 1
            fi
            grep -q "target-alias" "$TMPDIR/fixture-safety-alias-stderr.txt"
            test ! -e "$TMPDIR/fixture-safety-target/alias-child"
            test ! -L "$TMPDIR/fixture-safety-target/alias-child"
            test ! -e "$TMPDIR/fixture-safety-receipts/receipt.json"
            test -z "$(ls -A "$TMPDIR/fixture-safety-receipts")"
            test "$(ls -A "$TMPDIR/fixture-safety-target")" = sentinel
            test -L "$TMPDIR/fixture-safety-target-alias"
            cmp "$TMPDIR/fixture-safety-target-before.txt" "$TMPDIR/fixture-safety-target/sentinel"
            cmp "$TMPDIR/fixture-safety-catalog-before.json" "$TMPDIR/fixture-safety-catalog/point.json"

            # The adapter independently repeats the canonical native check before mutation.
            jq -n --slurpfile point "$TMPDIR/fixture-safety-catalog/point.json" \
              --arg root "$TMPDIR/fixture-safety-catalog" \
              --arg target "$TMPDIR/fixture-safety-target-alias" \
              --arg path "$TMPDIR/fixture-safety-target/native-alias-child" \
              '{protocolVersion:1, requestId:"native-alias", operation:"restore",
                stateId:"fixture/state", routeId:"fixture-route", targetId:"fixture-target",
                point:$point[0], destination:{path:$path},
                ownerPayload:{native:{root:$root, targetRoot:$target}}}' \
              > "$TMPDIR/fixture-native-alias-request.json"
            jq -e '.point.nativeId == "fixture-point-1" and .operation == "restore"' \
              "$TMPDIR/fixture-native-alias-request.json" >/dev/null
            homelab-preserve-fixture-adapter protocol < "$TMPDIR/fixture-native-alias-request.json" \
              > "$TMPDIR/fixture-native-alias-response.json" 2>"$TMPDIR/fixture-native-alias-stderr.txt"
            jq -e '.error.code == "fixture-error"' "$TMPDIR/fixture-native-alias-response.json" >/dev/null
            grep -q "restore destination aliases the native target root" "$TMPDIR/fixture-native-alias-stderr.txt"
            test ! -e "$TMPDIR/fixture-safety-target/native-alias-child"
            cmp "$TMPDIR/fixture-safety-target-before.txt" "$TMPDIR/fixture-safety-target/sentinel"
            cmp "$TMPDIR/fixture-safety-catalog-before.json" "$TMPDIR/fixture-safety-catalog/point.json"

            # A failed atomic catalog replacement must remove its newly allocated temporary file.
            mkdir -p "$TMPDIR/fixture-safety-blocked-catalog/point.json"
            jq --arg root "$TMPDIR/fixture-safety-blocked-catalog" \
              '.states[0].routes[0].ownerConfig.native.root = $root' \
              "$manifest" > "$TMPDIR/fixture-safety-blocked.json"
            if homelab-preserve --manifest "$TMPDIR/fixture-safety-blocked.json" run fixture/state \
              --route fixture-route >/dev/null 2>"$TMPDIR/fixture-safety-blocked-stderr.txt"; then
              echo "catalog replacement over a directory unexpectedly succeeded" >&2
              exit 1
            fi
            grep -q "fixture-error" "$TMPDIR/fixture-safety-blocked-stderr.txt"
            test "$(ls -A "$TMPDIR/fixture-safety-blocked-catalog")" = point.json
            test -d "$TMPDIR/fixture-safety-blocked-catalog/point.json"
            test -z "$(ls -A "$TMPDIR/fixture-safety-blocked-catalog/point.json")"
            cmp "$TMPDIR/fixture-safety-expected.txt" "$TMPDIR/fixture-safety-external.txt"

            rm -r "$TMPDIR/scratch/rehearsal" "$TMPDIR/scratch/second"
            test -z "$(ls -A "$TMPDIR/scratch")"
            cmp "$TMPDIR/retained-before.json" "$TMPDIR/catalog/point.json"
            touch "$out"
          '';
    };
}
