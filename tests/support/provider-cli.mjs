#!/usr/bin/env node
// External CLI stand-in (`gh`, `hc`). No product imports, ledger access or live network path.
import { basename } from 'node:path';
import { once } from 'node:events';
import { createInterface } from 'node:readline';

let rpc;
if (basename(process.argv[1]) === 'hc' && process.argv[2] === 'connect') {
  const input = createInterface({ input: process.stdin });
  rpc = JSON.parse((await once(input, 'line'))[0]);
  input.close();
  process.stdin.pause();
}

const endpoint = new URL('/cli', process.env.ACCEPTANCE_PROVIDER);
if (endpoint.hostname !== '127.0.0.1' || endpoint.protocol !== 'http:') {
  throw new Error('Synthetic provider must be loopback HTTP');
}
const response = await fetch(endpoint, {
  method: 'POST', headers: { 'content-type': 'application/json' },
  body: JSON.stringify({ program: basename(process.argv[1]), argv: process.argv.slice(2), rpc }),
  signal: AbortSignal.timeout(4_000),
});
const result = await response.json();
process.stdout.write(result.stdout);
process.exitCode = result.exitCode;
