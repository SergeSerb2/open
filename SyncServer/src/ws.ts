/**
 * Minimal RFC 6455 server implementation (no third-party dependencies).
 *
 * Supports: opening handshake, masked client frames (<= 64 KiB), fragmentation,
 * ping/pong, close handshake, unmasked server text frames, heartbeat pings and
 * server-initiated close codes.
 */
import { createHash } from "node:crypto";
import type { IncomingMessage } from "node:http";
import type { Duplex } from "node:stream";
import type { Socket } from "node:net";

const WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
export const MAX_CLIENT_PAYLOAD = 65_536;
/** Max fragments per client message; stops floods of zero-byte continuation frames. */
export const MAX_CLIENT_FRAGMENTS = 64;
export const CLOSE_SESSION_REVOKED = 4001;

const OP_CONT = 0x0;
const OP_TEXT = 0x1;
const OP_BINARY = 0x2;
const OP_CLOSE = 0x8;
const OP_PING = 0x9;
const OP_PONG = 0xa;

export function acceptKeyFor(clientKey: string): string {
  return createHash("sha1").update(clientKey + WS_GUID).digest("base64");
}

/** Validates the handshake headers. Returns the client key, or an error string. */
export function checkHandshake(req: IncomingMessage): { key: string } | { error: string } {
  if (req.method !== "GET") return { error: "WebSocket upgrade requires GET." };
  const upgrade = String(req.headers["upgrade"] ?? "").toLowerCase();
  const connection = String(req.headers["connection"] ?? "")
    .toLowerCase()
    .split(",")
    .map((s) => s.trim());
  if (upgrade !== "websocket" || !connection.includes("upgrade")) {
    return { error: "Expected a WebSocket upgrade request." };
  }
  if (req.headers["sec-websocket-version"] !== "13") return { error: "Unsupported WebSocket version (need 13)." };
  const key = req.headers["sec-websocket-key"];
  if (typeof key !== "string" || Buffer.from(key, "base64").length !== 16 || Buffer.from(key, "base64").toString("base64") !== key) {
    return { error: "Invalid Sec-WebSocket-Key." };
  }
  return { key };
}

function buildFrame(opcode: number, payload: Buffer): Buffer {
  const length = payload.length;
  let header: Buffer;
  if (length < 126) {
    header = Buffer.from([0x80 | opcode, length]);
  } else if (length <= 0xffff) {
    header = Buffer.alloc(4);
    header[0] = 0x80 | opcode;
    header[1] = 126;
    header.writeUInt16BE(length, 2);
  } else {
    header = Buffer.alloc(10);
    header[0] = 0x80 | opcode;
    header[1] = 127;
    header.writeBigUInt64BE(BigInt(length), 2);
  }
  return Buffer.concat([header, payload]);
}

function closePayload(code: number, reason: string): Buffer {
  const reasonBytes = Buffer.from(reason, "utf8").subarray(0, 123);
  const payload = Buffer.alloc(2 + reasonBytes.length);
  payload.writeUInt16BE(code, 0);
  reasonBytes.copy(payload, 2);
  return payload;
}

function isValidCloseCode(code: number): boolean {
  return (
    (code >= 1000 && code <= 1003) ||
    (code >= 1007 && code <= 1011) ||
    (code >= 3000 && code <= 4999)
  );
}

export interface WsMeta {
  accountId: string;
  deviceId: string;
  family: string;
}

export class WsConnection {
  readonly meta: WsMeta;
  alive = true;
  private readonly socket: Duplex;
  private state: "open" | "closing" | "closed" = "open";
  private buffer: Buffer = Buffer.alloc(0);
  private fragments: Buffer[] = [];
  private fragmentBytes = 0;
  private fragmentCount = 0;
  private fragmentOpcode = 0;
  private closeTimer: NodeJS.Timeout | undefined;
  private reported = false;
  private readonly onText: (conn: WsConnection, text: string) => void;
  private readonly onClosed: (conn: WsConnection) => void;

  constructor(
    socket: Duplex,
    meta: WsMeta,
    onText: (conn: WsConnection, text: string) => void,
    onClosed: (conn: WsConnection) => void,
  ) {
    this.socket = socket;
    this.meta = meta;
    this.onText = onText;
    this.onClosed = onClosed;
    socket.on("data", (chunk: Buffer) => this.feed(chunk));
    socket.on("error", () => this.terminate());
    socket.on("close", () => this.finish());
    socket.on("end", () => {
      if (this.state === "open") this.close(1001, "going_away");
      else socket.end();
    });
  }

  get isClosed(): boolean {
    return this.state === "closed";
  }

  get isOpen(): boolean {
    return this.state === "open";
  }

  sendText(text: string): void {
    if (this.state !== "open") return;
    this.write(buildFrame(OP_TEXT, Buffer.from(text, "utf8")));
  }

  sendJson(value: unknown): void {
    this.sendText(JSON.stringify(value));
  }

  ping(): void {
    if (this.state !== "open") return;
    this.write(buildFrame(OP_PING, Buffer.alloc(0)));
  }

  /** Starts the closing handshake; the socket is destroyed if the peer does not answer. */
  close(code: number, reason: string): void {
    if (this.state !== "open") return;
    this.state = "closing";
    this.write(buildFrame(OP_CLOSE, closePayload(code, reason)));
    this.closeTimer = setTimeout(() => this.terminate(), 2_000);
    this.closeTimer.unref();
  }

  terminate(): void {
    this.state = "closed";
    this.socket.destroy();
    this.finish();
  }

  private finish(): void {
    if (this.reported) return;
    this.reported = true;
    this.state = "closed";
    if (this.closeTimer) clearTimeout(this.closeTimer);
    this.closeTimer = undefined;
    this.onClosed(this);
  }

  private write(frame: Buffer): void {
    if (this.socket.destroyed || !this.socket.writable) return;
    if (this.socket.writableLength > 1_048_576) {
      this.terminate();
      return;
    }
    this.socket.write(frame);
  }

  private failProtocol(code: number, reason: string): void {
    this.buffer = Buffer.alloc(0);
    this.close(code, reason);
  }

  /** Feeds raw bytes received from the socket. */
  feed(chunk: Buffer): void {
    if (this.isClosed) return;
    this.alive = true;
    // A single frame is at most header (14) + payload; refuse chunks that would exceed that bound.
    if (this.buffer.length + chunk.length > MAX_CLIENT_PAYLOAD * 2 + 128) {
      return this.failProtocol(1009, "message_too_big");
    }
    this.buffer = this.buffer.length === 0 ? chunk : Buffer.concat([this.buffer, chunk]);
    // Bound memory: a single frame is at most header (14) + 64 KiB payload.
    for (;;) {
      if (this.isClosed) return;
      if (this.buffer.length < 2) return;
      const b0 = this.buffer[0] as number;
      const b1 = this.buffer[1] as number;
      const fin = (b0 & 0x80) !== 0;
      const rsv = b0 & 0x70;
      const opcode = b0 & 0x0f;
      const masked = (b1 & 0x80) !== 0;
      let length = b1 & 0x7f;
      let offset = 2;

      if (this.state === "closing" && opcode !== OP_CLOSE) {
        // After we sent Close, ignore everything except the peer's Close.
        this.buffer = Buffer.alloc(0);
        return;
      }
      if (rsv !== 0) return this.failProtocol(1002, "reserved_bits");
      if (!masked) return this.failProtocol(1002, "client_frames_must_be_masked");
      if (opcode > 0x2 && opcode < 0x8) return this.failProtocol(1002, "bad_opcode");
      if (opcode > 0xa) return this.failProtocol(1002, "bad_opcode");
      const isControl = opcode >= 0x8;
      if (isControl && !fin) return this.failProtocol(1002, "fragmented_control_frame");

      if (length === 126) {
        if (this.buffer.length < 4) return;
        length = this.buffer.readUInt16BE(2);
        offset = 4;
      } else if (length === 127) {
        if (this.buffer.length < 10) return;
        const big = this.buffer.readBigUInt64BE(2);
        if (big > BigInt(MAX_CLIENT_PAYLOAD)) return this.failProtocol(1009, "message_too_big");
        length = Number(big);
        offset = 10;
      }
      if (isControl && length > 125) return this.failProtocol(1002, "control_frame_too_large");
      if (length > MAX_CLIENT_PAYLOAD) return this.failProtocol(1009, "message_too_big");
      if (this.buffer.length < offset + 4 + length) return;

      const mask = this.buffer.subarray(offset, offset + 4);
      const payload = Buffer.allocUnsafe(length);
      const raw = this.buffer.subarray(offset + 4, offset + 4 + length);
      for (let i = 0; i < length; i += 1) payload[i] = (raw[i] as number) ^ (mask[i & 3] as number);
      this.buffer = this.buffer.subarray(offset + 4 + length);

      this.handleFrame(fin, opcode, payload);
    }
  }

  private handleFrame(fin: boolean, opcode: number, payload: Buffer): void {
    switch (opcode) {
      case OP_PING:
        this.write(buildFrame(OP_PONG, payload));
        return;
      case OP_PONG:
        return;
      case OP_CLOSE:
        this.handleClose(payload);
        return;
      case OP_CONT:
        if (this.fragmentOpcode === 0) return this.failProtocol(1002, "unexpected_continuation");
        break;
      case OP_TEXT:
      case OP_BINARY:
        if (this.fragmentOpcode !== 0) return this.failProtocol(1002, "interleaved_data_frames");
        this.fragmentOpcode = opcode;
        break;
      default:
        return this.failProtocol(1002, "bad_opcode");
    }

    this.fragmentBytes += payload.length;
    if (this.fragmentBytes > MAX_CLIENT_PAYLOAD) return this.failProtocol(1009, "message_too_big");
    if (payload.length > 0) this.fragments.push(payload);
    this.fragmentCount += 1;
    if (this.fragmentCount > MAX_CLIENT_FRAGMENTS) return this.failProtocol(1009, "too_many_fragments");
    if (!fin) return;

    const message = Buffer.concat(this.fragments);
    const messageOpcode = this.fragmentOpcode;
    this.fragments = [];
    this.fragmentBytes = 0;
    this.fragmentCount = 0;
    this.fragmentOpcode = 0;

    if (messageOpcode === OP_BINARY) return this.failProtocol(1003, "binary_not_supported");
    let text: string;
    try {
      text = new TextDecoder("utf-8", { fatal: true }).decode(message);
    } catch {
      return this.failProtocol(1007, "invalid_utf8");
    }
    this.onText(this, text);
  }

  private handleClose(payload: Buffer): void {
    let code = 1000;
    if (payload.length === 1) return this.failProtocol(1002, "bad_close_payload");
    if (payload.length >= 2) {
      code = payload.readUInt16BE(0);
      if (!isValidCloseCode(code)) return this.failProtocol(1002, "bad_close_code");
      try {
        new TextDecoder("utf-8", { fatal: true }).decode(payload.subarray(2));
      } catch {
        return this.failProtocol(1007, "invalid_utf8");
      }
    }
    if (this.state === "closing") {
      // We initiated: peer answered, finish.
      this.state = "closed";
      this.socket.end();
      return;
    }
    this.state = "closed";
    this.write(buildFrame(OP_CLOSE, closePayload(code === 1005 ? 1000 : code, "")));
    this.socket.end();
  }
}

export interface HubOptions {
  isFamilyActive: (family: string) => boolean;
  pingIntervalMs: number;
}

/** Tracks live WebSocket connections and fans out wake-ups. */
export class WsHub {
  private readonly connections = new Set<WsConnection>();
  private readonly options: HubOptions;
  private readonly heartbeat: NodeJS.Timeout;

  constructor(options: HubOptions) {
    this.options = options;
    this.heartbeat = setInterval(() => this.tick(), options.pingIntervalMs);
    this.heartbeat.unref();
  }

  get size(): number {
    return this.connections.size;
  }

  /** Completes the handshake on a raw upgrade socket and registers the connection. */
  accept(
    req: IncomingMessage,
    socket: Socket,
    key: string,
    meta: WsMeta,
    greeting: unknown,
  ): WsConnection {
    socket.write(
      [
        "HTTP/1.1 101 Switching Protocols",
        "Upgrade: websocket",
        "Connection: Upgrade",
        `Sec-WebSocket-Accept: ${acceptKeyFor(key)}`,
        "X-Content-Type-Options: nosniff",
        "Cache-Control: no-store",
        "",
        "",
      ].join("\r\n"),
    );
    socket.setTimeout(0);
    socket.setNoDelay(true);
    req.removeAllListeners();

    // Cap concurrent connections per device by retiring the oldest ones.
    const sameDevice = [...this.connections].filter(
      (c) => c.meta.accountId === meta.accountId && c.meta.deviceId === meta.deviceId,
    );
    while (sameDevice.length >= 8) {
      sameDevice.shift()?.close(1000, "replaced");
    }

    const conn = new WsConnection(
      socket,
      meta,
      (c, text) => this.handleText(c, text),
      (c) => {
        this.connections.delete(c);
      },
    );
    this.connections.add(conn);
    conn.sendJson(greeting);
    return conn;
  }

  private handleText(conn: WsConnection, text: string): void {
    let message: unknown;
    try {
      message = JSON.parse(text);
    } catch {
      conn.close(1008, "invalid_message");
      return;
    }
    if (typeof message !== "object" || message === null || Array.isArray(message)) {
      conn.close(1008, "invalid_message");
      return;
    }
    const keys = Object.keys(message);
    if (keys.length !== 1 || keys[0] !== "type" || (message as { type?: unknown }).type !== "ping") {
      conn.close(1008, "invalid_message");
      return;
    }
    conn.sendJson({ type: "pong" });
  }

  /** Wakes every connection of the account except those of the source device. */
  broadcastSyncAvailable(
    accountId: string,
    revision: number,
    resetRevision: number,
    sourceDeviceId: string,
  ): void {
    const message = JSON.stringify({
      type: "sync_available",
      revision,
      resetRevision,
      sourceDeviceId,
    });
    for (const conn of this.connections) {
      if (conn.meta.accountId !== accountId) continue;
      if (conn.meta.deviceId.toLowerCase() === sourceDeviceId.toLowerCase()) continue;
      conn.sendText(message);
    }
  }

  /** Closes (4001) every connection of the account whose session family is no longer live
   * (removing a device cascades to its sessions, so that is covered too). */
  reconcile(accountId: string): void {
    for (const conn of this.connections) {
      if (conn.meta.accountId !== accountId) continue;
      if (!this.options.isFamilyActive(conn.meta.family)) {
        conn.close(CLOSE_SESSION_REVOKED, "session_revoked");
      }
    }
  }

  closeAccount(accountId: string): void {
    for (const conn of this.connections) {
      if (conn.meta.accountId === accountId) conn.close(CLOSE_SESSION_REVOKED, "session_revoked");
    }
  }

  closeAll(code: number, reason: string): void {
    for (const conn of this.connections) conn.close(code, reason);
  }

  terminateAll(): void {
    for (const conn of [...this.connections]) conn.terminate();
  }

  private tick(): void {
    for (const conn of [...this.connections]) {
      if (!conn.isOpen) continue;
      if (!conn.alive) {
        conn.terminate();
        continue;
      }
      if (!this.options.isFamilyActive(conn.meta.family)) {
        conn.close(CLOSE_SESSION_REVOKED, "session_revoked");
        continue;
      }
      conn.alive = false;
      conn.ping();
    }
  }

  dispose(): void {
    clearInterval(this.heartbeat);
    this.terminateAll();
  }
}
