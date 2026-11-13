#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=cluster-lib.sh
source "$SCRIPT_DIR/cluster-lib.sh"
cinescope_set_environment
cinescope_require_hadoop_user
cinescope_require_master

failures=0
fail() {
    echo "FAIL: $*" >&2
    failures=$((failures + 1))
}
pass() {
    echo "PASS: $*"
}
check_process() {
    local host="$1"
    local process_class="$2"
    local listing
    if [[ "$host" == "master" ]]; then
        if ! listing="$("$JAVA_HOME/bin/jps" -l 2>&1)"; then
            fail "Could not run jps on master: ${listing:-no output}"
            return
        fi
    else
        if ! listing="$(ssh -o BatchMode=yes -o ConnectTimeout=10 "$host" \
            'set -eu; . /etc/cinescope/cluster.env; "$JAVA_HOME/bin/jps" -l' 2>&1)"; then
            fail "Could not query Java processes on $host: ${listing:-no output}"
            return
        fi
    fi
    if grep -Fq "$process_class" <<< "$listing"; then
        pass "$host has $(basename "$process_class")"
    else
        fail "$host is missing Java process $process_class"
        printf '%s\n' "$listing"
    fi
}
check_http() {
    local label="$1"
    local url="$2"
    local status
    status="$(curl --connect-timeout 3 --max-time 8 -sS -o /dev/null -w '%{http_code}' "$url" || true)"
    if [[ "$status" =~ ^[23][0-9][0-9]$ ]]; then
        pass "$label HTTP $status"
    else
        fail "$label did not return HTTP 2xx/3xx (received ${status:-no response})"
    fi
}

echo "=== Java daemons on the three physical computers ==="
check_process master org.apache.hadoop.hdfs.server.namenode.NameNode
check_process master org.apache.hadoop.hdfs.server.namenode.SecondaryNameNode
check_process master org.apache.hadoop.yarn.server.resourcemanager.ResourceManager
check_process master org.apache.hadoop.mapreduce.v2.hs.JobHistoryServer
check_process master org.apache.spark.deploy.history.HistoryServer
check_process worker1 org.apache.hadoop.hdfs.server.datanode.DataNode
check_process worker1 org.apache.hadoop.yarn.server.nodemanager.NodeManager
check_process worker2 org.apache.hadoop.hdfs.server.datanode.DataNode
check_process worker2 org.apache.hadoop.yarn.server.nodemanager.NodeManager

echo
echo "=== HDFS DataNode report ==="
HDFS_REPORT="$("$HADOOP_HOME/bin/hdfs" dfsadmin -report 2>&1)" || {
    fail "hdfs dfsadmin -report failed: $HDFS_REPORT"
    HDFS_REPORT=""
}
printf '%s\n' "$HDFS_REPORT"
LIVE_DATANODES="$(sed -nE 's/^Live datanodes \(([0-9]+)\):.*/\1/p' <<< "$HDFS_REPORT" | sed -n '1p')"
LIVE_DATANODES="${LIVE_DATANODES:-0}"
if [[ "$LIVE_DATANODES" == "2" ]]; then
    pass "Exactly two live HDFS DataNodes"
else
    fail "Expected 2 live HDFS DataNodes; found $LIVE_DATANODES"
fi

echo
echo "=== YARN worker state from the ResourceManager ==="
if YARN_STATES="$(cinescope_yarn_node_states 2>&1)"; then
    printf '%s\n' "$YARN_STATES"
    for host in worker1 worker2; do
        COUNT="$(awk -F '\t' -v h="$host" '$1 == h {n++} END {print n+0}' <<< "$YARN_STATES")"
        STATE="$(awk -F '\t' -v h="$host" '$1 == h {s=$2} END {print s}' <<< "$YARN_STATES")"
        if [[ "$COUNT" == "1" && "$STATE" == "RUNNING" ]]; then
            pass "$host has exactly one RUNNING NodeManager registration"
        else
            fail "$host expected exactly one RUNNING NodeManager; count=$COUNT state=${STATE:-missing}"
        fi
    done
else
    fail "Could not read ResourceManager node state: $YARN_STATES"
fi

echo
echo "=== Master HTTP services ==="
check_http "NameNode UI" "http://127.0.0.1:9870/"
check_http "SecondaryNameNode UI" "http://127.0.0.1:9868/"
check_http "ResourceManager UI" "http://127.0.0.1:8088/"
check_http "MapReduce JobHistory UI" "http://127.0.0.1:19888/"
check_http "Spark History UI" "http://127.0.0.1:18080/"
check_http "CineScope API health" "http://127.0.0.1:8000/api/health"

if (( failures > 0 )); then
    echo
    echo "CLUSTER CHECK FAILED: $failures item(s) did not pass." >&2
    exit 1
fi

echo
echo "CLUSTER CHECK PASSED: both physical workers and all required services are healthy."
