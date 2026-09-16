version 1.3

import "preprocessing_types.wdl" as types

task run_fastqc {
  input {
    String id
    Array[Directory]+ fastq_dirs
    Int cpu
    Int memory_gb
    String container_image
  }

  File fastq_dir_list = write_lines(fastq_dirs)

  command <<<
    set -euo pipefail
    mkdir -p fastqc-results
    WORK_DIR=$(mktemp -d)
    trap 'rm -rf "$WORK_DIR"' EXIT
    COUNT=0
    while IFS= read -r FASTQ_DIR || [[ -n "$FASTQ_DIR" ]]; do
      [[ -d "$FASTQ_DIR" ]] || { echo "FASTQ directory does not exist: $FASTQ_DIR" >&2; exit 1; }
      while IFS= read -r FASTQ; do
        COUNT=$((COUNT + 1))
        ITEM_DIR="$WORK_DIR/$COUNT"
        mkdir -p "$ITEM_DIR"
        fastqc --threads "~{cpu}" --outdir "$ITEM_DIR" "$FASTQ"
        HTML=("$ITEM_DIR"/*_fastqc.html)
        ZIP=("$ITEM_DIR"/*_fastqc.zip)
        [[ -f "${HTML[0]}" && -f "${ZIP[0]}" ]] || {
          echo "FastQC did not produce HTML and ZIP outputs for $FASTQ" >&2
          exit 1
        }
        printf -v PREFIX '%s_%04d' "~{id}" "$COUNT"
        mv "${HTML[0]}" "fastqc-results/${PREFIX}_$(basename "${HTML[0]}")"
        mv "${ZIP[0]}" "fastqc-results/${PREFIX}_$(basename "${ZIP[0]}")"
      done < <(find "$FASTQ_DIR" -type f -name '*R2*.fastq.gz' -print | LC_ALL=C sort)
    done < "~{fastq_dir_list}"
    if ((COUNT == 0)); then
      echo "no *R2*.fastq.gz files found for sample ~{id}" >&2
      exit 1
    fi
    find fastqc-results -maxdepth 1 -type f \( -name '*_fastqc.html' -o -name '*_fastqc.zip' \) \
      -print | sed 's#^.*/##' | LC_ALL=C sort > fastqc-results/report-names.txt
  >>>

  output {
    Array[File] html_reports = glob("fastqc-results/*_fastqc.html")
    Array[File] zip_reports = glob("fastqc-results/*_fastqc.zip")
    Array[String] report_names = read_lines("fastqc-results/report-names.txt")
  }

  runtime {
    cpu: cpu
    memory: "~{memory_gb} GB"
    container: container_image
  }
}

task run_multiqc {
  input {
    Array[File]+ fastqc_reports
    String project_name
    Int cpu
    Int memory_gb
    String container_image
  }

  File report_list = write_lines(fastqc_reports)

  command <<<
    set -euo pipefail
    mkdir -p multiqc-results/inputs
    COUNT=0
    while IFS= read -r REPORT || [[ -n "$REPORT" ]]; do
      [[ -f "$REPORT" ]] || { echo "FastQC report does not exist: $REPORT" >&2; exit 1; }
      COUNT=$((COUNT + 1))
      cp "$REPORT" "multiqc-results/inputs/$(printf '%04d' "$COUNT")_$(basename "$REPORT")"
    done < "~{report_list}"
    if ((COUNT == 0)); then
      echo "no FastQC reports supplied to MultiQC" >&2
      exit 1
    fi
    multiqc \
      --outdir multiqc-results \
      --filename multiqc_report.html \
      --title "~{project_name}" \
      --data-dir \
      --data-dir-name multiqc_data \
      multiqc-results/inputs
    [[ -f multiqc-results/multiqc_report.html && -d multiqc-results/multiqc_data ]] || {
      echo "MultiQC did not produce its expected report and data directory" >&2
      exit 1
    }
  >>>

  output {
    File html_report = "multiqc-results/multiqc_report.html"
    Directory data = "multiqc-results/multiqc_data"
  }

  runtime {
    cpu: cpu
    memory: "~{memory_gb} GB"
    container: container_image
  }
}

task run_cellranger {
  input {
    String id
    Array[Directory]+ fastq_dirs
    Array[String]+ sample_names
    Directory genome_reference
    Boolean create_bam
    String? chemistry
    Int? expected_cells
    Int cpu
    Int memory_gb
    String container_image
  }

  File fastq_dir_list = write_lines(fastq_dirs)
  File sample_name_list = write_lines(sample_names)

  command <<<
    set -euo pipefail
    [[ -d "~{genome_reference}" ]] || {
      echo "genome reference does not exist: ~{genome_reference}" >&2
      exit 1
    }
    mapfile -t FASTQ_DIRS < "~{fastq_dir_list}"
    mapfile -t SAMPLE_NAMES < "~{sample_name_list}"
    if ((${#FASTQ_DIRS[@]} == 0 || ${#FASTQ_DIRS[@]} != ${#SAMPLE_NAMES[@]})); then
      echo "FASTQ directory and sample name counts must match and be nonzero" >&2
      exit 1
    fi
    for DIRECTORY in "${FASTQ_DIRS[@]}"; do
      [[ -d "$DIRECTORY" ]] || { echo "FASTQ directory does not exist: $DIRECTORY" >&2; exit 1; }
      find "$DIRECTORY" -type f -name '*.fastq.gz' -print -quit | grep -q . || {
        echo "FASTQ directory contains no .fastq.gz files: $DIRECTORY" >&2
        exit 1
      }
    done
    FASTQS=$(IFS=,; echo "${FASTQ_DIRS[*]}")
    SAMPLE_LIST=$(IFS=,; echo "${SAMPLE_NAMES[*]}")
    LOCALMEM=$((~{memory_gb} * 9 / 10))
    if ((LOCALMEM < 8)); then LOCALMEM=8; fi
    ARGS=(
      count
      "--id=~{id}"
      "--transcriptome=~{genome_reference}"
      "--fastqs=$FASTQS"
      "--sample=$SAMPLE_LIST"
      "--create-bam=~{create_bam}"
      "--localcores=~{cpu}"
      "--localmem=$LOCALMEM"
    )
    CHEMISTRY="~{default="" chemistry}"
    EXPECTED_CELLS="~{default="" expected_cells}"
    if [[ -n "$CHEMISTRY" ]]; then ARGS+=("--chemistry=$CHEMISTRY"); fi
    if [[ -n "$EXPECTED_CELLS" ]]; then ARGS+=("--expect-cells=$EXPECTED_CELLS"); fi
    mkdir -p cellranger-results
    cd cellranger-results
    cellranger "${ARGS[@]}"
    [[ -d "~{id}/outs" && -f "~{id}/outs/metrics_summary.csv" ]] || {
      echo "Cell Ranger did not produce ~{id}/outs/metrics_summary.csv" >&2
      exit 1
    }
  >>>

  output {
    Directory count_output = "cellranger-results/~{id}/outs"
    File metrics = "cellranger-results/~{id}/outs/metrics_summary.csv"
  }

  runtime {
    cpu: cpu
    memory: "~{memory_gb} GB"
    container: container_image
  }
}

task estimate_downstream_resources {
  input {
    Array[String]+ sample_ids
    Array[File]+ metrics
    Int cpu
    Int memory_gb
    String container_image
  }

  File sample_ids_file = write_lines(sample_ids)
  File metrics_file_list = write_lines(metrics)

  command <<<
    set -euo pipefail
    Rscript --vanilla - "~{sample_ids_file}" "~{metrics_file_list}" <<'RSCRIPT'
    abort <- function(...) stop(..., call. = FALSE)
    args <- commandArgs(trailingOnly = TRUE)
    sample_ids <- readLines(args[[1]], warn = FALSE)
    metrics_paths <- readLines(args[[2]], warn = FALSE)

    if (!length(sample_ids) || length(sample_ids) != length(metrics_paths)) {
      abort("sample ID and metrics file counts must match and be nonzero")
    }
    if (any(!nzchar(trimws(sample_ids)))) abort("sample IDs must be nonempty")
    if (anyDuplicated(sample_ids)) {
      abort(
        "duplicate sample metrics: ",
        paste(unique(sample_ids[duplicated(sample_ids)]), collapse = ", ")
      )
    }

    read_cells <- function(path) {
      metrics <- tryCatch(
        read.csv(path, check.names = FALSE, stringsAsFactors = FALSE),
        error = function(error) {
          abort("failed to parse metrics CSV ", path, ": ", conditionMessage(error))
        }
      )
      column <- "Estimated Number of Cells"
      if (sum(names(metrics) == column) != 1L) {
        abort("metrics CSV must contain exactly one '", column, "' column: ", path)
      }
      if (nrow(metrics) != 1L) {
        abort("metrics CSV must contain exactly one data row: ", path)
      }
      raw <- gsub(",", "", trimws(as.character(metrics[[column]][[1L]])), fixed = TRUE)
      value <- suppressWarnings(as.numeric(raw))
      if (is.na(value) || !is.finite(value) || value != as.integer(value) || value < 1L) {
        abort("invalid Estimated Number of Cells value in ", path, ": ", raw)
      }
      as.integer(value)
    }

    num_samples <- length(sample_ids)
    total_cells <- sum(vapply(metrics_paths, read_cells, integer(1)))
    cell_scale <- max(1L, as.integer(ceiling(total_cells / 400000)))
    resources <- c(
      upstream_cpu = if (num_samples <= 4L) 8L else if (num_samples <= 12L) 16L else 24L,
      upstream_memory_gb = as.integer(ceiling((30L + 10L * (cell_scale - 1L)) * 1.2)),
      upstream_future_globals_gib = 200L + 50L * (cell_scale - 1L),
      integrative_cpu = if (num_samples <= 8L) 10L else 16L,
      integrative_memory_gb = as.integer(ceiling((96L + 24L * (cell_scale - 1L)) * 1.2)),
      integrative_future_globals_gib = 200L + 50L * (cell_scale - 1L)
    )

    dir.create("resources")
    entries <- sprintf('  "%s": %d', names(resources), resources)
    writeLines(
      c("{", paste(entries, collapse = ",\n"), "}"),
      "resources/resource_estimate.json"
    )
    RSCRIPT
  >>>

  output {
    File resource_estimate_json = "resources/resource_estimate.json"
    DownstreamResources resources = read_json(resource_estimate_json)
  }

  runtime {
    cpu: cpu
    memory: "~{memory_gb} GB"
    container: container_image
  }
}
