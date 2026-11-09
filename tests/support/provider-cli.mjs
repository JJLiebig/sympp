#!/usr/bin/env node
// External CLI stand-in (`gh`, `hc`). No product imports, ledger access or live network path.
import { basename } from 'node:path';

const endpoint = new URL('/cli', process.env.ACCEPTANCE_PROVIDER);
if (endpoint.hostname !== '127.0.0.1' || endpoint.protocol !== 'http:') {
  throw new Error('Synthetic provider must be loopback HTTP');
}
const response = await fetch(endpoint, {
  method: 'POST', headers: { 'content-type': 'application/json' },
  body: JSON.stringify({ program: basename(process.argv[1]), argv: process.argv.slice(2) }),
  signal: AbortSignal.timeout(4_000),
});
const result = await response.json();
process.stdout.write(result.stdout);
process.exitCode = result.exitCode;
