import type { Context } from "./http.js";
import {
  LIMITS,
  asObject,
  expectKeys,
  parseCollectionsFilter,
  parseQueryInt,
  readInteger,
  readMutation,
  readQuery,
  readUuid,
} from "./validation.js";
import type { Mutation } from "./validation.js";
import { validationError } from "./errors.js";

export function status(c: Context): void {
  const session = c.auth;
  readQuery(c.url, []);
  const state = c.store.accountState(session.accountId);
  c.json(200, {
    serverRevision: state.serverRevision,
    resetRevision: state.resetRevision,
    hasCloudData: state.hasCloudData,
    collectionCounts: state.collectionCounts,
    lastModifiedAt: c.store.lastModifiedAt(session.accountId),
  });
}

export function changes(c: Context): void {
  const session = c.auth;
  const query = readQuery(c.url, ["since", "limit", "collections"]);
  const since = parseQueryInt(query.get("since"), "since", 0, 0, Number.MAX_SAFE_INTEGER);
  const limit = parseQueryInt(query.get("limit"), "limit", LIMITS.defaultChangesLimit, 1, LIMITS.maxChangesLimit);
  const collections = parseCollectionsFilter(query.get("collections"));
  c.json(200, c.store.readChanges(session.accountId, since, limit, collections));
}

export async function push(c: Context): Promise<void> {
  const session = c.auth;
  const body = await c.readJson();
  expectKeys(body, "Request", ["deviceId", "mode", "baseRevision", "mutations"]);
  const deviceId = readUuid(body, "deviceId");
  if (deviceId.toLowerCase() !== session.deviceId.toLowerCase()) {
    throw validationError('"deviceId" does not match the authenticated device.');
  }
  const mode = body["mode"];
  if (mode !== "delta" && mode !== "replaceCloud") {
    throw validationError('"mode" must be "delta" or "replaceCloud".');
  }
  readInteger(body, "baseRevision", 0, Number.MAX_SAFE_INTEGER);
  const rawMutations = body["mutations"];
  if (!Array.isArray(rawMutations)) throw validationError('"mutations" must be an array.');
  if (rawMutations.length > LIMITS.maxMutationsPerPush) {
    throw validationError(`"mutations" may contain at most ${LIMITS.maxMutationsPerPush} entries.`);
  }
  const mutations: Mutation[] = rawMutations.map((value: unknown, index: number) => {
    asObject(value, `mutations[${index}]`);
    return readMutation(value, index);
  });

  const result = c.store.tx(() => c.store.applyPush(session.accountId, session.deviceId, mode, mutations, Date.now()));
  if (result.changed) {
    c.app.hub.broadcastSyncAvailable(session.accountId, result.currentRevision, result.resetRevision, session.deviceId);
  }
  c.json(200, {
    currentRevision: result.currentRevision,
    resetRevision: result.resetRevision,
    acceptedCount: result.acceptedCount,
    conflicts: result.conflicts,
  });
}
