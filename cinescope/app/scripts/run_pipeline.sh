#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# Shared helper is in the root scripts directory.
# shellcheck source=../../scripts/cluster-lib.sh
source "$PROJECT_ROOT/scripts/cluster-lib.sh"
cinescope_set_environment
cinescope_require_hadoop_user
cinescope_require_master

export CINESCOPE_HOME="$PROJECT_ROOT"
export CINESCOPE_DATA_ROOT="/var/lib/cinescope"
export CINESCOPE_RESULTS_DIR="$CINESCOPE_DATA_ROOT/results"
export CINESCOPE_HDFS="${CINESCOPE_HDFS:-hdfs://master:8020}"
DATASET="${DATASET:-ml-latest-small}"

case "$DATASET" in
    ml-latest-small|ml-32m) ;;
    *)
        echo "Unsupported DATASET: $DATASET" >&2
        exit 2
        ;;
esac

if [[ ! -x "$SPARK_HOME/bin/spark-submit" ]]; then
    echo "spark-submit is missing: $SPARK_HOME/bin/spark-submit" >&2
    exit 1
fi

# Refuse to start a workload against an incomplete physical cluster.
cinescope_wait_for_datanodes 2 30 >/dev/null
cinescope_wait_for_workers_running 30 >/dev/null

# Remove only the previous local validation marker. If this run fails before
# comparison completes, the dashboard must not show an old dataset as validated.
mkdir -p "$CINESCOPE_RESULTS_DIR"
rm -f -- "$CINESCOPE_RESULTS_DIR/validation.json"

cd "$PROJECT_ROOT"
echo "=========================================="
echo "CineScope physical 3-PC analytics pipeline"
echo "Dataset: $DATASET"
echo "Master: $(hostname -f)"
echo "=========================================="

bash app/scripts/ensure_spark_archive.sh
bash app/scripts/load_hdfs.sh

spark_submit() {
    "$SPARK_HOME/bin/spark-submit" --master yarn --deploy-mode client "$@"
}

echo "Running Spark cleaning on YARN."
spark_submit app/spark/01_clean.py

echo "Running Spark genre scorecard on YARN."
spark_submit app/spark/02_genre_scorecard.py

echo "Running Hadoop Streaming MapReduce on YARN."
bash app/scripts/run_mr.sh

echo "Comparing Spark and MapReduce outputs."
# compare.py returns non-zero when any metric differs; set -e stops here.
python3 app/scripts/compare.py

echo "Running Spark analytical aggregation on YARN."
spark_submit app/spark/03_analysis.py

echo "Exporting dashboard fact tables to the master."
bash app/scripts/export_results.sh

echo
echo "=========================================="
echo "PIPELINE DONE"
echo "Dataset: $DATASET"
echo "Validation: $CINESCOPE_RESULTS_DIR/validation.json"
echo "=========================================="
