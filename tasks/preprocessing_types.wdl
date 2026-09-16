version 1.3

struct SampleInput {
  String id
  Array[Directory]+ fastq_dirs
  Array[String]+ sample_names
}

struct DownstreamResources {
  Int upstream_cpu
  Int upstream_memory_gb
  Int upstream_future_globals_gib
  Int integrative_cpu
  Int integrative_memory_gb
  Int integrative_future_globals_gib
}
