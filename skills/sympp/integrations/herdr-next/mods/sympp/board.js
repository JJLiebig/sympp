import { readStarts } from "./controls.js";
import { boardUrl, httpError, networkError, parseBoard } from "./model.js";
import { request } from "./transport.js";

// The loaded mod owns the reads. The factory's writes affect every reader at its origin,
// while a parsed board belongs only to the connection and credentials that obtained it.
const factories = new Map();

export function boardConnection(endpoint, epoch = null, authorization) {
  if (!endpoint) return null;
  let factory = factories.get(endpoint);
  if (!factory || (epoch !== null && factory.epoch !== epoch)) {
    factory = { epoch, writes: 0, lastWrite: 0, local: null, remote: null };
    factories.set(endpoint, factory);
  }
  const scope = authorization === undefined ? "local" : "remote";
  if (!factory[scope] || factory[scope].authorization !== authorization) {
    factory[scope] = { endpoint, factory, scope, authorization, latest: null, pending: null, disconnected: false, denied: false };
  }
  return factory[scope];
}

export function currentConnection(connection) {
  const factory = factories.get(connection.endpoint);
  return factory === connection.factory && factory[connection.scope] === connection;
}

async function fetchBoard(connection, cached, since, stillCurrent) {
  const { endpoint, authorization } = connection;
  let response;
  try {
    const headers = {};
    if (cached?.etag) headers["If-None-Match"] = cached.etag;
    if (authorization) headers.Authorization = authorization;
    response = await request(boardUrl(endpoint), { headers });
  } catch (caught) {
    return { error: caught.userMessage || networkError(endpoint), unreachable: caught.status === undefined };
  }
  if (!stillCurrent()) return null;
  if (response.status === 202) return { ...cached, since, building: true };
  if (response.status === 304 && cached?.etag) return { ...cached, since, receivedAt: Date.now(), building: false };
  if (!response.ok) return { error: httpError(response.status), denied: response.status === 401 || response.status === 403 };

  try {
    const payload = await response.json().catch(() => null);
    return {
      board: parseBoard(payload), payload, since, receivedAt: Date.now(),
      etag: typeof payload.etag === "string" ? payload.etag : null,
      building: payload.refresh_pending === true,
    };
  } catch (caught) {
    return { error: caught.message };
  }
}

export function readBoard(connection, cx, { unconditional, after, needed }) {
  const { factory } = connection;
  const boundary = factory.lastWrite;
  const inFlight = connection.pending;
  if (inFlight?.boundary === boundary) {
    if (inFlight.since === null || inFlight.since >= after) return inFlight.promise;
    // Refresh may follow a write from another client, which leaves our local boundary unchanged.
    return inFlight.promise.then(() => needed() && currentConnection(connection) && !factory.writes
      ? readBoard(connection, cx, { unconditional, after, needed }) : null);
  }

  const cached = unconditional || connection.disconnected ? null : connection.latest;
  const stillCurrent = () => currentConnection(connection) && !factory.writes && factory.lastWrite === boundary;
  const pending = { boundary, since: null, promise: null };
  pending.promise = new Promise((resolve) => {
    // Native fetch inherits the owner of the host call. Start in an ownerless
    // timer so the request can settle after the initiating view closes.
    cx.timer.after(0, () => {
      if (!stillCurrent()) { resolve(null); return; }
      pending.since = readStarts();
      resolve(fetchBoard(connection, cached, pending.since, stillCurrent));
    }, { owner: null });
  }).then((outcome) => {
    if (connection.pending === pending) connection.pending = null;
    if (!outcome || !stillCurrent()) return null;
    if (outcome.denied) {
      connection.denied = true;
      connection.latest = null;
    }
    if (outcome.unreachable) connection.disconnected = true;
    if (outcome.board) {
      connection.denied = false;
      connection.disconnected = false;
      connection.latest = outcome;
    }
    return outcome;
  });
  connection.pending = pending;
  return pending.promise;
}
