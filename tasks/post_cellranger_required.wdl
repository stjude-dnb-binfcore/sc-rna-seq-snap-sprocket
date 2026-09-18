version 1.3

# Assumes FastQC and Cell Ranger have already completed.
#
# Container execution is handled by Sprocket (lsf_apptainer backend) via
# requirements.container — do not call singularity/apptainer in command blocks.
# Per-module email: LSF bsub -B/-N/-u CONTACT_EMAIL (inputs/sprocket.generated.toml).
# Workflow email: scripts/snap-notify-email.sh from launch-snap-sprocket.sh.
task run_upstream {
    meta {
        description: "Upstream Seurat QC module"
    }

    input {
        String snap_root
        String container_image
        String notify_email
        Int cpu = 16
        Int memory_gb = 30
        Int future_globals_gib = 200
    }

    command <<<
        set -euo pipefail
        TASK_DIR="$(pwd)"
        echo "Module: upstream  LSF mail: ~{notify_email}"
        export SNAP_CONFIG_FILE="~{snap_root}/inputs/project_parameters.generated.yaml"
        export FUTURE_GLOBALS_MAXSIZE_GIB="~{future_globals_gib}"
        cd "~{snap_root}/analyses/upstream-analysis"
        bash run-upstream-analysis.sh
        echo "done" > "${TASK_DIR}/upstream.done"
    >>>

    output {
        File done_flag = "upstream.done"
    }

    requirements {
        cpu: cpu
        memory: "~{memory_gb} GB"
        container: container_image
    }
}

task run_cluster {
    meta {
        description: "Cluster cell calling module"
    }

    input {
        String snap_root
        String container_image
        String notify_email
        Int cpu = 4
        Int memory_gb = 48
        Int future_globals_gib = 400
    }

    command <<<
        set -euo pipefail
        TASK_DIR="$(pwd)"
        echo "Module: cluster  LSF mail: ~{notify_email}"
        export SNAP_CONFIG_FILE="~{snap_root}/inputs/project_parameters.generated.yaml"
        export FUTURE_GLOBALS_MAXSIZE_GIB="~{future_globals_gib}"
        cd "~{snap_root}/analyses/cluster-cell-calling"
        bash run-cluster-cell-calling.sh
        echo "done" > "${TASK_DIR}/cluster.done"
    >>>

    output {
        File done_flag = "cluster.done"
    }

    requirements {
        cpu: cpu
        memory: "~{memory_gb} GB"
        container: container_image
    }
}

task run_cell_types {
    meta {
        description: "Cell types annotation module"
    }

    input {
        String snap_root
        String container_image
        String notify_email
        Int cpu = 4
        Int memory_gb = 64
    }

    command <<<
        set -euo pipefail
        TASK_DIR="$(pwd)"
        echo "Module: cell_types  LSF mail: ~{notify_email}"
        export SNAP_CONFIG_FILE="~{snap_root}/inputs/project_parameters.generated.yaml"
        cd "~{snap_root}/analyses/cell-types-annotation"
        bash run-cell-types-annotation.sh
        echo "done" > "${TASK_DIR}/cell_types.done"
    >>>

    output {
        File done_flag = "cell_types.done"
    }

    requirements {
        cpu: cpu
        memory: "~{memory_gb} GB"
        container: container_image
    }
}

task run_rshiny {
    meta {
        description: "R Shiny app packaging module"
    }

    input {
        String snap_root
        String container_image
        String notify_email
        Int cpu = 4
        Int memory_gb = 30
    }

    command <<<
        set -euo pipefail
        TASK_DIR="$(pwd)"
        echo "Module: rshiny  LSF mail: ~{notify_email}"
        export SNAP_CONFIG_FILE="~{snap_root}/inputs/project_parameters.generated.yaml"
        cd "~{snap_root}/analyses/rshiny-app"
        bash run-rshiny-app.sh
        echo "done" > "${TASK_DIR}/rshiny.done"
    >>>

    output {
        File done_flag = "rshiny.done"
    }

    requirements {
        cpu: cpu
        memory: "~{memory_gb} GB"
        container: container_image
    }
}
