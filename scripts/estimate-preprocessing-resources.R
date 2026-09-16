#!/usr/bin/env Rscript

abort <- function(...) stop(..., call. = FALSE)

read_estimated_cells <- function(path) {
  if (!file.exists(path) || dir.exists(path)) abort("metrics file does not exist: ", path)
  metrics <- tryCatch(
    read.csv(path, check.names = FALSE, stringsAsFactors = FALSE),
    error = function(error) abort("failed to parse metrics CSV ", path, ": ", conditionMessage(error))
  )
  matches <- which(names(metrics) == "Estimated Number of Cells")
  if (length(matches) != 1L) {
    abort("metrics CSV must contain exactly one 'Estimated Number of Cells' column: ", path)
  }
  if (nrow(metrics) != 1L) abort("metrics CSV must contain exactly one data row: ", path)
  raw <- gsub(",", "", trimws(as.character(metrics[[matches]][[1L]])), fixed = TRUE)
  value <- suppressWarnings(as.numeric(raw))
  if (length(value) != 1L || is.na(value) || !is.finite(value) ||
      value != as.integer(value) || value < 1L) {
    abort("invalid Estimated Number of Cells value in ", path, ": ", raw)
  }
  as.integer(value)
}

compute_resources <- function(num_samples, total_cells) {
  num_samples <- as.integer(num_samples)
  total_cells <- as.integer(total_cells)
  if (is.na(num_samples) || num_samples < 1L) abort("num_samples must be >= 1")
  if (is.na(total_cells) || total_cells < 1L) abort("total_cells must be >= 1")
  sample_scale <- max(1L, as.integer(ceiling(num_samples / 8)))
  cell_scale <- max(1L, as.integer(ceiling(total_cells / 400000)))
  list(
    baseline_samples = 8L,
    baseline_total_cells = 400000L,
    num_samples = num_samples,
    total_cells = total_cells,
    sample_scale = sample_scale,
    cell_scale = cell_scale,
    upstream_cpu = if (num_samples <= 4L) 8L else if (num_samples <= 12L) 16L else 24L,
    upstream_memory_gb = as.integer(ceiling((30L + 10L * (cell_scale - 1L)) * 1.2)),
    upstream_future_globals_gib = 200L + 50L * (cell_scale - 1L),
    integrative_cpu = if (num_samples <= 8L) 10L else 16L,
    integrative_memory_gb = as.integer(ceiling((96L + 24L * (cell_scale - 1L)) * 1.2)),
    integrative_future_globals_gib = 200L + 50L * (cell_scale - 1L)
  )
}

estimate_from_metrics <- function(sample_ids, metrics_paths) {
  if (!length(sample_ids) || length(sample_ids) != length(metrics_paths)) {
    abort("sample ID and metrics file counts must match and be nonzero")
  }
  if (any(!nzchar(sample_ids))) abort("sample IDs must be nonempty")
  if (anyDuplicated(sample_ids)) abort("duplicate sample metrics: ", paste(unique(sample_ids[duplicated(sample_ids)]), collapse = ", "))
  counts <- vapply(metrics_paths, read_estimated_cells, integer(1))
  resources <- compute_resources(length(sample_ids), sum(counts))
  resources$sample_metrics <- unname(Map(function(id, path, cells) {
    list(id = id, metrics = normalizePath(path, winslash = "/", mustWork = TRUE), estimated_cells = cells)
  }, sample_ids, metrics_paths, counts))
  resources
}

json_escape <- function(value) {
  value <- gsub("\\\\", "\\\\\\\\", value)
  value <- gsub("\"", "\\\\\"", value, fixed = TRUE)
  value <- gsub("\n", "\\\\n", value, fixed = TRUE)
  paste0("\"", value, "\"")
}

write_resource_json <- function(resources, path) {
  resource_names <- c(
    "upstream_cpu",
    "upstream_memory_gb",
    "upstream_future_globals_gib",
    "integrative_cpu",
    "integrative_memory_gb",
    "integrative_future_globals_gib"
  )
  scalars <- vapply(resource_names, function(name) {
    paste0("  ", json_escape(name), ": ", as.integer(resources[[name]]))
  }, character(1))
  lines <- c(
    "{",
    paste(scalars, collapse = ",\n"),
    "}"
  )
  writeLines(lines, path)
}

write_resource_outputs <- function(resources, output_dir) {
  dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)
  write_resource_json(resources, file.path(output_dir, "resource_estimate.json"))
  invisible(resources)
}

parse_args <- function(args) {
  values <- list(sample_ids_file = NULL, metrics_file_list = NULL, output_dir = NULL)
  index <- 1L
  while (index <= length(args)) {
    key <- args[[index]]
    mapped <- switch(
      key,
      "--sample-ids-file" = "sample_ids_file",
      "--metrics-file-list" = "metrics_file_list",
      "--output-dir" = "output_dir",
      abort("unknown argument: ", key)
    )
    index <- index + 1L
    if (index > length(args)) abort("missing value for ", key)
    values[[mapped]] <- args[[index]]
    index <- index + 1L
  }
  missing <- names(values)[vapply(values, is.null, logical(1))]
  if (length(missing)) abort("missing required arguments: ", paste(missing, collapse = ", "))
  values
}

main <- function(args) {
  args <- parse_args(args)
  sample_ids <- readLines(args$sample_ids_file, warn = FALSE)
  metrics_paths <- readLines(args$metrics_file_list, warn = FALSE)
  write_resource_outputs(estimate_from_metrics(sample_ids, metrics_paths), args$output_dir)
}

if (sys.nframe() == 0L) main(commandArgs(trailingOnly = TRUE))
