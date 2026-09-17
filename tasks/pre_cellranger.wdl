version 1.3

import "preprocessing_types.wdl" as types

task validate_existing_cellranger {
    input {
        Array[String]+ sample_ids
        Array[Directory]+ count_outputs
        Int cpu
        Int memory_gb
        String container_image
    }

    File sample_id_list = write_lines(sample_ids)
    File count_output_list = write_lines(count_outputs)

    command <<<
        set -euo pipefail
        mapfile -t SAMPLE_IDS < "~{sample_id_list}"
        mapfile -t COUNT_OUTPUTS < "~{count_output_list}"
        if ((${#SAMPLE_IDS[@]} != ${#COUNT_OUTPUTS[@]})); then
          echo "sample ID and Cell Ranger output counts must match" >&2
          exit 1
        fi
        if printf '%s\n' "${SAMPLE_IDS[@]}" | LC_ALL=C sort | uniq -d | grep -q .; then
          echo "sample IDs must be unique" >&2
          exit 1
        fi
        for INDEX in "${!SAMPLE_IDS[@]}"; do
          SAMPLE_ID="${SAMPLE_IDS[$INDEX]}"
          COUNT_OUTPUT="${COUNT_OUTPUTS[$INDEX]}"
          [[ -f "$COUNT_OUTPUT/metrics_summary.csv" ]] || {
            echo "Cell Ranger output for $SAMPLE_ID has no metrics_summary.csv: $COUNT_OUTPUT" >&2
            exit 1
          }
          [[ -f "$COUNT_OUTPUT/filtered_feature_bc_matrix.h5" || \
             -d "$COUNT_OUTPUT/filtered_feature_bc_matrix" ]] || {
            echo "Cell Ranger output for $SAMPLE_ID has no filtered feature matrix: $COUNT_OUTPUT" >&2
            exit 1
          }
        done
    >>>

    output {
        Boolean valid = true
    }

    requirements {
        cpu: cpu
        memory: "~{memory_gb} GB"
        container: container_image
    }
}

task parse_cellranger_metrics {
    input {
        File metrics_csv
        Int cpu
        Int memory_gb
        String container_image
    }

    command <<<
        set -euo pipefail
        Rscript --vanilla - "~{metrics_csv}" <<'RSCRIPT'
        abort <- function(...) stop(..., call. = FALSE)
        args <- commandArgs(trailingOnly = TRUE)
        path <- args[[1]]
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
        cat(as.integer(value), "\n")
        RSCRIPT
    >>>

    output {
        Int estimated_cells = read_int(stdout())
    }

    requirements {
        cpu: cpu
        memory: "~{memory_gb} GB"
        container: container_image
    }
}

task write_cellranger_summary {
    input {
        Array[String]+ sample_ids
        Array[Int]+ estimated_cells
        Int cpu
        Int memory_gb
        String container_image
    }

    File sample_id_list = write_lines(sample_ids)

    command <<<
        set -euo pipefail
        Rscript --vanilla - \
          "~{sample_id_list}" \
          "~{sep(",", estimated_cells)}" <<'RSCRIPT'
        abort <- function(...) stop(..., call. = FALSE)
        args <- commandArgs(trailingOnly = TRUE)
        columns <- list(
          readLines(args[[1L]], warn = FALSE),
          strsplit(args[[2L]], ",", fixed = TRUE)[[1L]]
        )
        lengths <- vapply(columns, length, integer(1))
        if (!length(lengths) || length(unique(lengths)) != 1L || lengths[[1L]] < 1L) {
          abort("Cell Ranger summary columns must have matching nonzero lengths")
        }
        estimated_cells <- suppressWarnings(as.integer(columns[[2L]]))
        if (any(is.na(estimated_cells)) || any(estimated_cells < 1L)) {
          abort("estimated cell counts must be positive integers")
        }
        summary <- data.frame(
          sample_id = columns[[1L]],
          estimated_cells = estimated_cells,
          check.names = FALSE,
          stringsAsFactors = FALSE
        )
        write.table(
          summary,
          file = "cellranger_summary.tsv",
          sep = "\t",
          quote = FALSE,
          row.names = FALSE
        )
        RSCRIPT
    >>>

    output {
        File summary = "cellranger_summary.tsv"
    }

    requirements {
        cpu: cpu
        memory: "~{memory_gb} GB"
        container: container_image
    }
}

task estimate_downstream_resources {
    input {
        Array[Int]+ estimated_cells
        Int cpu
        Int memory_gb
        String container_image
    }

    command <<<
        set -euo pipefail
        Rscript --vanilla - ~{sep(" ", estimated_cells)} <<'RSCRIPT'
        abort <- function(...) stop(..., call. = FALSE)
        estimated_cells <- suppressWarnings(as.integer(commandArgs(trailingOnly = TRUE)))
        if (!length(estimated_cells) || any(is.na(estimated_cells)) || any(estimated_cells < 1L)) {
          abort("estimated cell counts must be positive integers")
        }

        num_samples <- length(estimated_cells)
        total_cells <- sum(estimated_cells)
        sample_scale <- max(1L, as.integer(ceiling(num_samples / 8)))
        cell_scale <- max(1L, as.integer(ceiling(total_cells / 400000)))
        scale <- max(sample_scale, cell_scale)
        resources <- c(
          upstream_cpu = if (num_samples <= 4L) 8L else if (num_samples <= 12L) 16L else 24L,
          upstream_memory_gb = as.integer(ceiling((30L + 10L * (cell_scale - 1L)) * 1.2)),
          upstream_future_globals_gib = 200L + 50L * (cell_scale - 1L),
          integrative_cpu = if (num_samples <= 8L) 10L else 16L,
          integrative_memory_gb = as.integer(ceiling((96L + 24L * (cell_scale - 1L)) * 1.2)),
          integrative_future_globals_gib = 200L + 50L * (cell_scale - 1L),
          cluster_cpu = if (scale <= 1L) 4L else if (scale <= 2L) 8L else 12L,
          cluster_memory_gb = as.integer(ceiling((48L + 16L * (cell_scale - 1L)) * 1.2)),
          cluster_future_globals_gib = 400L + 100L * (cell_scale - 1L),
          contamination_cpu = 8L,
          contamination_memory_gb = as.integer(ceiling((96L + 24L * (cell_scale - 1L)) * 1.2)),
          contamination_future_globals_gib = 400L + 100L * (cell_scale - 1L),
          cell_types_cpu = 4L,
          cell_types_memory_gb = as.integer(ceiling((64L + 16L * (cell_scale - 1L)) * 1.2)),
          clone_phylogeny_cpu = 16L,
          clone_phylogeny_memory_gb = 30L,
          de_go_cpu = 4L,
          de_go_memory_gb = as.integer(ceiling((32L + 8L * (cell_scale - 1L)) * 1.2)),
          de_go_future_globals_gib = 200L + 50L * (cell_scale - 1L),
          rshiny_cpu = 4L,
          rshiny_memory_gb = 30L
        )

        entries <- sprintf('  "%s": %d', names(resources), resources)
        cat("{\n", paste(entries, collapse = ",\n"), "\n}\n", sep = "")
        RSCRIPT
    >>>

    output {
        DownstreamResources resources = read_json(stdout())
    }

    requirements {
        cpu: cpu
        memory: "~{memory_gb} GB"
        container: container_image
    }
}
