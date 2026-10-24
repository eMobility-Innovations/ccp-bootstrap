#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
export PYTHONDONTWRITEBYTECODE=1
./scripts/sync-connector-profile.sh --check ${CCP_CHECKOUT:+"$CCP_CHECKOUT"}
python3 -m unittest discover -s tests -v
