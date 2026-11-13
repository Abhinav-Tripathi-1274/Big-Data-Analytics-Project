#!/usr/bin/env bash
set -Eeuo pipefail

EXPECTED_DATANODES="${EXPECTED_DATANODES:-2}"
SPARK_VERSION="${SPARK_VERSION:-3.5.9}"
SPARK_HOME="${SPARK_HOME:-/opt/spark}"
HADOOP_HOME="${HADOOP_HOME:-/opt/hadoop}"
HDFS_BIN="$HADOOP_HOME/bin/hdfs"
ARCHIVE="/spark-archive/spark-libs-${SPARK_VERSION}.zip"

if [[ ! "$EXPECTED_DATANODES" =~ ^[1-9][0-9]*$ ]]; then
    echo "EXPECTED_DATANODES must be a positive integer." >&2
    exit 2
fi
if [[ ! -x "$HDFS_BIN" ]]; then
    echo "HDFS executable not found: $HDFS_BIN" >&2
    exit 1
fi
if [[ ! -d "$SPARK_HOME/jars" ]]; then
    echo "Spark jars directory is missing: $SPARK_HOME/jars" >&2
    exit 1
fi

live=0
for _ in $(seq 1 120); do
    report="$($HDFS_BIN dfsadmin -report 2>/dev/null || true)"
    live="$(sed -nE 's/^Live datanodes \(([0-9]+)\):.*/\1/p' <<< "$report" | sed -n '1p')"
    live="${live:-0}"
    if (( live >= EXPECTED_DATANODES )); then
        break
    fi
    echo "Waiting for live DataNodes: $live/$EXPECTED_DATANODES"
    sleep 2
done
if (( live < EXPECTED_DATANODES )); then
    echo "Not enough live DataNodes to stage the Spark archive." >&2
    exit 1
fi

"$HDFS_BIN" dfs -mkdir -p /spark-archive /spark-logs /user/hadoop
"$HDFS_BIN" dfs -chown -R hadoop:hadoop /spark-archive /spark-logs /user/hadoop

ensure_replication() {
    local current
    current="$($HDFS_BIN dfs -stat '%r' "$ARCHIVE" 2>/dev/null || printf '0')"
    if [[ ! "$current" =~ ^[0-9]+$ ]]; then
        echo "Could not determine replication for $ARCHIVE." >&2
        return 1
    fi
    if (( current < EXPECTED_DATANODES )); then
        echo "Increasing Spark archive replication from $current to $EXPECTED_DATANODES."
        "$HDFS_BIN" dfs -setrep -w "$EXPECTED_DATANODES" "$ARCHIVE"
    fi
}

if "$HDFS_BIN" dfs -test -e "$ARCHIVE"; then
    echo "Version-specific Spark archive already exists: $ARCHIVE"
    ensure_replication
    exit 0
fi

local_archive_dir="$(mktemp -d /tmp/cinescope-spark-libs.XXXXXX)"
local_archive="$local_archive_dir/spark-libs-${SPARK_VERSION}.zip"
trap 'rm -rf -- "$local_archive_dir"' EXIT

echo "Creating Spark ${SPARK_VERSION} JAR archive."
(
    cd "$SPARK_HOME/jars"
    zip -q -r "$local_archive" .
)

# Test the ZIP before uploading it to HDFS.
unzip -tq "$local_archive"

echo "Uploading Spark archive to HDFS: $ARCHIVE"
"$HDFS_BIN" dfs -put "$local_archive" "$ARCHIVE"
"$HDFS_BIN" dfs -setrep -w "$EXPECTED_DATANODES" "$ARCHIVE"

echo "Spark archive is staged successfully."
echo "HDFS path: $ARCHIVE"
echo "Replication: $EXPECTED_DATANODES"
