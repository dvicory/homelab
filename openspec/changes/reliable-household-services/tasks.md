## 1. Shared delivery and ownership

- [x] 1.1 Record the delegated architecture decisions and their relationship to current contracts. Verify the proposal/spec/design/task artifacts with OpenSpec; do not promote active changes to current authority.
- [x] 1.2 Integrate Sini-style Den cluster composition, Nixidy and pinned upstream charts. Build the environment/bootstrap outputs and prove cluster settings reach the selected manifests without duplicating host metadata.
- [ ] 1.3 Provide Argo application reconciliation, protected retained resources and static bootstrap/recovery artifacts. Exercise delivery and resource retirement against a disposable Git source; demonstrate a single owner and no-live-Git bootstrap. Migrate the existing Jellyfin AddOn callers without overlapping ownership.

## 2. Retained state and runtime credentials

- [x] 2.1 Replace application-specific compute state plumbing with declared retained-path mappings while preserving non-root ID translation, encryption/persistence, read-only legacy media and independent management. Evaluate exact boundaries and exercise missing-path refusal plus writer/reader permissions in disposable storage.
- [ ] 2.2 Deliver named Kubernetes Secrets from host-staged runtime files using the existing agenix flow. Prove missing files fail closed, values stay out of rendered artifacts, and replacement consumers receive the declared secrets without regenerating identities.
- [ ] 2.3 Implement quiesced, application-consistent export/restore using standard native/database tools and explicit retained inputs. Demonstrate completion/failure reporting, input validation and preservation of displaced state with a representative disposable recovery set; distinguish same-host recovery points from independent backups.

## 3. Thin workload integrations

- [ ] 3.1 Move Jellyfin onto the shared rendering/delivery path while preserving its retained configuration, pinned image, native-client access and read-only media. Run a representative authenticated service smoke check after delivery/replacement; leave physical GPU validation gated.
- [ ] 3.2 Add the official Immich chart with compatible server/CPU-ML/database/cache releases and declared asset/database storage. Render and start the real services; use one disposable upload/recovery smoke to establish that our mounts and recovery set are complete, not an upstream feature suite.
- [ ] 3.3 Add Radarr, Sonarr, SABnzbd and Seerr through thin upstream-chart aspects with retained local state, consistent fresh library/download paths and required internal service connections. Exercise probes/API access and shared-path ownership with disposable content; do not connect production providers or migrate existing libraries.

## 4. Access and visibility

- [ ] 4.1 Declare one route inventory and Gateway API integration compatible with the existing CNI. Build/render domain and supported-prefix variants; reject unsupported prefixes and observe routing to real local services.
- [ ] 4.2 Add independently deployable NixOS remote/home proxy roles with verified private-origin transport, trusted forwarding boundaries, valid primary/backup TLS and explicit manual failover. Exercise both local entrances, unknown-route denial and backend bypass refusal; no public DNS changes.
- [ ] 4.3 Integrate Kanidm and supported native OIDC plus administrator-only browser access without breaking native media authentication or independent management. Verify the owned identity/authorization boundary with disposable credentials, including non-admin denial; document client-dependent flows not exercised.
- [ ] 4.4 Add bounded Prometheus/Alertmanager/Grafana/Loki/Alloy integration using upstream charts and existing discovery patterns. Observe collected metrics/logs and one actionable failure firing/resolving through a disposable receiver; keep external email/Telegram delivery gated on real credentials.

## 5. Verification and handoff

- [ ] 5.1 Run focused Nix/Den boundary checks and the relevant disposable runtime smoke scenarios. Keep permanent tests limited to Homelab-owned behavior; report native Darwin and Linux evidence separately and do not confuse local proof with production acceptance.
- [ ] 5.2 Update operating guidance with exact rendered outputs, delivery/restore procedures, delegated decisions and remaining production/provider/hardware prerequisites. Remove spent diagnostic scripts after preserving useful evidence in local continuity notes.
