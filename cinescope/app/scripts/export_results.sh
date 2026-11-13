#!/usr/bin/env bash
set -Eeuo pipefail

DATA_ROOT="${CINESCOPE_DATA_ROOT:-/var/lib/cinescope}"
RESULTS="$DATA_ROOT/results"
HADOOP_HOME="${HADOOP_HOME:-/opt/hadoop}"
HDFS_BIN="$HADOOP_HOME/bin/hdfs"
HDFS_ROOT="${CINESCOPE_HDFS:-hdfs://master:8020}"
HDFS_ROOT="${HDFS_ROOT%/}/cinescope/results"

if [[ ! -x "$HDFS_BIN" ]]; then
    echo "HDFS executable not found: $HDFS_BIN" >&2
    exit 1
fi
mkdir -p "$RESULTS"

export_table() {
    local table="$1"
    local target="$RESULTS/$table"
    local staging backup
    staging="$(mktemp -d "$RESULTS/.${table}.stage.XXXXXX")"
    backup="$RESULTS/.${table}.backup.$$"

    echo "Exporting $table from HDFS."
    if ! "$HDFS_BIN" dfs -get "$HDFS_ROOT/$table" "$staging/$table"; then
        rm -rf -- "$staging"
        echo "Failed exporting $table." >&2
        return 1
    fi

    if [[ -e "$target" ]]; then
        if [[ -e "$backup" ]]; then
            rm -rf -- "$staging"
            echo "Backup path already exists; refusing to overwrite: $backup" >&2
            return 1
        fi
        mv -- "$target" "$backup"
    fi

    if mv -- "$staging/$table" "$target"; then
        rm -rf -- "$backup" "$staging"
        echo "Exported $table successfully."
    else
        if [[ -e "$backup" ]]; then
            mv -- "$backup" "$target"
        fi
        rm -rf -- "$staging"
        echo "Could not install exported table: $table" >&2
        return 1
    fi
}

export_table movies_all
export_table movie_hist
export_table movie_year

echo "All large dashboard tables exported successfully."
