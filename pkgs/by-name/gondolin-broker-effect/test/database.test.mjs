import assert from "node:assert/strict"
import { mkdtemp } from "node:fs/promises"
import os from "node:os"
import path from "node:path"
import test from "node:test"
import { Effect, Layer } from "effect"
import { BrokerConfig } from "../dist/config.js"
import { BrokerDatabase, BrokerDatabaseLive } from "../dist/database.js"
import { makePolicyFile } from "./fakes.mjs"

const withDatabase = async (run) => {
  const stateDir = await mkdtemp(path.join(os.tmpdir(), "gondolin-database-test-"))
  const config = {
    policyPath: path.join(stateDir, "policy.json"),
    stateDir,
    workspaceRoot: path.join(stateDir, "workspaces"),
    databasePath: path.join(stateDir, "broker.sqlite"),
    socketPath: path.join(stateDir, "broker.sock"),
    controlSocketPath: path.join(stateDir, "control.sock"),
    profile: "test",
    policyFile: makePolicyFile()
  }
  const layer = BrokerDatabaseLive.pipe(
    Layer.provideMerge(Layer.succeed(BrokerConfig, config))
  )
  return Effect.runPromise(Effect.scoped(run.pipe(Effect.provide(layer))))
}

test("shared database joins nested transactions and rolls back atomically", async () => {
  await withDatabase(Effect.gen(function* () {
    const database = yield* BrokerDatabase
    database.connection.exec("CREATE TABLE records (value TEXT PRIMARY KEY) STRICT")

    database.transaction(() => {
      database.connection.prepare("INSERT INTO records VALUES (?)").run("outer")
      database.transaction(() => {
        database.connection.prepare("INSERT INTO records VALUES (?)").run("nested")
      })
    })

    assert.throws(() => database.transaction(() => {
      database.connection.prepare("INSERT INTO records VALUES (?)").run("rolled-back")
      database.transaction(() => {
        database.connection.prepare("INSERT INTO records VALUES (?)").run("also-rolled-back")
      })
      throw new Error("abort")
    }), /abort/)

    const values = database.connection.prepare("SELECT value FROM records ORDER BY value").all()
    assert.deepEqual(values.map((row) => row.value), ["nested", "outer"])
  }))
})
