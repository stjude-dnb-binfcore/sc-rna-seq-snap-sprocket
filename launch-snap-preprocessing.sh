#!/usr/bin/env bash
set -euo pipefail

SNAP_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
exec bash "$SNAP_ROOT/scripts/launch-snap-preprocessing.sh" "$@"
