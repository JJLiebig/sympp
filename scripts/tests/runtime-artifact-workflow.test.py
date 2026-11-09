"""Exercise the workflow's retry decisions with a fake GitHub CLI (bash + jq)."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import textwrap
import unittest

WORKFLOW = Path(__file__).resolve().parents[2] / '.github/workflows/sympp-runtime-artifact.yml'
PLAN = textwrap.dedent(WORKFLOW.read_text().split('      - name: Select required builds or missing macOS\n', 1)[1]
                       .split('        run: |\n', 1)[1].split('\n  build-runtime-artifact:', 1)[0])
PRUNE_PATH = WORKFLOW.parents[2] / 'scripts/prune-sympp-runtime-assets.py'
spec = importlib.util.spec_from_file_location('prune_runtime', PRUNE_PATH)
prune = importlib.util.module_from_spec(spec)
spec.loader.exec_module(prune)
SHA = 'a' * 40


class RetryPlanTest(unittest.TestCase):
    def plan(self, *, retry=True, branch='main', current=SHA, published=SHA, mac=False, available=True):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'gh').write_text('''#!/bin/bash
set -eu
if [ "$1" = api ]; then
  echo "$FAKE_CURRENT"
else
  [ "$FAKE_AVAILABLE" = True ] || exit 1
  mkdir -p channel
  cp "$FAKE_MANIFEST" "channel/sympp-runtime-artifacts-${FAKE_CHANNEL}.json"
fi
''')
            (root / 'gh').chmod(0o755)
            (root / 'manifest.json').write_text(json.dumps({
                'source_revision': published,
                'artifacts': [{'platform': {'os': 'macos', 'arch': 'aarch64'}}] if mac else [],
            }))
            output = root / 'output'
            output.touch()
            env = dict(os.environ, PATH=f'{root}:{os.environ["PATH"]}',
                       GITHUB_OUTPUT=str(output), GITHUB_SHA=SHA, GITHUB_REF_NAME=branch,
                       GITHUB_REPOSITORY='example/repo', RETRY_MACOS=str(retry).lower(),
                       FAKE_CURRENT=current, FAKE_AVAILABLE=str(available),
                       FAKE_MANIFEST=str(root / 'manifest.json'),
                       FAKE_CHANNEL='stable')
            result = subprocess.run(['bash', '-eu', '-o', 'pipefail', '-c', PLAN],
                                    cwd=root, env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            return dict(line.split('=', 1) for line in output.read_text().splitlines())

    def test_required_builds_never_wait_for_macos(self):
        result = self.plan(retry=False)
        self.assertEqual(result['build'], 'true')
        self.assertEqual([item['platform'] for item in json.loads(result['matrix'])['include']],
                         ['linux-x64', 'windows-x64'])

    def test_only_missing_current_macos_is_built_for_stable(self):
        for branch in ['main']:
            with self.subTest(branch=branch):
                result = self.plan(branch=branch)
                self.assertEqual(result['build'], 'true')
                self.assertEqual([item['platform'] for item in json.loads(result['matrix'])['include']],
                                 ['macos-arm64'])

    def test_no_build_when_current_or_not_ready(self):
        for args in [dict(mac=True), dict(current='b' * 40),
                     dict(published='b' * 40), dict(available=False)]:
            with self.subTest(args=args):
                self.assertEqual(self.plan(**args), {})

    def test_publication_uploads_only_rebuilt_platforms(self):
        upload = textwrap.dedent(WORKFLOW.read_text().split('      - name: Upload platform release assets\n', 1)[1]
                                .split('        run: |\n', 1)[1].split('      - name:', 1)[0])
        for retry, platforms in [(True, ['macos-arm64']), (False, ['linux-x64', 'windows-x64'])]:
            with self.subTest(retry=retry), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                assets = root / 'artifacts/sympp-runtime-release'
                assets.mkdir(parents=True)
                for platform in ['linux-x64', 'windows-x64', 'macos-arm64']:
                    for suffix in ['zip', 'manifest.json']:
                        (assets / f'sympp-runtime-{SHA}-{platform}.{suffix}').touch()
                (root / 'gh').write_text('#!/bin/bash\nprintf "%s\\n" "$@" > "$UPLOAD_ARGS"\n')
                (root / 'gh').chmod(0o755)
                env = dict(os.environ, PATH=f'{root}:{os.environ["PATH"]}',
                           RELEASE_TAG='test-runtime', RETRY_MACOS=str(retry).lower(),
                           UPLOAD_ARGS=str(root / 'args'))
                subprocess.run(['bash', '-eu', '-o', 'pipefail', '-c', upload],
                               cwd=root, env=env, check=True)
                uploaded = (root / 'args').read_text().splitlines()[3:-1]
                expected = {f'artifacts/sympp-runtime-release/sympp-runtime-{SHA}-{platform}.{suffix}'
                            for platform in platforms for suffix in ['zip', 'manifest.json']}
                self.assertEqual(set(uploaded), expected)


class PruneTest(unittest.TestCase):
    def assets(self):
        return [dict(id=build * 10 + index,
                     name=f'sympp-runtime-{build:040x}-{platform}.{suffix}',
                     created_at=f'2026-11-{build + 1:02d}T00:00:00Z')
                for build in range(14)
                for index, (platform, suffix) in enumerate(
                    (p, s) for p in ['linux-x64', 'windows-x64', 'macos-arm64']
                    for s in ['zip', 'manifest.json'])]

    def test_retains_newest_groups_channel_references_and_unrelated_assets(self):
        assets = self.assets()
        unrelated = ['sympp-runtime-artifacts-stable.json', 'notes.zip',
                     'sympp-runtime-short-linux-x64.zip',
                     f'sympp-runtime-{2:040x}-linux-x64.zip.bak',
                     f'sympp-runtime-{2:040x}-linux-x64.tar.gz']
        assets += [dict(id=1000 + i, name=name) for i, name in enumerate(unrelated)]
        manifest = {'source_revision': f'{0:040x}', 'artifacts': [
            {'source_revision': f'{1:040x}', 'archive': {
                'url': f'https://example.com/sympp-runtime-{2:040x}-macos-arm64.zip'}}]}
        deleted = prune.select_deletions(list(reversed(assets)), manifest, SHA)
        self.assertEqual({a['id'] for a in deleted}, set(range(30, 36)))
        self.assertEqual(prune.select_deletions(self.assets()[-60:], {}, SHA), [])

    def test_build_recency_uses_latest_asset_creation(self):
        assets = self.assets()
        assets[0]['created_at'] = '2026-12-01T00:00:00Z'
        deleted = prune.select_deletions(assets, {}, SHA)
        self.assertEqual({a['id'] // 10 for a in deleted}, {1, 2, 3, 4})

    def test_retains_older_revision_being_republished(self):
        deleted = prune.select_deletions(self.assets(), {}, f'{1:040x}')
        self.assertEqual({a['id'] // 10 for a in deleted}, {0, 2, 3})

    def test_cli_paginates_protects_channel_logs_and_stops_on_delete_failure(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'assets.json').write_text(json.dumps([self.assets()[:42], self.assets()[42:]]))
            (root / 'gh').write_text('''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
args = sys.argv[1:]
with open('calls.jsonl', 'a') as log:
    log.write(json.dumps(args) + '\\n')
if args[:3] == ['api', '--method', 'DELETE']:
    sys.exit(int(os.environ.get('FAIL_DELETE', '0')))
elif args[:3] == ['api', '--paginate', '--slurp']:
    print(Path('assets.json').read_text())
elif args[0] == 'api':
    print('{"id": 123}')
else:
    print(json.dumps({'source_revision': '0' * 40}))
''')
            (root / 'gh').chmod(0o755)
            pages = json.loads((root / 'assets.json').read_text())
            pages[1].append({'name': 'sympp-runtime-artifacts-stable.json', 'id': 999})
            (root / 'assets.json').write_text(json.dumps(pages))
            env = dict(os.environ, PATH=f'{root}:{os.environ["PATH"]}',
                       GITHUB_REPOSITORY='example/repo', RELEASE_TAG='test-runtime',
                       RELEASE_CHANNEL='stable', GITHUB_SHA=SHA)
            for failure in [0, 1]:
                (root / 'calls.jsonl').unlink(missing_ok=True)
                result = subprocess.run(['python3', str(PRUNE_PATH)], cwd=root,
                                        env=dict(env, FAIL_DELETE=str(failure)),
                                        capture_output=True, text=True)
                self.assertEqual(result.returncode == 0, failure == 0, result.stderr)
                calls = [json.loads(line) for line in (root / 'calls.jsonl').read_text().splitlines()]
                deletes = [c for c in calls if c[:3] == ['api', '--method', 'DELETE']]
                self.assertEqual(len(deletes), 1 if failure else 18)
                self.assertEqual(deletes[0][-1], 'repos/example/repo/releases/assets/10')
                self.assertIn('Deleting sympp-runtime-', result.stdout)


if __name__ == '__main__':
    unittest.main()
