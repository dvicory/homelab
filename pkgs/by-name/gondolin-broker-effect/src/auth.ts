import type { Obligation } from "@agent-x/policy-kernel";
import { Context, Effect } from "effect";
import type { BrokerError } from "./errors.js";

export const BrokerActions = [
  "environment.ensure",
  "environment.status",
  "environment.close",
  "exec.foreground",
  "fs.stat",
  "fs.list",
  "fs.read",
  "fs.write",
  "fs.mkdir",
  "fs.remove",
] as const;

export type BrokerAction = (typeof BrokerActions)[number];

export interface AuthorizationRequest {
  readonly action: BrokerAction;
  readonly resource: string;
  readonly requestedLimits?: Readonly<Record<string, number>>;
}

export interface AuthorizationResult {
  readonly decisionDigest: string;
  readonly policyGeneration: number;
  readonly limits: Readonly<Record<string, number>>;
  readonly obligations: ReadonlyArray<Obligation>;
}

export interface AuthorizationService {
  readonly authorize: (request: AuthorizationRequest) => Effect.Effect<AuthorizationResult, BrokerError>;
}

export class Authorization extends Context.Tag("@agent-x/gondolin-broker-effect/Authorization")<
  Authorization,
  AuthorizationService
>() {}
