#!/usr/bin/env Rscript
################################################################################
# estimate-snap-downstream-resources.R
#
# Estimate LSF / future.globals resources for snap modules from upstream onwards.
# Baseline: 8 samples x 50,000 cells.
#
# Usage:
#   Rscript scripts/estimate-snap-downstream-resources.R \
#     --snap-root /path/to/sc-rna-seq-snap \
#     --output inputs/generated_downstream.json \
#     [--update-yaml] \
#     [--yaml-in-place]
#
# By default --update-yaml writes inputs/project_parameters.generated.yaml and
# leaves project_parameters.Config.yaml (your master template) unchanged.
# Use --yaml-in-place to overwrite the master file (creates .orig backup first).
################################################################################

suppressPackageStartupMessages({
  if (!requireNamespace("yaml", quietly = TRUE)) stop("Install yaml: install.packages('yaml')")
  library(yaml)
})

`%||%` <- function(a, b) {
  if (is.null(a)) return(b)
  if (length(a) == 1L && (is.na(a) || (is.character(a) && !nzchar(a)))) return(b)
  a
}

#' Sprocket lsf_apptainer treats bare paths as docker:// URIs. Local images need file://.
sprocket_container_uri <- function(image, snap_root) {
  if (is.null(image) || !nzchar(image)) return(image)
  if (grepl("^[a-zA-Z][a-zA-Z0-9+.-]*://", image) && !startsWith(image, "file://")) {
    return(image)
  }

  path <- sub("^file://", "", image)
  is_file_path <- startsWith(image, "file://") ||
    startsWith(path, "/") ||
    startsWith(path, "./") ||
    startsWith(path, "../") ||
    grepl("\\.sif$", path, ignore.case = TRUE)
  if (!is_file_path) return(image)

  if (!startsWith(path, "/")) path <- file.path(snap_root, path)
  path <- normalizePath(path, winslash = "/", mustWork = FALSE)
  if (!file.exists(path)) {
    stop("Container image does not exist: ", path)
  }
  paste0("file://", path)
}

parse_args <- function(args) {
  out <- list(
    snap_root = NULL,
    output = NULL,
    update_yaml = FALSE,
    yaml_in_place = FALSE,
    yaml_output = NULL,
    estimated_cells_per_sample = NULL
  )
  i <- 1L
  while (i <= length(args)) {
    key <- args[[i]]
    if (key == "--snap-root") { i <- i + 1L; out$snap_root <- args[[i]] }
    else if (key == "--output") { i <- i + 1L; out$output <- args[[i]] }
    else if (key == "--yaml-output") { i <- i + 1L; out$yaml_output <- args[[i]] }
    else if (key == "--update-yaml") out$update_yaml <- TRUE
    else if (key == "--yaml-in-place") out$yaml_in_place <- TRUE
    else if (key == "--estimated-cells-per-sample") { i <- i + 1L; out$estimated_cells_per_sample <- as.integer(args[[i]]) }
    else stop("Unknown argument: ", key)
    i <- i + 1L
  }
  if (is.null(out$snap_root)) stop("--snap-root is required")
  out
}

apply_resource_profile <- function(cfg, res, cellranger = NULL) {
  cfg$resource_profile <- list(
    num_samples = res$num_samples,
    estimated_cells_per_sample = res$estimated_cells_per_sample,
    total_estimated_cells = res$total_estimated_cells,
    resource_tier = res$resource_tier,
    scale_factor = res$scale_factor,
    container_image = cfg$resource_profile$container_image,
    cell_count_source = res$cell_count_source %||% "yaml_or_default"
  )
  if (!is.null(cellranger) && identical(cellranger$source, "cellranger_metrics")) {
    cfg$resource_profile$cellranger_total_cells <- cellranger$total_cells
    cfg$resource_profile$cellranger_max_cells_per_sample <- cellranger$estimated_cells_per_sample_max
  }
  cfg$future_globals_value_upstream <- res$upstream_future_globals_gib
  cfg$future_globals_value_integrative <- res$integrative_future_globals_gib
  cfg$future_globals_value_clustering <- res$cluster_future_globals_gib
  cfg$future_globals_value_contamination <- res$contamination_future_globals_gib
  cfg$future_globals_value_dego <- res$de_go_future_globals_gib
  cfg
}

write_updated_yaml <- function(cfg, master_path, yaml_output, yaml_in_place) {
  generated_default <- file.path(dirname(master_path), "inputs", "project_parameters.generated.yaml")
  out_path <- yaml_output %||% generated_default

  if (isTRUE(yaml_in_place)) {
    backup_path <- paste0(master_path, ".orig")
    if (!file.exists(backup_path)) {
      file.copy(master_path, backup_path)
      cat("Preserved master template at", backup_path, "\n")
    }
    write_yaml(cfg, master_path)
    cat("Updated resource values in-place:", master_path, "\n")
    return(invisible(master_path))
  }

  dir.create(dirname(out_path), recursive = TRUE, showWarnings = FALSE)
  write_yaml(cfg, out_path)
  cat("Wrote resource overlay (master unchanged):", out_path, "\n")
  cat("  Master template:", master_path, "\n")
  invisible(out_path)
}

count_metadata_samples <- function(metadata_path) {
  if (!file.exists(metadata_path)) { warning("Metadata not found — using 8 samples"); return(8L) }
  md <- suppressWarnings(read.delim(metadata_path, stringsAsFactors = FALSE))
  if (!"ID" %in% colnames(md)) stop("Metadata must contain an ID column")
  length(unique(trimws(as.character(md$ID))))
}

validate_metadata_samples <- function(metadata_path, cellranger_sample_ids, data_dir) {
  if (!file.exists(metadata_path)) {
    stop("Project metadata does not exist: ", metadata_path)
  }

  md <- suppressWarnings(read.delim(metadata_path, stringsAsFactors = FALSE))
  if (!"ID" %in% colnames(md)) stop("Metadata must contain an ID column: ", metadata_path)

  raw_metadata_ids <- trimws(as.character(md$ID))
  raw_metadata_ids <- raw_metadata_ids[!is.na(raw_metadata_ids) & nzchar(raw_metadata_ids)]
  duplicate_ids <- sort(unique(raw_metadata_ids[duplicated(raw_metadata_ids)]))
  if (length(duplicate_ids)) {
    stop(
      "Project metadata IDs must be unique. Duplicates: ",
      paste(duplicate_ids, collapse = ", "),
      "\n  Metadata: ", metadata_path
    )
  }
  metadata_ids <- sort(raw_metadata_ids)
  cellranger_ids <- sort(unique(trimws(as.character(cellranger_sample_ids))))

  missing_metadata <- setdiff(cellranger_ids, metadata_ids)
  missing_cellranger <- setdiff(metadata_ids, cellranger_ids)
  if (length(missing_metadata) || length(missing_cellranger)) {
    details <- character()
    if (length(missing_metadata)) {
      details <- c(
        details,
        paste0("  Missing from metadata: ", paste(missing_metadata, collapse = ", "))
      )
    }
    if (length(missing_cellranger)) {
      details <- c(
        details,
        paste0("  Missing Cell Ranger output: ", paste(missing_cellranger, collapse = ", "))
      )
    }
    stop(
      "Project metadata IDs must exactly match completed Cell Ranger sample directories.\n",
      paste(details, collapse = "\n"),
      "\n  Metadata: ", metadata_path,
      "\n  Cell Ranger root: ", data_dir
    )
  }

  invisible(metadata_ids)
}

parse_cellranger_metrics <- function(metrics_path) {
  if (!file.exists(metrics_path)) return(NA_integer_)
  lines <- readLines(metrics_path, warn = FALSE)
  if (length(lines) < 2L) return(NA_integer_)
  val <- sub('^"([^"]*)".*', "\\1", lines[[2L]])
  val <- gsub(",", "", val)
  suppressWarnings(as.integer(val))
}

#' Read Cell Ranger metrics_summary.csv under data_dir (one subdir per sample ID).
#' Returns list with per-sample counts and summary stats; source = "cellranger_metrics".
estimate_cells_from_cellranger <- function(data_dir) {
  if (!dir.exists(data_dir)) {
    return(list(
      num_samples = NA_integer_,
      estimated_cells_per_sample = NA_integer_,
      total_cells = NA_integer_,
      per_sample = list(),
      source = "missing_data_dir"
    ))
  }

  sample_dirs <- list.dirs(data_dir, full.names = TRUE, recursive = FALSE)
  per_sample <- list()
  for (d in sample_dirs) {
    sample_id <- basename(d)
    metrics <- file.path(d, "outs", "metrics_summary.csv")
    n <- parse_cellranger_metrics(metrics)
    if (!is.na(n)) per_sample[[sample_id]] <- n
  }

  if (length(per_sample) == 0L) {
    return(list(
      num_samples = NA_integer_,
      estimated_cells_per_sample = NA_integer_,
      total_cells = NA_integer_,
      per_sample = per_sample,
      source = "no_metrics_found"
    ))
  }

  counts <- unlist(per_sample, use.names = TRUE)
  mean_cells <- as.integer(round(mean(counts)))
  list(
    num_samples = length(counts),
    estimated_cells_per_sample = mean_cells,
    estimated_cells_per_sample_max = as.integer(max(counts)),
    total_cells = sum(counts),
    per_sample = per_sample,
    source = "cellranger_metrics"
  )
}

resolve_project_paths <- function(cfg, snap_root) {
  snap_root <- normalizePath(snap_root, winslash = "/", mustWork = TRUE)
  params <- cfg$cellranger_parameters %||% "DefaultParameters"

  list(
    snap_root = snap_root,
    root_dir = snap_root,
    data_dir = file.path(
      snap_root, "analyses", "cellranger-analysis", "results",
      "02_cellranger_count", params
    ),
    metadata_dir = file.path(snap_root, "data", "project_metadata"),
    gene_markers_dir = file.path(snap_root, "data"),
    container_image = {
      existing <- cfg$resource_profile$container_image %||% ""
      if (nzchar(existing)) existing else file.path(snap_root, "rstudio_4.4.0_seurat_4.4.0_latest.sif")
    }
  )
}

#' Derive root_dir, data_dir, metadata_dir, and container_image from snap_root (for YAML write).
populate_project_paths <- function(cfg, snap_root) {
  paths <- resolve_project_paths(cfg, snap_root)
  cfg$root_dir <- paths$root_dir
  cfg$data_dir <- paths$data_dir
  cfg$metadata_dir <- paths$metadata_dir
  cfg$gene_markers_dir <- paths$gene_markers_dir
  if (is.null(cfg$resource_profile)) cfg$resource_profile <- list()
  cfg$resource_profile$container_image <- paths$container_image
  cfg
}

workflow_toggles <- function(cfg) {
  wp <- cfg$workflow_profile %||% list()
  list(
    run_upstream = isTRUE(wp$run_upstream %||% FALSE),
    run_integrative = isTRUE(wp$run_integrative %||% FALSE),
    run_cluster = isTRUE(wp$run_cluster %||% FALSE),
    run_contamination_removal = isTRUE(wp$run_contamination_removal %||% FALSE),
    run_cell_types = isTRUE(wp$run_cell_types %||% FALSE),
    run_clone_phylogeny = isTRUE(wp$run_clone_phylogeny %||% FALSE),
    run_de_go = isTRUE(wp$run_de_go %||% FALSE),
    run_rshiny = isTRUE(wp$run_rshiny %||% FALSE)
  )
}

LSF_MEMORY_HEADROOM <- 1.2

#' Add headroom so LSF jobs are not killed at the exact memory limit.
apply_lsf_memory_headroom <- function(gb) {
  as.integer(ceiling(as.numeric(gb) * LSF_MEMORY_HEADROOM))
}

compute_resources <- function(num_samples, estimated_cells_per_sample, total_cells_actual = NULL) {
  baseline_samples <- 8L
  baseline_cells <- 50000L
  total_cells <- if (!is.null(total_cells_actual)) {
    as.integer(total_cells_actual)
  } else {
    num_samples * estimated_cells_per_sample
  }
  baseline_total <- baseline_samples * baseline_cells
  sample_scale <- max(1L, as.integer(ceiling(num_samples / baseline_samples)))
  cell_scale <- max(1L, as.integer(ceiling(total_cells / baseline_total)))
  scale <- max(sample_scale, cell_scale)

  res <- list(
    num_samples = num_samples,
    estimated_cells_per_sample = estimated_cells_per_sample,
    total_estimated_cells = total_cells,
    resource_tier = if (scale <= 1L) "default" else if (scale <= 2L) "large" else "xlarge",
    scale_factor = scale,
    upstream_cpu = if (num_samples <= 4L) 8L else if (num_samples <= 12L) 16L else 24L,
    upstream_memory_gb = 30L + (cell_scale - 1L) * 10L,
    upstream_future_globals_gib = 200L + (cell_scale - 1L) * 50L,
    integrative_cpu = if (num_samples <= 8L) 10L else 16L,
    integrative_memory_gb = 96L + (cell_scale - 1L) * 24L,
    integrative_future_globals_gib = 200L + (cell_scale - 1L) * 50L,
    cluster_cpu = if (scale <= 1L) 4L else if (scale <= 2L) 8L else 12L,
    cluster_memory_gb = 48L + (cell_scale - 1L) * 16L,
    cluster_future_globals_gib = 400L + (cell_scale - 1L) * 100L,
    contamination_memory_gb = 96L + (cell_scale - 1L) * 24L,
    contamination_future_globals_gib = 400L + (cell_scale - 1L) * 100L,
    cell_types_memory_gb = 64L + (cell_scale - 1L) * 16L,
    de_go_memory_gb = 32L + (cell_scale - 1L) * 8L,
    de_go_future_globals_gib = 200L + (cell_scale - 1L) * 50L
  )

  for (key in grep("_memory_gb$", names(res), value = TRUE)) {
    res[[key]] <- apply_lsf_memory_headroom(res[[key]])
  }
  res
}

build_cellranger_inputs <- function(data_dir, cellranger) {
  sample_ids <- sort(names(cellranger$per_sample))
  if (!length(sample_ids)) {
    stop(
      "The static from_cellranger workflow requires completed Cell Ranger outputs under:\n  ",
      data_dir
    )
  }

  unname(lapply(sample_ids, function(sample_id) {
    count_output <- normalizePath(
      file.path(data_dir, sample_id, "outs"),
      winslash = "/",
      mustWork = TRUE
    )
    has_matrix <- file.exists(file.path(count_output, "filtered_feature_bc_matrix.h5")) ||
      dir.exists(file.path(count_output, "filtered_feature_bc_matrix"))
    if (!has_matrix) {
      stop("Cell Ranger output has no filtered feature matrix: ", count_output)
    }
    list(id = sample_id, count_output = count_output)
  }))
}

build_sprocket_inputs <- function(
  snap_root,
  container_image,
  notify_email,
  toggles,
  cellranger_inputs
) {
  list(
    `daedalus_from_cellranger.cellranger_inputs` = cellranger_inputs,
    `daedalus_from_cellranger.resource_estimator_container` = container_image,
    `daedalus_from_cellranger.project_root` = snap_root,
    `daedalus_from_cellranger.downstream_container` = container_image,
    `daedalus_from_cellranger.notify_email` = notify_email,
    `daedalus_from_cellranger.run_upstream` = toggles$run_upstream,
    `daedalus_from_cellranger.run_integrative` = toggles$run_integrative,
    `daedalus_from_cellranger.run_cluster` = toggles$run_cluster,
    `daedalus_from_cellranger.run_contamination_removal` = toggles$run_contamination_removal,
    `daedalus_from_cellranger.run_cell_types` = toggles$run_cell_types,
    `daedalus_from_cellranger.run_clone_phylogeny` = toggles$run_clone_phylogeny,
    `daedalus_from_cellranger.run_de_go` = toggles$run_de_go,
    `daedalus_from_cellranger.run_rshiny` = toggles$run_rshiny
  )
}

main <- function() {
  args <- parse_args(commandArgs(trailingOnly = TRUE))
  snap_root <- normalizePath(args$snap_root, mustWork = TRUE)
  config_path <- file.path(snap_root, "project_parameters.Config.yaml")
  cfg <- read_yaml(config_path)
  paths <- resolve_project_paths(cfg, snap_root)

  metadata_path <- file.path(paths$metadata_dir, cfg$metadata_file %||% "project_metadata.tsv")
  cellranger <- estimate_cells_from_cellranger(paths$data_dir)

  num_samples <- cfg$resource_profile$num_samples %||% count_metadata_samples(metadata_path)
  if (is.null(cfg$resource_profile$num_samples) && identical(cellranger$source, "cellranger_metrics")) {
    num_samples <- cellranger$num_samples
  }

  estimated_cells <- args$estimated_cells_per_sample
  total_cells_actual <- NULL
  cell_count_source <- "cli_override"

  if (is.null(estimated_cells)) {
    if (identical(cellranger$source, "cellranger_metrics")) {
      estimated_cells <- cellranger$estimated_cells_per_sample
      total_cells_actual <- cellranger$total_cells
      cell_count_source <- "cellranger_metrics"
    } else {
      stop(
        "Could not read Cell Ranger metrics under:\n  ", paths$data_dir, "\n",
        "Complete Cell Ranger first, or pass --estimated-cells-per-sample N to override.\n",
        "Expected: <data_dir>/<sample_id>/outs/metrics_summary.csv"
      )
    }
  }

  res <- compute_resources(
    as.integer(num_samples),
    as.integer(estimated_cells),
    total_cells_actual = total_cells_actual
  )
  res$cell_count_source <- cell_count_source
  if (identical(cellranger$source, "cellranger_metrics")) {
    res$cellranger_observed <- cellranger
    res$total_estimated_cells <- cellranger$total_cells
  }
  cellranger_inputs <- build_cellranger_inputs(paths$data_dir, cellranger)
  toggles <- workflow_toggles(cfg)
  if (any(unlist(toggles, use.names = FALSE))) {
    validate_metadata_samples(metadata_path, names(cellranger$per_sample), paths$data_dir)
  }
  container_image <- sprocket_container_uri(paths$container_image, snap_root)

  cat("Downstream resource estimate:", snap_root, "\n")
  cat("  tier:", res$resource_tier, " samples:", res$num_samples,
      " cells/sample (", cell_count_source, "):", res$estimated_cells_per_sample,
      " total cells:", res$total_estimated_cells, "\n")
  if (identical(cellranger$source, "cellranger_metrics")) {
    cat("  Cell Ranger observed: total=", cellranger$total_cells,
        " mean/sample=", cellranger$estimated_cells_per_sample,
        " max/sample=", cellranger$estimated_cells_per_sample_max, "\n")
    for (nm in names(cellranger$per_sample)) {
      cat("    ", nm, ":", cellranger$per_sample[[nm]], "cells\n")
    }
  }
  cat("  upstream:", res$upstream_cpu, "cpu", res$upstream_memory_gb, "GB future:", res$upstream_future_globals_gib, "GiB\n")
  cat("  integrative:", res$integrative_cpu, "cpu", res$integrative_memory_gb, "GB future:", res$integrative_future_globals_gib, "GiB\n")
  cat("  cluster:", res$cluster_cpu, "cpu", res$cluster_memory_gb, "GB future:", res$cluster_future_globals_gib, "GiB\n")

  if (isTRUE(args$update_yaml)) {
    cfg <- populate_project_paths(cfg, snap_root)
    cfg <- apply_resource_profile(cfg, res, cellranger)
    write_updated_yaml(
      cfg = cfg,
      master_path = config_path,
      yaml_output = args$yaml_output,
      yaml_in_place = isTRUE(args$yaml_in_place)
    )
  }

  notify_email <- cfg$CONTACT_EMAIL %||% "user.name@stjude.org"
  payload <- list(
    resource_estimate = res,
    sprocket_inputs = build_sprocket_inputs(
      snap_root,
      container_image,
      notify_email,
      toggles,
      cellranger_inputs
    )
  )

  if (!is.null(args$output)) {
    if (!requireNamespace("jsonlite", quietly = TRUE)) stop("Install jsonlite")
    dir.create(dirname(normalizePath(args$output, mustWork = FALSE)), recursive = TRUE, showWarnings = FALSE)
    jsonlite::write_json(payload, args$output, auto_unbox = TRUE, pretty = TRUE)
    cat("Wrote", args$output, "\n")

    sprocket_inputs_path <- file.path(dirname(args$output), "sprocket_inputs.json")
    jsonlite::write_json(
      payload$sprocket_inputs,
      sprocket_inputs_path,
      auto_unbox = TRUE,
      pretty = TRUE
    )
    cat("Wrote", sprocket_inputs_path, "\n")
  }
  invisible(payload)
}

if (sys.nframe() == 0L) main()
