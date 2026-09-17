# Daedalus downstream launcher

`launch-snap-downstream.sh` runs enabled downstream analyses from completed
Cell Ranger outputs. It uses the checked-in
`workflows/daedalus_from_cellranger.wdl`.

## Requirements

- Cell Ranger outputs under
  `analyses/cellranger-analysis/results/02_cellranger_count/<parameters>/<sample>/outs`
- `data/project_metadata/project_metadata.tsv`
- An exact match between metadata `ID` values and Cell Ranger sample directory
  names
- An R/Seurat Apptainer or Singularity image configured at
  `resource_profile.container_image` in `project_parameters.Config.yaml`
- Sprocket on `PATH`
- The R and Singularity modules loaded on the St. Jude HPC

## Configuration

Set the downstream module switches under `workflow_profile` in
`project_parameters.Config.yaml`:

```yaml
workflow_profile:
  run_upstream: true
  run_integrative: true
  run_cluster: false
  run_contamination_removal: false
  run_cell_types: false
  run_clone_phylogeny: false
  run_de_go: false
  run_rshiny: false
```

The WDL uses `after` clauses to enforce this dependency graph:

```text
Cell Ranger validation -> Upstream +-> Integrative
                                    \-> Cluster +-> Contamination removal
                                                \-> Cell types +-> Clone phylogeny
                                                                +-> DE/GO
                                                                \-> R Shiny
```

Each descendant lists all earlier calls on its branch, so disabling an
intermediate module does not remove its dependency on an enabled ancestor.
When a data-producing prerequisite is disabled, its expected result files must
already exist.

## Run

From the repository root on the HPC:

```bash
module load R singularity

./launch-snap-downstream.sh
./launch-snap-downstream.sh --submit
```

The first command refreshes launch inputs and validates the static WDL without
submitting jobs. The second command submits the enabled modules. Every
submission disables Sprocket call caching.

## Generated files and results

The launcher rewrites these ignored runtime files:

- `<root_dir>/inputs/project_parameters.generated.yaml`
- `inputs/generated_downstream.json`
- `inputs/sprocket_inputs.json`
- `inputs/sprocket.generated.toml`

Workflow execution data is stored under
`out/runs/daedalus_from_cellranger/`. Resource reports are stored under
`out/resource_usage/`.

Downstream tasks set `SNAP_CONFIG_FILE` to
`<root_dir>/inputs/project_parameters.generated.yaml`.
