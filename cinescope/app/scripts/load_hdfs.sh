#!/usr/bin/env bash
set -Eeuo pipefail

DATASET="${DATASET:-ml-latest-small}"
BASE_URL="https://files.grouplens.org/datasets/movielens"
CACHE="/data/raw/${DATASET}"

mkdir -p /data/raw
if [[ ! -f "${CACHE}/ratings.csv" ]]; then
  mkdir -p "$CACHE"
  curl -fL --retry 4 -o "/tmp/${DATASET}.zip" "${BASE_URL}/${DATASET}.zip"
  unzip -q -o "/tmp/${DATASET}.zip" -d /data/raw
  rm -f "/tmp/${DATASET}.zip"
fi

if [[ ! -f "${CACHE}/ratings.csv" ]]; then
  echo "Expected ${CACHE}/ratings.csv after extraction; unsupported DATASET=${DATASET}." >&2
  exit 2
fi

hdfs dfs -rm -r -f /cinescope || true
hdfs dfs -mkdir -p /cinescope/raw/{ratings,movies,links} /cinescope/curated /cinescope/results
hdfs dfs -Ddfs.blocksize=33554432 -put -f "${CACHE}/ratings.csv" /cinescope/raw/ratings/
hdfs dfs -put -f "${CACHE}/movies.csv" /cinescope/raw/movies/
hdfs dfs -put -f "${CACHE}/links.csv" /cinescope/raw/links/
hdfs fsck /cinescope/raw/ratings/ratings.csv -files -blocks -locations
