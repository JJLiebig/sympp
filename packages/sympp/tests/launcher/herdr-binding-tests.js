"use strict";

const assert = require("assert/strict");
const path = require("path");
const { decodeHerdrBinding, herdrMetadataArgs } = require(path.resolve(__dirname, "../../scripts/start-sympp-mcp-bridge.js"));
const { withTerminal } = require(path.resolve(__dirname, "../../scripts/sympp-session-location.js"));

const encoded = Buffer.from(JSON.stringify({ role: "worker", work_package_id: "wp-test", show_inspector: false })).toString("base64url");
const binding = decodeHerdrBinding(encoded);
const args = herdrMetadataArgs(binding, "http://127.0.0.1:19998/");

assert.equal(decodeHerdrBinding("clear"), null);
assert.ok(args.includes("sympp_role=worker"));
assert.ok(args.includes("sympp_work_package_id=wp-test"));
assert.ok(args.includes("sympp_show_inspector=false"));
assert.ok(args.includes("sympp_endpoint=http://127.0.0.1:19998"));
assert.ok(args.includes("sympp_work_request_id"));

const identity = { core_id: "core-a", core_name: "build-desk", terminal_id: "t3", pid: 41, process_id: 42, client_id: "client-a",
  labels: { "sympp.role": "chief", "sympp.domain": "Widgets", "sympp.session_id": "other", where: "desk" } };
const request = { jsonrpc: "2.0", id: 1, method: "tools/call", params: { name: "read_work_request", arguments: {}, _meta: { another: true } } };
const forwarded = JSON.parse(withTerminal(JSON.stringify(request), identity));
assert.equal(forwarded.params._meta.another, true);
assert.deepEqual(forwarded.params.arguments, {});
assert.deepEqual(forwarded.params._meta.herdr, {
  core_id: "core-a", core_name: "build-desk", terminal_id: "t3", labels: { "sympp.role": "chief", "sympp.domain": "Widgets" },
}, "only the chief role and domain labels travel, and never a pid");
const unlabeled = JSON.parse(withTerminal(JSON.stringify(request), { ...identity, core_name: null, labels: {} }));
assert.deepEqual(unlabeled.params._meta.herdr, { core_id: "core-a", terminal_id: "t3" });
assert.equal(JSON.parse(withTerminal(JSON.stringify(request), null)).params._meta.herdr, undefined);
const notification = { jsonrpc: "2.0", method: "notifications/initialized" };
assert.deepEqual(JSON.parse(withTerminal(JSON.stringify(notification), identity)), notification);

process.stdout.write("Herdr binding adapter tests passed.\n");
