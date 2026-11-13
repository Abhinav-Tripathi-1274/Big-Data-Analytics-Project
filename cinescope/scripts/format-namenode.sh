#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=cluster-lib.sh
source "$SCRIPT_DIR/cluster-lib.sh"
cinescope_set_environment
cinescope_require_hadoop_user
cinescope_require_master

NAMENODE_DIR="/var/lib/hadoop/namenode"
HDFS_BIN="$HADOOP_HOME/bin/hdfs"

if [[ ! -x "$HDFS_BIN" ]]; then
    echo "HDFS command is missing: $HDFS_BIN" >&2
    exit 1
fi
if [[ ! -d "$NAMENODE_DIR" ]]; then
    echo "NameNode directory does not exist: $NAMENODE_DIR" >&2
    exit 1
fi
if [[ "$(stat -c '%U' "$NAMENODE_DIR")" != "hadoop" ]]; then
    echo "NameNode directory must be owned by hadoop." >&2
    exit 1
fi
if [[ -f "$NAMENODE_DIR/current/VERSION" ]]; then
    echo "An existing NameNode namespace was found; refusing to format it." >&2
    exit 1
fi
if find "$NAMENODE_DIR" -mindepth 1 -print -quit | grep -q .; then
    echo "NameNode directory is not empty; inspect it before formatting." >&2
    exit 1
fi
JPS_OUTPUT="$("$JAVA_HOME/bin/jps" -l 2>/dev/null || true)"
if grep -Eq 'org\.apache\.hadoop\.hdfs\.server\.namenode\.(NameNode|SecondaryNameNode)' <<< "$JPS_OUTPUT"; then
    echo "A NameNode or SecondaryNameNode process is already running; refusing to format." >&2
    exit 1
fi

# A fresh NameNode must pair with fresh DataNode storage. Do not initialize
# a new namespace against old worker block directories.
for host in worker1 worker2; do
    echo "Checking that $host has an empty new DataNode directory."
    ssh -o BatchMode=yes -o ConnectTimeout=10 "$host" /bin/bash -s <<'REMOTE'
set -Eeuo pipefail
DATA_DIR=/var/lib/hadoop/datanode
if [[ ! -d "$DATA_DIR" ]]; then
    echo "DataNode directory is missing: $DATA_DIR" >&2
    exit 1
fi
if [[ "$(stat -c '%U' "$DATA_DIR")" != "hadoop" ]]; then
    echo "DataNode directory must be owned by hadoop: $DATA_DIR" >&2
    exit 1
fi
if find "$DATA_DIR" -mindepth 1 -print -quit | grep -q .; then
    echo "DataNode directory is not empty; refusing new NameNode formatting." >&2
    exit 1
fi
if . /etc/cinescope/cluster.env; then
    if "$JAVA_HOME/bin/jps" -l 2>/dev/null | grep -q 'org.apache.hadoop.hdfs.server.datanode.DataNode'; then
        echo "DataNode process is running; stop the cluster before formatting." >&2
        exit 1
    fi
fi
REMOTE
done

if [[ "${FORMAT_CINESCOPE_NAMENODE:-}" != "YES" ]]; then
    cat >&2 <<'MSG'
Formatting creates a new HDFS namespace. This operation is only for a
brand-new cluster with an empty NameNode directory and empty DataNode
directories on BOTH workers. It destroys the ability to use an existing
namespace. To authorize this initial format, run:

  FORMAT_CINESCOPE_NAMENODE=YES bash scripts/format-namenode.sh
MSG
    exit 1
fi

printf 'Formatting the new physical NameNode at %s\n' "$NAMENODE_DIR"
"$HDFS_BIN" namenode -format -nonInteractive

if [[ ! -s "$NAMENODE_DIR/current/VERSION" ]]; then
    echo "NameNode formatting verification failed." >&2
    exit 1
fi

echo "New HDFS namespace initialized successfully. Never format it during normal restarts."
