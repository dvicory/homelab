## Why

The media-acquisition services need a reproducible, independently reconciled deployment whose cross-application configuration is usable on a fresh cluster without silently changing existing user content. The platform and Jellyfin foundations are owned by earlier changes; this change defines only the media family's responsibilities and their acceptance evidence.

## What Changes

- Deliver Radarr, Sonarr, Prowlarr, SABnzbd and Seerr with retained private state and declared shared media access. Keep separate Radarr/Sonarr instances independently configurable and explicitly select the instances used by Seerr.
- Pin Configarr and selected TRaSH policy inputs locally for offline reconstruction. Configarr owns declared Arr root records, semantic profiles and scored formats, download clients and managed Prowlarr registrations. Removing an undeclared Arr root record SHALL NOT delete files; unrelated accounts, media and UI-owned Prowlarr applications survive.
- Initialize Seerr privately with the Jellyfin-owned credential and existing libraries. Publish its household-facing native-auth route only after its owner and library integration are verified; use a stable operator-owned Seerr API key for later reconciliation. Keep Arr, Prowlarr and SAB browser administration behind administrator access.
- Order workload Applications, Jellyfin integration and immediate media PostSync Jobs. Run Configarr and Seerr repairs on staggered, unsuspended six-hour schedules without overlapping runs. Require pinned-application evidence for initial setup, idempotence, malformed-input and API-write failures, credential rotation, data preservation and no search/upgrade actions before claiming completion.
- State the actual write boundary: shared media GID 505 grants coarse filesystem write capability; declarative root/category ownership and explicit sharing prevent logical conflicts, not cross-application filesystem writes.

## Capabilities

### New Capabilities

- `household-services`: Independent media-family delivery, retained state, scoped configuration authority and cross-application integration.

### Modified Capabilities

None. Existing platform, storage, secret-management and access contracts remain authoritative.

## Impact

The change affects media-family Den aspects, selected policy assets, configuration reconcilers and focused evaluation/runtime evidence. PR22 owns compute, retained-storage infrastructure, charts and secret transport; PR23 owns edge/identity infrastructure; PR24 owns Jellyfin startup, configuration and recovery. This change consumes those interfaces without transferring their ownership.

Production provider/indexer credentials, live provider connectivity, production deployment and a production 4K instance remain operator gates. Immich, monitoring and general backup capture/restore are not part of this delta.
