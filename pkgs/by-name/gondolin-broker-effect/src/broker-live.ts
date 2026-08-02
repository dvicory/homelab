import { Layer } from "effect";
import { TaskRunActivationsLive } from "./task-run-activations.js";
import { AuthorizationLive, BrokerPolicyKernelLive } from "./authorization-live.js";
import { BrokerConfigLive } from "./config.js";
import { BrokerDatabaseLive } from "./database.js";
import { EnvironmentsLive } from "./environments.js";
import { ExecutorLive } from "./exec.js";
import { ProcessesLive } from "./processes.js";
import { FilesLive } from "./files.js";
import { AccessGrantsLive } from "./grants.js";
import { HandoffStoreLive } from "./workspace-handoff/repository.js";
import { HandoffOperationsLive } from "./workspace-handoff/service.js";
import { HandoffStorageLive } from "./workspace-handoff/frozen-tree.js";
import { InputPreparationRepositoryLive } from "./task-run-inputs/repository.js";
import { InputPreparationsLive } from "./task-run-inputs/service.js";
import { RegistryLive } from "./registry.js";
import { VmRuntimeLive } from "./runtime.js";
import { WorkspacesLive, makeTestWorkspacesLayer } from "./workspaces.js";
import { WorkspaceBranchesLive } from "./workspace-branches.js";
import { ProjectWorkspaceStoreLive } from "./project-workspace/store.js";
import {
  ProjectWorkspacesLive,
  makeTestProjectWorkspacesLayer,
} from "./project-workspace/service.js";

const makeBrokerLive = (
  workspacesLayer: typeof WorkspacesLive,
  projectWorkspacesLayer: typeof ProjectWorkspacesLive,
) => {
  const infrastructure = Layer.mergeAll(BrokerConfigLive, VmRuntimeLive);
  const policy = BrokerPolicyKernelLive.pipe(Layer.provideMerge(infrastructure));
  const authorization = AuthorizationLive.pipe(Layer.provideMerge(policy));
  const database = BrokerDatabaseLive.pipe(Layer.provideMerge(authorization));
  const workspaces = workspacesLayer.pipe(Layer.provideMerge(database));
  const projectStore = ProjectWorkspaceStoreLive.pipe(Layer.provideMerge(workspaces));
  const projectWorkspaces = projectWorkspacesLayer.pipe(Layer.provideMerge(projectStore));
  const registry = RegistryLive.pipe(Layer.provideMerge(projectWorkspaces));
  const inputRepository = InputPreparationRepositoryLive.pipe(Layer.provideMerge(database));
  const inputPreparations = InputPreparationsLive.pipe(Layer.provideMerge(inputRepository));
  const runActivations = TaskRunActivationsLive.pipe(
    Layer.provideMerge(Layer.mergeAll(registry, inputPreparations)),
  );
  const handoffs = HandoffStoreLive.pipe(Layer.provideMerge(runActivations));
  const handoffStorage = HandoffStorageLive.pipe(Layer.provideMerge(handoffs));
  const grants = AccessGrantsLive.pipe(Layer.provideMerge(handoffStorage));
  const environments = EnvironmentsLive.pipe(Layer.provideMerge(grants));
  const workspaceBranches = WorkspaceBranchesLive.pipe(Layer.provideMerge(environments));
  const handoffOperations = HandoffOperationsLive.pipe(Layer.provideMerge(workspaceBranches));
  const executor = ExecutorLive.pipe(Layer.provideMerge(handoffOperations));
  const processes = ProcessesLive.pipe(Layer.provideMerge(executor));
  return FilesLive.pipe(Layer.provideMerge(processes));
};

export const BrokerLive = makeBrokerLive(WorkspacesLive, ProjectWorkspacesLive);

/** @internal Nix build-sandbox composition; production remains fail-closed. */
export const TestBrokerLive = makeBrokerLive(
  makeTestWorkspacesLayer(),
  makeTestProjectWorkspacesLayer(),
);
