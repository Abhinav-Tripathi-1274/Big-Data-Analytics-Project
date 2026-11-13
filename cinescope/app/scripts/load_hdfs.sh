#!/usr/bin/env bash

set -Eeuo pipefail

DATASET="${DATASET:-ml-latest-small}"

DATA_ROOT="${CINESCOPE_DATA_ROOT:-/var/lib/cinescope}"

RAW_ROOT="$DATA_ROOT/raw"

CACHE="$RAW_ROOT/$DATASET"

BASE_URL="https://files.grouplens.org/datasets/movielens"

HDFS_ROOT="${CINESCOPE_HDFS:-hdfs://master:8020}"

HDFS_ROOT="${HDFS_ROOT%/}/cinescope"


case "$DATASET" in
    ml-latest-small|ml-32m)
        ;;
    *)
        echo "Unsupported DATASET: $DATASET" >&2
        exit 2
        ;;
esac


mkdir -p "$RAW_ROOT" "$CACHE"


if [[ ! -f "$CACHE/ratings.csv" ||
      ! -f "$CACHE/movies.csv" ||
      ! -f "$CACHE/links.csv" ]]; then

    archive="$(mktemp "/tmp/${DATASET}.XXXXXX.zip")"

    trap 'rm -f -- "$archive"' EXIT

    echo "Downloading MovieLens dataset: $DATASET"

    curl \
        --fail \
        --location \
        --retry 4 \
        --retry-delay 2 \
        --output "$archive" \
        "$BASE_URL/${DATASET}.zip"

    echo "Extracting MovieLens dataset."

    unzip -q -o "$archive" -d "$RAW_ROOT"

    rm -f "$archive"

    trap - EXIT
fi


for file in ratings.csv movies.csv links.csv; do

    if [[ ! -s "$CACHE/$file" ]]; then

        echo "Missing or empty dataset file: $CACHE/$file" >&2

        exit 2
    fi

done


echo "Dataset: $DATASET"

echo "Local source: $CACHE"

echo "HDFS destination: $HDFS_ROOT/raw"


"$HADOOP_HOME/bin/hdfs" dfs \
    -mkdir -p \
    "$HDFS_ROOT/raw/ratings" \
    "$HDFS_ROOT/raw/movies" \
    "$HDFS_ROOT/raw/links" \
    "$HDFS_ROOT/curated" \
    "$HDFS_ROOT/results"


"$HADOOP_HOME/bin/hdfs" dfs \
    -Ddfs.blocksize=33554432 \
    -Ddfs.replication=2 \
    -put -f \
    "$CACHE/ratings.csv" \
    "$HDFS_ROOT/raw/ratings/"


"$HADOOP_HOME/bin/hdfs" dfs \
    -Ddfs.blocksize=33554432 \
    -Ddfs.replication=2 \
    -put -f \
    "$CACHE/movies.csv" \
    "$HDFS_ROOT/raw/movies/"


"$HADOOP_HOME/bin/hdfs" dfs \
    -Ddfs.blocksize=33554432 \
    -Ddfs.replication=2 \
    -put -f \
    "$CACHE/links.csv" \
    "$HDFS_ROOT/raw/links/"


echo "Verifying uploaded ratings file."

"$HADOOP_HOME/bin/hdfs" fsck \
    "$HDFS_ROOT/raw/ratings/ratings.csv" \
    -files \
    -blocks \
    -locations


echo "MovieLens input data uploaded successfully."
