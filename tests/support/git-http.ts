import { spawn } from 'node:child_process';
import { once } from 'node:events';
import { createServer } from 'node:http';

// A Git remote over smart HTTP, served by Git's own http-backend from disposable
// bare repositories. Clients and the factory clone and fetch it like any remote.
export class GitHttp {
  readonly server = createServer((request, response) => {
    const url = new URL(request.url!, 'http://127.0.0.1');
    const backend = spawn('git', ['http-backend'], {
      env: {
        PATH: process.env.PATH, GIT_PROJECT_ROOT: this.root, GIT_HTTP_EXPORT_ALL: '1',
        GIT_CONFIG_NOSYSTEM: '1', GIT_CONFIG_GLOBAL: '/dev/null',
        REQUEST_METHOD: request.method!, PATH_INFO: decodeURIComponent(url.pathname), QUERY_STRING: url.search.slice(1),
        CONTENT_TYPE: request.headers['content-type'] ?? '', REMOTE_ADDR: '127.0.0.1',
      },
      stdio: ['pipe', 'pipe', 'ignore'],
    });
    request.pipe(backend.stdin);
    let head = Buffer.alloc(0);
    let started = false;
    backend.stdout.on('data', (chunk: Buffer) => {
      if (started) return void response.write(chunk);
      head = Buffer.concat([head, chunk]);
      const end = head.indexOf('\r\n\r\n');
      if (end < 0) return;
      started = true;
      let status = 200;
      for (const line of head.subarray(0, end).toString().split('\r\n')) {
        const [name, ...value] = line.split(':');
        if (name.toLowerCase() === 'status') status = Number.parseInt(value.join(':'), 10);
        else response.setHeader(name, value.join(':').trim());
      }
      response.writeHead(status);
      response.write(head.subarray(end + 4));
    });
    backend.on('close', () => response.end());
  });

  constructor(readonly root: string) {}

  async start() {
    this.server.listen(0, '127.0.0.1');
    await once(this.server, 'listening');
    return `http://127.0.0.1:${(this.server.address() as { port: number }).port}`;
  }

  async stop() {
    const closed = once(this.server, 'close');
    this.server.close();
    this.server.closeAllConnections();
    await closed;
  }
}
