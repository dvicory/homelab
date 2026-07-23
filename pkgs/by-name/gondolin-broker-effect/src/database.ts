import * as fs from "node:fs";
import { DatabaseSync } from "node:sqlite";
import { Context, Effect, Layer } from "effect";
import { BrokerConfig } from "./config.js";
import { brokerError } from "./errors.js";

export interface BrokerDatabaseService {
  readonly connection: DatabaseSync;
  readonly transaction: <A>(operation: () => A) => A;
}

export class BrokerDatabase extends Context.Tag("@agent-x/gondolin-broker-effect/BrokerDatabase")<
  BrokerDatabase,
  BrokerDatabaseService
>() {}

const make = Effect.gen(function* () {
  const config = yield* BrokerConfig;
  const connection = yield* Effect.acquireRelease(
    Effect.try({
      try: () => {
        fs.mkdirSync(config.stateDir, { recursive: true, mode: 0o700 });
        const opened = new DatabaseSync(config.databasePath);
        opened.exec(
          "PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; PRAGMA foreign_keys=ON; PRAGMA busy_timeout=5000;",
        );
        fs.chmodSync(config.databasePath, 0o600);
        return opened;
      },
      catch: (error) => brokerError("registry.failed", "broker database open failed", {
        cause: error instanceof Error ? error.message : String(error),
      }),
    }),
    (opened) => Effect.sync(() => opened.close()),
  );

  let transactionDepth = 0;
  const transaction = <A>(operation: () => A): A => {
    if (transactionDepth > 0) return operation();
    connection.exec("BEGIN IMMEDIATE");
    transactionDepth = 1;
    try {
      const result = operation();
      connection.exec("COMMIT");
      return result;
    } catch (error) {
      connection.exec("ROLLBACK");
      throw error;
    } finally {
      transactionDepth = 0;
    }
  };

  return { connection, transaction } satisfies BrokerDatabaseService;
});

export const BrokerDatabaseLive = Layer.scoped(BrokerDatabase, make);
