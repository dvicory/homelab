import { test } from "node:test";
import assert from "node:assert/strict";
import { VfsService } from "../dist/vfs.js";
import { REASONS } from "../dist/errors.js";
import { FakeFs } from "./fakes.mjs";

const ROOT = "/workspace";

function setup() {
  const fs = new FakeFs();
  fs.entries.set(ROOT, { type: "directory", mode: 0o755 });
  fs.entries.set(`${ROOT}/file.txt`, { type: "file", content: Buffer.from("hello"), mode: 0o644 });
  fs.entries.set(`${ROOT}/sub`, { type: "directory", mode: 0o755 });
  fs.entries.set(`${ROOT}/sub/nested.bin`, { type: "file", content: Buffer.from([0, 1, 2, 255]), mode: 0o644 });
  const vfs = new VfsService();
  return { fs, vfs };
}

test("path confinement: escapes, absolutes, dot segments", async () => {
  const { fs, vfs } = setup();
  for (const bad of ["../etc/passwd", "sub/../../etc/passwd", "/etc/passwd", "/workspace/../../root/x", "\0"]) {
    for (const fn of [
      () => vfs.read(fs, ROOT, bad),
      () => vfs.stat(fs, ROOT, bad),
      () => vfs.writeAtomic(fs, ROOT, bad, Buffer.from("x"), "replace"),
      () => vfs.remove(fs, ROOT, bad, true),
    ]) {
      await assert.rejects(fn, (err) => err.reason === REASONS.FS_ESCAPE || err.reason === REASONS.FS_PATH, bad);
    }
  }
  // Allowed forms
  assert.deepEqual((await vfs.read(fs, ROOT, "file.txt")).toString(), "hello");
  assert.deepEqual((await vfs.read(fs, ROOT, "/workspace/file.txt")).toString(), "hello");
  assert.deepEqual((await vfs.read(fs, ROOT, "sub/../file.txt")).toString(), "hello");
  assert.deepEqual((await vfs.read(fs, ROOT, "./sub/nested.bin"))[3], 255);
});

test("reads are binary-safe; writes are atomic via tmp+rename", async () => {
  const { fs, vfs } = setup();
  const payload = Buffer.from([0, 159, 146, 150, 255, 10]);
  await vfs.writeAtomic(fs, ROOT, "bin.dat", payload, "replace");
  const names = await vfs.list(fs, ROOT, ".");
  assert.ok(names.some((e) => e.name === "bin.dat"));
  assert.ok(!names.some((e) => e.name.includes("hermes-broker-tmp")));
  assert.deepEqual([...(await vfs.read(fs, ROOT, "bin.dat"))], [...payload]);
});

test("create modes are explicit", async () => {
  const { fs, vfs } = setup();
  await assert.rejects(
    () => vfs.writeAtomic(fs, ROOT, "new.txt", Buffer.from("x"), "create"),
    (err) => err.reason === REASONS.FS_NOT_FOUND,
  );
  await vfs.writeAtomic(fs, ROOT, "new.txt", Buffer.from("x"), "create-exclusive");
  await assert.rejects(
    () => vfs.writeAtomic(fs, ROOT, "new.txt", Buffer.from("y"), "create-exclusive"),
    (err) => err.reason === REASONS.FS_EXISTS,
  );
  await vfs.writeAtomic(fs, ROOT, "new.txt", Buffer.from("y"), "replace");
  assert.equal((await vfs.read(fs, ROOT, "new.txt")).toString(), "y");
});

test("write-side symlink components are rejected deterministically", async () => {
  const { fs, vfs } = setup();
  fs.entries.set(`${ROOT}/link`, { type: "symlink", mode: 0o777 });
  await assert.rejects(
    () => vfs.writeAtomic(fs, ROOT, "link/evil.txt", Buffer.from("x"), "replace"),
    (err) => err.reason === REASONS.FS_TYPE,
  );
  await assert.rejects(
    () => vfs.mkdir(fs, ROOT, "link/inner", true),
    (err) => err.reason === REASONS.FS_TYPE,
  );
});

test("remove refuses the root and honors recursion", async () => {
  const { fs, vfs } = setup();
  await assert.rejects(() => vfs.remove(fs, ROOT, ".", true), (err) => err.reason === REASONS.FS_PATH);
  await assert.rejects(() => vfs.remove(fs, ROOT, "sub", false));
  await vfs.remove(fs, ROOT, "sub", true);
  await assert.rejects(() => vfs.stat(fs, ROOT, "sub"), (err) => err.reason === REASONS.FS_NOT_FOUND);
});

test("size caps are enforced", async () => {
  const { fs } = setup();
  const vfs = new VfsService({ maxFileBytes: 4, maxListEntries: 1, maxPathLength: 4096 });
  await assert.rejects(
    () => vfs.writeAtomic(fs, ROOT, "big", Buffer.alloc(5), "replace"),
    (err) => err.reason === REASONS.FS_LIMIT,
  );
  await assert.rejects(
    () => vfs.read(fs, ROOT, "file.txt"),
    (err) => err.reason === REASONS.FS_LIMIT,
  );
  await assert.rejects(
    () => vfs.list(fs, ROOT, "."),
    (err) => err.reason === REASONS.FS_LIMIT,
  );
});
