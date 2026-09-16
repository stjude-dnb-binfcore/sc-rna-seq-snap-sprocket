#!/usr/bin/env Rscript

abort <- function(...) stop(..., call. = FALSE)

require_dependency <- function(package) {
  if (!requireNamespace(package, quietly = TRUE)) {
    abort("required R package is not installed: ", package)
  }
}

parse_args <- function(args) {
  values <- list(config = NULL, output = NULL, manifest = NULL)
  index <- 1L
  while (index <= length(args)) {
    key <- args[[index]]
    if (!key %in% c("--config", "--output", "--manifest")) {
      abort("unknown argument: ", key)
    }
    index <- index + 1L
    if (index > length(args)) abort("missing value for ", key)
    values[[substring(key, 3L)]] <- args[[index]]
    index <- index + 1L
  }
  missing <- names(values)[vapply(values, is.null, logical(1))]
  if (length(missing)) abort("missing required arguments: --", paste(missing, collapse = ", --"))
  values
}

validate_keys <- function(value, required, context) {
  if (!is.list(value) || is.null(names(value))) abort(context, " must be a mapping")
  unknown <- setdiff(names(value), required)
  missing <- setdiff(required, names(value))
  if (length(unknown)) abort(context, " contains unknown keys: ", paste(unknown, collapse = ", "))
  if (length(missing)) abort(context, " is missing required keys: ", paste(missing, collapse = ", "))
}

is_scalar_string <- function(value) {
  is.character(value) && length(value) == 1L && !is.na(value) && nzchar(trimws(value))
}

validate_string <- function(value, context) {
  if (!is_scalar_string(value)) abort(context, " must be a nonempty string")
  value
}

validate_integer <- function(value, context, minimum = 1L) {
  if (!is.numeric(value) || length(value) != 1L || is.na(value) ||
      !is.finite(value) || value != as.integer(value) || value < minimum) {
    abort(context, " must be an integer >= ", minimum)
  }
  as.integer(value)
}

validate_boolean <- function(value, context) {
  if (!is.logical(value) || length(value) != 1L || is.na(value)) {
    abort(context, " must be a boolean")
  }
  value
}

validate_absolute_path <- function(path, context, kind = c("any", "file", "directory")) {
  kind <- match.arg(kind)
  path <- validate_string(path, context)
  if (!startsWith(path, "/")) abort(context, " must be an absolute path")
  if (!file.exists(path)) abort(context, " does not exist: ", path)
  if (kind == "file" && dir.exists(path)) abort(context, " must be a file: ", path)
  if (kind == "directory" && !dir.exists(path)) abort(context, " must be a directory: ", path)
  normalizePath(path, winslash = "/", mustWork = TRUE)
}

validate_container <- function(value, context) {
  value <- validate_string(value, context)
  path <- if (startsWith(value, "file://")) substring(value, 8L) else value
  if (!startsWith(path, "/") || !grepl("\\.sif$", path, ignore.case = TRUE)) {
    abort(context, " must be a file:// URI or absolute .sif path")
  }
  path <- validate_absolute_path(path, context, "file")
  paste0("file://", path)
}

split_csv <- function(value, context) {
  values <- trimws(strsplit(value, ",", fixed = TRUE)[[1L]])
  if (!length(values) || any(!nzchar(values))) abort(context, " contains an empty comma-separated value")
  values
}

read_metadata <- function(path) {
  metadata <- tryCatch(
    read.delim(
      path,
      header = TRUE,
      sep = "\t",
      quote = "",
      comment.char = "",
      colClasses = "character",
      check.names = FALSE,
      stringsAsFactors = FALSE
    ),
    error = function(error) abort("failed to parse metadata: ", conditionMessage(error))
  )
  required <- c("ID", "SAMPLE", "FASTQ")
  missing <- setdiff(required, names(metadata))
  if (length(missing)) abort("metadata is missing required columns: ", paste(missing, collapse = ", "))
  metadata <- metadata[, required, drop = FALSE]
  if (!nrow(metadata)) abort("metadata must contain at least one row")
  if (anyNA(metadata) || any(!nzchar(trimws(as.matrix(metadata))))) {
    abort("metadata ID, SAMPLE, and FASTQ values must be nonempty")
  }
  if (anyDuplicated(metadata)) abort("metadata contains duplicate identical rows")

  grouped <- list()
  order <- character()
  for (row in seq_len(nrow(metadata))) {
    id <- trimws(metadata$ID[[row]])
    sample_names <- split_csv(metadata$SAMPLE[[row]], paste0("metadata SAMPLE row ", row))
    fastq_dirs <- split_csv(metadata$FASTQ[[row]], paste0("metadata FASTQ row ", row))
    if (length(sample_names) != length(fastq_dirs)) {
      abort("metadata row ", row, " has mismatched SAMPLE and FASTQ value counts")
    }
    fastq_dirs <- vapply(
      fastq_dirs,
      validate_absolute_path,
      character(1),
      context = paste0("metadata FASTQ row ", row),
      kind = "directory"
    )
    if (is.null(grouped[[id]])) {
      order <- c(order, id)
      grouped[[id]] <- list(id = id, fastq_dirs = character(), sample_names = character())
    }
    grouped[[id]]$fastq_dirs <- c(grouped[[id]]$fastq_dirs, unname(fastq_dirs))
    grouped[[id]]$sample_names <- c(grouped[[id]]$sample_names, sample_names)
  }
  lapply(unname(grouped[order]), function(sample) {
    sample$fastq_dirs <- unname(as.list(sample$fastq_dirs))
    sample$sample_names <- unname(as.list(sample$sample_names))
    sample
  })
}

atomic_write_json <- function(value, path) {
  directory <- dirname(path)
  dir.create(directory, recursive = TRUE, showWarnings = FALSE)
  temporary <- tempfile(paste0(".", basename(path), "."), tmpdir = directory)
  on.exit(unlink(temporary), add = TRUE)
  jsonlite::write_json(value, temporary, pretty = TRUE, auto_unbox = TRUE, null = "null")
  if (!file.rename(temporary, path)) abort("failed to atomically replace ", path)
}

absolute_output_path <- function(path) {
  directory <- dirname(path)
  dir.create(directory, recursive = TRUE, showWarnings = FALSE)
  file.path(normalizePath(directory, winslash = "/", mustWork = TRUE), basename(path))
}

render_inputs <- function(config_path, output_path, manifest_path) {
  require_dependency("yaml")
  require_dependency("jsonlite")
  config_path <- validate_absolute_path(
    normalizePath(config_path, winslash = "/", mustWork = FALSE),
    "config",
    "file"
  )
  config <- tryCatch(
    yaml::read_yaml(config_path),
    error = function(error) abort("failed to parse YAML config: ", conditionMessage(error))
  )

  validate_keys(config, c("project", "containers", "resources", "cellranger"), "config")
  validate_keys(config$project, c("name", "metadata_tsv", "genome_reference", "output_dir"), "project")
  validate_keys(config$containers, c("fastqc_multiqc", "cellranger", "resource_estimator"), "containers")
  validate_keys(config$resources, c("fastqc", "multiqc", "cellranger", "estimator"), "resources")
  validate_keys(config$cellranger, c("create_bam", "chemistry", "expected_cells"), "cellranger")

  project <- list(
    name = validate_string(config$project$name, "project.name"),
    metadata_tsv = validate_absolute_path(config$project$metadata_tsv, "project.metadata_tsv", "file"),
    genome_reference = validate_absolute_path(config$project$genome_reference, "project.genome_reference", "directory"),
    output_dir = validate_absolute_path(config$project$output_dir, "project.output_dir", "directory")
  )
  containers <- list(
    fastqc_multiqc = validate_container(config$containers$fastqc_multiqc, "containers.fastqc_multiqc"),
    cellranger = validate_container(config$containers$cellranger, "containers.cellranger"),
    resource_estimator = validate_container(config$containers$resource_estimator, "containers.resource_estimator")
  )

  resources <- list()
  for (name in c("fastqc", "multiqc", "cellranger", "estimator")) {
    validate_keys(config$resources[[name]], c("cpu", "memory_gb"), paste0("resources.", name))
    resources[[name]] <- list(
      cpu = validate_integer(config$resources[[name]]$cpu, paste0("resources.", name, ".cpu")),
      memory_gb = validate_integer(
        config$resources[[name]]$memory_gb,
        paste0("resources.", name, ".memory_gb"),
        if (name == "cellranger") 12L else 1L
      )
    )
  }

  chemistry <- config$cellranger$chemistry
  if (!is.null(chemistry)) chemistry <- validate_string(chemistry, "cellranger.chemistry")
  expected_cells <- config$cellranger$expected_cells
  if (!is.null(expected_cells)) {
    expected_cells <- validate_integer(expected_cells, "cellranger.expected_cells")
  }
  create_bam <- validate_boolean(config$cellranger$create_bam, "cellranger.create_bam")
  samples <- read_metadata(project$metadata_tsv)

  manifest_path <- absolute_output_path(manifest_path)
  output_path <- absolute_output_path(output_path)
  manifest <- list(
    project = project,
    source_paths = list(config = config_path, metadata_tsv = project$metadata_tsv),
    samples = samples
  )
  atomic_write_json(manifest, manifest_path)

  prefix <- "snap_preprocessing."
  inputs <- list()
  inputs[[paste0(prefix, "project_name")]] <- project$name
  inputs[[paste0(prefix, "samples")]] <- samples
  inputs[[paste0(prefix, "genome_reference")]] <- project$genome_reference
  inputs[[paste0(prefix, "normalized_sample_manifest")]] <- manifest_path
  inputs[[paste0(prefix, "fastqc_multiqc_container")]] <- containers$fastqc_multiqc
  inputs[[paste0(prefix, "cellranger_container")]] <- containers$cellranger
  inputs[[paste0(prefix, "resource_estimator_container")]] <- containers$resource_estimator
  for (name in names(resources)) {
    inputs[[paste0(prefix, name, "_cpu")]] <- resources[[name]]$cpu
    inputs[[paste0(prefix, name, "_memory_gb")]] <- resources[[name]]$memory_gb
  }
  inputs[[paste0(prefix, "cellranger_create_bam")]] <- create_bam
  inputs[[paste0(prefix, "cellranger_chemistry")]] <- chemistry
  inputs[[paste0(prefix, "cellranger_expected_cells")]] <- expected_cells
  atomic_write_json(inputs, output_path)
}

if (sys.nframe() == 0L) {
  args <- parse_args(commandArgs(trailingOnly = TRUE))
  render_inputs(args$config, args$output, args$manifest)
}
