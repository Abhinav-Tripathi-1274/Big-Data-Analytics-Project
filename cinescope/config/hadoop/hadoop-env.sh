#!/usr/bin/env bash

# Installed by install-distributed-tools.sh on each physical PC.
if [[ -r /etc/cinescope/cluster.env ]]; then
    # shellcheck disable=SC1091
    source /etc/cinescope/cluster.env
fi

if [[ -z "${JAVA_HOME:-}" || ! -x "${JAVA_HOME}/bin/java" ]]; then
    echo "CineScope requires the configured Java 11 installation." >&2
    return 1
fi
export JAVA_HOME

export HADOOP_HOME=/opt/hadoop
export HADOOP_CONF_DIR=/opt/hadoop/etc/hadoop
export HADOOP_LOG_DIR=/var/log/hadoop
export HADOOP_PID_DIR=/var/lib/hadoop/pids
export HADOOP_COMMON_HOME="$HADOOP_HOME"
export HADOOP_HDFS_HOME="$HADOOP_HOME"
export HADOOP_YARN_HOME="$HADOOP_HOME"
export HADOOP_MAPRED_HOME="$HADOOP_HOME"
export HADOOP_COMMON_LIB_NATIVE_DIR="$HADOOP_HOME/lib/native"
export LD_LIBRARY_PATH="$HADOOP_HOME/lib/native:${LD_LIBRARY_PATH:-}"
