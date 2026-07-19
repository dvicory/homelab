/**
 * Per-VM cgroup v2 resource governance (V3 §16).
 *
 * QEMU's -m/-smp flags are guest-visible sizing, not host enforcement. The
 * broker service runs with a delegated cgroup v2 subtree (systemd
 * Delegate=yes) and creates one child cgroup per VM directly — no
 * systemd-manager authority, no systemd-run. Placement failure is fatal:
 * a VM that cannot be governed never runs.
 */
import fs from "node:fs";
import path from "node:path";
import { BrokerError, REASONS } from "./errors.js";

export interface CgroupLimits {
  memoryMiB: number;
  cpus: number;
  pidsMax: number;
  /** io.weight is out of scope for the spike; cpu.weight default */
}

export interface VmCgroup {
  readonly path: string;
  attach(pid: number): void;
  /** kill remaining processes and remove the cgroup; safe to call twice */
  destroy(): void;
}

const CGROUP_ROOT = "/sys/fs/cgroup";

function writeFile(file: string, value: string): void {
  fs.writeFileSync(file, value);
}

function readFile(file: string): string {
  return fs.readFileSync(file, "utf8").trim();
}

/**
 * Manage per-VM cgroups under the broker's delegated subtree.
 *
 * `basePath` is the broker's own cgroup (from /proc/self/cgroup). Controllers
 * are enabled once at the broker level; each VM gets a child with hard caps.
 */
export class CgroupManager {
  readonly #basePath: string;
  readonly #enabled: boolean;

  constructor(basePath?: string) {
    if (!fs.existsSync(CGROUP_ROOT)) {
      // Non-Linux / non-cgroup host (local darwin development): enforcement
      // is disabled but every operation remains fail-visible.
      this.#basePath = "";
      this.#enabled = false;
      return;
    }
    const self = basePath ?? readFile("/proc/self/cgroup").split(":").pop() ?? "/";
    this.#basePath = path.join(CGROUP_ROOT, self);
    if (!fs.existsSync(this.#basePath)) {
      throw new BrokerError(REASONS.RESOURCE_CGROUP, "broker cgroup does not exist", {
        path: this.#basePath,
      });
    }
    this.#enabled = true;
    this.#enableControllers();
  }

  get enabled(): boolean {
    return this.#enabled;
  }

  #enableControllers(): void {
    const available = readFile(path.join(this.#basePath, "cgroup.controllers")).split(/\s+/);
    const wanted = ["cpu", "memory", "pids"].filter((c) => available.includes(c));
    if (wanted.length === 0) {
      throw new BrokerError(REASONS.RESOURCE_CGROUP, "no cpu/memory/pids controllers delegated", {
        available,
      });
    }
    try {
      writeFile(path.join(this.#basePath, "cgroup.subtree_control"), wanted.map((c) => `+${c}`).join(" "));
    } catch (err) {
      throw new BrokerError(REASONS.RESOURCE_CGROUP, "cannot enable delegated controllers", {
        error: err instanceof Error ? err.message : String(err),
      });
    }
  }

  /** Create a governed cgroup for one VM. Throws (fatal) on any failure. */
  create(vmId: string, limits: CgroupLimits): VmCgroup {
    if (!this.#enabled) {
      return {
        path: "",
        attach: () => {},
        destroy: () => {},
      };
    }
    const safeId = vmId.replace(/[^a-zA-Z0-9_.-]/g, "_");
    const dir = path.join(this.#basePath, `hermes-vm-${safeId}`);
    try {
      fs.mkdirSync(dir, { recursive: false });
      // memory.max: hard cap; swap off for the VM subtree.
      writeFile(path.join(dir, "memory.max"), `${limits.memoryMiB}M`);
      writeFile(path.join(dir, "memory.swap.max"), "0");
      // cpu.max: quota over one period (100ms) scaled by cpu count.
      writeFile(path.join(dir, "cpu.max"), `${limits.cpus * 100000} 100000`);
      writeFile(path.join(dir, "pids.max"), `${limits.pidsMax}`);
    } catch (err) {
      try {
        fs.rmSync(dir, { recursive: true, force: true });
      } catch {
        // best effort
      }
      throw new BrokerError(REASONS.RESOURCE_CGROUP, "cannot create per-VM cgroup", {
        error: err instanceof Error ? err.message : String(err),
      });
    }

    let destroyed = false;
    return {
      path: dir,
      attach(pid: number): void {
        try {
          writeFile(path.join(dir, "cgroup.procs"), `${pid}`);
        } catch (err) {
          throw new BrokerError(REASONS.RESOURCE_CGROUP, "cannot place VM process in cgroup", {
            pid,
            error: err instanceof Error ? err.message : String(err),
          });
        }
      },
      destroy(): void {
        if (destroyed) return;
        destroyed = true;
        try {
          const procs = readFile(path.join(dir, "cgroup.procs")).split(/\s+/).filter(Boolean);
          for (const pid of procs) {
            try {
              process.kill(Number(pid), "SIGKILL");
            } catch {
              // already gone
            }
          }
        } catch {
          // cgroup already gone
        }
        // Removal can race zombie reaping; retry briefly.
        for (let attempt = 0; attempt < 10; attempt += 1) {
          try {
            fs.rmdirSync(dir);
            return;
          } catch {
            Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 50);
          }
        }
      },
    };
  }
}
