#!/usr/bin/env bash
# Stage Spark's jars only after both DataNodes can satisfy replication=2.
set -Eeuo pipefail

EXPECTED_DATANODES="${EXPECTED_DATANODES:-2}"
ARCHIVE='/spark-archive/spark-libs.zip'

if hdfs dfs -test -e "$ARCHIVE"; then
  echo "Spark archive already present: $ARCHIVE"
  exit 0
fi

for _ in $(seq 1 90); do
  report="$(hdfs dfsadmin -report 2>/dev/null || true)"
  live="$(printf '%s\n' "$report" | sed -nE 's/^Live datanodes \(([0-9]+)\):$/\1/p' | head -n 1)"
  if [[ "${live:-0}" -ge "$EXPECTED_DATANODES" ]]; then
    break
  fi
  echo "Waiting for ${EXPECTED_DATANODES} live DataNodes (currently ${live:-0})…"
  sleep 2
done

if [[ "${live:-0}" -lt "$EXPECTED_DATANODES" ]]; then
  echo "Timed out waiting for ${EXPECTED_DATANODES} live DataNodes; Spark archive was not uploaded." >&2
  exit 1
fi

if hdfs dfs -test -e "$ARCHIVE"; then
  echo "Spark archive already present: $ARCHIVE"
  exit 0
fi

hdfs dfs -mkdir -p /spark-archive /spark-logs /user/hadoop
hdfs dfs -chown -R hadoop:hadoop /spark-archive /spark-logs /user/hadoop

local_archive_dir="$(mktemp -d /tmp/spark-libs.XXXXXX)"
local_archive="$local_archive_dir/spark-libs.zip"

trap 'rm -rf -- "$local_archive_dir"' EXIT

(cd /opt/spark/jars && zip -q -r "$local_archive" .)

hdfs dfs -put -f "$local_archive" "$ARCHIVE"
hdfs dfs -setrep -w "$EXPECTED_DATANODES" "$ARCHIVE"
echo "Staged Spark archive with replication ${EXPECTED_DATANODES}: $ARCHIVE"
