#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../../scripts/cluster-lib.sh
source "$PROJECT_ROOT/scripts/cluster-lib.sh"
cinescope_set_environment
cinescope_require_hadoop_user
cinescope_require_master

DATASET="${DATASET:-ml-latest-small}"
case "$DATASET" in
    ml-latest-small|ml-32m) ;;
    *)
        echo "Unsupported DATASET: $DATASET" >&2
        exit 2
        ;;
esac

export CINESCOPE_RESULTS_DIR="/var/lib/cinescope/results"
HDFS="${CINESCOPE_HDFS:-hdfs://master:8020}"
HDFS_RAW="/cinescope/raw/ratings"
HDFS_PARQUET="/cinescope/curated/ratings"
RAW10X="/cinescope/raw10x/${DATASET}/ratings"
INPUT10X="$RAW10X/ratings_10x.csv"
WORKER2_STOPPED=0

cinescope_wait_for_datanodes 2 30 >/dev/null
cinescope_wait_for_workers_running 30 >/dev/null

remote_worker2_nm() {
    local action="$1"
    case "$action" in
        start|stop) ;;
        *) echo "Invalid NodeManager action: $action" >&2; return 2 ;;
    esac
    ssh -o BatchMode=yes -o ConnectTimeout=10 worker2 /bin/bash -s -- "$action" <<'REMOTE'
set -Eeuo pipefail
source /etc/cinescope/cluster.env
export JAVA_HOME
export HOME=/home/hadoop
export HADOOP_HOME=/opt/hadoop
export HADOOP_CONF_DIR=/opt/hadoop/etc/hadoop
export YARN_CONF_DIR=/opt/hadoop/etc/hadoop
export HADOOP_LOG_DIR=/var/log/hadoop
export HADOOP_PID_DIR=/var/lib/hadoop/pids
export PATH=/opt/hadoop/bin:/opt/hadoop/sbin:/usr/local/bin:/usr/bin:/bin
/opt/hadoop/bin/yarn --daemon "$1" nodemanager
REMOTE
}

restore_worker2() {
    if (( WORKER2_STOPPED == 1 )); then
        local states worker2_state
        states="$(cinescope_yarn_node_states 2>/dev/null || true)"
        worker2_state="$(awk -F '\t' '$1 == "worker2" {s=$2} END {print s}' <<< "$states")"

        if [[ "$worker2_state" != "RUNNING" ]]; then
            echo "Restoring NodeManager on physical worker2."
            if ! remote_worker2_nm start; then
                echo "ERROR: failed to start worker2 NodeManager." >&2
                return 1
            fi
        fi

        if ! cinescope_wait_for_workers_running 300 >/dev/null; then
            echo "ERROR: worker2 did not re-register as RUNNING." >&2
            return 1
        fi
        WORKER2_STOPPED=0
        echo "worker2 is RUNNING again."
    fi
}

on_exit() {
    local original_status=$?
    trap - EXIT INT TERM
    if ! restore_worker2; then
        original_status=1
    fi
    exit "$original_status"
}
trap on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

timeit() {
    local id="$1" engine="$2" format="$3" size="$4" workers="$5"
    shift 5
    local started=$SECONDS
    if "$@" >"/tmp/bench-${id}.log" 2>&1; then
        local elapsed=$((SECONDS - started))
        python3 app/scripts/bench_log.py "$id" "$engine" "$format" "$size" "$workers" "$elapsed"
        echo "${id}: ${elapsed}s"
    else
        echo "FAILED ${id}. Inspect /tmp/bench-${id}.log" >&2
        tail -n 80 "/tmp/bench-${id}.log" >&2 || true
        return 1
    fi
}

spark_submit() {
    "$SPARK_HOME/bin/spark-submit" --master yarn --deploy-mode client "$@"
}

mr() {
    bash app/scripts/run_mr.sh "$1" /cinescope/results/mr_bench
}

cd "$PROJECT_ROOT"
echo "=========================================="
echo "CineScope physical cluster benchmarks"
echo "Dataset: $DATASET"
echo "=========================================="

# Two-worker trials.
timeit spark_csv_1x_2w spark csv 1x 2 \
    spark_submit app/spark/bench_genre.py csv "$HDFS$HDFS_RAW" true

timeit spark_parquet_1x_2w spark parquet 1x 2 \
    spark_submit app/spark/bench_genre.py parquet "$HDFS$HDFS_PARQUET"

timeit mr_csv_1x_2w mapreduce csv 1x 2 \
    mr "$HDFS_RAW"

# Keep the HDFS DataNode on worker2 available; stop only its YARN NodeManager.
echo "Stopping the YARN NodeManager on physical worker2."
remote_worker2_nm stop
WORKER2_STOPPED=1

# Do not start one-worker trials until ResourceManager confirms that only
# worker1 is RUNNING. If the shutdown state does not appear, fail safely.
cinescope_wait_for_worker2_not_running 240

timeit spark_csv_1x_1w spark csv 1x 1 \
    spark_submit --num-executors 1 app/spark/bench_genre.py csv "$HDFS$HDFS_RAW" true

timeit mr_csv_1x_1w mapreduce csv 1x 1 \
    mr "$HDFS_RAW"

# Restore worker2 before making any two-worker benchmark input.
restore_worker2

echo "Both physical YARN workers have rejoined."

# Use a dataset-specific path to prevent a previous 10x file being reused.
if ! "$HADOOP_HOME/bin/hdfs" dfs -test -e "$INPUT10X"; then
    echo "Creating 10x benchmark input for $DATASET."
    "$HADOOP_HOME/bin/hdfs" dfs -mkdir -p "$RAW10X"
    for _ in $(seq 1 10); do
        "$HADOOP_HOME/bin/hdfs" dfs -cat "$HDFS_RAW/ratings.csv" | tail -n +2
    done | "$HADOOP_HOME/bin/hdfs" \
        -Ddfs.blocksize=33554432 \
        -Ddfs.replication=2 \
        -put - "$INPUT10X"
fi

# The generated 10x file intentionally has no header.
timeit spark_csv_10x_2w spark csv 10x 2 \
    spark_submit app/spark/bench_genre.py csv "$HDFS$INPUT10X" false

timeit mr_csv_10x_2w mapreduce csv 10x 2 \
    mr "$INPUT10X"

echo
echo "BENCHMARKS COMPLETED"
echo "Dataset: $DATASET"
echo "Results: $CINESCOPE_RESULTS_DIR/benchmarks.json"
