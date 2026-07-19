/**
 * Broker wire protocol (V3 §13.1).
 *
 * Versioned, length-prefixed JSON frames over AF_UNIX. Every frame carries a
 * protocol version, request id, operation, and typed payload. Binary data and
 * stream chunks travel as bounded base64 fields. The server consumes systemd
 * socket activation (LISTEN_PID/LISTEN_FDS, fd 3) and never binds the
 * pathname the socket unit owns.
 *
 * Unknown versions, operations, fields, duplicate ids, oversized frames,
 * invalid base64, and invalid state transitions fail closed with stable
 * reason codes.
 */
import net from "node:net";
import { BrokerError, REASONS } from "./errors.js";

export const PROTOCOL_VERSION = 1 as const;
export const LENGTH_PREFIX_BYTES = 4;
/** Hard cap on a single frame's payload; the effective cap comes from policy. */
export const ABSOLUTE_MAX_FRAME_BYTES = 16 * 1024 * 1024;

const FRAME_FIELDS: Record<string, true> = { v: true, id: true, op: true, payload: true };
const RESPONSE_FIELDS: Record<string, true> = { v: true, id: true, ok: true, result: true, error: true };
const STREAM_FIELDS: Record<string, true> = { v: true, id: true, event: true, stream: true, seq: true, data: true, final: true, exitCode: true, signal: true, reason: true, truncated: true };

/** Operations accepted in the credential-free spike (§13.2). Later
 * operations are recognized and rejected with the same fail-closed code so
 * older gateways get a deterministic answer. */
export const SPIKE_OPERATIONS: Record<string, true> = {
  ensure: true,
  status: true,
  "exec.start": true,
  "exec.stdin": true,
  "exec.signal": true,
  "exec.wait": true,
  "exec.cancel": true,
  "fs.stat": true,
  "fs.list": true,
  "fs.read": true,
  "fs.writeAtomic": true,
  "fs.mkdir": true,
  "fs.remove": true,
  close: true,
};

export interface RequestFrame {
  v: number;
  id: number;
  op: string;
  payload: Record<string, unknown>;
}

export interface ResponseFrame {
  v: number;
  id: number;
  ok: boolean;
  result?: unknown;
  error?: { reason: string; message: string } & Record<string, unknown>;
}

export interface StreamFrame {
  v: number;
  id: number;
  event: "exec.output" | "exec.exit" | "exec.state";
  stream?: "stdout" | "stderr";
  seq?: number;
  /** base64 payload for exec.output */
  data?: string;
  final?: boolean;
  exitCode?: number | null;
  signal?: number | null;
  reason?: string | null;
  truncated?: boolean;
}

/** Decode a base64 field with a byte cap; anything malformed fails closed. */
export function decodeBase64Field(value: unknown, maxBytes: number, path: string): Buffer {
  if (typeof value !== "string") {
    throw new BrokerError(REASONS.PROTOCOL_BAD_BASE64, `${path} must be base64`, { path });
  }
  if (value.length > ((maxBytes + 2) / 3) * 4 + 4) {
    throw new BrokerError(REASONS.RESOURCE_INPUT, `${path} exceeds ${maxBytes} bytes`, { path });
  }
  if (!/^[A-Za-z0-9+/]*={0,2}$/.test(value) || value.length % 4 !== 0) {
    throw new BrokerError(REASONS.PROTOCOL_BAD_BASE64, `${path} is not valid base64`, { path });
  }
  const buf = Buffer.from(value, "base64");
  if (buf.length > maxBytes) {
    throw new BrokerError(REASONS.RESOURCE_INPUT, `${path} exceeds ${maxBytes} bytes`, { path });
  }
  return buf;
}

/** Parse and strictly validate one request frame body. */
export function parseRequestFrame(body: Buffer): RequestFrame {
  let frame: unknown;
  try {
    frame = JSON.parse(body.toString("utf8"));
  } catch {
    throw new BrokerError(REASONS.PROTOCOL_FRAME, "frame is not valid JSON");
  }
  if (typeof frame !== "object" || frame === null || Array.isArray(frame)) {
    throw new BrokerError(REASONS.PROTOCOL_FRAME, "frame must be a JSON object");
  }
  const obj = frame as Record<string, unknown>;
  for (const key of Object.keys(obj)) {
    if (!FRAME_FIELDS[key]) {
      throw new BrokerError(REASONS.PROTOCOL_UNKNOWN_FIELD, `unknown frame field`, { field: key });
    }
  }
  if (obj.v !== PROTOCOL_VERSION) {
    throw new BrokerError(REASONS.PROTOCOL_VERSION, `unsupported protocol version`, { version: obj.v });
  }
  if (typeof obj.id !== "number" || !Number.isInteger(obj.id) || obj.id < 0 || obj.id > 2 ** 53) {
    throw new BrokerError(REASONS.PROTOCOL_FRAME, `id must be a non-negative integer`);
  }
  if (typeof obj.op !== "string" || obj.op.length === 0) {
    throw new BrokerError(REASONS.PROTOCOL_FRAME, `op must be a non-empty string`);
  }
  if (!SPIKE_OPERATIONS[obj.op]) {
    throw new BrokerError(REASONS.PROTOCOL_UNKNOWN_OP, `unknown operation`, { op: obj.op });
  }
  if (typeof obj.payload !== "object" || obj.payload === null || Array.isArray(obj.payload)) {
    throw new BrokerError(REASONS.PROTOCOL_FRAME, `payload must be an object`);
  }
  return { v: obj.v, id: obj.id, op: obj.op, payload: obj.payload as Record<string, unknown> };
}

export function serializeResponse(frame: ResponseFrame | StreamFrame): Buffer {
  const body = Buffer.from(JSON.stringify(frame), "utf8");
  const prefix = Buffer.allocUnsafe(LENGTH_PREFIX_BYTES);
  prefix.writeUInt32LE(body.length, 0);
  return Buffer.concat([prefix, body]);
}

export function errorResponse(id: number, err: BrokerError): ResponseFrame {
  return {
    v: PROTOCOL_VERSION,
    id,
    ok: false,
    error: { reason: err.reason, message: err.message, ...err.details },
  };
}

export function okResponse(id: number, result: unknown): ResponseFrame {
  return { v: PROTOCOL_VERSION, id, ok: true, result };
}

/**
 * Incremental length-prefixed frame decoder with a hard cap. Feed socket
 * data; complete frames come back in order. Oversized prefixes throw
 * fail-closed before the body is buffered.
 */
export class FrameDecoder {
  #buffer: Buffer = Buffer.alloc(0);
  readonly #maxFrameBytes: number;

  constructor(maxFrameBytes: number) {
    if (maxFrameBytes > ABSOLUTE_MAX_FRAME_BYTES) {
      throw new BrokerError(REASONS.POLICY_ATTENUATION, "frame cap exceeds absolute maximum");
    }
    this.#maxFrameBytes = maxFrameBytes;
  }

  push(chunk: Buffer): Buffer[] {
    this.#buffer = this.#buffer.length === 0 ? chunk : Buffer.concat([this.#buffer, chunk]);
    const frames: Buffer[] = [];
    for (;;) {
      if (this.#buffer.length < LENGTH_PREFIX_BYTES) break;
      const length = this.#buffer.readUInt32LE(0);
      if (length > this.#maxFrameBytes) {
        throw new BrokerError(REASONS.PROTOCOL_OVERSIZED, `frame exceeds ${this.#maxFrameBytes} bytes`, {
          length,
        });
      }
      if (this.#buffer.length < LENGTH_PREFIX_BYTES + length) break;
      frames.push(this.#buffer.subarray(LENGTH_PREFIX_BYTES, LENGTH_PREFIX_BYTES + length));
      this.#buffer = this.#buffer.subarray(LENGTH_PREFIX_BYTES + length);
    }
    return frames;
  }
}

export interface ActivationSocket {
  /** bound listening socket from systemd activation */
  server: net.Server;
  /** "activation" when fd 3 was inherited, never a bound pathname */
  source: "activation";
}

/**
 * Consume the systemd-activated socket on fd 3 (§13.1). Returns null when no
 * activation environment is present; the broker never binds a pathname the
 * socket unit owns.
 */
export function consumeSystemdActivation(
  onConnection: (conn: net.Socket) => void,
  onError: (err: Error) => void,
): ActivationSocket | null {
  const listenPid = Number(process.env.LISTEN_PID ?? "0");
  const listenFds = Number(process.env.LISTEN_FDS ?? "0");
  if (listenPid !== process.pid || listenFds < 1) return null;
  const server = net.createServer({ pauseOnConnect: false }, onConnection);
  server.on("error", onError);
  // fd 3 is the first (and only) socket handed to the broker.
  server.listen({ fd: 3 });
  return { server, source: "activation" };
}

/** Per-connection request multiplexer: framing, validation, duplicate-id
 * enforcement, and ordered dispatch to the operation handler. */
export class BrokerConnection {
  #decoder: FrameDecoder;
  #inflight = new Set<number>();
  #socket: net.Socket;
  #closed = false;
  readonly onRequest: (
    frame: RequestFrame,
    reply: (frame: ResponseFrame | StreamFrame) => void,
  ) => Promise<void> | void;

  constructor(
    socket: net.Socket,
    maxFrameBytes: number,
    onRequest: BrokerConnection["onRequest"],
    readonly onClose: () => void,
  ) {
    this.#socket = socket;
    this.#decoder = new FrameDecoder(maxFrameBytes);
    this.onRequest = onRequest;
    socket.on("data", (chunk) => this.#onData(chunk));
    socket.on("error", () => this.close());
    socket.on("close", () => {
      this.#closed = true;
      this.onClose();
    });
  }

  #onData(chunk: Buffer): void {
    if (this.#closed) return;
    let frames: Buffer[];
    try {
      frames = this.#decoder.push(chunk);
    } catch (err) {
      // Framing violations are unrecoverable: fail closed (§13.1), but send
      // the error frame with a graceful FIN — an immediate destroy() can RST
      // the response before the peer reads it.
      this.#socket.end(serializeResponse(errorResponse(-1, asProtocolError(err))), () => this.close());
      return;
    }
    for (const body of frames) {
      let request: RequestFrame;
      try {
        request = parseRequestFrame(body);
        if (this.#inflight.has(request.id)) {
          throw new BrokerError(REASONS.PROTOCOL_DUPLICATE_ID, `duplicate request id`, { id: request.id });
        }
      } catch (err) {
        const brokerErr = asProtocolError(err);
        this.#socket.write(serializeResponse(errorResponse(requestIdOrZero(body), brokerErr)));
        continue;
      }
      this.#inflight.add(request.id);
      const reply = (frame: ResponseFrame | StreamFrame): void => {
        if (this.#closed) return;
        this.#socket.write(serializeResponse(frame), (writeErr) => {
          if (writeErr) this.close();
        });
      };
      Promise.resolve()
        .then(() => this.onRequest(request, reply))
        .catch((err: unknown) => {
          reply(errorResponse(request.id, asProtocolError(err)));
        })
        .finally(() => {
          this.#inflight.delete(request.id);
        });
    }
  }

  close(): void {
    if (this.#closed) return;
    this.#closed = true;
    this.#socket.destroy();
  }
}

function requestIdOrZero(body: Buffer): number {
  try {
    const parsed = JSON.parse(body.toString("utf8")) as { id?: unknown };
    return typeof parsed.id === "number" ? parsed.id : 0;
  } catch {
    return 0;
  }
}

function asProtocolError(err: unknown): BrokerError {
  if (err instanceof BrokerError) return err;
  return new BrokerError(REASONS.INTERNAL, err instanceof Error ? err.message : String(err));
}

/** Validate that a payload object carries only declared fields. Handlers
 * declare their surface explicitly; anything else fails closed. */
export function assertPayloadFields(
  payload: Record<string, unknown>,
  allowed: Record<string, true>,
  op: string,
): void {
  for (const key of Object.keys(payload)) {
    if (!allowed[key]) {
      throw new BrokerError(REASONS.PROTOCOL_UNKNOWN_FIELD, `${op}: unknown field`, { op, field: key });
    }
  }
}

export function requiredString(payload: Record<string, unknown>, field: string, op: string): string {
  const value = payload[field];
  if (typeof value !== "string" || value.length === 0) {
    throw new BrokerError(REASONS.PROTOCOL_FRAME, `${op}.${field} must be a non-empty string`, { op, field });
  }
  return value;
}

export function optionalString(payload: Record<string, unknown>, field: string, op: string): string | null {
  const value = payload[field];
  if (value === undefined || value === null) return null;
  if (typeof value !== "string") {
    throw new BrokerError(REASONS.PROTOCOL_FRAME, `${op}.${field} must be a string`, { op, field });
  }
  return value;
}

export function optionalInt(
  payload: Record<string, unknown>,
  field: string,
  op: string,
  min: number,
  max: number,
): number | null {
  const value = payload[field];
  if (value === undefined || value === null) return null;
  if (typeof value !== "number" || !Number.isInteger(value) || value < min || value > max) {
    throw new BrokerError(REASONS.PROTOCOL_FRAME, `${op}.${field} must be an integer in [${min}, ${max}]`, {
      op,
      field,
    });
  }
  return value;
}

// Re-export for handler use (stream frame field whitelist used by tests).
export { STREAM_FIELDS, RESPONSE_FIELDS };
