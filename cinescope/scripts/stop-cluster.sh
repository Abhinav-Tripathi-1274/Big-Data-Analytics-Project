#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=cluster-lib.sh
source "$SCRIPT_DIR/cluster-lib.sh"
cinescope_set_environment
cinescope_require_hadoop_user
cinescope_require_master

failures=0
run_stop() {
    local label="$1"
    shift
    echo "Stopping ${label}."
    if "$@"; then
        echo "Stopped/checked: ${label}"
    else
        echo "WARNING: stop command reported a problem: ${label}" >&2
        failures=$((failures + 1))
    fi
}

run_stop "Spark History Server" "$SPARK_HOME/sbin/stop-history-server.sh"
run_stop "MapReduce JobHistory Server" "$HADOOP_HOME/bin/mapred" --daemon stop historyserver
run_stop "YARN ResourceManager and NodeManagers" "$HADOOP_HOME/sbin/stop-yarn.sh"
run_stop "HDFS NameNode, SecondaryNameNode and DataNodes" "$HADOOP_HOME/sbin/stop-dfs.sh"

echo
if (( failures > 0 )); then
    echo "Cluster stop finished with $failures warning(s). Inspect daemon logs and process lists." >&2
    exit 1
fi
echo "Hadoop and Spark services have been stopped. HDFS data and metadata were not deleted."
