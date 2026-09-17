version 1.3

struct ExistingCellRangerInput {
    String id
    Directory count_output
}

struct CellRangerOutput {
    String sample_id
    Directory count_output
    File metrics_csv
    Int estimated_cells
}

struct DownstreamResources {
    Int upstream_cpu
    Int upstream_memory_gb
    Int upstream_future_globals_gib
    Int integrative_cpu
    Int integrative_memory_gb
    Int integrative_future_globals_gib
    Int cluster_cpu
    Int cluster_memory_gb
    Int cluster_future_globals_gib
    Int contamination_cpu
    Int contamination_memory_gb
    Int contamination_future_globals_gib
    Int cell_types_cpu
    Int cell_types_memory_gb
    Int clone_phylogeny_cpu
    Int clone_phylogeny_memory_gb
    Int de_go_cpu
    Int de_go_memory_gb
    Int de_go_future_globals_gib
    Int rshiny_cpu
    Int rshiny_memory_gb
}
