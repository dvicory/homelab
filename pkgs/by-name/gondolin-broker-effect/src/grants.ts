import { createHash, randomUUID } from "node:crypto";
import { Context, Effect, Layer, Schema } from "effect";
import {
  type DecideAccessRequest,
  type GrantScope,
  PreparedNetworkOriginCapability,
  type PreparedNetworkOriginCapability as PreparedNetworkOrigin,
  type PrepareAccessRequest,
} from "./domain.js";
import { Authorization } from "./auth.js";
import {
  requireAuthorityBinding,
  resolveAuthorityPolicy,
} from "./authority.js";
import { BrokerConfig } from "./config.js";
import { BrokerDatabase } from "./database.js";
import {
  canonicalCapabilityKey,
  prepareCapabilityBatch,
  type AddressResolver,
} from "./capabilities.js";
import { BrokerError, brokerError } from "./errors.js";
import { isCapabilityCoveredByStaticPolicy } from "./network.js";
import { Registry, type AuthorityBindingRecord } from "./registry.js";
import { Workspaces } from "./workspaces.js";

export type AccessRequestState = "pending" | "approved" | "denied";
export type RuntimeGrantState = "active" | "revoked" | "consumed" | "expired";

export interface PreparedAccess {
  readonly state: "pending" | "existing-pending" | "active";
  readonly requestId: string | null;
  readonly fingerprint: string;
  readonly environmentKey: string;
  readonly requestedScope: GrantScope;
  readonly durationSeconds: number | null;
  readonly capabilities: ReadonlyArray<PreparedNetworkOrigin>;
  readonly grantIds: ReadonlyArray<string>;
}

export interface AccessDecision {
  readonly requestId: string;
  readonly state: "approved" | "denied";
  readonly grantIds: ReadonlyArray<string>;
}

export interface RuntimeGrant {
  readonly grantId: string;
  readonly requestId: string;
  readonly bindingId: string;
  readonly environmentKey: string;
  readonly profile: string;
  readonly executor: string;
  readonly authorityClass: string;
  readonly policyDigest: string;
  readonly capabilities: ReadonlyArray<PreparedNetworkOrigin>;
  readonly scope: GrantScope;
  readonly state: RuntimeGrantState;
  readonly usesRemaining: number | null;
  readonly expiresAt: number | null;
  readonly approvedBy: string;
  readonly createdAt: number;
  readonly lastUsedAt: number | null;
  readonly revokedAt: number | null;
  readonly revokedBy: string | null;
}

export interface GrantSnapshot {
  readonly revision: number;
  readonly grants: ReadonlyArray<RuntimeGrant>;
}

export interface AccessGrantService {
  readonly prepare: (request: PrepareAccessRequest) => Effect.Effect<PreparedAccess, BrokerError>;
  readonly decide: (request: DecideAccessRequest) => Effect.Effect<AccessDecision, BrokerError>;
  readonly list: (environmentKey?: string) => Effect.Effect<ReadonlyArray<RuntimeGrant>, BrokerError>;
  readonly revoke: (grantId: string, principal: string) => Effect.Effect<RuntimeGrant, BrokerError>;
  readonly revokeEnvironment: (
    environmentKey: string,
    scopes: ReadonlyArray<GrantScope>,
    principal: string,
  ) => Effect.Effect<number, BrokerError>;
  readonly snapshot: () => GrantSnapshot;
  readonly matching: (
    binding: AuthorityBindingRecord,
    environmentKey: string,
    now?: number,
  ) => ReadonlyArray<RuntimeGrant>;
  readonly consumeOnce: (grantId: string) => Effect.Effect<boolean, BrokerError>;
}

export class AccessGrants extends Context.Tag("@agent-x/gondolin-broker-effect/AccessGrants")<
  AccessGrants,
  AccessGrantService
>() {}

type AccessRequestRow = {
  request_id: string;
  fingerprint: string;
  binding_id: string;
  environment_key: string;
  profile: string;
  executor: string;
  authority_class: string;
  policy_digest: string;
  capabilities_json: string;
  requested_scope: GrantScope;
  requested_duration_seconds: number | null;
  state: AccessRequestState;
  created_at: number;
  decided_at: number | null;
  decision_principal: string | null;
};

type RuntimeGrantRow = {
  grant_id: string;
  request_id: string;
  binding_id: string;
  environment_key: string;
  profile: string;
  executor: string;
  authority_class: string;
  policy_digest: string;
  capabilities_json: string;
  scope: GrantScope;
  state: RuntimeGrantState;
  uses_remaining: number | null;
  expires_at: number | null;
  approved_by: string;
  created_at: number;
  last_used_at: number | null;
  revoked_at: number | null;
  revoked_by: string | null;
};

const PreparedBatch = Schema.Array(PreparedNetworkOriginCapability).pipe(Schema.minItems(1), Schema.maxItems(32));

const parsePrepared = (text: string): ReadonlyArray<PreparedNetworkOrigin> =>
  Schema.decodeUnknownSync(PreparedBatch)(JSON.parse(text) as unknown, { onExcessProperty: "error" });

const freezeCapability = (capability: PreparedNetworkOrigin): PreparedNetworkOrigin => Object.freeze({
  ...capability,
  ports: Object.freeze([...capability.ports]),
  pinnedAddresses: Object.freeze([...capability.pinnedAddresses]),
});

const grantFromRow = (row: RuntimeGrantRow): RuntimeGrant => Object.freeze({
  grantId: row.grant_id,
  requestId: row.request_id,
  bindingId: row.binding_id,
  environmentKey: row.environment_key,
  profile: row.profile,
  executor: row.executor,
  authorityClass: row.authority_class,
  policyDigest: row.policy_digest,
  capabilities: Object.freeze(parsePrepared(row.capabilities_json).map(freezeCapability)),
  scope: row.scope,
  state: row.state,
  usesRemaining: row.uses_remaining,
  expiresAt: row.expires_at,
  approvedBy: row.approved_by,
  createdAt: row.created_at,
  lastUsedAt: row.last_used_at,
  revokedAt: row.revoked_at,
  revokedBy: row.revoked_by,
});

const bindingIdFor = (binding: AuthorityBindingRecord): string => createHash("sha256")
  .update(JSON.stringify({
    environmentKey: binding.environmentKey,
    profile: binding.profile,
    executor: binding.executor,
    authorityClass: binding.authorityClass,
    policyDigest: binding.policyDigest,
  }))
  .digest("hex");

const fingerprintFor = (
  binding: AuthorityBindingRecord,
  capabilities: ReadonlyArray<PreparedNetworkOrigin>,
  scope: GrantScope,
  durationSeconds: number | undefined,
): string => createHash("sha256")
  .update(JSON.stringify({
    bindingId: bindingIdFor(binding),
    capabilities,
    scope,
    durationSeconds: durationSeconds ?? null,
  }))
  .digest("hex");

const grantFailure = (operation: string, error: unknown): BrokerError =>
  error instanceof BrokerError
    ? error
    : brokerError("registry.failed", `grant registry ${operation} failed`, {
        cause: error instanceof Error ? error.message : String(error),
      });

const isRememberedFor = (grant: RuntimeGrant, binding: AuthorityBindingRecord): boolean =>
  (grant.scope === "profile" && grant.profile === binding.profile) ||
  (grant.scope === "executor" && grant.executor === binding.executor);

const containsCapabilities = (
  grants: ReadonlyArray<RuntimeGrant>,
  capabilities: ReadonlyArray<PreparedNetworkOrigin>,
): boolean => {
  const installed = new Set(grants.flatMap((grant) => grant.capabilities.map(canonicalCapabilityKey)));
  return capabilities.every((capability) => installed.has(canonicalCapabilityKey(capability)));
};

interface AccessGrantOptions {
  readonly now?: () => number;
  readonly resolver?: AddressResolver;
}

const make = (options: AccessGrantOptions) => Effect.gen(function* () {
  const config = yield* BrokerConfig;
  const authorization = yield* Authorization;
  const registry = yield* Registry;
  const workspaces = yield* Workspaces;
  const database = yield* BrokerDatabase;
  const db = database.connection;
  const now = options.now ?? Date.now;
  yield* Effect.try({
    try: () => database.transaction(() => {
      const legacyRequestSchema = db.prepare(
        "SELECT 1 FROM pragma_table_info('access_requests') WHERE name='policy_generation'",
      ).get();
      const legacyGrantSchema = db.prepare(
        "SELECT 1 FROM pragma_table_info('runtime_grants') WHERE name='policy_generation'",
      ).get();
      if (legacyRequestSchema !== undefined || legacyGrantSchema !== undefined) {
        // The prior integer cannot identify the immutable policy content.
        // Fail closed by discarding only broker authorization overlays.
        db.exec("DROP TABLE IF EXISTS runtime_grants; DROP TABLE IF EXISTS access_requests;");
      }
      db.exec(`
        CREATE TABLE IF NOT EXISTS access_requests (
          request_id TEXT PRIMARY KEY,
          fingerprint TEXT NOT NULL,
          binding_id TEXT NOT NULL,
          environment_key TEXT NOT NULL,
          profile TEXT NOT NULL,
          executor TEXT NOT NULL,
          authority_class TEXT NOT NULL,
          policy_digest TEXT NOT NULL CHECK (length(policy_digest) = 64),
          capabilities_json TEXT NOT NULL,
          requested_scope TEXT NOT NULL CHECK (requested_scope IN ('once','task','conversation','timed','profile','executor')),
          requested_duration_seconds INTEGER CHECK (requested_duration_seconds IS NULL OR requested_duration_seconds > 0),
          state TEXT NOT NULL CHECK (state IN ('pending','approved','denied')),
          created_at INTEGER NOT NULL,
          decided_at INTEGER,
          decision_principal TEXT
        ) STRICT;
        CREATE UNIQUE INDEX IF NOT EXISTS access_requests_one_pending_environment
          ON access_requests(environment_key) WHERE state = 'pending';
        CREATE INDEX IF NOT EXISTS access_requests_fingerprint_state
          ON access_requests(fingerprint, state, decided_at);

        CREATE TABLE IF NOT EXISTS runtime_grants (
          grant_id TEXT PRIMARY KEY,
          request_id TEXT NOT NULL REFERENCES access_requests(request_id),
          binding_id TEXT NOT NULL,
          environment_key TEXT NOT NULL,
          profile TEXT NOT NULL,
          executor TEXT NOT NULL,
          authority_class TEXT NOT NULL,
          policy_digest TEXT NOT NULL CHECK (length(policy_digest) = 64),
          capabilities_json TEXT NOT NULL,
          scope TEXT NOT NULL CHECK (scope IN ('once','task','conversation','timed','profile','executor')),
          state TEXT NOT NULL CHECK (state IN ('active','revoked','consumed','expired')),
          uses_remaining INTEGER CHECK (uses_remaining IS NULL OR uses_remaining >= 0),
          expires_at INTEGER,
          approved_by TEXT NOT NULL,
          created_at INTEGER NOT NULL,
          last_used_at INTEGER,
          revoked_at INTEGER,
          revoked_by TEXT
        ) STRICT;
        CREATE INDEX IF NOT EXISTS runtime_grants_active_environment
          ON runtime_grants(environment_key, state, policy_digest);
        CREATE INDEX IF NOT EXISTS runtime_grants_remembered_profile
          ON runtime_grants(profile, executor, scope, state, policy_digest);
      `);
      const timestamp = now();
      db.prepare(`
        UPDATE runtime_grants
        SET state='expired'
        WHERE state='active' AND expires_at IS NOT NULL AND expires_at <= ?
      `).run(timestamp);
      db.prepare(`
        UPDATE runtime_grants
        SET state='revoked', revoked_at=?, revoked_by='policy-digest'
        WHERE state='active' AND policy_digest <> ?
      `).run(timestamp, config.policyFile.policyDigest);
    }),
    catch: (error) => grantFailure("open", error),
  });

  let revision = 0;
  let currentSnapshot: GrantSnapshot = Object.freeze({ revision, grants: Object.freeze([]) });

  const buildSnapshot = (nextRevision: number): GrantSnapshot => {
    const rows = db.prepare(`
      SELECT * FROM runtime_grants
      WHERE state='active' AND policy_digest=?
      ORDER BY created_at, grant_id
    `).all(config.policyFile.policyDigest) as unknown as RuntimeGrantRow[];
    return Object.freeze({
      revision: nextRevision,
      grants: Object.freeze(rows.map(grantFromRow)),
    });
  };
  const installSnapshot = (next: GrantSnapshot): void => {
    revision = next.revision;
    currentSnapshot = next;
  };
  const publishSnapshot = (): void => installSnapshot(buildSnapshot(revision + 1));
  const mutateWithSnapshot = <A>(mutation: () => A): A => {
    const committed = database.transaction(() => {
      const result = mutation();
      return { result, snapshot: buildSnapshot(revision + 1) };
    });
    installSnapshot(committed.snapshot);
    return committed.result;
  };
  yield* Effect.try({
    try: publishSnapshot,
    catch: (error) => grantFailure("restore snapshot", error),
  });

  const validateScope = (
    scope: GrantScope,
    durationSeconds: number | undefined,
  ): Effect.Effect<number | null, BrokerError> => {
    if (!config.policyFile.grantPolicy.allowedScopes.includes(scope)) {
      return Effect.fail(brokerError("policy.denied", "requested grant scope is not enabled", { scope }));
    }
    if (scope === "timed") {
      if (durationSeconds === undefined) {
        return Effect.fail(brokerError("capability.invalid", "timed grant scope requires a duration"));
      }
      if (durationSeconds > config.policyFile.grantPolicy.maxDurationSeconds) {
        return Effect.fail(brokerError("policy.denied", "requested grant duration exceeds the configured ceiling", {
          requestedSeconds: durationSeconds,
          maximumSeconds: config.policyFile.grantPolicy.maxDurationSeconds,
        }));
      }
      return Effect.succeed(durationSeconds);
    }
    if (durationSeconds !== undefined) {
      return Effect.fail(brokerError("capability.invalid", "duration is valid only for timed grant scope"));
    }
    return Effect.succeed(null);
  };

  const requireBinding = (environmentKey: string): Effect.Effect<AuthorityBindingRecord, BrokerError> =>
    requireAuthorityBinding(registry, config, environmentKey);

  const matching = (
    binding: AuthorityBindingRecord,
    environmentKey: string,
    timestamp = now(),
  ): ReadonlyArray<RuntimeGrant> => currentSnapshot.grants.filter((grant) =>
    grant.state === "active" &&
    grant.policyDigest === binding.policyDigest &&
    (grant.expiresAt === null || grant.expiresAt > timestamp) &&
    (grant.usesRemaining === null || grant.usesRemaining > 0) &&
    (grant.environmentKey === environmentKey || isRememberedFor(grant, binding))
  );

  const prepare = (request: PrepareAccessRequest): Effect.Effect<PreparedAccess, BrokerError> =>
    Effect.gen(function* () {
      const duration = yield* validateScope(request.requestedScope, request.durationSeconds);
      const binding = yield* requireBinding(request.environmentKey);
      const capabilities = yield* prepareCapabilityBatch(request.capabilities, options.resolver);
      const fingerprint = fingerprintFor(binding, capabilities, request.requestedScope, request.durationSeconds);
      const { network } = yield* resolveAuthorityPolicy(config, authorization, binding);
      if (capabilities.every((capability) =>
        isCapabilityCoveredByStaticPolicy(network, capability)
      )) {
        return {
          state: "active",
          requestId: null,
          fingerprint,
          environmentKey: request.environmentKey,
          requestedScope: request.requestedScope,
          durationSeconds: duration,
          capabilities,
          grantIds: [],
        };
      }
      const remembered = matching(binding, request.environmentKey).filter((grant) => isRememberedFor(grant, binding));
      if (containsCapabilities(remembered, capabilities)) {
        return {
          state: "active",
          requestId: null,
          fingerprint,
          environmentKey: request.environmentKey,
          requestedScope: request.requestedScope,
          durationSeconds: duration,
          capabilities,
          grantIds: remembered.map((grant) => grant.grantId),
        };
      }

      return yield* Effect.try({
        try: () => mutateWithSnapshot(() => {
          const timestamp = now();
          db.prepare(`UPDATE runtime_grants SET state='expired' WHERE state='active' AND expires_at IS NOT NULL AND expires_at <= ?`)
            .run(timestamp);
          const pending = db.prepare(`SELECT * FROM access_requests WHERE environment_key=? AND state='pending'`)
            .get(request.environmentKey) as AccessRequestRow | undefined;
          if (pending !== undefined) {
            if (pending.fingerprint === fingerprint) {
              return {
                state: "existing-pending",
                requestId: pending.request_id,
                fingerprint,
                environmentKey: request.environmentKey,
                requestedScope: request.requestedScope,
                durationSeconds: duration,
                capabilities,
                grantIds: [],
              } satisfies PreparedAccess;
            }
            throw brokerError("approval.request_suppressed", "environment already has a pending access request", {
              pendingRequestId: pending.request_id,
            });
          }
          const cooldownFloor = timestamp - config.policyFile.grantPolicy.denialCooldownSeconds * 1000;
          const denied = db.prepare(`
            SELECT decided_at FROM access_requests
            WHERE fingerprint=? AND state='denied' AND decided_at >= ?
            ORDER BY decided_at DESC LIMIT 1
          `).get(fingerprint, cooldownFloor) as { decided_at: number } | undefined;
          if (denied !== undefined) {
            throw brokerError("approval.request_suppressed", "equivalent access request is in denial cooldown", {
              cooldownUntil: denied.decided_at + config.policyFile.grantPolicy.denialCooldownSeconds * 1000,
            });
          }
          const windowFloor = timestamp - config.policyFile.grantPolicy.promptBudget.windowSeconds * 1000;
          const count = db.prepare(`
            SELECT COUNT(*) AS count FROM access_requests
            WHERE environment_key=? AND created_at >= ?
          `).get(request.environmentKey, windowFloor) as { count: number };
          if (count.count >= config.policyFile.grantPolicy.promptBudget.maxNewRequests) {
            throw brokerError("approval.request_suppressed", "access request prompt budget is exhausted", {
              maximum: config.policyFile.grantPolicy.promptBudget.maxNewRequests,
              windowSeconds: config.policyFile.grantPolicy.promptBudget.windowSeconds,
            });
          }
          const requestId = randomUUID();
          db.prepare(`
            INSERT INTO access_requests (
              request_id, fingerprint, binding_id, environment_key, profile, executor,
              authority_class, policy_digest, capabilities_json, requested_scope,
              requested_duration_seconds, state, created_at, decided_at, decision_principal
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'pending', ?, NULL, NULL)
          `).run(
            requestId,
            fingerprint,
            bindingIdFor(binding),
            request.environmentKey,
            binding.profile,
            binding.executor,
            binding.authorityClass,
            binding.policyDigest,
            JSON.stringify(capabilities),
            request.requestedScope,
            duration,
            timestamp,
          );
          return {
            state: "pending",
            requestId,
            fingerprint,
            environmentKey: request.environmentKey,
            requestedScope: request.requestedScope,
            durationSeconds: duration,
            capabilities,
            grantIds: [],
          } satisfies PreparedAccess;
        }),
        catch: (error) => grantFailure("prepare access request", error),
      });
    });

  const decide = (request: DecideAccessRequest): Effect.Effect<AccessDecision, BrokerError> =>
    Effect.gen(function* () {
      const row = yield* Effect.try({
        try: () => db.prepare("SELECT * FROM access_requests WHERE request_id=?").get(request.requestId) as AccessRequestRow | undefined,
        catch: (error) => grantFailure("read access request", error),
      });
      if (row === undefined) {
        return yield* brokerError("approval.request_not_found", "access request does not exist", { requestId: request.requestId });
      }
      if (row.state !== "pending") {
        return yield* brokerError("approval.invalid_state", "access request is no longer pending", {
          requestId: request.requestId,
          state: row.state,
        });
      }
      if (row.policy_digest !== config.policyFile.policyDigest) {
        return yield* brokerError("policy.indeterminate", "access request uses an inactive policy digest", {
          requestId: request.requestId,
        });
      }
      if (request.decision === "deny") {
        if (request.scope !== undefined || request.durationSeconds !== undefined) {
          return yield* brokerError("capability.invalid", "denial cannot carry grant scope or duration");
        }
        return yield* Effect.try({
          try: () => {
            const timestamp = now();
            const result = db.prepare(`
              UPDATE access_requests
              SET state='denied', decided_at=?, decision_principal=?
              WHERE request_id=? AND state='pending'
            `).run(timestamp, request.principal, request.requestId);
            if (result.changes !== 1) throw brokerError("approval.invalid_state", "access request changed concurrently");
            return { requestId: request.requestId, state: "denied", grantIds: [] } as const;
          },
          catch: (error) => grantFailure("deny access request", error),
        });
      }

      const scope = request.scope ?? row.requested_scope;
      const duration = yield* validateScope(scope, request.durationSeconds ?? row.requested_duration_seconds ?? undefined);
      const grantId = randomUUID();
      yield* Effect.try({
        try: () => mutateWithSnapshot(() => {
          const timestamp = now();
          const latest = db.prepare("SELECT state FROM access_requests WHERE request_id=?").get(request.requestId) as { state: AccessRequestState };
          if (latest.state !== "pending") throw brokerError("approval.invalid_state", "access request changed concurrently");
          db.prepare(`
            INSERT INTO runtime_grants (
              grant_id, request_id, binding_id, environment_key, profile, executor,
              authority_class, policy_digest, capabilities_json, scope, state,
              uses_remaining, expires_at, approved_by, created_at, last_used_at,
              revoked_at, revoked_by
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'active', ?, ?, ?, ?, NULL, NULL, NULL)
          `).run(
            grantId,
            row.request_id,
            row.binding_id,
            row.environment_key,
            row.profile,
            row.executor,
            row.authority_class,
            row.policy_digest,
            row.capabilities_json,
            scope,
            scope === "once" ? 1 : null,
            scope === "timed" ? timestamp + (duration ?? 0) * 1000 : null,
            request.principal,
            timestamp,
          );
          db.prepare(`
            UPDATE access_requests
            SET state='approved', decided_at=?, decision_principal=?
            WHERE request_id=? AND state='pending'
          `).run(timestamp, request.principal, request.requestId);
        }),
        catch: (error) => grantFailure("approve access request", error),
      });
      return { requestId: request.requestId, state: "approved", grantIds: [grantId] };
    });

  const expire = (): void => {
    const expired = db.prepare(`
      SELECT COUNT(*) AS count FROM runtime_grants
      WHERE state='active' AND expires_at IS NOT NULL AND expires_at <= ?
    `).get(now()) as { count: number };
    if (expired.count === 0) return;
    mutateWithSnapshot(() => {
      db.prepare(`
        UPDATE runtime_grants SET state='expired'
        WHERE state='active' AND expires_at IS NOT NULL AND expires_at <= ?
      `).run(now());
    });
  };

  const list = (environmentKey?: string): Effect.Effect<ReadonlyArray<RuntimeGrant>, BrokerError> =>
    Effect.try({
      try: () => {
        expire();
        const rows = (environmentKey === undefined
          ? db.prepare("SELECT * FROM runtime_grants ORDER BY created_at, grant_id").all()
          : db.prepare("SELECT * FROM runtime_grants WHERE environment_key=? ORDER BY created_at, grant_id").all(environmentKey)
        ) as unknown as RuntimeGrantRow[];
        return rows.map(grantFromRow);
      },
      catch: (error) => grantFailure("list grants", error),
    });

  const revoke = (grantId: string, principal: string): Effect.Effect<RuntimeGrant, BrokerError> =>
    Effect.try({
      try: () => mutateWithSnapshot(() => {
        const timestamp = now();
        const result = db.prepare(`
          UPDATE runtime_grants
          SET state='revoked', revoked_at=?, revoked_by=?
          WHERE grant_id=? AND state='active'
        `).run(timestamp, principal, grantId);
        if (result.changes !== 1) {
          throw brokerError("grant.not_found", "active runtime grant does not exist", { grantId });
        }
        const row = db.prepare("SELECT * FROM runtime_grants WHERE grant_id=?").get(grantId) as RuntimeGrantRow;
        return grantFromRow(row);
      }),
      catch: (error) => grantFailure("revoke grant", error),
    });

  const revokeEnvironment = (
    environmentKey: string,
    scopes: ReadonlyArray<GrantScope>,
    principal: string,
  ): Effect.Effect<number, BrokerError> => Effect.try({
    try: () => {
      if (scopes.length === 0) return 0;
      const placeholders = scopes.map(() => "?").join(",");
      return mutateWithSnapshot(() => {
        const result = db.prepare(`
          UPDATE runtime_grants
          SET state='revoked', revoked_at=?, revoked_by=?
          WHERE environment_key=? AND state='active' AND scope IN (${placeholders})
        `).run(now(), principal, environmentKey, ...scopes);
        return Number(result.changes);
      });
    },
    catch: (error) => grantFailure("revoke environment grants", error),
  });

  const consumeOnce = (grantId: string): Effect.Effect<boolean, BrokerError> =>
    Effect.try({
      try: () => mutateWithSnapshot(() => {
        const timestamp = now();
        const result = db.prepare(`
          UPDATE runtime_grants
          SET uses_remaining=0, state='consumed', last_used_at=?
          WHERE grant_id=? AND state='active' AND uses_remaining=1
            AND (expires_at IS NULL OR expires_at > ?)
        `).run(timestamp, grantId, timestamp);
        return result.changes === 1;
      }),
      catch: (error) => grantFailure("consume once grant", error),
    });

  return {
    prepare,
    decide,
    list,
    revoke,
    revokeEnvironment,
    snapshot: () => currentSnapshot,
    matching,
    consumeOnce,
  } satisfies AccessGrantService;
});

export const makeAccessGrantsLayer = (options: AccessGrantOptions = {}) =>
  Layer.scoped(AccessGrants, make(options));

export const AccessGrantsLive = makeAccessGrantsLayer();
