#!/usr/bin/env bash
set -Eeuo pipefail

mkdir -p /data/results
for table in movies_all movie_hist movie_year; do
  rm -rf "/data/results/${table}"
  hdfs dfs -get "/cinescope/results/${table}" "/data/results/${table}"
done
