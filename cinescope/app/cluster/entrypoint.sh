#!/usr/bin/env bash
set -Eeuo pipefail

ROLE="${1:-master}"
export HOME=/home/hadoop

as_hadoop() {
  su -s /bin/bash hadoop -c "export HOME=/home/hadoop; export HADOOP_HOME=/opt/hadoop; export HADOOP_CONF_DIR=/opt/hadoop/etc/hadoop; export SPARK_HOME=/opt/spark; export HADOOP_LOG_DIR=/var/log/hadoop; export HADOOP_PID_DIR=/var/run/hadoop; export PATH=/opt/hadoop/bin:/opt/hadoop/sbin:/opt/spark/bin:/opt/spark/sbin:\$PATH; $*"
}

prepare_dirs() {
  mkdir -p /var/lib/hadoop/{namenode,datanode,tmp} /var/log/hadoop /var/run/hadoop /data/results
  chown -R hadoop:hadoop /var/lib/hadoop /var/log/hadoop /var/run/hadoop /data
}

wait_for_hdfs() {
  for _ in $(seq 1 60); do
    if as_hadoop 'hdfs dfs -test -d /'; then return 0; fi
    sleep 2
  done
  echo 'NameNode did not become ready within two minutes.' >&2
  return 1
}

start_master() {
  if [[ ! -f /var/lib/hadoop/namenode/current/VERSION ]]; then
    echo 'Formatting the new NameNode volume (this happens once).'
    as_hadoop 'hdfs namenode -format -force -nonInteractive'
  fi
  as_hadoop 'hdfs --daemon start namenode'
  as_hadoop 'hdfs --daemon start secondarynamenode'
  wait_for_hdfs
  # Namespace-only operations work before DataNodes join. Do not upload the
  # replicated Spark archive here: workers are gated on this service becoming
  # healthy, and an HDFS write with replication=2 needs those workers running.
  as_hadoop 'hdfs dfs -mkdir -p /spark-logs /user/hadoop'
  as_hadoop 'hdfs dfs -chown -R hadoop:hadoop /spark-logs /user/hadoop'
  as_hadoop 'yarn --daemon start resourcemanager'
  as_hadoop 'mapred --daemon start historyserver'
  as_hadoop 'start-history-server.sh'
  exec su -s /bin/bash hadoop -c 'cd /workspace && exec uvicorn api.main:app --host 0.0.0.0 --port 8000'
}

start_worker() {
  for _ in $(seq 1 60); do getent hosts master >/dev/null && break; sleep 2; done
  as_hadoop 'hdfs --daemon start datanode'
  as_hadoop 'yarn --daemon start nodemanager'
  touch /var/log/hadoop/container.log
  exec tail -F /var/log/hadoop/*.log
}

prepare_dirs
case "$ROLE" in
  master) start_master ;;
  worker) start_worker ;;
  *) echo "Usage: cinescope-entrypoint {master|worker}" >&2; exit 64 ;;
esac
