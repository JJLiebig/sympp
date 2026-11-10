#!/usr/bin/env python3
"""Stage an exact-revision Linux release using the published runtime contract.

The portable launcher verifier is PowerShell-only. This installer consumes the
same platform manifest, archive digest, MCP contract and dashboard fingerprint,
without requiring PowerShell on a Linux factory. A miss leaves source fallback
to the caller; no unverified files are placed in the selected release.
"""
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import stat
import subprocess
import sys
import tempfile
import urllib.parse
import urllib.request
import zipfile


def digest(data):
    return hashlib.sha256(data).hexdigest()


def download(url):
    parsed = urllib.parse.urlparse(url)
    if parsed.scheme != 'https' and not (parsed.scheme == 'http' and parsed.hostname in ('127.0.0.1', 'localhost', '::1')):
        raise ValueError('Runtime downloads require HTTPS or loopback HTTP')
    with urllib.request.urlopen(url, timeout=45) as response:
        return response.read()


def install(revision, destination):
    if platform.machine() not in ('x86_64', 'AMD64'):
        raise ValueError('No published Linux runtime for this architecture')
    repo = Path(__file__).resolve().parents[1]
    contract = json.loads((repo / 'elixir/priv/symphony_plus_plus/mcp_contract.json').read_text())['mcp_contract_fingerprint']
    plugin = json.loads((repo / 'packages/sympp/package.json').read_text())['name']
    base = os.environ.get('SYMPP_RUNTIME_RELEASE_URL', 'https://github.com/JJLiebig/sympp/releases/download/sympp-runtime-stable').rstrip('/')
    name = 'sympp-runtime-' + revision + '-linux-x64'
    manifest = json.loads(download(base + '/' + name + '.manifest.json'))
    if (manifest['source_revision'] != revision or manifest['platform'] != 'linux-x64'
            or manifest['plugin']['name'] != plugin
            or manifest['launcher_contract']['mcp_contract_fingerprint'] != contract):
        raise ValueError('Runtime identity does not match checkout')
    # Use the revision-specific assets, never the moving stable channel selection.
    archive = download(base + '/' + name + '.zip')
    if digest(archive) != manifest['artifact']['sha256']:
        raise ValueError('Runtime archive digest mismatch')
    with tempfile.TemporaryDirectory(dir=destination.parent, prefix='runtime-') as temporary:
        stage = Path(temporary)
        archive_file = stage / 'runtime.zip'
        archive_file.write_bytes(archive)
        extract = stage / 'release'
        extract.mkdir()
        with zipfile.ZipFile(archive_file) as zipped:
            for member in zipped.infolist():
                target = extract / member.filename
                if extract.resolve() not in target.resolve().parents or stat.S_ISLNK(member.external_attr >> 16):
                    raise ValueError('Unsafe runtime archive path')
                zipped.extract(member, extract)
                if not member.is_dir():
                    target.chmod((member.external_attr >> 16) & 0o777)
        payload_file = extract / 'runtime-manifest.json'
        if digest(payload_file.read_bytes()) != manifest['payload_manifest']['sha256']:
            raise ValueError('Runtime payload manifest digest mismatch')
        payload = json.loads(payload_file.read_text())
        for key in ('source_revision', 'platform', 'plugin', 'launcher_contract', 'dashboard', 'backend'):
            if payload[key] != manifest[key]:
                raise ValueError('Runtime payload identity mismatch')
        dashboard = (extract / payload['dashboard']['relative_path']).resolve()
        if extract.resolve() not in dashboard.parents or not (dashboard / 'index.html').is_file():
            raise ValueError('Runtime dashboard missing')
        lines = sorted(str(file.relative_to(dashboard)).replace('\\', '/') + ' ' + digest(file.read_bytes())
                       for file in dashboard.rglob('*') if file.is_file())
        if digest('\n'.join(lines).encode()) != payload['dashboard']['fingerprint']:
            raise ValueError('Runtime dashboard fingerprint mismatch')
        if not (extract / 'bin/symphony_elixir').is_file():
            raise ValueError('Runtime release entrypoint missing')
        # CI's native Erlang/SQLite binaries may require newer host libraries.
        # Evaluate without starting applications, opening listeners or migrating
        # the factory ledger, before replacing the running service.
        probe_env = {**os.environ, 'SYMPP_SERVICE_MODE': '0',
                     'SYMPP_RUNTIME_ARTIFACT': '1', 'SYMPP_RUNTIME_ARTIFACT_ACKNOWLEDGED': '1',
                     'SYMPP_LOGS_ROOT': str(stage / 'logs'), 'SYMPP_BACKEND_PORT': '0',
                     'RELEASE_TMP': str(stage / 'tmp')}
        subprocess.run([str(extract / 'bin/symphony_elixir'), 'eval',
                        '{:ok, db} = Exqlite.Sqlite3.open(":memory:"); :ok = Exqlite.Sqlite3.close(db)'],
                       env=probe_env, check=True, timeout=30)
        shutil.copytree(extract, destination, dirs_exist_ok=True)


if __name__ == '__main__':
    try:
        install(sys.argv[1], Path(sys.argv[2]))
    except Exception as error:
        # Diagnostics stay in install.log, including why a download was unavailable.
        print(type(error).__name__ + ': ' + str(error), file=sys.stderr)
        sys.exit(1)
