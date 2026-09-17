version 1.3

import "../tasks/post_cellranger_optional.wdl" as optional
import "../tasks/post_cellranger_required.wdl" as required
import "../tasks/pre_cellranger.wdl" as preprocessing
import "../tasks/preprocessing_types.wdl" as types

workflow daedalus_from_cellranger {
    meta {
        description: "Import existing Cell Ranger outputs, estimate resources, and run upstream and integrative analyses"
        author: "DNB Bioinformatics Core"
    }

    input {
        Array[ExistingCellRangerInput]+ cellranger_inputs
        String resource_estimator_container
        String project_root
        String downstream_container
        String notify_email
        Boolean run_upstream = false
        Boolean run_integrative = false
        Boolean run_cluster = false
        Boolean run_contamination_removal = false
        Boolean run_cell_types = false
        Boolean run_clone_phylogeny = false
        Boolean run_de_go = false
        Boolean run_rshiny = false
        Int resource_estimator_cpu = 1
        Int resource_estimator_memory_gb = 1
    }

    scatter (cellranger_input in cellranger_inputs) {
        String sample_id = cellranger_input.id
        Directory count_output = cellranger_input.count_output
        File metrics_csv = join_paths(count_output, "metrics_summary.csv")
    }

    call preprocessing.validate_existing_cellranger { input:
        sample_ids = sample_id,
        count_outputs = count_output,
        cpu = resource_estimator_cpu,
        memory_gb = resource_estimator_memory_gb,
        container_image = resource_estimator_container,
    }

    scatter (index in range(length(cellranger_inputs))) {
        call preprocessing.parse_cellranger_metrics after validate_existing_cellranger { input:
            metrics_csv = metrics_csv[index],
            cpu = resource_estimator_cpu,
            memory_gb = resource_estimator_memory_gb,
            container_image = resource_estimator_container,
        }

        Int sample_estimated_cells = parse_cellranger_metrics.estimated_cells
        CellRangerOutput cellranger_output = CellRangerOutput {
            sample_id: sample_id[index],
            count_output: count_output[index],
            metrics_csv: metrics_csv[index],
            estimated_cells: parse_cellranger_metrics.estimated_cells,
        }
    }

    call preprocessing.estimate_downstream_resources { input:
        estimated_cells = sample_estimated_cells,
        cpu = resource_estimator_cpu,
        memory_gb = resource_estimator_memory_gb,
        container_image = resource_estimator_container,
    }

    call preprocessing.write_cellranger_summary { input:
        sample_ids = sample_id,
        estimated_cells = sample_estimated_cells,
        cpu = resource_estimator_cpu,
        memory_gb = resource_estimator_memory_gb,
        container_image = resource_estimator_container,
    }

    if (run_upstream) {
        call required.run_upstream as upstream after write_cellranger_summary { input:
            snap_root = project_root,
            container_image = downstream_container,
            notify_email = notify_email,
            cpu = estimate_downstream_resources.resources.upstream_cpu,
            memory_gb = estimate_downstream_resources.resources.upstream_memory_gb,
            future_globals_gib = estimate_downstream_resources.resources.upstream_future_globals_gib,
        }
    }
    if (run_integrative) {
        call optional.run_integrative as integrative after write_cellranger_summary after upstream { input:
            snap_root = project_root,
            container_image = downstream_container,
            notify_email = notify_email,
            cpu = estimate_downstream_resources.resources.integrative_cpu,
            memory_gb = estimate_downstream_resources.resources.integrative_memory_gb,
            future_globals_gib = estimate_downstream_resources.resources.integrative_future_globals_gib,
        }
    }

    if (run_cluster) {
        call required.run_cluster as cluster after write_cellranger_summary after upstream { input:
            snap_root = project_root,
            container_image = downstream_container,
            notify_email = notify_email,
            cpu = estimate_downstream_resources.resources.cluster_cpu,
            memory_gb = estimate_downstream_resources.resources.cluster_memory_gb,
            future_globals_gib = estimate_downstream_resources.resources.cluster_future_globals_gib,
        }
    }

    if (run_contamination_removal) {
        call optional.run_contamination_removal as contamination_removal after write_cellranger_summary
            after upstream after cluster { input:
            snap_root = project_root,
            container_image = downstream_container,
            notify_email = notify_email,
            cpu = estimate_downstream_resources.resources.contamination_cpu,
            memory_gb = estimate_downstream_resources.resources.contamination_memory_gb,
            future_globals_gib = estimate_downstream_resources.resources.contamination_future_globals_gib,
        }
    }

    if (run_cell_types) {
        call required.run_cell_types as cell_types after write_cellranger_summary after upstream
            after cluster { input:
            snap_root = project_root,
            container_image = downstream_container,
            notify_email = notify_email,
            cpu = estimate_downstream_resources.resources.cell_types_cpu,
            memory_gb = estimate_downstream_resources.resources.cell_types_memory_gb,
        }
    }

    if (run_clone_phylogeny) {
        call optional.run_clone_phylogeny as clone_phylogeny after write_cellranger_summary
            after upstream after cluster after cell_types { input:
            snap_root = project_root,
            container_image = downstream_container,
            notify_email = notify_email,
            cpu = estimate_downstream_resources.resources.clone_phylogeny_cpu,
            memory_gb = estimate_downstream_resources.resources.clone_phylogeny_memory_gb,
        }
    }

    if (run_de_go) {
        call optional.run_de_go as de_go after write_cellranger_summary after upstream
            after cluster after cell_types { input:
            snap_root = project_root,
            container_image = downstream_container,
            notify_email = notify_email,
            cpu = estimate_downstream_resources.resources.de_go_cpu,
            memory_gb = estimate_downstream_resources.resources.de_go_memory_gb,
            future_globals_gib = estimate_downstream_resources.resources.de_go_future_globals_gib,
        }
    }

    if (run_rshiny) {
        call required.run_rshiny as rshiny after write_cellranger_summary after upstream
            after cluster after cell_types { input:
            snap_root = project_root,
            container_image = downstream_container,
            notify_email = notify_email,
            cpu = estimate_downstream_resources.resources.rshiny_cpu,
            memory_gb = estimate_downstream_resources.resources.rshiny_memory_gb,
        }
    }

    output {
        Array[CellRangerOutput] cellranger_outputs = cellranger_output
        File cellranger_summary = write_cellranger_summary.summary
        Array[Int] estimated_cells = sample_estimated_cells
        Int num_samples = length(cellranger_inputs)
        DownstreamResources downstream_resources = estimate_downstream_resources.resources
        Int upstream_cpu = estimate_downstream_resources.resources.upstream_cpu
        Int upstream_memory_gb = estimate_downstream_resources.resources.upstream_memory_gb
        Int upstream_future_globals_gib = estimate_downstream_resources.resources.upstream_future_globals_gib
        Int integrative_cpu = estimate_downstream_resources.resources.integrative_cpu
        Int integrative_memory_gb = estimate_downstream_resources.resources.integrative_memory_gb
        Int integrative_future_globals_gib = estimate_downstream_resources.resources.integrative_future_globals_gib
        File? upstream_completion = upstream.done_flag
        String? upstream_results = if run_upstream
            then project_root + "/analyses/upstream-analysis/results"
            else None
        File? cluster_completion = cluster.done_flag
        String? cluster_results = if run_cluster
            then project_root + "/analyses/cluster-cell-calling"
            else None
        File? cell_types_completion = cell_types.done_flag
        String? cell_types_results = if run_cell_types
            then project_root + "/analyses/cell-types-annotation"
            else None
        File? rshiny_completion = rshiny.done_flag
        String? rshiny_results = if run_rshiny
            then project_root + "/analyses/rshiny-app"
            else None
        File? integrative_completion = integrative.done_flag
        String? integrative_results = if run_integrative
            then project_root + "/analyses/integrative-analysis/results"
            else None
        File? contamination_removal_completion = contamination_removal.done_flag
        String? contamination_removal_results = if run_contamination_removal
            then project_root + "/analyses/cell-contamination-removal-analysis"
            else None
        File? clone_phylogeny_completion = clone_phylogeny.done_flag
        String? clone_phylogeny_results = if run_clone_phylogeny
            then project_root + "/analyses/clone-phylogeny-analysis"
            else None
        File? de_go_completion = de_go.done_flag
        String? de_go_results = if run_de_go
            then project_root + "/analyses/de-go-analysis"
            else None
    }
}
