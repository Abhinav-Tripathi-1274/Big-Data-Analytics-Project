#!/usr/bin/env bash
set -Eeuo pipefail

INPUT="${1:-/cinescope/raw/ratings}"
OUTPUT="${2:-/cinescope/results/mr_genre}"
hdfs dfs -rm -r -f "$OUTPUT" || true
hadoop jar /opt/hadoop/share/hadoop/tools/lib/hadoop-streaming-*.jar \
  -D mapreduce.job.name=CineScope-MR-genre \
  -D mapreduce.job.reduces=1 \
  -files "hdfs:///cinescope/raw/movies/movies.csv#movies.csv,file:///workspace/mr/mr_mapper.py,file:///workspace/mr/mr_combiner.py,file:///workspace/mr/mr_reducer.py" \
  -input "$INPUT" -output "$OUTPUT" \
  -mapper "python3 mr_mapper.py" \
  -combiner "python3 mr_combiner.py" \
  -reducer "python3 mr_reducer.py"
hdfs dfs -cat "$OUTPUT/part-*"
