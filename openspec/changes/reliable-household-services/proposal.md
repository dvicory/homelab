## Why

The media-acquisition services need a reproducible, independently reconciled deployment whose cross-application configuration is usable on a fresh cluster without silently changing existing user content. The platform and Jellyfin foundations are owned by earlier changes; this change defines only the media family's responsibilities and their acceptance evidence.

## What Changes

- Deliver Radarr, Sonarr, Prowlarr, SABnzbd and Seerr with retained private state and declared shared media access. Keep separate Radarr/Sonarr instances independently configurable and explicitly select the instances used by Seerr.
- Pin Configarr and selected TRaSH policy inputs so configuration can be reconstructed offline. Reconcile only declared roots, profiles, download clients and service connections while preserving undeclared application records and UI-owned state.
- Expose Seerr for household use through its native Jellyfin/local authentication; keep Arr, Prowlarr and SAB browser administration behind administrator access. Consume the Jellyfin readiness, library and integration-credential contracts owned by the Jellyfin configuration path rather than creating another owner account or library configurator.
- Establish startup ordering between workload Applications, Jellyfin integration readiness and media configuration, with supported-API readiness checks and repeatable re-sync. Require real pinned-application API evidence of first setup, idempotence and unmanaged-record preservation before claiming completion.
- State the actual write boundary: shared media GID 505 grants coarse filesystem write capability; declarative root/category ownership and explicit sharing prevent logical conflicts, not cross-application filesystem writes.

## Capabilities

### New Capabilities

- `household-services`: Independent media-family delivery, retained state, scoped configuration authority and cross-application integration.

### Modified Capabilities

None. Existing platform, storage, secret-management and access contracts remain authoritative.

## Impact

The change affects media-family Den aspects, selected policy assets, configuration reconcilers and focused evaluation/runtime evidence. PR22 owns compute, retained-storage infrastructure, charts and secret transport; PR23 owns edge/identity infrastructure; PR24 owns Jellyfin startup, configuration and recovery. This change consumes those interfaces without transferring their ownership.

Production provider/indexer credentials, live provider connectivity, production deployment and a production 4K instance remain operator gates. Immich, monitoring and general backup capture/restore are not part of this delta.
