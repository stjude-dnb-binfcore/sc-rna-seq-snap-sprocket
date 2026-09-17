version 1.3

import "../tasks/pre_cellranger.wdl" as preprocessing
import "../tasks/preprocessing_types.wdl" as types

workflow daedalus_from_cellranger {
    meta {
        description: "Import existing Cell Ranger outputs and estimate downstream resources"
        author: "DNB Bioinformatics Core"
    }

    input {
        Array[ExistingCellRangerInput]+ cellranger_inputs
        String resource_estimator_container
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
    }
}
