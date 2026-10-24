#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
python3 - "$root" "$@" <<'PY'
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tomllib

root = Path(sys.argv[1])
args = sys.argv[2:]
check = bool(args and args[0] == '--check')
if check:
    args = args[1:]
if len(args) > 1 or (not check and not args):
    sys.exit('usage: sync-connector-profile.sh [--check] [CCP_CHECKOUT]')
path = root / 'profiles/connector-managed-settings.json'
pin_path = root / 'profiles/PINNED'
try:
    pin = json.loads(pin_path.read_text())
    raw = path.read_bytes()
    if args:
        checkout = args[0]
        commit = pin['ccp_commit'] if check else subprocess.check_output(
            ['git', '-C', checkout, 'rev-parse', 'HEAD'], text=True).strip()
        source = subprocess.check_output(['git', '-C', checkout, 'show',
                    commit + ':policy/profiles/connector-managed-settings.json'])
        codex_source = subprocess.check_output(['git', '-C', checkout, 'show',
                    commit + ':policy/codex-managed-config.toml'])
        codex = tomllib.loads(codex_source.decode())
        codex_hash = hashlib.sha256(codex_source).hexdigest()
        if check and (codex != pin['codex_requirements'] or codex_hash != pin['codex_source_sha256']):
            sys.exit('stale Codex requirements against pinned CCP commit')
        if not check:
            pin.update(codex_requirements=codex, codex_source_sha256=codex_hash)
        if check:
            if json.loads(source) != json.loads(raw):
                sys.exit('stale connector profile against pinned CCP commit')
        else:
            raw = source
            pin.update(ccp_commit=commit, source='policy/profiles/connector-managed-settings.json',
                       profile_version=json.loads(raw)['profile_version'],
                       sha256=hashlib.sha256(raw).hexdigest())
    profile = json.loads(raw)
    if type(profile['profile_version']) is not int or profile['profile_version'] < 1:
        sys.exit('invalid profile_version')
    if not isinstance(profile.get('env'), dict) or not profile.get('otelHeadersHelper'):
        sys.exit('invalid connector profile')
    if profile['profile_version'] != pin['profile_version'] or hashlib.sha256(raw).hexdigest() != pin['sha256']:
        sys.exit('stale connector profile: version/content differs from PINNED')
    if not check:
        path.write_bytes(raw)
        pin_path.write_text(json.dumps(pin, indent=2) + '\n')
    print('connector profile matches PINNED' + (' and CCP source' if args else ' (offline digest)'))
except (OSError, ValueError, KeyError, subprocess.CalledProcessError):
    sys.exit('connector profile validation failed; check PINNED and CCP source')
PY
