#!/usr/bin/env bash
set -euo pipefail

[[ "$(uname -s)" == Linux ]] || { echo 'This installer requires Linux.' >&2; exit 1; }
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export SYMPP_SERVICE_SOURCE="$repo_root"
service_revision="$(git -C "$repo_root" rev-parse HEAD)"
service_ref="${SYMPP_SERVICE_REF:-$(git -C "$repo_root" symbolic-ref --short -q HEAD || true)}"
if [[ -z "$service_ref" && "$(git -C "$repo_root" config --get sympp.serviceRevision || true)" == "$service_revision" ]]; then
  service_ref="$(git -C "$repo_root" config --get sympp.serviceRef || true)"
fi
export SYMPP_SERVICE_REF="${service_ref:-$service_revision}"
export SYMPP_HOME="${SYMPP_HOME:-$HOME/.agents/splusplus}"
export SYMPP_REPOS_ROOT="${SYMPP_REPOS_ROOT:-$HOME/Code}"
export SYMPP_DATABASE="${SYMPP_DATABASE:-$SYMPP_HOME/symphony_plus_plus.sqlite3}"
export SYMPP_SERVICE_HOST="${SYMPP_SERVICE_HOST:?Set SYMPP_SERVICE_HOST to the machine tailnet IPv4 address}"
export SYMPP_BACKEND_PORT="${SYMPP_BACKEND_PORT:-19998}"
export SYMPP_SERVICE_NAME="${SYMPP_SERVICE_NAME:-sympp}"
export SYMPP_SERVICE_CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
[[ "$SYMPP_HOME" == /* && "$SYMPP_DATABASE" == /* && "$SYMPP_REPOS_ROOT" == /* ]] || { echo 'Factory home, ledger and repos root paths must be absolute.' >&2; exit 1; }
[[ "$SYMPP_SERVICE_NAME" =~ ^[a-zA-Z0-9_-]+$ ]] || { echo 'Invalid service name.' >&2; exit 1; }
systemctl --user show-environment >/dev/null
command -v ss >/dev/null
mkdir -p "$SYMPP_HOME/service"
if [[ -z "${SYMPP_UPDATE_LOCK_FD:-}" ]]; then
  exec {SYMPP_UPDATE_LOCK_FD}>>"${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/sympp-factory-update.lock"
fi
flock -n "$SYMPP_UPDATE_LOCK_FD" || { echo 'Another factory update is running. Retry later.' >&2; exit 1; }

# Build before stopping the existing service. Never select a substitute ledger.
mkdir -p "$SYMPP_HOME/logs"
build_log="$SYMPP_HOME/logs/install.log"
(
set -e
cd "$repo_root/elixir" || exit 1
mise install || exit 1
mise exec -- npm --prefix assets ci || exit 1
mise exec -- npm --prefix assets run build || exit 1
mise exec -- mix local.hex --force || exit 1
mise exec -- mix local.rebar --force || exit 1
MIX_ENV=prod mise exec -- mix deps.get --only prod || exit 1
export SYMPP_SOURCE_REVISION="$(git -C "$repo_root" rev-parse HEAD)"
MIX_ENV=prod mise exec -- mix release symphony_elixir --overwrite || exit 1
) >"$build_log" 2>&1 || {
  echo "Factory build failed for ${service_revision:0:12}. Inspect $build_log" >&2
  exit 1
}
cd "$repo_root/elixir"
export SYMPP_SOURCE_REVISION="$service_revision"

git -C "$repo_root" config sympp.serviceRef "$SYMPP_SERVICE_REF"
git -C "$repo_root" config sympp.serviceRevision "$service_revision"

release="$SYMPP_HOME/service/releases/$(date -u +%Y%m%dT%H%M%S)-$$"
mkdir -p "$release" "$SYMPP_HOME/logs" "$SYMPP_SERVICE_CONFIG"
cp -a _build/prod/rel/symphony_elixir/. "$release/"
previous_release="$(readlink -f "$SYMPP_HOME/service/current" || true)"
previous_unit="$release/previous.service"
unit_file="$SYMPP_SERVICE_CONFIG/$SYMPP_SERVICE_NAME.service"
[[ ! -f "$unit_file" ]] || cp "$unit_file" "$previous_unit"

write_unit() {
python3 - <<'PY'
import os
from pathlib import Path

def quoted(value):
    return '"' + value.replace('\\', '\\\\').replace('"', '\\"').replace('%', '%%').replace('\n', '\\n') + '"'

home = os.environ['SYMPP_HOME']
env = {
    'HOME': os.environ['HOME'],
    'PATH': os.environ['PATH'],
    'SYMPP_HOME': home,
    'SYMPP_SERVICE_SOURCE': os.environ['SYMPP_SERVICE_SOURCE'],
    'SYMPP_SERVICE_REF': os.environ['SYMPP_SERVICE_REF'],
    'SYMPP_DATABASE': os.environ['SYMPP_DATABASE'],
    'SYMPP_REPOS_ROOT': os.environ['SYMPP_REPOS_ROOT'],
    'SYMPP_SOURCE_REVISION': os.environ['SYMPP_SOURCE_REVISION'],
    'SYMPP_SERVICE_MODE': '1',
    'SYMPP_SERVICE_HOST': os.environ['SYMPP_SERVICE_HOST'],
    'SYMPP_BACKEND_PORT': os.environ['SYMPP_BACKEND_PORT'],
    'SYMPP_RUNTIME_ARTIFACT': '1',
    'SYMPP_RUNTIME_ARTIFACT_ACKNOWLEDGED': '1',
    'SYMPP_LOGS_ROOT': home + '/logs',
    'SYMPP_OPEN_DASHBOARD': '0',
    'RELEASE_TMP': home + '/service/tmp',
}
for key in ['SYMPP_WORKFLOW_FILE', 'ERL_FLAGS']:
    if os.environ.get(key):
        env[key] = os.environ[key]
unit = '\n'.join([
    '[Unit]', 'Description=sympp factory', 'After=network-online.target', '',
    '[Service]', 'Type=simple', 'UMask=0077', 'Restart=on-failure', 'RestartSec=3',
    'WorkingDirectory=' + home.replace('%', '%%'),
    *['Environment=' + quoted(key + '=' + value) for key, value in env.items()],
    'ExecStart=' + quoted(home + '/service/current/bin/symphony_elixir') + ' start',
    '', '[Install]', 'WantedBy=default.target', '',
])
Path(home + '/service/tmp').mkdir(parents=True, exist_ok=True)
file = Path(os.environ['SYMPP_SERVICE_CONFIG']) / (os.environ['SYMPP_SERVICE_NAME'] + '.service')
file.write_text(unit)
print('unit: ' + str(file))
PY
}
# Link also supports a scratch XDG_CONFIG_HOME without changing the default unit.
wait_ready() {
python3 - <<'READY'
import json
import os
import time
import subprocess
import urllib.error
import urllib.request

port = os.environ['SYMPP_BACKEND_PORT']
unit = os.environ['SYMPP_SERVICE_NAME'] + '.service'
addresses = {'127.0.0.1:' + port, os.environ['SYMPP_SERVICE_HOST'] + ':' + port}
url = 'http://127.0.0.1:' + port + '/mcp/readiness'
deadline = time.monotonic() + 60
while time.monotonic() < deadline:
    try:
        with urllib.request.urlopen(url, timeout=2) as response:
            health = json.load(response)
        pid = subprocess.check_output(['systemctl', '--user', 'show', unit, '-p', 'MainPID', '--value'], text=True).strip()
        sockets = subprocess.check_output(['ss', '-H', '-ltnp', 'sport = :' + port], text=True).splitlines()
        owned = {line.split()[3] for line in sockets if 'pid=' + pid + ',' in line}
        if (pid != '0' and addresses <= owned and health.get('status') == 'ok'
                and health.get('ledger', {}).get('reachable') is True
                and health.get('source', {}).get('revision') == os.environ['SYMPP_SOURCE_REVISION']):
            break
    except (OSError, ValueError, urllib.error.URLError):
        pass
    time.sleep(0.2)
else:
    raise SystemExit('Service did not become ready. Inspect journalctl --user -u ' + os.environ['SYMPP_SERVICE_NAME'])
READY
}
started=$SECONDS
if write_unit &&
   ln -s "$release" "$SYMPP_HOME/service/current.new" &&
   mv -Tf "$SYMPP_HOME/service/current.new" "$SYMPP_HOME/service/current" &&
   systemctl --user link "$SYMPP_SERVICE_CONFIG/$SYMPP_SERVICE_NAME.service" &&
   systemctl --user daemon-reload &&
   systemctl --user enable "$SYMPP_SERVICE_NAME.service" &&
   systemctl --user restart "$SYMPP_SERVICE_NAME.service" && wait_ready; then
  printf 'factory: updated %s (restart to ready: %ss)\n' "${service_revision:0:12}" "$((SECONDS-started))"
else
  echo "Factory revision ${service_revision:0:12} failed readiness; restoring previous release." >&2
  if [[ -n "$previous_release" && -f "$previous_unit" ]]; then
    ln -s "$previous_release" "$SYMPP_HOME/service/current.rollback"
    mv -Tf "$SYMPP_HOME/service/current.rollback" "$SYMPP_HOME/service/current"
    cp "$previous_unit" "$unit_file"
    mapfile -t previous_settings < <(python3 - "$unit_file" <<'REV'
import shlex, sys
values = {}
for line in open(sys.argv[1]):
    if line.startswith('Environment='):
        value = shlex.split(line[len('Environment='):])[0]
        key, _, value = value.partition('=')
        values[key] = value
for key in ['SYMPP_SOURCE_REVISION', 'SYMPP_BACKEND_PORT', 'SYMPP_SERVICE_HOST']:
    print(values[key])
REV
)
    export SYMPP_SOURCE_REVISION="${previous_settings[0]}"
    export SYMPP_BACKEND_PORT="${previous_settings[1]}"
    export SYMPP_SERVICE_HOST="${previous_settings[2]}"
    systemctl --user daemon-reload
    if systemctl --user restart "$SYMPP_SERVICE_NAME.service" && wait_ready; then
      echo 'factory: previous release restored and ready' >&2
    else
      echo 'factory: rollback failed readiness; inspect the service journal' >&2
    fi
  fi
  exit 1
fi
printf 'service: %s\nendpoint: http://%s:%s\n' "$SYMPP_SERVICE_NAME" "$SYMPP_SERVICE_HOST" "$SYMPP_BACKEND_PORT"
