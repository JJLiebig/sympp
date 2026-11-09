import { execFileSync } from 'node:child_process';
import { appendFileSync } from 'node:fs';
import { pathToFileURL } from 'node:url';

export function windowsJobs(event, paths = []) {
  if (event !== 'pull_request') return { runtime: true, frontend: true };
  // Both jobs consume the Node toolchain and frontend/Herdr build inputs.
  const frontend = paths.some(path => /^(\.github\/workflows\/|elixir\/assets\/|integrations\/herdr-next\/|packages\/sympp\/herdr\/)/.test(path)
    || ['elixir/mise.toml', 'package.json', 'package-lock.json', '.npmrc', '.gitattributes', '.gitmodules'].includes(path));
  const runtime = frontend || paths.some(path => /^(packages\/sympp\/|skills\/sympp\/|scripts\/|tests\/|\.e2e\/|elixir\/config\/|elixir\/rel\/|elixir\/priv\/)/.test(path)
    || /\.(ps1|psm1|psd1|cmd|bat)$/i.test(path)
    || ['elixir/mix.exs', 'elixir/mix.lock', 'elixir/Makefile', 'e2e.config.ts'].includes(path));
  return { runtime, frontend };
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const event = process.env.GITHUB_EVENT_NAME;
  // Compare the PR merge base with its head, not the synthetic merge commit.
  // Disabling rename detection includes both paths, without an API file limit.
  const paths = event === 'pull_request'
    ? execFileSync('git', ['diff', '--name-only', '-z', '--no-renames',
      `${process.env.PR_BASE_SHA}...${process.env.PR_HEAD_SHA}`], { encoding: 'utf8' }).split('\0').filter(Boolean)
    : [];
  const result = windowsJobs(event, paths);
  for (const [job, needed] of Object.entries(result)) {
    appendFileSync(process.env.GITHUB_OUTPUT, `${job}=${needed}\n`);
  }
  console.log(`runtime=${result.runtime} frontend=${result.frontend}`);
}
