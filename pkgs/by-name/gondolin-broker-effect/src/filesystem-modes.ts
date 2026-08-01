import * as fs from "node:fs";
import * as fsPromises from "node:fs/promises";

const SETGID = 0o2000;
export interface SharedDirectoryModeOptions {
  readonly allowMissingSetgid?: boolean;
}

const rejectsSetgid = (error: unknown, mode: number): boolean =>
  (mode & SETGID) !== 0
  && typeof error === "object"
  && error !== null
  && "code" in error
  && error.code === "EPERM";

const missingSetgid = (actualMode: number, requestedMode: number): boolean =>
  (requestedMode & SETGID) !== 0 && (actualMode & SETGID) === 0;

const setgidError = (target: string): Error =>
  new Error(`filesystem did not preserve required setgid mode on '${target}'`);

/**
 * Apply the requested shared-directory mode. Production callers use the
 * strict default. Restricted test filesystems may explicitly permit a
 * group-mode-only fallback; later cross-user access still fails closed
 * without group inheritance.
 */
export const chmodSharedDirectorySync = (
  target: string,
  mode: number,
  options: SharedDirectoryModeOptions = {},
): void => {
  try {
    fs.chmodSync(target, mode);
  } catch (error) {
    if (options.allowMissingSetgid !== true || !rejectsSetgid(error, mode)) throw error;
    fs.chmodSync(target, mode & ~SETGID);
    return;
  }
  if (options.allowMissingSetgid !== true && missingSetgid(fs.statSync(target).mode, mode)) {
    throw setgidError(target);
  }
};

export const chmodSharedDirectory = async (
  target: string,
  mode: number,
  options: SharedDirectoryModeOptions = {},
): Promise<void> => {
  try {
    await fsPromises.chmod(target, mode);
  } catch (error) {
    if (options.allowMissingSetgid !== true || !rejectsSetgid(error, mode)) throw error;
    await fsPromises.chmod(target, mode & ~SETGID);
    return;
  }
  if (options.allowMissingSetgid !== true && missingSetgid((await fsPromises.stat(target)).mode, mode)) {
    throw setgidError(target);
  }
};
