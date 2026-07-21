import { test } from "node:test";
import assert from "node:assert/strict";
import net from "node:net";
import {
  BrokerConnection,
  FrameDecoder,
  decodeBase64Field,
  errorResponse,
  okResponse,
  parseRequestFrame,
  serializeResponse,
} from "../dist/protocol.js";
import { REASONS } from "../dist/errors.js";

function frameBody(obj) {
  return Buffer.from(JSON.stringify(obj), "utf8");
}

function framed(obj) {
  const body = frameBody(obj);
  const prefix = Buffer.alloc(4);
  prefix.writeUInt32LE(body.length, 0);
  return Buffer.concat([prefix, body]);
}

test("frame decoder reassembles split and coalesced frames", () => {
  const decoder = new FrameDecoder(1024);
  const a = framed({ v: 1, id: 1, op: "status", payload: {} });
  const b = framed({ v: 1, id: 2, op: "status", payload: {} });

  const out = [];
  for (const chunk of [a.subarray(0, 5), a.subarray(5), b]) {
    out.push(...decoder.push(chunk));
  }
  assert.equal(out.length, 2);
  assert.deepEqual(JSON.parse(out[0].toString()).id, 1);
  assert.deepEqual(JSON.parse(out[1].toString()).id, 2);
});

test("oversized frames fail closed before buffering", () => {
  const decoder = new FrameDecoder(16);
  const prefix = Buffer.alloc(4);
  prefix.writeUInt32LE(4096, 0);
  assert.throws(
    () => decoder.push(prefix),
    (err) => err.reason === REASONS.PROTOCOL_OVERSIZED,
  );
});

test("request validation: version, fields, ops, payload", () => {
  const good = parseRequestFrame(frameBody({ v: 1, id: 7, op: "ensure", payload: {} }));
  assert.equal(good.id, 7);

  const cases = [
    [{ v: 2, id: 1, op: "status", payload: {} }, REASONS.PROTOCOL_VERSION],
    [{ v: 1, id: 1, op: "status", payload: {}, extra: 1 }, REASONS.PROTOCOL_UNKNOWN_FIELD],
    [{ v: 1, id: 1, op: "rm -rf /", payload: {} }, REASONS.PROTOCOL_UNKNOWN_OP],
    [{ v: 1, id: "x", op: "status", payload: {} }, REASONS.PROTOCOL_FRAME],
    [{ v: 1, id: 1, op: "status", payload: [] }, REASONS.PROTOCOL_FRAME],
    ["not json", REASONS.PROTOCOL_FRAME],
  ];
  for (const [input, reason] of cases) {
    const body = typeof input === "string" ? Buffer.from(input) : frameBody(input);
    assert.throws(() => parseRequestFrame(body), (err) => err.reason === reason);
  }
});

test("base64 fields are bounded and strict", () => {
  const buf = decodeBase64Field(Buffer.from("hello").toString("base64"), 16, "data");
  assert.equal(buf.toString(), "hello");
  assert.throws(() => decodeBase64Field("!!!", 16, "data"), (err) => err.reason === REASONS.PROTOCOL_BAD_BASE64);
  assert.throws(
    () => decodeBase64Field(Buffer.alloc(64).toString("base64"), 16, "data"),
    (err) => err.reason === REASONS.RESOURCE_INPUT,
  );
});

test("response frames round-trip", () => {
  const ok = serializeResponse(okResponse(3, { state: "active" }));
  const err = serializeResponse(errorResponse(3, { reason: "x.y", message: "m", details: {} }));
  assert.ok(ok.length > 4);
  assert.ok(err.length > 4);
});

test("connection multiplexes requests and rejects duplicates", async () => {
  const server = net.createServer((socket) => {
    new BrokerConnection(
      socket,
      1 << 20,
      (request, reply) => {
        if (request.op === "status") reply(okResponse(request.id, { pong: request.payload.n ?? null }));
      },
      () => {},
    );
  });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  const port = server.address().port;

  try {
    const client = net.connect(port, "127.0.0.1");
    await new Promise((resolve) => client.once("connect", resolve));

    const replies = [];
    const decoder = new FrameDecoder(1 << 20);
    client.on("data", (chunk) => {
      for (const body of decoder.push(chunk)) replies.push(JSON.parse(body.toString()));
    });

    // Two pipelined requests, plus a duplicate id.
    client.write(framed({ v: 1, id: 1, op: "status", payload: { n: 1 } }));
    client.write(framed({ v: 1, id: 2, op: "status", payload: { n: 2 } }));
    client.write(framed({ v: 1, id: 2, op: "status", payload: { n: 3 } }));

    await new Promise((resolve) => {
      const check = () => (replies.length >= 3 ? resolve() : setTimeout(check, 10));
      check();
    });

    const okReplies = replies.filter((r) => r.ok).map((r) => r.result.pong).sort();
    assert.deepEqual(okReplies, [1, 2]);
    const dup = replies.find((r) => !r.ok);
    assert.equal(dup.error.reason, REASONS.PROTOCOL_DUPLICATE_ID);
    client.destroy();
  } finally {
    await new Promise((resolve) => server.close(resolve));
  }
});

test("malformed framing closes the connection fail-closed", async () => {
  const server = net.createServer((socket) => {
    new BrokerConnection(socket, 16, () => {}, () => {});
  });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  const port = server.address().port;

  try {
    const client = net.connect(port, "127.0.0.1");
    await new Promise((resolve) => client.once("connect", resolve));
    const closed = new Promise((resolve) => client.once("close", resolve));
    const frames = [];
    const decoder = new FrameDecoder(1 << 20);
    client.on("data", (chunk) => {
      for (const body of decoder.push(chunk)) frames.push(JSON.parse(body.toString()));
    });
    client.on("error", () => {});
    const prefix = Buffer.alloc(4);
    prefix.writeUInt32LE(4096, 0);
    client.write(prefix);
    await closed;
    assert.equal(frames.length, 1);
    assert.equal(frames[0].error.reason, REASONS.PROTOCOL_OVERSIZED);
  } finally {
    await new Promise((resolve) => server.close(resolve));
  }
});
