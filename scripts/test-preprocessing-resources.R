#!/usr/bin/env Rscript

args <- commandArgs(trailingOnly = FALSE)
script_path <- sub("^--file=", "", args[grepl("^--file=", args)])
scripts_dir <- dirname(normalizePath(script_path))
estimator <- new.env(parent = globalenv())
sys.source(file.path(scripts_dir, "estimate-preprocessing-resources.R"), envir = estimator)

assert_equal <- function(actual, expected, label) {
  if (!identical(as.integer(actual), as.integer(expected))) {
    stop(label, ": expected ", expected, ", got ", actual, call. = FALSE)
  }
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

assert_equal(estimator$compute_resources(4L, 400000L)$upstream_cpu, 8L, "upstream <=4")
assert_equal(estimator$compute_resources(5L, 400000L)$upstream_cpu, 16L, "upstream 5")
assert_equal(estimator$compute_resources(13L, 400000L)$upstream_cpu, 24L, "upstream >12")
assert_equal(estimator$compute_resources(8L, 400000L)$integrative_cpu, 10L, "integrative <=8")
assert_equal(estimator$compute_resources(9L, 400000L)$integrative_cpu, 16L, "integrative >8")

baseline <- estimator$compute_resources(8L, 400000L)
scaled <- estimator$compute_resources(8L, 400001L)
assert_equal(baseline$upstream_memory_gb, 36L, "baseline upstream memory")
assert_equal(baseline$integrative_memory_gb, 116L, "baseline integrative memory")
assert_equal(scaled$upstream_memory_gb, 48L, "scaled upstream memory")
assert_equal(scaled$integrative_memory_gb, 144L, "scaled integrative memory")
assert_equal(scaled$upstream_future_globals_gib, 250L, "scaled upstream globals")

root <- tempfile("preprocessing-resources-")
dir.create(root)
quoted <- file.path(root, "quoted.csv")
large <- file.path(root, "large.csv")
malformed <- file.path(root, "malformed.csv")
missing <- file.path(root, "missing.csv")
writeLines(c(
  "\"Estimated Number of Cells\",\"Mean Reads per Cell\"",
  "\"750\",\"20,000\""
), quoted)
writeLines(c("Estimated Number of Cells,Mean Reads per Cell", "400001,20000"), large)
writeLines(c("Estimated Number of Cells,Mean Reads per Cell", "not-a-number,20000"), malformed)
writeLines(c("Mean Reads per Cell", "20000"), missing)

assert_equal(estimator$read_estimated_cells(quoted), 750L, "quoted low cell count")
expect_error(estimator$read_estimated_cells(malformed), "invalid Estimated")
expect_error(estimator$read_estimated_cells(missing), "exactly one")
expect_error(estimator$read_estimated_cells(file.path(root, "absent.csv")), "does not exist")
expect_error(estimator$estimate_from_metrics(c("sample", "sample"), c(quoted, large)), "duplicate")

resources <- estimator$estimate_from_metrics(c("small", "large"), c(quoted, large))
estimator$write_resource_outputs(resources, root)
expected <- c(
  "resource_estimate.json"
)
if (any(!file.exists(file.path(root, expected)))) stop("resource outputs are incomplete")
if (!requireNamespace("jsonlite", quietly = TRUE)) stop("Install jsonlite")
resource_json <- jsonlite::fromJSON(file.path(root, "resource_estimate.json"))
if (!setequal(names(resource_json), c(
  "upstream_cpu",
  "upstream_memory_gb",
  "upstream_future_globals_gib",
  "integrative_cpu",
  "integrative_memory_gb",
  "integrative_future_globals_gib"
))) stop("resource JSON does not match DownstreamResources")
cat("preprocessing resource tests passed\n")
