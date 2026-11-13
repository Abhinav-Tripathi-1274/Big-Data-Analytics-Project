#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HADOOP_HOME="${HADOOP_HOME:-/opt/hadoop}"
HDFS_BIN="$HADOOP_HOME/bin/hdfs"
HADOOP_BIN="$HADOOP_HOME/bin/hadoop"
STREAMING_DIR="$HADOOP_HOME/share/hadoop/tools/lib"
STREAMING_JAR="$(find "$STREAMING_DIR" -maxdepth 1 -type f -name 'hadoop-streaming-*.jar' -print -quit 2>/dev/null || true)"
INPUT="${1:-/cinescope/raw/ratings}"
OUTPUT="${2:-/cinescope/results/mr_genre}"

if [[ ! -x "$HDFS_BIN" || ! -x "$HADOOP_BIN" ]]; then
    echo "Hadoop executables are missing under $HADOOP_HOME." >&2
    exit 1
fi
if [[ -z "$STREAMING_JAR" || ! -s "$STREAMING_JAR" ]]; then
    echo "Hadoop Streaming JAR was not found in $STREAMING_DIR." >&2
    exit 1
fi
for file in mr_mapper.py mr_combiner.py mr_reducer.py; do
    if [[ ! -s "$PROJECT_ROOT/app/mr/$file" ]]; then
        echo "Missing or empty MapReduce program: $PROJECT_ROOT/app/mr/$file" >&2
        exit 1
    fi
done
if ! "$HDFS_BIN" dfs -test -e "$INPUT"; then
    echo "MapReduce input does not exist in HDFS: $INPUT" >&2
    exit 1
fi
if ! "$HDFS_BIN" dfs -test -e /cinescope/raw/movies/movies.csv; then
    echo "Movie metadata file is missing from HDFS." >&2
    exit 1
fi

echo "MapReduce input: $INPUT"
echo "MapReduce output: $OUTPUT"

# Hadoop Streaming requires a new output directory for every job.
"$HDFS_BIN" dfs -rm -r -f "$OUTPUT"

"$HADOOP_BIN" jar "$STREAMING_JAR" \
    -D mapreduce.job.name=CineScope-MR-genre \
    -D mapreduce.job.reduces=1 \
    -files "hdfs://master:8020/cinescope/raw/movies/movies.csv#movies.csv,file://$PROJECT_ROOT/app/mr/mr_mapper.py,file://$PROJECT_ROOT/app/mr/mr_combiner.py,file://$PROJECT_ROOT/app/mr/mr_reducer.py" \
    -input "$INPUT" \
    -output "$OUTPUT" \
    -mapper "python3 mr_mapper.py" \
    -combiner "python3 mr_combiner.py" \
    -reducer "python3 mr_reducer.py"

"$HDFS_BIN" dfs -cat "$OUTPUT/part-*"
