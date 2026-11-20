#!/usr/bin/env bash
# Run only after the full dataset pipeline has completed.
set -Eeuo pipefail
cd /workspace

timeit() {
  local id=$1 engine=$2 format=$3 size=$4 workers=$5
  shift 5
  SECONDS=0
  if "$@" >"/tmp/bench-${id}.log" 2>&1; then
    python3 scripts/bench_log.py "$id" "$engine" "$format" "$size" "$workers" "$SECONDS"
    echo "${id}: ${SECONDS}s"
  else
    echo "FAILED ${id}; inspect /tmp/bench-${id}.log" >&2
    return 1
  fi
}

mr() { bash scripts/run_mr.sh "$1" /cinescope/results/mr_bench; }
HDFS=hdfs://master:8020

timeit spark_csv_1x_2w spark csv 1x 2 spark-submit spark/bench_genre.py csv "$HDFS/cinescope/raw/ratings" true
timeit spark_parquet_1x_2w spark parquet 1x 2 spark-submit spark/bench_genre.py parquet "$HDFS/cinescope/curated/ratings"
timeit mr_csv_1x_2w mapreduce csv 1x 2 mr /cinescope/raw/ratings

# NodeManager only: HDFS remains available with its two replicas.
echo 'For the one-worker trial, run this from a second terminal:'
echo '  docker compose exec --user hadoop worker2 yarn --daemon stop nodemanager'
echo 'Wait until yarn node -list shows one node, then press Enter here.'
read -r
timeit spark_csv_1x_1w spark csv 1x 1 spark-submit --num-executors 1 spark/bench_genre.py csv "$HDFS/cinescope/raw/ratings" true
timeit mr_csv_1x_1w mapreduce csv 1x 1 mr /cinescope/raw/ratings
echo 'Restart worker2 after this script with:'
echo '  docker compose exec --user hadoop worker2 yarn --daemon start nodemanager'

if ! hdfs dfs -test -d /cinescope/raw10x/ratings; then
  hdfs dfs -mkdir -p /cinescope/raw10x/ratings
  for _ in $(seq 1 10); do hdfs dfs -cat /cinescope/raw/ratings/ratings.csv | tail -n +2; done \
    | hdfs dfs -Ddfs.blocksize=33554432 -put - /cinescope/raw10x/ratings/ratings_10x.csv
fi
timeit spark_csv_10x_2w spark csv 10x 2 spark-submit spark/bench_genre.py csv "$HDFS/cinescope/raw10x/ratings" false
timeit mr_csv_10x_2w mapreduce csv 10x 2 mr /cinescope/raw10x/ratings
