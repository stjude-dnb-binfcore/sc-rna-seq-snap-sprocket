version 1.3

# Assumes FastQC and Cell Ranger have already completed.
#
# Container execution is handled by Sprocket (lsf_apptainer backend) via
# runtime.container — do not call singularity/apptainer in command blocks.
# Per-module email: LSF bsub -B/-N/-u CONTACT_EMAIL (inputs/sprocket.generated.toml).
# Workflow email: scripts/snap-notify-email.sh from launch-snap-sprocket.sh.

task run_integrative {
    meta {
        description: "Integrative analysis module"
    }

    input {
        String snap_root
        String container_image
        String notify_email
        Int cpu = 10
        Int memory_gb = 96
        Int future_globals_gib = 200
        File? wait_on
    }

    command <<<
        set -euo pipefail
        TASK_DIR="$(pwd)"
        echo "Module: integrative  LSF mail: ~{notify_email}"
        export SNAP_CONFIG_FILE="~{snap_root}/inputs/project_parameters.generated.yaml"
        export FUTURE_GLOBALS_MAXSIZE_GIB="~{future_globals_gib}"
        export SNAP_FUTURE_WORKERS="~{cpu}"
        if [ -n "~{wait_on}" ]; then echo "Previous step: ~{wait_on}"; fi
        cd "~{snap_root}/analyses/integrative-analysis"
        bash run-integrative-analysis.sh
        echo "done" > "${TASK_DIR}/integrative.done"
    >>>

    output {
        File done_flag = "integrative.done"
    }

    runtime {
        cpu: cpu
        memory: "~{memory_gb} GB"
        container: container_image
    }
}

task run_contamination_removal {
    meta {
        description: "Cell contamination removal module"
    }

    input {
        String snap_root
        String container_image
        String notify_email
        Int cpu = 8
        Int memory_gb = 96
        Int future_globals_gib = 400
        File? wait_on
    }

    command <<<
        set -euo pipefail
        TASK_DIR="$(pwd)"
        echo "Module: contamination_removal  LSF mail: ~{notify_email}"
        export SNAP_CONFIG_FILE="~{snap_root}/inputs/project_parameters.generated.yaml"
        export FUTURE_GLOBALS_MAXSIZE_GIB="~{future_globals_gib}"
        if [ -n "~{wait_on}" ]; then echo "Previous step: ~{wait_on}"; fi
        cd "~{snap_root}/analyses/cell-contamination-removal-analysis"
        bash run-cell-contamination-removal-analysis.sh
        echo "done" > "${TASK_DIR}/contamination.done"
    >>>

    output {
        File done_flag = "contamination.done"
    }

    runtime {
        cpu: cpu
        memory: "~{memory_gb} GB"
        container: container_image
    }
}

task run_clone_phylogeny {
    meta {
        description: "Clone phylogeny analysis module"
    }

    input {
        String snap_root
        String container_image
        String notify_email
        Int cpu = 16
        Int memory_gb = 30
        File? wait_on
    }

    command <<<
        set -euo pipefail
        TASK_DIR="$(pwd)"
        echo "Module: clone_phylogeny  LSF mail: ~{notify_email}"
        export SNAP_CONFIG_FILE="~{snap_root}/inputs/project_parameters.generated.yaml"
        if [ -n "~{wait_on}" ]; then echo "Previous step: ~{wait_on}"; fi
        cd "~{snap_root}/analyses/clone-phylogeny-analysis"
        bash run-clone-phylogeny-analysis.sh
        echo "done" > "${TASK_DIR}/clone_phylogeny.done"
    >>>

    output {
        File done_flag = "clone_phylogeny.done"
    }

    runtime {
        cpu: cpu
        memory: "~{memory_gb} GB"
        container: container_image
    }
}

task run_de_go {
    meta {
        description: "DE and GO analysis module"
    }

    input {
        String snap_root
        String container_image
        String notify_email
        Int cpu = 4
        Int memory_gb = 32
        Int future_globals_gib = 200
        File? wait_on
    }

    command <<<
        set -euo pipefail
        TASK_DIR="$(pwd)"
        echo "Module: de_go  LSF mail: ~{notify_email}"
        export SNAP_CONFIG_FILE="~{snap_root}/inputs/project_parameters.generated.yaml"
        export FUTURE_GLOBALS_MAXSIZE_GIB="~{future_globals_gib}"
        if [ -n "~{wait_on}" ]; then echo "Previous step: ~{wait_on}"; fi
        cd "~{snap_root}/analyses/de-go-analysis"
        bash run-de-go-analysis.sh
        echo "done" > "${TASK_DIR}/de_go.done"
    >>>

    output {
        File done_flag = "de_go.done"
    }

    runtime {
        cpu: cpu
        memory: "~{memory_gb} GB"
        container: container_image
    }
}
