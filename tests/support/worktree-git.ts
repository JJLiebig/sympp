import { execFile } from 'node:child_process';
import { appendFile, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { promisify } from 'node:util';
import { contract, type Client } from './factory.js';

// Only disposable hosted fixtures invoke Git. Retain failed commands as well as
// successful ones; no Git authentication or global configuration is changed.
export async function git(root: string, cwd: string, ...args: string[]) {
  let receipt: object;
  try {
    const result = await promisify(execFile)('git', args, { cwd,
      env: { PATH: process.env.PATH, HOME: root, LANG: 'C.UTF-8', GIT_CONFIG_NOSYSTEM: '1', GIT_CONFIG_GLOBAL: '/dev/null',
        GIT_AUTHOR_NAME: 'Acceptance', GIT_AUTHOR_EMAIL: 'acceptance@example.invalid',
        GIT_COMMITTER_NAME: 'Acceptance', GIT_COMMITTER_EMAIL: 'acceptance@example.invalid' },
    });
    receipt = { cwd, args, ...result, exitCode: 0 };
    return result.stdout.trim();
  } catch (error: any) {
    receipt = { cwd, args, stdout: error.stdout, stderr: error.stderr, exitCode: error.code };
    throw error;
  } finally {
    await appendFile(join('.e2e', 'worktree-git.jsonl'), `${JSON.stringify(receipt!)}\n`);
  }
}

export async function repository(root: string, name: string) {
  const origin = join(root, `${name}.git`);
  const checkout = join(root, name);
  await git(root, root, 'init', '--bare', origin);
  await git(root, root, 'init', '-b', 'beta', checkout);
  await writeFile(join(checkout, 'README.md'), 'Initial fixture content\n');
  await git(root, checkout, 'add', 'README.md');
  await git(root, checkout, 'commit', '-m', 'Initial fixture');
  await git(root, checkout, 'remote', 'add', 'origin', origin);
  await git(root, checkout, 'push', '-u', 'origin', 'beta');
  return { origin, checkout };
}

// A checkout of github.com/example/service on `branch`, with no fetchable
// remote. Without `originHead` its base comes from the `origin/main` ref alone.
export async function githubCheckout(root: string, name: string, branch: string, originHead = true) {
  const dir = join(root, 'checkouts', name);
  await git(root, root, 'init', '--quiet', '--initial-branch', 'main', dir);
  await git(root, dir, 'commit', '--quiet', '--allow-empty', '-m', 'root');
  await git(root, dir, 'remote', 'add', 'origin', 'https://github.com/example/service.git');
  await git(root, dir, 'update-ref', 'refs/remotes/origin/main', 'HEAD');
  if (originHead) await git(root, dir, 'symbolic-ref', 'refs/remotes/origin/HEAD', 'refs/remotes/origin/main');
  if (branch !== 'main') await git(root, dir, 'checkout', '--quiet', '-b', branch);
  return { dir, switch: (next: string) => git(root, dir, 'checkout', '--quiet', '-b', next) };
}

export async function workPackage(client: Client, origin: string, branch: string) {
  await client.request(`Worktree ${branch}`, 'beta', origin);
  const [id] = (await client.addPackages([contract('Owned worktree', { branch_pattern: branch })]));
  return id as string;
}
