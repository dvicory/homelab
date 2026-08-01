#!/usr/bin/env node
import * as NodeRuntime from "@effect/platform-node/NodeRuntime";
import { Effect } from "effect";
import { TestBrokerLive } from "./broker-live.js";
import { serve } from "./server.js";

NodeRuntime.runMain(serve.pipe(Effect.provide(TestBrokerLive)));
