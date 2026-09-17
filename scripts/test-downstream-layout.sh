#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SNAP_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

echo "==> Snap root: ${SNAP_ROOT}"
echo

required=(
  wdl/snap.wdl
  wdl/tasks.wdl
  wdl/resources.wdl
  wdl/snap_multi_project.wdl
  sprocket.toml
  inputs/sprocket_inputs.json
  scripts/estimate-snap-downstream-resources.R
  scripts/launch-snap-sprocket.sh
  workflows/daedalus_processing.wdl
  workflows/daedalus_from_cellranger.wdl
  tasks/preprocessing_types.wdl
  tasks/pre_cellranger.wdl
  tasks/pre_cellranger.yaml
  inputs/preprocessing.example.json
  inputs/from_cellranger.example.json
  test/fixtures/preprocessing/cells-1750-quoted.csv
  test/fixtures/preprocessing/missing-cell-count.csv
  test/fixtures/preprocessing/not-a-number.csv
)

for f in "${required[@]}"; do
  [[ -e "${SNAP_ROOT}/${f}" ]] && echo "OK      ${f}" || { echo "MISSING: ${f}"; exit 1; }
done

resume_workflow="${SNAP_ROOT}/workflows/daedalus_from_cellranger.wdl"
post_cellranger_tasks="${SNAP_ROOT}/tasks/post_cellranger.wdl"
parallel_plan="${SNAP_ROOT}/scripts/snap_parallel_plan.R"
grep -qF 'import "../tasks/post_cellranger.wdl" as post_cellranger' "${resume_workflow}"
grep -qF 'call post_cellranger.run_upstream as upstream' "${resume_workflow}"
grep -qF 'call post_cellranger.run_integrative as integrative' "${resume_workflow}"
grep -qF 'cpu = estimate_downstream_resources.resources.upstream_cpu' "${resume_workflow}"
grep -qF 'memory_gb = estimate_downstream_resources.resources.upstream_memory_gb' "${resume_workflow}"
grep -qF 'future_globals_gib = estimate_downstream_resources.resources.upstream_future_globals_gib' "${resume_workflow}"
grep -qF 'cpu = estimate_downstream_resources.resources.integrative_cpu' "${resume_workflow}"
grep -qF 'memory_gb = estimate_downstream_resources.resources.integrative_memory_gb' "${resume_workflow}"
grep -qF 'future_globals_gib = estimate_downstream_resources.resources.integrative_future_globals_gib' "${resume_workflow}"
[[ "$(grep -cF 'export SNAP_FUTURE_WORKERS="~{cpu}"' "${post_cellranger_tasks}")" -eq 2 ]]
grep -qF 'requested workers:' "${parallel_plan}"
grep -qF 'available cores:' "${parallel_plan}"
grep -qF 'selected workers:' "${parallel_plan}"
if grep -Eq 'call post_cellranger\.run_(cluster|contamination_removal|cell_types|clone_phylogeny|de_go|rshiny)' "${resume_workflow}"; then
  echo "UNEXPECTED: unsupported post-Cell-Ranger module in ${resume_workflow}" >&2
  exit 1
fi

echo
echo "==> Downstream modules in workflow"
grep -E "^task run_" "${SNAP_ROOT}/wdl/tasks.wdl" | sed 's/task /  /'

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
  tier=$([[ $scale -le 1 ]] && echo default || ([[ $scale -le 2 ]] && echo large || echo xlarge))
  up=$((30 + (cs - 1) * 10))
  integ=$((96 + (cs - 1) * 24))
  clust=$((48 + (cs - 1) * 16))
  printf "%-8s %-10s %-12s %-12s %-10s\n" "$samples" "$tier" "$up" "$integ" "$clust"
done

echo
echo "Next: module load sprocket R && bash scripts/launch-snap-sprocket.sh --snap-root \"${SNAP_ROOT}\" --dry-run"
