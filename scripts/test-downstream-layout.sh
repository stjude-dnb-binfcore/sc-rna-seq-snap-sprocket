#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SNAP_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

echo "==> Snap root: ${SNAP_ROOT}"
echo

required=(
  sprocket.toml
  scripts/estimate-snap-downstream-resources.R
  scripts/launch-snap-sprocket.sh
  workflows/daedalus_from_cellranger.wdl
  tasks/post_cellranger_optional.wdl
  tasks/post_cellranger_required.wdl
  tasks/preprocessing_types.wdl
  tasks/pre_cellranger.wdl
  tasks/pre_cellranger.yaml
  test/fixtures/preprocessing/cells-1750-quoted.csv
  test/fixtures/preprocessing/missing-cell-count.csv
  test/fixtures/preprocessing/not-a-number.csv
)

for f in "${required[@]}"; do
  if [[ -e "${SNAP_ROOT}/${f}" ]]; then
    echo "OK      ${f}"
  else
    echo "MISSING: ${f}"
    exit 1
  fi
done

echo
echo "==> Downstream modules in workflow"
grep -hE "^task run_" \
  "${SNAP_ROOT}/tasks/post_cellranger_required.wdl" \
  "${SNAP_ROOT}/tasks/post_cellranger_optional.wdl" \
  | sed 's/task /  /'

echo
echo "==> Static launcher contract"
if ! grep -Fq 'WORKFLOW_NAME="daedalus_from_cellranger"' "${SNAP_ROOT}/scripts/launch-snap-sprocket.sh"; then
  echo "Launcher does not select the static daedalus_from_cellranger workflow" >&2
  exit 1
fi
if grep -Fq 'NO_CALL_CACHE' "${SNAP_ROOT}/scripts/launch-snap-sprocket.sh"; then
  echo "Call caching is still conditional" >&2
  exit 1
fi
if ! grep -Eq '^SPROCKET_RUN_FLAGS=.*--no-call-cache' "${SNAP_ROOT}/scripts/launch-snap-sprocket.sh"; then
  echo "Launcher does not disable Sprocket call caching" >&2
  exit 1
fi
if grep -Fq 'generate-snap-wdl.R' "${SNAP_ROOT}/scripts/launch-snap-sprocket.sh"; then
  echo "Launcher still generates WDL" >&2
  exit 1
fi
echo "OK      launcher uses static WDL with call caching disabled"

echo
echo "==> Resource scaling preview (baseline 8 x 50k cells)"
printf "%-8s %-10s %-12s %-12s %-10s\n" "samples" "tier" "upstream_GB" "integrative_GB" "cluster_GB"
for samples in 8 16 24; do
  cells=50000
  total=$((samples * cells))
  base=$((8 * 50000))
  cs=$(( (total + base - 1) / base )); cs=$(( cs < 1 ? 1 : cs ))
  ss=$(( (samples + 7) / 8 )); ss=$(( ss < 1 ? 1 : ss ))
  scale=$(( ss > cs ? ss : cs ))
  if [[ $scale -le 1 ]]; then
    tier=default
  elif [[ $scale -le 2 ]]; then
    tier=large
  else
    tier=xlarge
  fi
  up=$((30 + (cs - 1) * 10))
  integ=$((96 + (cs - 1) * 24))
  clust=$((48 + (cs - 1) * 16))
  printf "%-8s %-10s %-12s %-12s %-10s\n" "$samples" "$tier" "$up" "$integ" "$clust"
done

echo
echo "Next: module load sprocket R && bash scripts/launch-snap-sprocket.sh --snap-root \"${SNAP_ROOT}\" --dry-run"
