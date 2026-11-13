#!/usr/bin/env bash
# Shared physical-cluster environment and YARN worker-state helpers.

cinescope_set_environment() {
    export HOME=/home/hadoop
    export HADOOP_HOME=/opt/hadoop
    export HADOOP_CONF_DIR=/opt/hadoop/etc/hadoop
    export YARN_CONF_DIR=/opt/hadoop/etc/hadoop
    export HADOOP_MAPRED_HOME=/opt/hadoop
    export HADOOP_LOG_DIR=/var/log/hadoop
    export HADOOP_PID_DIR=/var/lib/hadoop/pids
    export SPARK_HOME=/opt/spark
    export SPARK_CONF_DIR=/opt/spark/conf
    export PYSPARK_PYTHON=/usr/bin/python3
    export PYSPARK_DRIVER_PYTHON=/usr/bin/python3
    export CINESCOPE_HDFS="${CINESCOPE_HDFS:-hdfs://master:8020}"
    export PATH="/opt/cinescope/.venv/bin:/opt/hadoop/bin:/opt/hadoop/sbin:/opt/spark/bin:/opt/spark/sbin:/opt/node/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

    if [[ ! -r /etc/cinescope/cluster.env ]]; then
        echo "Missing /etc/cinescope/cluster.env; run install-distributed-tools.sh first." >&2
        return 1
    fi
    # shellcheck disable=SC1091
    source /etc/cinescope/cluster.env
    if [[ -z "${JAVA_HOME:-}" || ! -x "$JAVA_HOME/bin/java" ]]; then
        echo "Configured JAVA_HOME does not contain an executable java: ${JAVA_HOME:-unset}" >&2
        return 1
    fi
    export JAVA_HOME
}

cinescope_require_hadoop_user() {
    if [[ "$(id -un)" != "hadoop" ]]; then
        echo "Run this command as the hadoop user." >&2
        return 1
    fi
}

cinescope_require_master() {
    if [[ "$(hostname -s)" != "master" ]]; then
        echo "Run this command on the physical master." >&2
        return 1
    fi
}

# Print canonical worker hostname and state from the ResourceManager REST API.
# This avoids depending on human-readable `yarn node -list` formatting.
cinescope_yarn_node_states() {
    python3 - <<'PY'
import json
import socket
import urllib.request

request = urllib.request.Request(
    "http://master:8088/ws/v1/cluster/nodes",
    headers={"Accept": "application/json"},
)
with urllib.request.urlopen(request, timeout=5) as response:
    payload = json.load(response)

raw = (payload.get("nodes") or {}).get("node")
if raw is None:
    nodes = []
elif isinstance(raw, dict):
    nodes = [raw]
elif isinstance(raw, list):
    nodes = raw
else:
    raise SystemExit("Unexpected ResourceManager nodes response")

aliases = {}
for expected in ("worker1", "worker2"):
    try:
        for item in socket.getaddrinfo(expected, None, socket.AF_INET):
            aliases[item[4][0]] = expected
    except OSError:
        pass

for node in nodes:
    if not isinstance(node, dict):
        continue
    raw_host = str(node.get("nodeHostName") or node.get("id") or "unknown")
    host_only = raw_host.rsplit(":", 1)[0] if ":" in raw_host else raw_host
    short = host_only.split(".", 1)[0].lower()
    canonical = aliases.get(host_only, short)
    if canonical not in ("worker1", "worker2"):
        try:
            canonical = aliases.get(socket.gethostbyname(host_only), canonical)
        except OSError:
            pass
    print(f"{canonical}\t{str(node.get('state') or 'UNKNOWN').upper()}")
PY
}

cinescope_wait_for_workers_running() {
    local timeout_seconds="${1:-240}"
    local deadline=$((SECONDS + timeout_seconds))
    local states state host count missing

    while (( SECONDS < deadline )); do
        if states="$(cinescope_yarn_node_states 2>/dev/null)"; then
            missing=0
            for host in worker1 worker2; do
                count="$(awk -F '\t' -v h="$host" '$1 == h {n++} END {print n+0}' <<< "$states")"
                state="$(awk -F '\t' -v h="$host" '$1 == h {s=$2} END {print s}' <<< "$states")"
                if [[ "$count" != "1" || "$state" != "RUNNING" ]]; then
                    missing=1
                fi
            done
            if (( missing == 0 )); then
                printf '%s\n' "$states"
                return 0
            fi
        fi
        sleep 2
    done

    echo "Timed out waiting for exactly one RUNNING NodeManager on each physical worker." >&2
    cinescope_yarn_node_states || true
    return 1
}

cinescope_wait_for_worker2_not_running() {
    local timeout_seconds="${1:-180}"
    local deadline=$((SECONDS + timeout_seconds))
    local states worker1_state worker2_state

    while (( SECONDS < deadline )); do
        if states="$(cinescope_yarn_node_states 2>/dev/null)"; then
            worker1_state="$(awk -F '\t' '$1 == "worker1" {s=$2} END {print s}' <<< "$states")"
            worker2_state="$(awk -F '\t' '$1 == "worker2" {s=$2} END {print s}' <<< "$states")"
            if [[ "$worker1_state" == "RUNNING" && "$worker2_state" != "RUNNING" ]]; then
                printf '%s\n' "$states"
                return 0
            fi
        fi
        sleep 2
    done

    echo "Timed out waiting for worker2 NodeManager to stop while worker1 remains RUNNING." >&2
    cinescope_yarn_node_states || true
    return 1
}

cinescope_wait_for_datanodes() {
    local expected="${1:-2}"
    local timeout_seconds="${2:-240}"
    local deadline=$((SECONDS + timeout_seconds))
    local report live

    while (( SECONDS < deadline )); do
        report="$("$HADOOP_HOME/bin/hdfs" dfsadmin -report 2>/dev/null || true)"
        live="$(sed -nE 's/^Live datanodes \(([0-9]+)\):.*/\1/p' <<< "$report" | sed -n '1p')"
        live="${live:-0}"
        if (( live >= expected )); then
            printf '%s\n' "$report"
            return 0
        fi
        sleep 2
    done

    echo "Timed out waiting for $expected live HDFS DataNodes." >&2
    "$HADOOP_HOME/bin/hdfs" dfsadmin -report || true
    return 1
}
