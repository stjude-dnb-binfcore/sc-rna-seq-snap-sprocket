#!/usr/bin/env Rscript

args <- commandArgs(trailingOnly = FALSE)
script_path <- sub("^--file=", "", args[grepl("^--file=", args)])
scripts_dir <- dirname(normalizePath(script_path))
repo_root <- dirname(scripts_dir)

if (!requireNamespace("jsonlite", quietly = TRUE)) stop("Install jsonlite")

renderer <- new.env(parent = globalenv())
sys.source(file.path(scripts_dir, "render-preprocessing-inputs.R"), envir = renderer)

assert <- function(condition, message) {
  if (!isTRUE(condition)) stop(message, call. = FALSE)
}

expect_error <- function(expression, pattern) {
  error <- tryCatch({
    force(expression)
    NULL
  }, error = identity)
  if (is.null(error) || !grepl(pattern, conditionMessage(error))) {
    stop("expected error matching: ", pattern, call. = FALSE)
  }
}

make_project <- function(metadata_lines = NULL) {
  root <- tempfile("preprocessing-inputs-")
  paths <- file.path(root, c(
    "fastq-a", "fastq-b", "fastq-c", "reference", "output", "containers"
  ))
  invisible(vapply(paths, dir.create, logical(1), recursive = TRUE))
  file.create(file.path(root, "fastq-a", "a_R2_001.fastq.gz"))
  file.create(file.path(root, "fastq-b", "b_R2_001.fastq.gz"))
  file.create(file.path(root, "fastq-c", "c_R2_001.fastq.gz"))
  file.create(file.path(root, "reference", "reference.json"))
  containers <- file.path(root, "containers", c("fastqc.sif", "cellranger.sif", "estimator.sif"))
  file.create(containers)

  if (is.null(metadata_lines)) {
    metadata_lines <- c(
      "ID\tSAMPLE\tFASTQ",
      paste("sample-a", "library-a,library-b", paste(file.path(root, c("fastq-a", "fastq-b")), collapse = ","), sep = "\t"),
      paste("sample-b", "library-c", file.path(root, "fastq-c"), sep = "\t")
    )
  }
  metadata <- file.path(root, "metadata.tsv")
  writeLines(metadata_lines, metadata)
  config <- file.path(root, "preprocessing.yaml")
  writeLines(c(
    "project:",
    "  name: test-project",
    paste0("  metadata_tsv: ", metadata),
    paste0("  genome_reference: ", file.path(root, "reference")),
    paste0("  output_dir: ", file.path(root, "output")),
    "containers:",
    paste0("  fastqc_multiqc: ", containers[[1L]]),
    paste0("  cellranger: file://", containers[[2L]]),
    paste0("  resource_estimator: ", containers[[3L]]),
    "resources:",
    "  fastqc: { cpu: 2, memory_gb: 4 }",
    "  multiqc: { cpu: 1, memory_gb: 2 }",
    "  cellranger: { cpu: 8, memory_gb: 32 }",
    "  estimator: { cpu: 1, memory_gb: 2 }",
    "cellranger:",
    "  create_bam: true",
    "  chemistry: null",
    "  expected_cells: 2500"
  ), config)
  list(root = root, config = config)
}

project <- make_project()
inputs_path <- file.path(project$root, "inputs.json")
manifest_path <- file.path(project$root, "manifest.json")
renderer$render_inputs(project$config, inputs_path, manifest_path)
inputs <- jsonlite::fromJSON(inputs_path, simplifyVector = FALSE)
samples <- inputs[["snap_preprocessing.samples"]]

assert(length(samples) == 2L, "repeated IDs were not grouped")
assert(length(samples[[1L]]$fastq_dirs) == 2L, "multi-directory sample was not retained")
assert(is.list(samples[[2L]]$fastq_dirs), "single FASTQ directory was serialized as a scalar")
assert(length(samples[[2L]]$fastq_dirs) == 1L, "single FASTQ directory was not retained")
assert(is.list(samples[[2L]]$sample_names), "single sample name was serialized as a scalar")
assert(file.exists(inputs[["snap_preprocessing.normalized_sample_manifest"]]), "manifest input does not exist")

unknown <- readLines(project$config)
writeLines(c(unknown, "unknown: true"), project$config)
expect_error(renderer$render_inputs(project$config, inputs_path, manifest_path), "unknown keys")

duplicate <- make_project(c(
  "ID\tSAMPLE\tFASTQ",
  "sample-a\tlibrary-a\t/does/not/matter",
  "sample-a\tlibrary-a\t/does/not/matter"
))
expect_error(
  renderer$render_inputs(
    duplicate$config,
    file.path(duplicate$root, "inputs.json"),
    file.path(duplicate$root, "manifest.json")
  ),
  "duplicate identical"
)

workflow <- readLines(file.path(repo_root, "workflows", "preprocessing.wdl"))
assert(any(grepl("^workflow snap_preprocessing \\{", workflow)), "renderer prefix and workflow name drifted")
cat("preprocessing input tests passed\n")
