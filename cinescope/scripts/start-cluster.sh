#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=cluster-lib.sh
source "$SCRIPT_DIR/cluster-lib.sh"
cinescope_set_environment
cinescope_require_hadoop_user
cinescope_require_master

NAMENODE_VERSION="/var/lib/hadoop/namenode/current/VERSION"
if [[ ! -s "$NAMENODE_VERSION" ]]; then
    echo "NameNode has not been formatted." >&2
    echo "For a brand-new cluster only, follow the separate formatting procedure." >&2
    exit 1
fi

for command in \
    "$HADOOP_HOME/sbin/start-dfs.sh" \
    "$HADOOP_HOME/sbin/start-yarn.sh" \
    "$HADOOP_HOME/bin/mapred" \
    "$SPARK_HOME/sbin/start-history-server.sh"; do
    if [[ ! -x "$command" ]]; then
        echo "Required startup command is missing: $command" >&2
        exit 1
    fi
done

for host in worker1 worker2; do
    echo "Testing passwordless SSH to $host."
    ssh -o BatchMode=yes -o ConnectTimeout=10 "$host" /bin/true
done

echo "Starting HDFS daemons on master and both physical workers."
"$HADOOP_HOME/sbin/start-dfs.sh"

# First require both physical DataNodes. This bounded check makes a missing
# worker fail with a useful timeout rather than waiting indefinitely in safe mode.
cinescope_wait_for_datanodes 2 240 >/dev/null
"$HADOOP_HOME/bin/hdfs" dfsadmin -safemode wait

"$HADOOP_HOME/bin/hdfs" dfs -mkdir -p /user/hadoop /spark-logs /spark-archive
"$HADOOP_HOME/bin/hdfs" dfs -chown -R hadoop:hadoop /user/hadoop /spark-logs /spark-archive

echo "Starting YARN ResourceManager and both physical NodeManagers."
"$HADOOP_HOME/sbin/start-yarn.sh"
cinescope_wait_for_workers_running 300

echo "Starting MapReduce JobHistory Server."
"$HADOOP_HOME/bin/mapred" --daemon start historyserver

echo "Starting Spark History Server."
"$SPARK_HOME/sbin/start-history-server.sh"

echo
echo "Hadoop and Spark services have been started."
echo "Required YARN workers confirmed RUNNING: worker1, worker2"
echo "Now run: sudo -u hadoop -H bash /opt/cinescope/scripts/cluster-check.sh"
