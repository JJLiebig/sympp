#!/usr/bin/env bash
set -euo pipefail
# Read only the chosen unit's install settings; do not print its environment.
python3 - "$@" <<'PY'
import fcntl
import json
import urllib.request
import os
from pathlib import Path
import shlex
import subprocess
import sys
unit = sys.argv[1] + '.service'
raw = subprocess.check_output(['systemctl', '--user', 'show', unit, '-p', 'Environment', '--value'], text=True)
values = dict(item.split('=', 1) for item in shlex.split(raw) if '=' in item)
if not values.get('SYMPP_HOME') or not values.get('SYMPP_SERVICE_HOST'):
    raise SystemExit('Factory service is not installed. Run its installer first.')
if len(sys.argv) > 2 and sys.argv[2] != values.get('SYMPP_BACKEND_PORT', '19998'):
    raise SystemExit('Selected factory service does not match the saved server port. Rerun setup with its service name.')
allowed = ['PATH', 'SYMPP_HOME', 'SYMPP_DATABASE', 'SYMPP_REPOS_ROOT', 'SYMPP_BACKEND_PORT', 'SYMPP_SERVICE_HOST', 'SYMPP_WORKFLOW_FILE', 'ERL_FLAGS', 'SYMPP_SERVICE_SOURCE', 'SYMPP_SERVICE_REF']
env = dict(os.environ, **{key: values[key] for key in allowed if key in values})
env['SYMPP_SERVICE_NAME'] = sys.argv[1]
fragment = subprocess.check_output(['systemctl', '--user', 'show', unit, '-p', 'FragmentPath', '--value'], text=True).strip()
env['XDG_CONFIG_HOME'] = str(Path(fragment).resolve().parents[2])
# Use the saved factory source and ref.
source = Path(values.get('SYMPP_SERVICE_SOURCE', str(Path.home() / '.local/share/symphony-plus-plus/source')))
ref = values.get('SYMPP_SERVICE_REF', 'main')
lock_path = Path(os.environ.get('XDG_RUNTIME_DIR', '/run/user/' + str(os.getuid()))) / 'sympp-factory-update.lock'
lock_path.parent.mkdir(parents=True, exist_ok=True)
lock = open(lock_path, 'a')
try:
    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
except BlockingIOError:
    raise SystemExit('Another factory update is running. Retry later.')
env['SYMPP_UPDATE_LOCK_FD'] = str(lock.fileno())
if subprocess.check_output(['git', '-C', str(source), 'status', '--porcelain'], text=True).strip():
    raise SystemExit('Factory checkout has local changes. Commit or remove them before updating.')
subprocess.run(['git', '-C', str(source), 'fetch', '--quiet', 'origin', ref], check=True, env={**env, 'GIT_TERMINAL_PROMPT': '0'})
target = subprocess.check_output(['git', '-C', str(source), 'rev-parse', 'FETCH_HEAD'], text=True).strip()
pid = subprocess.check_output(['systemctl', '--user', 'show', unit, '-p', 'MainPID', '--value'], text=True).strip()
port = values.get('SYMPP_BACKEND_PORT', '19998')
sockets = subprocess.check_output(['ss', '-H', '-ltnpe', 'sport = :' + port], text=True)
local_addresses = {'127.0.0.1:' + port, '0.0.0.0:' + port, '*:' + port, '[::]:' + port}
listeners = [line for line in sockets.splitlines() if line.split()[3] in local_addresses and 'v6only:1' not in line]
owns_listener = bool(listeners) and pid != '0' and all('pid=' + pid + ',' in line for line in listeners)
if listeners and not owns_listener:
    raise SystemExit('Saved factory endpoint belongs to another process. Rerun setup with its service name.')
try:
    with urllib.request.urlopen('http://127.0.0.1:' + port + '/mcp/readiness', timeout=3) as response:
        health = json.load(response)
    running = health.get('source', {}).get('revision') if owns_listener and health.get('status') == 'ok' and health.get('ledger', {}).get('reachable') is True else None
except (OSError, ValueError):
    running = None
subprocess.run(['git', '-C', str(source), 'checkout', '--quiet', '--detach', target], check=True)
def non_runtime(path):
    return (path.startswith(('skills/', 'docs/', 'plans/'))
            or (path.startswith('packages/sympp/skills/') and path.endswith('.md'))
            or ('/' not in path and path.endswith('.md')))
needs_build = running != target
if running and needs_build:
    diff = subprocess.run(['git', '-C', str(source), 'diff', '--name-only', '-z', '--no-renames', running, target], capture_output=True)
    if diff.returncode == 0:
        paths = diff.stdout.decode().rstrip('\0').split('\0') if diff.stdout else []
        needs_build = not all(non_runtime(path) for path in paths)
if not needs_build:
    subprocess.run(['git', '-C', str(source), 'config', 'sympp.serviceRef', ref], check=True)
    subprocess.run(['git', '-C', str(source), 'config', 'sympp.serviceRevision', target], check=True)
    print('factory: already current' if running == target else 'factory: runtime unchanged')
    raise SystemExit(0)
env['SYMPP_SERVICE_REF'] = ref
result = subprocess.run(['bash', str(source / 'scripts/install-sympp-checkout.sh')], env=env, pass_fds=(lock.fileno(),))
raise SystemExit(result.returncode)
PY
