version 1.3

## An existing Cell Ranger output supplied for one sample.
struct ExistingCellRangerInput {
    ## The sample identifier, matching the metadata `ID`.
    String id
    ## The Cell Ranger `outs` directory for the sample.
    Directory count_output
}

## A validated Cell Ranger output with its estimated cell count.
struct CellRangerOutput {
    ## The sample identifier.
    String sample_id
    ## The Cell Ranger `outs` directory for the sample.
    Directory count_output
    ## The Cell Ranger `metrics_summary.csv` file.
    File metrics_csv
    ## The estimated number of cells reported by Cell Ranger.
    Int estimated_cells
}

## Resource requests derived from the number of samples and estimated cells.
struct DownstreamResources {
    ## The number of CPU cores for upstream analysis.
    Int upstream_cpu
    ## The upstream-analysis memory request in GB.
    Int upstream_memory_gb
    ## The upstream-analysis `future.globals.maxSize` limit in GiB.
    Int upstream_future_globals_gib
    ## The number of CPU cores for integrative analysis.
    Int integrative_cpu
    ## The integrative-analysis memory request in GB.
    Int integrative_memory_gb
    ## The integrative-analysis `future.globals.maxSize` limit in GiB.
    Int integrative_future_globals_gib
    ## The number of CPU cores for cluster analysis.
    Int cluster_cpu
    ## The cluster-analysis memory request in GB.
    Int cluster_memory_gb
    ## The cluster-analysis `future.globals.maxSize` limit in GiB.
    Int cluster_future_globals_gib
    ## The number of CPU cores for contamination-removal analysis.
    Int contamination_cpu
    ## The contamination-removal memory request in GB.
    Int contamination_memory_gb
    ## The contamination-removal `future.globals.maxSize` limit in GiB.
    Int contamination_future_globals_gib
    ## The number of CPU cores for cell-type annotation.
    Int cell_types_cpu
    ## The cell-type-annotation memory request in GB.
    Int cell_types_memory_gb
    ## The number of CPU cores for clone-phylogeny analysis.
    Int clone_phylogeny_cpu
    ## The clone-phylogeny memory request in GB.
    Int clone_phylogeny_memory_gb
    ## The number of CPU cores for differential-expression and gene-ontology analysis.
    Int de_go_cpu
    ## The differential-expression and gene-ontology memory request in GB.
    Int de_go_memory_gb
    ## The differential-expression and gene-ontology `future.globals.maxSize` limit in GiB.
    Int de_go_future_globals_gib
    ## The number of CPU cores for R Shiny app generation.
    Int rshiny_cpu
    ## The R Shiny app generation memory request in GB.
    Int rshiny_memory_gb
}
