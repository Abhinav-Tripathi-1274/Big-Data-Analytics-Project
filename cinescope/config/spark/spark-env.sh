#!/usr/bin/env bash

# Installed by install-distributed-tools.sh on each applicable node.
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
export YARN_CONF_DIR=/opt/hadoop/etc/hadoop
export SPARK_HOME=/opt/spark
export SPARK_CONF_DIR=/opt/spark/conf
export PYSPARK_PYTHON=/usr/bin/python3
export PYSPARK_DRIVER_PYTHON=/usr/bin/python3
export HADOOP_LOG_DIR=/var/log/hadoop
export HADOOP_PID_DIR=/var/lib/hadoop/pids
