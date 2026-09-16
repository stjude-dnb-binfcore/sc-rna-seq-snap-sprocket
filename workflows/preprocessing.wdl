version 1.3

import "../tasks/pre_cellranger.wdl" as preprocessing
import "../tasks/preprocessing_types.wdl" as types

workflow snap_preprocessing {
    meta {
        description: "FastQC, MultiQC, Cell Ranger, and downstream resource estimation"
        author: "DNB Bioinformatics Core"
    }

    input {
        String project_name
        Array[SampleInput]+ samples
        Directory genome_reference
        String fastqc_multiqc_container
        String cellranger_container
        String resource_estimator_container
        Int fastqc_cpu
        Int fastqc_memory_gb
        Int multiqc_cpu
        Int multiqc_memory_gb
        Int cellranger_cpu
        Int cellranger_memory_gb
        Boolean cellranger_create_bam
        String? cellranger_chemistry
        Int? cellranger_expected_cells
    }

    scatter (sample in samples) {
        String sample_id = sample.id

        call preprocessing.run_fastqc { input:
            id = sample.id,
            fastq_dirs = sample.fastq_dirs,
            cpu = fastqc_cpu,
            memory_gb = fastqc_memory_gb,
            container_image = fastqc_multiqc_container,
        }

        call preprocessing.run_cellranger { input:
            id = sample.id,
            fastq_dirs = sample.fastq_dirs,
            sample_names = sample.sample_names,
            genome_reference = genome_reference,
            create_bam = cellranger_create_bam,
            chemistry = cellranger_chemistry,
            expected_cells = cellranger_expected_cells,
            cpu = cellranger_cpu,
            memory_gb = cellranger_memory_gb,
            container_image = cellranger_container,
        }

        Array[File] sample_fastqc_reports = flatten([
            run_fastqc.result.html_reports,
            run_fastqc.result.zip_reports,
        ])
    }

    Array[File] all_fastqc_reports = flatten(sample_fastqc_reports)

    call preprocessing.run_multiqc { input:
        fastqc_reports = all_fastqc_reports,
        project_name = project_name,
        cpu = multiqc_cpu,
        memory_gb = multiqc_memory_gb,
        container_image = fastqc_multiqc_container,
    }

    scatter (index in range(length(samples))) {
        call preprocessing.parse_cellranger_metrics { input:
            metrics_csv = run_cellranger.metrics[index],
            cpu = 1,
            memory_gb = 1,
            container_image = resource_estimator_container,
        }

        Int sample_estimated_cells = parse_cellranger_metrics.estimated_cells
        CellRangerOutput cellranger_output = CellRangerOutput {
            sample_id: sample_id[index],
            count_output: run_cellranger.count_output[index],
            metrics_csv: run_cellranger.metrics[index],
            estimated_cells: parse_cellranger_metrics.estimated_cells,
        }
    }

    call preprocessing.estimate_downstream_resources { input:
        estimated_cells = sample_estimated_cells,
        cpu = 1,
        memory_gb = 1,
        container_image = resource_estimator_container,
    }

    output {
        Array[FastQcOutput] fastqc_outputs = run_fastqc.result
        File multiqc_html_report = run_multiqc.html_report
        Directory multiqc_data = run_multiqc.data
        Array[CellRangerOutput] cellranger_outputs = cellranger_output
        Array[SampleInput] normalized_samples = samples
        DownstreamResources downstream_resources = estimate_downstream_resources.resources
    }
}
