#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SNAP_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
CONFIG="$SNAP_ROOT/inputs/preprocessing.yaml"
SUBMIT=0
NO_CALL_CACHE=0
RUN_TESTS=0

usage() {
  cat <<'EOF'
Usage: scripts/launch-snap-preprocessing.sh [--config PATH] [--submit] [--no-call-cache] [--test]

Without --submit, validates the analyst YAML and generated WDL inputs.
EOF
}

while (($#)); do
  case "$1" in
    --config)
      [[ $# -ge 2 ]] || { echo "--config requires a path" >&2; exit 2; }
      CONFIG=$2
      shift 2
      ;;
    --submit)
      SUBMIT=1
      shift
      ;;
    --no-call-cache)
      NO_CALL_CACHE=1
      shift
      ;;
    --test)
      RUN_TESTS=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if ((RUN_TESTS)); then
  Rscript "$SCRIPT_DIR/test-preprocessing-inputs.R"
  Rscript "$SCRIPT_DIR/test-preprocessing-resources.R"
  sprocket check "$SNAP_ROOT/workflows/preprocessing.wdl"
  exit
fi

mkdir -p "$SNAP_ROOT/inputs"
INPUTS="$SNAP_ROOT/inputs/preprocessing.generated.json"
MANIFEST="$SNAP_ROOT/inputs/preprocessing-manifest.generated.json"
Rscript "$SCRIPT_DIR/render-preprocessing-inputs.R" \
  --config "$CONFIG" \
  --output "$INPUTS" \
  --manifest "$MANIFEST"

WORKFLOW="$SNAP_ROOT/workflows/preprocessing.wdl"
SPROCKET_CONFIG="$SNAP_ROOT/sprocket.toml"
sprocket check "$WORKFLOW"
sprocket validate "$WORKFLOW" "@$INPUTS" --config "$SPROCKET_CONFIG" --skip-config-search

if ((!SUBMIT)); then
  echo "Validation complete. Re-run with --submit to launch the workflow."
  exit
fi

OUTPUT_DIR=$(Rscript -e 'cat(jsonlite::fromJSON(commandArgs(TRUE)[1])$project$output_dir)' "$MANIFEST")
run_args=(
  run "$WORKFLOW" "@$INPUTS"
  --config "$SPROCKET_CONFIG"
  --skip-config-search
  --output-dir "$OUTPUT_DIR"
)
if ((NO_CALL_CACHE)); then run_args+=(--no-call-cache); fi
sprocket "${run_args[@]}"
